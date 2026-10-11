// Phones as controllers, with nothing to install. Connect a Controller → Phone starts a small web
// server on the local network and shows a QR code; the phone plays as an SDL virtual gamepad named
// "Phone 1"–"Phone 4", which players, joining, toasts and the Controllers screen treat like any other
// controller. The server runs from the first time it's wanted until KartPad quits, with a new link
// each launch. A phone connects one of two ways:
// - With tilt, when the build says where web/phone is published over HTTPS (KARTPAD_PHONE_PAGE_URL,
//   cmake/KartPadPhoneLink.cmake): the code opens that page, where the browser lets it read the
//   phone's motion. It can't reach this Mac's plain-HTTP address, so it opens this server's helper
//   page (/link) in a second tab, which passes its signed WebRTC offer here (/signal) and the answer
//   back, then closes. The phone then talks to the Mac directly over two WebRTC data channels
//   (libdatachannel): "pad" (unordered, no resends) for input and pings, and "control" (reliable)
//   for everything else.
// - Touch only, offline, and the only way without a published page: the code opens the page this
//   server serves itself (KartPadPhonePage.inc.mm), which joins over a WebSocket.
// Either way the phone proves it has this launch's key, which only the code carries, without sending
// it (phone_pad.h, "Joining"). The protocol itself is in kartpad/network/phone_pad.h. Network work
// runs on its own queue, which also sets the virtual pads' buttons and axes (SDL's joystick lock
// makes that safe from there).
// Attaching and detaching pads and choosing their players happen on the main thread, as the rest
// of the roster does. Each phone is also told what its player is doing (the menus, the start of a
// race, the race), read from the game's memory on the game loop (kartpad/network/phone_race.h), so
// the page shows the controls for it.
// Included by KartPadMacShell.mm after KartPadControllerRoster.inc.mm.

#import <CoreImage/CoreImage.h>
#import <Network/Network.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

#include <atomic>
#include <memory>
#include <vector>

#include <rtc/rtc.h>

#include "kartpad/network/phone_pad.h"
#include "kartpad/network/phone_race.h"
#include "memory.h"

namespace kpp = kartpad::phone_pad;

static_assert(kpp::sdl::South == SDL_GAMEPAD_BUTTON_SOUTH && kpp::sdl::East == SDL_GAMEPAD_BUTTON_EAST &&
              kpp::sdl::West == SDL_GAMEPAD_BUTTON_WEST && kpp::sdl::North == SDL_GAMEPAD_BUTTON_NORTH &&
              kpp::sdl::Guide == SDL_GAMEPAD_BUTTON_GUIDE && kpp::sdl::Start == SDL_GAMEPAD_BUTTON_START &&
              kpp::sdl::RightShoulder == SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER &&
              kpp::sdl::DpadUp == SDL_GAMEPAD_BUTTON_DPAD_UP && kpp::sdl::DpadDown == SDL_GAMEPAD_BUTTON_DPAD_DOWN &&
              kpp::sdl::DpadLeft == SDL_GAMEPAD_BUTTON_DPAD_LEFT && kpp::sdl::DpadRight == SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
              "phone_pad's SDL button numbers");
static_assert(kpp::sdl::LeftX == SDL_GAMEPAD_AXIS_LEFTX && kpp::sdl::LeftY == SDL_GAMEPAD_AXIS_LEFTY &&
              kpp::sdl::LeftTrigger == SDL_GAMEPAD_AXIS_LEFT_TRIGGER &&
              kpp::sdl::RightTrigger == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER && kpp::sdl::AxisCount == SDL_GAMEPAD_AXIS_COUNT,
              "phone_pad's SDL axis numbers");

static constexpr const char *KPPhonePreferredPort = "47800";
static constexpr uint64_t KPPhoneRequestDeadlineMs = 5000;  // a connection that hasn't asked for anything or joined
static constexpr uint64_t KPPhoneSilenceMs = 5000;          // a phone that has stopped sending (it sends every 50 ms)
// A WebRTC phone goes quiet when its screen locks, and its link can outlast a short lock, which saves
// a tap on Reconnect (coming back needs the helper tab again). Its buttons are let go after a second.
static constexpr uint64_t KPPhoneRtcSilenceMs = 30000;
static constexpr uint64_t KPPhoneJoinDeadlineMs = 15000;    // a WebRTC link that never opened its channels

static uint64_t KPPhoneNow() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000; }

static std::string KPPhoneRandomHex(size_t bytes) {
  std::vector<uint8_t> random(bytes);
  arc4random_buf(random.data(), random.size());
  static constexpr char kDigits[] = "0123456789abcdef";
  std::string out;
  for (uint8_t b : random) out += {kDigits[b >> 4], kDigits[b & 15]};
  return out;
}

static dispatch_queue_t KPPhoneQueue() {
  static dispatch_queue_t queue = dispatch_queue_create("com.kartpad.phone-controllers", DISPATCH_QUEUE_SERIAL);
  return queue;
}

#pragma mark Network queue

// One TCP connection (a page request, a phone's WebSocket, or the helper page's signal socket), or
// one phone's WebRTC link.
struct KPPhoneLink {
  nw_connection_t connection;  // nil for a WebRTC link
  std::string from;            // the peer's address, for phone_pad's limits on waiting connections
  std::string buffer;
  bool upgraded = false;
  bool signal = false;    // the helper page's socket: one WebRTC offer in, its answer out
  bool proven = false;    // it proved it has this launch's key (a join or a signal)
  bool answered = false;  // nothing more is read: a response or a goodbye is on its way out
  bool closed = false;
  int phone = -1;         // the session it drives, once joined
  uint64_t openedAt = 0, lastHeard = 0;
  std::string nonce;      // a WebSocket's, from its hello, for the join's proof
  // A WebRTC link: libdatachannel's peer connection, the "pad" and "control" channels, every
  // channel the phone opened (each to delete), its key in KPPhoneRtcLinks, the phone's id until it
  // joins, and the helper's socket waiting for the answer.
  int peer = 0, pad = 0, control = 0;
  std::vector<int> channels;
  uintptr_t serial = 0;
  bool joined = false;
  std::string phoneId;
  std::weak_ptr<KPPhoneLink> signalLink;
};
using KPPhoneLinkRef = std::shared_ptr<KPPhoneLink>;

// Everything below is used on KPPhoneQueue() only, except where noted.
static nw_listener_t KPPhoneListener;
static dispatch_source_t KPPhoneTimer;
static std::string KPPhoneKey;
static kpp::Sessions KPPhoneSessions;
static kpp::Replays KPPhoneReplays;
static std::vector<KPPhoneLinkRef> KPPhoneLinks;
static std::array<KPPhoneLinkRef, kpp::MaxPhones> KPPhoneDriver;  // the connection each phone plays through
static std::array<bool, kpp::MaxPhones> KPPhoneRumbling{};
static std::string KPPhoneControllerOrigin;  // the HTTPS controller page's origin, for the helper page
// libdatachannel calls back on its own threads with a link's serial (as its user pointer).
static std::unordered_map<uintptr_t, std::weak_ptr<KPPhoneLink>> KPPhoneRtcLinks;
static uintptr_t KPPhoneNextSerial = 0;
// Read from any thread.
static std::atomic<uint16_t> KPPhonePort{0};
static std::atomic<bool> KPPhoneFailed{false};
// Each phone's virtual pad; set on the main thread and read on the queue, both under SDL's joystick lock.
static std::array<SDL_Joystick *, kpp::MaxPhones> KPPhoneJoysticks{};
// What each player is doing in the game (phone_pad::RaceView), by slot, from the game loop; whether one
// of KartPad's screens has the controllers, from the main thread; each phone's player (1-4, 0 for
// none), from the main thread; and each phone's link delay, from the queue, for the Connect screen.
static std::array<std::atomic<uint8_t>, kpp::race::Channels> KPPhoneRaceViews{};
static std::atomic<bool> KPPhoneScreenUp{false}, KPPhoneStarted{false};
static std::array<std::atomic<int>, kpp::MaxPhones> KPPhonePlayers{};
static std::array<std::atomic<int>, kpp::MaxPhones> KPPhoneDelays{};
static std::array<std::atomic<bool>, kpp::MaxPhones> KPPhoneLinked{};  // connected now, not just holding its player
// On the queue: the view each phone was last told, -1 until its welcome.
static std::array<int, kpp::MaxPhones> KPPhoneToldView{-1, -1, -1, -1};

static void KPPhoneApply(int phone, const kpp::PadState &state) {
  const kpp::GamepadValues values = kpp::ToGamepad(state);
  SDL_LockJoysticks();
  if (SDL_Joystick *joystick = KPPhoneJoysticks[phone]) {
    for (int button = 0; button < kpp::sdl::ButtonCount; ++button)
      SDL_SetJoystickVirtualButton(joystick, button, values.buttons[button]);
    for (int axis = 0; axis < kpp::sdl::AxisCount; ++axis) SDL_SetJoystickVirtualAxis(joystick, axis, values.axes[axis]);
  }
  SDL_UnlockJoysticks();
}

static void KPPhoneSendText(const KPPhoneLinkRef &link, const std::string &text);
static void KPPhoneFinish(const KPPhoneLinkRef &link);

static void KPPhoneClose(const KPPhoneLinkRef &link) {
  if (link->closed) return;
  link->closed = true;
  link->answered = true;
  const int phone = link->phone;
  if (phone >= 0 && KPPhoneDriver[phone] == link) {
    // Dropped: the phone keeps its pad and player for a while, holding nothing, to come back to.
    KPPhoneDriver[phone] = nullptr;
    KPPhoneLinked[phone] = false;
    KPPhoneSessions.Disconnected(phone, KPPhoneNow());
    KPPhoneApply(phone, {});
  }
  if (link->peer) {
    // A link that never got as far as its answer leaves the helper page waiting: tell it.
    if (const KPPhoneLinkRef helper = link->signalLink.lock(); helper && !helper->closed) {
      KPPhoneSendText(helper, "error:no connection");
      KPPhoneFinish(helper);
    }
    // Every channel, as deleting the peer connection doesn't delete them. libdatachannel waits for
    // callbacks in flight; those only queue work here, so this can't block.
    for (int channel : link->channels) rtcDeleteDataChannel(channel);
    rtcDeletePeerConnection(link->peer);
    link->peer = link->pad = link->control = 0;
    link->channels.clear();
    KPPhoneRtcLinks.erase(link->serial);
  } else {
    nw_connection_cancel(link->connection);
  }
  std::erase(KPPhoneLinks, link);
}

static void KPPhoneSend(const KPPhoneLinkRef &link, const std::string &bytes, void (^sent)(void) = nil) {
  if (link->closed) return;
  dispatch_data_t data = dispatch_data_create(bytes.data(), bytes.size(), KPPhoneQueue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  nw_connection_send(link->connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
    (void)error;
    if (sent) sent();
  });
}
// A text message: on a WebRTC link, over its reliable channel.
static void KPPhoneSendText(const KPPhoneLinkRef &link, const std::string &text) {
  if (link->closed) return;
  if (link->peer) {
    if (link->control) rtcSendMessage(link->control, text.c_str(), -1);
    return;
  }
  KPPhoneSend(link, kpp::WriteFrame(kpp::Text, text));
}

// Closes a WebSocket politely: a close frame, then the connection.
static void KPPhoneFinish(const KPPhoneLinkRef &link) {
  link->answered = true;
  KPPhoneLinkRef keep = link;
  KPPhoneSend(link, kpp::WriteFrame(kpp::Close, std::string("\x03\xe8", 2)), ^{ KPPhoneClose(keep); });
}

// A plain HTTP answer, then the connection closes.
static void KPPhoneRespond(const KPPhoneLinkRef &link, int status, const char *reason, const char *type, std::string_view body) {
  link->answered = true;
  KPPhoneLinkRef keep = link;
  KPPhoneSend(link, kpp::HttpResponse(status, reason, type, body), ^{ KPPhoneClose(keep); });
}

// Tells a phone why it's being let go (phone_pad::ByeMessage), then closes the WebSocket.
static void KPPhoneSendAway(const KPPhoneLinkRef &link, std::string_view reason) {
  link->answered = true;
  KPPhoneSendText(link, kpp::ByeMessage(reason));
  if (link->peer) {
    // Give the goodbye a moment on the reliable channel before the link goes.
    KPPhoneLinkRef keep = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), KPPhoneQueue(), ^{ KPPhoneClose(keep); });
    return;
  }
  KPPhoneFinish(link);
}

static std::string KPPhoneColorMessage(int slot) {
  const unsigned rgb = KPPlayerColors[slot];
  return kpp::ColorMessage((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
}

// A phone with a pad, for the Connect screen's list: its number (0-3), its player (1-4, 0 for none),
// its link delay (0 until it reports one), and whether it's connected or away, holding its player.
struct KPPhoneEntry {
  int phone = 0, player = 0, delayMs = 0;
  bool linked = false;
};

@interface KPPhoneServer : NSObject <KPRosterListener>
+ (instancetype)shared;
- (void)start;
// The phone's links, nil until the server is listening and this Mac is on a network: the HTTPS
// controller page with tilt (nil too when no page is set), and the touch-only page served here.
- (NSString *)tiltURL;
- (NSString *)touchURL;
- (BOOL)hasTiltPage;
- (NSString *)problem;  // why there's no link, for the Connect screen
- (void)drawCode:(NSString *)url in:(CGContextRef)c rect:(CGRect)rect;
- (void)seatPhone:(int)phone then:(void (^)(int slot))done;
- (void)removePhone:(int)phone;
- (void)sendAway:(int)phone;  // the Connect screen's Remove
- (std::vector<KPPhoneEntry>)entries;
- (NSString *)status;
@end

// The controls a phone should show: its player's race view, or the menus while it has no player or
// one of KartPad's screens has the controllers.
static kpp::RaceView KPPhoneView(int phone) {
  const int player = KPPhonePlayers[phone].load();
  if (player <= 0 || KPPhoneScreenUp.load()) return kpp::RaceView::Menus;
  return static_cast<kpp::RaceView>(KPPhoneRaceViews[player - 1].load());
}

// Tells a phone its view when it changes, or always (just after its welcome).
static void KPPhoneTellView(int phone, bool always) {
  const KPPhoneLinkRef &link = KPPhoneDriver[phone];
  if (link == nullptr || (!always && KPPhoneToldView[phone] < 0)) return;
  const kpp::RaceView view = KPPhoneView(phone);
  if (!always && KPPhoneToldView[phone] == static_cast<int>(view)) return;
  KPPhoneToldView[phone] = static_cast<int>(view);
  KPPhoneSendText(link, kpp::RaceMessage(view));
}

// Lets a phone go for good: it left, or the Mac removed it.
static void KPPhoneLetGo(const KPPhoneLinkRef &link, int phone, std::string_view reason) {
  KPPhoneSessions.Leave(phone);
  KPPhoneDriver[phone] = nullptr;
  KPPhoneDelays[phone] = 0;
  KPPhoneLinked[phone] = false;
  link->phone = -1;
  KPPhoneApply(phone, {});
  KPPhoneSendAway(link, reason);
  dispatch_async(dispatch_get_main_queue(), ^{ [KPPhoneServer.shared removePhone:phone]; });
}

// The phone proved it has this launch's key (a join on its WebSocket, or the signal before its WebRTC
// link opened): its session, then its pad and a player (on the main thread), then the welcome.
static void KPPhoneJoin(const KPPhoneLinkRef &link, const std::string &phoneId) {
  link->joined = true;
  const kpp::Sessions::Joined joined = KPPhoneSessions.Join(phoneId, KPPhoneNow());
  if (joined.index < 0) {
    KPPhoneSendAway(link, "full");
    return;
  }
  const int phone = joined.index;
  if (KPPhoneLinkRef old = KPPhoneDriver[phone]; old && old != link) {
    old->phone = -1;
    KPPhoneSendAway(old, "replaced");
  }
  KPPhoneDriver[phone] = link;
  link->phone = phone;
  KPPhoneRumbling[phone] = false;
  KPPhoneToldView[phone] = -1;
  KPPhoneLinked[phone] = true;
  // The session starts with nothing pressed, and so does the pad, whatever the old link was holding.
  KPPhoneApply(phone, {});
  const bool resumed = joined.resumed;
  KPPhoneLinkRef keep = link;
  dispatch_async(dispatch_get_main_queue(), ^{
    [KPPhoneServer.shared seatPhone:phone then:^(int slot) {
      dispatch_async(KPPhoneQueue(), ^{
        if (KPPhoneDriver[phone] != keep) return;
        KPPhoneSendText(keep, kpp::WelcomeMessage(phone + 1, slot + 1, resumed));
        if (slot >= 0) KPPhoneSendText(keep, KPPhoneColorMessage(slot));
        KPPhoneTellView(phone, true);
      });
    }];
  });
}

// A WebSocket's first message: the join, proving the key with the nonce of this socket's hello.
static void KPPhoneJoinRequest(const KPPhoneLinkRef &link, const std::string &text) {
  const int version = kpp::MessageVersion(text, "join");
  kpp::Join join;
  if (version >= 0 && version != kpp::ProtocolVersion) {
    KPPhoneSendAway(link, "version");
  } else if (version < 0 || !kpp::ParseJoin(text, "join", join)) {
    KPPhoneClose(link);
  } else if (!kpp::Proves(KPPhoneKey, kpp::JoinProven(join, link->nonce), join.proof)) {
    KPPhoneSendAway(link, "expired");  // a link from an earlier launch, with its key
  } else {
    link->proven = true;
    KPPhoneJoin(link, join.phone);
  }
}

// A binary message from a phone; channel is the WebRTC channel it came on.
static void KPPhoneMessage(const KPPhoneLinkRef &link, const std::string &payload, int channel = 0) {
  const int phone = link->phone;
  kpp::Message message;
  if (phone < 0 || KPPhoneDriver[phone] != link || !kpp::DecodeMessage(payload, message)) return;
  if (message.type == kpp::PingMessage) {
    if (!link->peer) KPPhoneSend(link, kpp::WriteFrame(kpp::Binary, payload));
    else if (channel) rtcSendMessage(channel, payload.data(), static_cast<int>(payload.size()));
    return;
  }
  if (message.type == kpp::LeaveMessage) {
    KPPhoneLetGo(link, phone, "left");
    return;
  }
  if (message.type == kpp::DelayMessage) {
    KPPhoneSessions.Delay(phone, message.delayMs);
    KPPhoneDelays[phone] = message.delayMs;
    return;
  }
  if (KPPhoneSessions.Update(phone, message.seq, message.state, KPPhoneNow())) KPPhoneApply(phone, message.state);
}

static void KPPhoneSignal(const KPPhoneLinkRef &signalLink, const std::string &text);

static void KPPhoneReadFrames(const KPPhoneLinkRef &link) {
  while (!link->answered) {
    kpp::Frame frame;
    size_t consumed = 0;
    const kpp::Parse parse =
        kpp::ReadFrame(link->buffer, frame, consumed, link->signal ? kpp::MaxSignalPayload : kpp::MaxFramePayload);
    if (parse == kpp::Parse::NeedMore) return;
    if (parse == kpp::Parse::Bad) {
      KPPhoneClose(link);
      return;
    }
    link->buffer.erase(0, consumed);
    link->lastHeard = KPPhoneNow();
    if (frame.opcode == kpp::Binary) {
      if (link->proven) KPPhoneMessage(link, frame.payload);
      else KPPhoneClose(link);  // input before joining
    } else if (frame.opcode == kpp::Text && !link->proven) {
      if (link->signal) KPPhoneSignal(link, frame.payload);
      else KPPhoneJoinRequest(link, frame.payload);
    } else if (frame.opcode == kpp::Ping) {
      KPPhoneSend(link, kpp::WriteFrame(kpp::Pong, frame.payload));
    } else if (frame.opcode == kpp::Close) {
      link->answered = true;
      KPPhoneLinkRef keep = link;
      KPPhoneSend(link, kpp::WriteFrame(kpp::Close, ""), ^{ KPPhoneClose(keep); });
    }
  }
}

static void KPPhoneServeRequest(const KPPhoneLinkRef &link) {
  kpp::HttpRequest request;
  size_t consumed = 0;
  const kpp::Parse parse = kpp::ParseRequest(link->buffer, request, consumed);
  if (parse == kpp::Parse::NeedMore) return;
  if (parse == kpp::Parse::Bad) {
    KPPhoneRespond(link, 400, "Bad Request", "text/plain", "Bad request");
    return;
  }
  link->buffer.erase(0, consumed);
  if (request.path == "/ws" || request.path == "/signal") {
    if (!kpp::IsWebSocketUpgrade(request)) {
      KPPhoneRespond(link, 400, "Bad Request", "text/plain", "Bad request");
    } else if (!kpp::OriginMatchesHost(request.origin, request.host)) {
      // Another page: only the ones served here open these.
      KPPhoneRespond(link, 403, "Forbidden", "text/plain", "Scan the code in KartPad again.");
    } else {
      // The key is checked by what comes next: a join proving it with this hello's nonce, or a signal.
      KPPhoneSend(link, kpp::UpgradeResponse(request.webSocketKey));
      link->upgraded = true;
      link->signal = request.path == "/signal";
      link->lastHeard = KPPhoneNow();
      link->nonce = KPPhoneRandomHex(16);
      KPPhoneSendText(link, kpp::HelloMessage(link->nonce));
      KPPhoneReadFrames(link);
    }
  } else if (request.method == "GET" && request.path == "/") {
    KPPhoneRespond(link, 200, "OK", "text/html; charset=utf-8", std::string_view(KPPhonePage, sizeof KPPhonePage - 1));
  } else if (request.method == "GET" && request.path == "/link" && !KPPhoneControllerOrigin.empty()) {
    std::string page(KPPhoneHelperPage, sizeof KPPhoneHelperPage - 1);
    const std::string placeholder = "{{CONTROLLER_ORIGIN}}";
    page.replace(page.find(placeholder), placeholder.size(), KPPhoneControllerOrigin);
    KPPhoneRespond(link, 200, "OK", "text/html; charset=utf-8", page);
  } else {
    KPPhoneRespond(link, 404, "Not Found", "text/plain", "Not found");
  }
}

static void KPPhoneReceive(const KPPhoneLinkRef &link) {
  std::weak_ptr<KPPhoneLink> weak = link;
  nw_connection_receive(link->connection, 1, 4096,
                        ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
    (void)context;
    KPPhoneLinkRef live = weak.lock();
    if (live == nullptr || live->closed) return;
    if (content && !live->answered)
      dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
        (void)region, (void)offset;
        live->buffer.append(static_cast<const char *>(bytes), size);
        return true;
      });
    if (!live->answered) {
      if (live->upgraded) KPPhoneReadFrames(live);
      else KPPhoneServeRequest(live);
    }
    if (live->closed) return;
    if (error || complete) {
      KPPhoneClose(live);
      return;
    }
    KPPhoneReceive(live);
  });
}

// An address as phone_pad has them (IPv4 mapped into IPv6).
static kpp::Address KPPhoneAddressOf(const sockaddr *address) {
  kpp::Address out{};
  if (address->sa_family == AF_INET) out = kpp::MappedIPv4(ntohl(reinterpret_cast<const sockaddr_in *>(address)->sin_addr.s_addr));
  else if (address->sa_family == AF_INET6) memcpy(out.data(), &reinterpret_cast<const sockaddr_in6 *>(address)->sin6_addr, out.size());
  return out;
}

static std::string KPPhoneAddressText(const kpp::Address &address) {
  char text[INET6_ADDRSTRLEN] = {};
  if (kpp::IsMappedIPv4(address)) inet_ntop(AF_INET, address.data() + 12, text, sizeof text);
  else inet_ntop(AF_INET6, address.data(), text, sizeof text);
  return text;
}

// The subnets this Mac's interfaces are on, but not loopback or tunnels (point to point), for
// phone_pad's OnNetwork. A netmask's sockaddr can leave out its trailing zero bytes (sa_len).
static std::vector<kpp::Subnet> KPPhoneSubnets() {
  std::vector<kpp::Subnet> subnets;
  ifaddrs *list = nullptr;
  if (getifaddrs(&list) != 0) return subnets;
  for (ifaddrs *entry = list; entry; entry = entry->ifa_next) {
    const sockaddr *address = entry->ifa_addr, *mask = entry->ifa_netmask;
    if (address == nullptr || mask == nullptr || !(entry->ifa_flags & IFF_UP) ||
        (entry->ifa_flags & (IFF_LOOPBACK | IFF_POINTOPOINT)) ||
        (address->sa_family != AF_INET && address->sa_family != AF_INET6))
      continue;
    const bool v4 = address->sa_family == AF_INET;
    const size_t at = v4 ? offsetof(sockaddr_in, sin_addr) : offsetof(sockaddr_in6, sin6_addr), size = v4 ? 4 : 16;
    kpp::Subnet subnet;
    subnet.address = KPPhoneAddressOf(address);
    if (v4) std::fill(subnet.mask.begin(), subnet.mask.begin() + 12, 0xff);
    if (mask->sa_len > at)
      memcpy(subnet.mask.data() + 16 - size, reinterpret_cast<const uint8_t *>(mask) + at, std::min<size_t>(size, mask->sa_len - at));
    subnets.push_back(subnet);
  }
  freeifaddrs(list);
  return subnets;
}

// phone_pad's limits on connections that haven't proved the key yet: the oldest go to make room.
static void KPPhoneMakeRoom(const std::string &from) {
  while (true) {
    std::vector<KPPhoneLinkRef> links;
    std::vector<kpp::Waiting> waiting;
    for (const KPPhoneLinkRef &link : KPPhoneLinks) {
      if (link->peer || link->proven || link->closed) continue;
      links.push_back(link);
      waiting.push_back({link->from, link->openedAt});
    }
    const int drop = kpp::WaitingToDrop(waiting, from);
    if (drop < 0) return;
    KPPhoneClose(links[drop]);
  }
}

static void KPPhoneAccept(nw_connection_t connection) {
  nw_endpoint_t remote = nw_connection_copy_endpoint(connection);
  const sockaddr *address =
      remote && nw_endpoint_get_type(remote) == nw_endpoint_type_address ? nw_endpoint_get_address(remote) : nullptr;
  const kpp::Address peer = address ? KPPhoneAddressOf(address) : kpp::Address{};
  if (address == nullptr || (address->sa_family != AF_INET && address->sa_family != AF_INET6) ||
      !kpp::OnNetwork(peer, KPPhoneSubnets())) {
    nw_connection_cancel(connection);
    return;
  }
  auto link = std::make_shared<KPPhoneLink>();
  link->from = KPPhoneAddressText(peer);
  KPPhoneMakeRoom(link->from);
  link->connection = connection;
  link->openedAt = KPPhoneNow();
  KPPhoneLinks.push_back(link);
  std::weak_ptr<KPPhoneLink> weak = link;
  nw_connection_set_queue(connection, KPPhoneQueue());
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
    (void)error;
    if (state != nw_connection_state_failed && state != nw_connection_state_cancelled) return;
    if (KPPhoneLinkRef live = weak.lock()) KPPhoneClose(live);
  });
  nw_connection_start(connection);
  KPPhoneReceive(link);
}

// Every 100 ms: let go of a quiet phone's buttons, remove pads whose phone didn't come back, close
// connections that stopped talking or never joined, and tell phones what their players are doing.
static void KPPhoneTick() {
  const uint64_t now = KPPhoneNow();
  const kpp::Sessions::Changes changes = KPPhoneSessions.Advance(now);
  for (int phone : changes.idle) KPPhoneApply(phone, {});
  for (int phone : changes.expired)
    dispatch_async(dispatch_get_main_queue(), ^{ [KPPhoneServer.shared removePhone:phone]; });
  for (int phone = 0; phone < kpp::MaxPhones; ++phone) KPPhoneTellView(phone, false);
  const std::vector<KPPhoneLinkRef> links = KPPhoneLinks;
  for (const KPPhoneLinkRef &link : links) {
    if (link->answered) continue;
    bool quiet;
    if (link->peer) quiet = link->joined ? now - link->lastHeard > KPPhoneRtcSilenceMs : now - link->openedAt > KPPhoneJoinDeadlineMs;
    else if (!link->proven) quiet = now - link->openedAt > KPPhoneRequestDeadlineMs;
    else quiet = now - link->lastHeard > KPPhoneSilenceMs;
    if (quiet) KPPhoneClose(link);
  }
}

static void KPPhoneListen(const char *port) {
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) {
    nw_tcp_options_set_no_delay(tcp, true);
  });
  nw_parameters_set_reuse_local_address(parameters, true);
  nw_listener_t listener = nw_listener_create_with_port(port, parameters);
  if (listener == nil) {
    KPPhoneFailed = true;
    return;
  }
  KPPhoneListener = listener;
  const bool preferred = strcmp(port, "0") != 0;
  nw_listener_set_queue(listener, KPPhoneQueue());
  nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
    if (state == nw_listener_state_ready) {
      KPPhonePort = nw_listener_get_port(KPPhoneListener);
      NSLog(@"[KartPad] Phone controllers on port %u", (unsigned)KPPhonePort.load());
    } else if (state == nw_listener_state_failed) {
      NSLog(@"[KartPad] Phone controller listener failed (port %s): error %d", preferred ? KPPhonePreferredPort : "any",
            error ? nw_error_get_error_code(error) : 0);
      KPPhonePort = 0;
      nw_listener_cancel(KPPhoneListener);
      // Something else has the usual port: any free one does (the QR code says which).
      if (preferred) KPPhoneListen("0");
      else KPPhoneFailed = true;
    }
  });
  nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) { KPPhoneAccept(connection); });
  nw_listener_start(listener);
}

#pragma mark WebRTC links

static KPPhoneLinkRef KPPhoneRtcLink(uintptr_t serial) {
  const auto found = KPPhoneRtcLinks.find(serial);
  if (found == KPPhoneRtcLinks.end()) return nullptr;
  KPPhoneLinkRef link = found->second.lock();
  return link && !link->closed ? link : nullptr;
}

static std::string KPPhoneChannelName(int channel) {
  char label[32] = {};
  return rtcGetDataChannelLabel(channel, label, sizeof label) > 0 ? std::string(label) : std::string();
}

static void KPPhoneRtcDrop(const KPPhoneLinkRef &link, int channel) {
  std::erase(link->channels, channel);
  rtcDeleteDataChannel(channel);
}

// A channel opened: the page's "pad" or "control" (whose opening is when the phone joins); any other,
// or a second of one, goes.
static void KPPhoneRtcOpened(const KPPhoneLinkRef &link, int channel, const std::string &name) {
  int *slot = name == "pad" ? &link->pad : name == "control" ? &link->control : nullptr;
  if (slot && *slot == channel) return;
  if (slot == nullptr || *slot) {
    KPPhoneRtcDrop(link, channel);
    return;
  }
  *slot = channel;
  link->lastHeard = KPPhoneNow();
  if (slot == &link->control && !link->joined) KPPhoneJoin(link, link->phoneId);
}

// libdatachannel's callbacks, on its threads: copy what's needed and carry on on the phone queue.
static void RTC_API KPPhoneRtcGathering(int peer, rtcGatheringState state, void *pointer) {
  (void)peer;
  if (state != RTC_GATHERING_COMPLETE) return;
  const auto serial = reinterpret_cast<uintptr_t>(pointer);
  dispatch_async(KPPhoneQueue(), ^{
    const KPPhoneLinkRef link = KPPhoneRtcLink(serial);
    if (link == nullptr) return;
    // With every candidate gathered, the answer is complete: back through the helper page, which
    // has nothing more to wait for.
    std::vector<char> sdp(kpp::MaxSignalPayload);
    const int size = rtcGetLocalDescription(link->peer, sdp.data(), static_cast<int>(sdp.size()));
    const KPPhoneLinkRef helper = link->signalLink.lock();
    link->signalLink.reset();
    if (helper && !helper->closed) {
      KPPhoneSendText(helper, size > 0 ? std::string(sdp.data()) : std::string("error:no answer"));
      KPPhoneFinish(helper);
    }
    if (size <= 0) KPPhoneClose(link);
  });
}

static void RTC_API KPPhoneRtcState(int peer, rtcState state, void *pointer) {
  (void)peer;
  // Disconnected can recover; failed and closed don't. A phone that just went quiet is closed by
  // KPPhoneTick, as on a WebSocket.
  if (state != RTC_FAILED && state != RTC_CLOSED) return;
  const auto serial = reinterpret_cast<uintptr_t>(pointer);
  dispatch_async(KPPhoneQueue(), ^{
    if (const KPPhoneLinkRef link = KPPhoneRtcLink(serial)) KPPhoneClose(link);
  });
}

static void RTC_API KPPhoneRtcOpen(int channel, void *pointer) {
  const auto serial = reinterpret_cast<uintptr_t>(pointer);
  const std::string name = KPPhoneChannelName(channel);
  dispatch_async(KPPhoneQueue(), ^{
    if (const KPPhoneLinkRef link = KPPhoneRtcLink(serial)) KPPhoneRtcOpened(link, channel, name);
  });
}

static void RTC_API KPPhoneRtcClosed(int channel, void *pointer) {
  const auto serial = reinterpret_cast<uintptr_t>(pointer);
  dispatch_async(KPPhoneQueue(), ^{
    const KPPhoneLinkRef link = KPPhoneRtcLink(serial);
    if (link == nullptr) return;
    if (channel == link->control || channel == link->pad) KPPhoneClose(link);
    else if (std::find(link->channels.begin(), link->channels.end(), channel) != link->channels.end()) KPPhoneRtcDrop(link, channel);
  });
}

static void RTC_API KPPhoneRtcMessage(int channel, const char *message, int size, void *pointer) {
  if (size < 0) return;  // text: phones only send binary
  const auto serial = reinterpret_cast<uintptr_t>(pointer);
  const std::string payload(message, static_cast<size_t>(size));
  dispatch_async(KPPhoneQueue(), ^{
    const KPPhoneLinkRef link = KPPhoneRtcLink(serial);
    if (link == nullptr || link->answered) return;
    link->lastHeard = KPPhoneNow();
    KPPhoneMessage(link, payload, channel);
  });
}

static void RTC_API KPPhoneRtcChannel(int peer, int channel, void *pointer) {
  (void)peer;
  const auto serial = reinterpret_cast<uintptr_t>(pointer);
  // Every channel the phone makes is the link's to delete (deleting the peer connection doesn't), or
  // goes at once if the link has. Queued before its opening below.
  dispatch_async(KPPhoneQueue(), ^{
    if (const KPPhoneLinkRef link = KPPhoneRtcLink(serial)) link->channels.push_back(channel);
    else rtcDeleteDataChannel(channel);
  });
  rtcSetUserPointer(channel, pointer);
  // A channel the phone made is usually open by the time it's announced: libdatachannel then calls
  // its open callback as soon as it's set.
  rtcSetOpenCallback(channel, KPPhoneRtcOpen);
  rtcSetClosedCallback(channel, KPPhoneRtcClosed);
  rtcSetMessageCallback(channel, KPPhoneRtcMessage);
}

// The helper page's signal: once it proves the key, a WebRTC link for the phone, whose answer goes
// back the same way (KPPhoneRtcGathering). Host candidates only: no STUN or relay servers, so the
// link stays on this network or doesn't happen. A refusal says why once, as "error:" and a word.
static void KPPhoneSignal(const KPPhoneLinkRef &signalLink, const std::string &text) {
  const auto refuse = [&](const char *why) {
    KPPhoneSendText(signalLink, std::string("error:") + why);
    KPPhoneFinish(signalLink);
  };
  const int version = kpp::MessageVersion(text, "signal");
  kpp::Join signal;
  if (version >= 0 && version != kpp::ProtocolVersion) return refuse("version");
  if (version < 0 || !kpp::ParseJoin(text, "signal", signal)) return refuse("bad offer");
  if (!kpp::Proves(KPPhoneKey, kpp::SignalProven(signal), signal.proof)) return refuse("expired");
  if (!KPPhoneReplays.Fresh(signal.proof)) return refuse("used");
  signalLink->proven = true;
  const auto linking = std::count_if(KPPhoneLinks.begin(), KPPhoneLinks.end(),
                                     [](const KPPhoneLinkRef &link) { return link->peer && !link->joined; });
  if (static_cast<size_t>(linking) >= kpp::MaxLinking) return refuse("busy");
  rtcConfiguration config{};
  const int peer = rtcCreatePeerConnection(&config);
  if (peer < 0) return refuse("no webrtc");
  signalLink->answered = true;  // one offer per socket
  auto link = std::make_shared<KPPhoneLink>();
  link->peer = peer;
  link->proven = true;
  link->from = signalLink->from;
  link->serial = ++KPPhoneNextSerial;
  link->phoneId = signal.phone;
  link->openedAt = link->lastHeard = KPPhoneNow();
  link->signalLink = signalLink;
  KPPhoneLinks.push_back(link);
  KPPhoneRtcLinks[link->serial] = link;
  void *pointer = reinterpret_cast<void *>(link->serial);
  rtcSetUserPointer(peer, pointer);
  rtcSetStateChangeCallback(peer, KPPhoneRtcState);
  rtcSetGatheringStateChangeCallback(peer, KPPhoneRtcGathering);
  rtcSetDataChannelCallback(peer, KPPhoneRtcChannel);
  if (rtcSetRemoteDescription(peer, signal.offer.c_str(), "offer") < 0) {
    link->signalLink.reset();  // told here, not again as the link closes
    KPPhoneClose(link);
    refuse("bad offer");
  }
}

static void RTC_API KPPhoneRtcLog(rtcLogLevel level, const char *message) {
  (void)level;
  NSLog(@"[KartPad] WebRTC: %s", message);
}

static bool SDLCALL KPPhoneRumble(void *userdata, Uint16 low, Uint16 high) {
  const int phone = static_cast<int>(reinterpret_cast<intptr_t>(userdata));
  const bool on = low || high;
  dispatch_async(KPPhoneQueue(), ^{
    if (KPPhoneRumbling[phone] == on) return;
    KPPhoneRumbling[phone] = on;
    if (const KPPhoneLinkRef &link = KPPhoneDriver[phone]) KPPhoneSendText(link, kpp::RumbleMessage(on));
  });
  return true;
}

// KartPad is quitting: tell every phone ("closed", so its page says so instead of reconnecting), and
// give the goodbyes a moment to leave. Waits a third of a second at most.
static void KPPhoneSayGoodbye() {
  static std::atomic<bool> said{false};
  if (!KPPhoneStarted.load() || said.exchange(true)) return;
  dispatch_semaphore_t gone = dispatch_semaphore_create(0);
  dispatch_async(KPPhoneQueue(), ^{
    dispatch_group_t sent = dispatch_group_create();
    bool rtc = false;
    for (const KPPhoneLinkRef &link : KPPhoneDriver) {
      if (link == nullptr || link->closed) continue;
      link->answered = true;
      const std::string bye = kpp::ByeMessage("closed");
      if (link->peer) {
        KPPhoneSendText(link, bye);
        rtc = true;
      } else {
        dispatch_group_enter(sent);
        KPPhoneSend(link, kpp::WriteFrame(kpp::Text, bye), ^{ dispatch_group_leave(sent); });
      }
    }
    // A WebRTC message is sent from libdatachannel's threads: a moment more for those.
    dispatch_group_notify(sent, KPPhoneQueue(), ^{
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (rtc ? 50 : 0) * NSEC_PER_MSEC), KPPhoneQueue(),
                     ^{ dispatch_semaphore_signal(gone); });
    });
  });
  dispatch_semaphore_wait(gone, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC));
}

// Every way out of the game goes through SDL's quit (the window's close, Quit, restarting); AppKit's
// is for quitting without a game window.
static bool SDLCALL KPPhoneQuitWatch(void *userdata, SDL_Event *event) {
  (void)userdata;
  if (event->type == SDL_EVENT_QUIT) KPPhoneSayGoodbye();
  return true;
}

#pragma mark Game loop

// Ten times a second once phones are on: what each player is doing, from the game's memory.
static void KPPhoneRaceTick() {
  static uint64_t lastRead;
  static kpp::race::Views logged{};
  const uint64_t now = KPPhoneNow();
  if (!KPPhoneStarted.load(std::memory_order_relaxed) || now - lastRead < 100) return;
  lastRead = now;
  const kpp::race::Views views =
      kpp::race::ReadViews([](uint32_t address, uint32_t &value) { return Memory::TryRead32(address, value); });
  for (size_t slot = 0; slot < views.size(); ++slot) KPPhoneRaceViews[slot] = static_cast<uint8_t>(views[slot]);
  if (views == logged) return;
  logged = views;
  const auto &kNames = kpp::RaceViewNames;
  AppendSessionLine([NSString stringWithFormat:@"phoneRace=%s,%s,%s,%s", kNames[int(views[0])], kNames[int(views[1])],
                                               kNames[int(views[2])], kNames[int(views[3])]]);
}

#pragma mark Main thread

static BOOL KPPhoneOverlayActive();                // KartPadControllersScreen.inc.mm
extern "C" bool KartPadControllersVisible();       // KartPadMacMiis.inc.mm

// Where the HTTPS controller page (web/phone in this repository) is published: the build's
// KARTPAD_PHONE_PAGE_URL (cmake/KartPadPhoneLink.cmake, empty unless a build sets it), overridable with
// `defaults write dev.kartpad.app KartPadPhonePageURL <https URL>`. With neither, or an empty value,
// phones get the touch-only page this Mac serves, and tilt isn't offered.
#ifndef KARTPAD_PHONE_PAGE_URL
#define KARTPAD_PHONE_PAGE_URL ""
#endif
static NSString *const KPPhonePageURLKey = @"KartPadPhonePageURL";
static NSString *const KPPhoneDefaultPageURL = @KARTPAD_PHONE_PAGE_URL;

static NSURL *KPPhonePageURL() {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:KPPhonePageURLKey];
  NSString *text = [value isKindOfClass:NSString.class] ? value : KPPhoneDefaultPageURL;
  NSURLComponents *components = text.length ? [NSURLComponents componentsWithString:text] : nil;
  if (![components.scheme isEqualToString:@"https"] || components.host.length == 0) return nil;
  components.fragment = nil;
  return components.URL;
}

// scheme://host[:port], as browsers report a page's origin. Only plain host characters get through,
// since it's written into the helper page's script.
static std::string KPPhoneOrigin(NSURL *page) {
  if (page == nil) return {};
  NSString *origin = page.port ? [NSString stringWithFormat:@"https://%@:%@", page.host, page.port]
                               : [NSString stringWithFormat:@"https://%@", page.host];
  NSCharacterSet *allowed =
      [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/"];
  if ([origin rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return {};
  return origin.lowercaseString.UTF8String;
}

// The address phones reach this Mac on, for the code: the best IPv4 one by phone_pad's AddressRank,
// Wi-Fi or Ethernet first, public addresses included (phones on the same subnet may connect).
static NSString *KPPhoneAddress() {
  ifaddrs *list = nullptr;
  if (getifaddrs(&list) != 0) return nil;
  NSString *best = nil;
  int bestRank = 0;
  for (ifaddrs *entry = list; entry; entry = entry->ifa_next) {
    if (entry->ifa_addr == nullptr || entry->ifa_addr->sa_family != AF_INET) continue;
    if (!(entry->ifa_flags & IFF_UP) || !(entry->ifa_flags & IFF_RUNNING) || (entry->ifa_flags & IFF_LOOPBACK)) continue;
    const in_addr address = reinterpret_cast<const sockaddr_in *>(entry->ifa_addr)->sin_addr;
    const int rank = kpp::AddressRank(entry->ifa_name, ntohl(address.s_addr), entry->ifa_flags & IFF_POINTOPOINT);
    if (rank > bestRank) {
      char text[INET_ADDRSTRLEN];
      inet_ntop(AF_INET, &address, text, sizeof text);
      best = @(text);
      bestRank = rank;
    }
  }
  freeifaddrs(list);
  return best;
}

// The QR code's modules, row by row from the top (CoreImage makes it, at medium error correction).
static std::vector<bool> KPPhoneQRModules(NSString *text, int &size) {
  size = 0;
  CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
  [filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
  [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
  CIImage *image = filter.outputImage;
  if (image == nil) return {};
  const int width = (int)image.extent.size.width;
  CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
  CGImageRef rendered = [context createCGImage:image fromRect:image.extent];
  if (rendered == nullptr || width <= 0) return {};
  std::vector<uint8_t> gray(static_cast<size_t>(width) * width, 255);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
  CGContextRef bitmap = CGBitmapContextCreate(gray.data(), width, width, 8, width, space, kCGImageAlphaNone);
  CGColorSpaceRelease(space);
  if (bitmap) {
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationNone);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, width), rendered);
    CGContextRelease(bitmap);
  }
  CGImageRelease(rendered);
  std::vector<bool> modules(gray.size());
  for (size_t i = 0; i < gray.size(); ++i) modules[i] = gray[i] < 128;
  size = width;
  return modules;
}

@implementation KPPhoneServer {
  BOOL _started;
  NSTimer *_screenTimer;
  NSString *_key;
  NSURL *_page;
  std::array<SDL_JoystickID, kpp::MaxPhones> _pads;
  std::array<int, kpp::MaxPhones> _toldSlot;  // the player each phone was last told about
  NSString *_codeText;
  std::vector<bool> _code;
  int _codeSize;
  NSString *_address;
  NSTimeInterval _addressAt;
}

+ (instancetype)shared {
  static KPPhoneServer *server;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ server = [KPPhoneServer new]; });
  return server;
}

- (instancetype)init {
  if ((self = [super init])) {
    _pads.fill(0);
    _toldSlot.fill(-2);
  }
  return self;
}

- (void)start {
  if (_started) return;
  _started = YES;
  const std::string key = KPPhoneRandomHex(16);
  _key = @(key.c_str());
  _page = KPPhonePageURL();
  const std::string origin = KPPhoneOrigin(_page);
  if (origin.empty()) _page = nil;
  rtcInitLogger(RTC_LOG_WARNING, KPPhoneRtcLog);
  [KPControllerRoster.shared.listeners addObject:self];
  KPPhoneStarted = true;
  SDL_AddEventWatch(KPPhoneQuitWatch, nullptr);
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                                              usingBlock:^(NSNotification *note) {
    (void)note;
    KPPhoneSayGoodbye();
  }];
  // While one of KartPad's screens has the controllers, phones show the menus' controls. (Screens that
  // pause the game stop the game loop, so this is looked at here.)
  _screenTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
    KPPhoneScreenUp = KPPhoneOverlayActive() || KartPadControllersVisible();
  }];
  dispatch_async(KPPhoneQueue(), ^{
    KPPhoneKey = key;
    KPPhoneControllerOrigin = origin;
    KPPhoneListen(KPPhonePreferredPort);
    KPPhoneTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, KPPhoneQueue());
    dispatch_source_set_timer(KPPhoneTimer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), 100 * NSEC_PER_MSEC,
                              20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(KPPhoneTimer, ^{ KPPhoneTick(); });
    dispatch_resume(KPPhoneTimer);
  });
  AppendSessionLine(@"phoneControllers=started");
}

- (NSString *)address {
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - _addressAt > 2) {
    _address = KPPhoneAddress();
    _addressAt = now;
  }
  return _address;
}

- (NSString *)touchURL {
  const uint16_t port = KPPhonePort.load();
  NSString *address = self.address;
  if (!_started || port == 0 || address == nil) return nil;
  return [NSString stringWithFormat:@"http://%@:%u/#%@", address, (unsigned)port, _key];
}

- (BOOL)hasTiltPage { return _page != nil; }

// The page, with where to find this Mac and this launch's key after the # (which browsers never
// send to the page's host).
- (NSString *)tiltURL {
  const uint16_t port = KPPhonePort.load();
  NSString *address = self.address;
  if (!_started || _page == nil || port == 0 || address == nil) return nil;
  return [NSString stringWithFormat:@"%@#mac=%@:%u&k=%@", _page.absoluteString, address, (unsigned)port, _key];
}

- (NSString *)problem {
  if (KPPhoneFailed.load()) return @"KartPad couldn’t start listening for phones.";
  if (KPPhonePort.load() == 0) return @"Getting ready…";
  if (self.address == nil) return @"Connect this Mac to Wi‑Fi or Ethernet first.";
  return nil;
}

// The link as a QR code: black modules on white with the standard four-module margin, drawn as
// squares so it stays sharp at any size (the overlay is flipped, so rows go down from the top).
- (void)drawCode:(NSString *)url in:(CGContextRef)c rect:(CGRect)rect {
  if (url && ![url isEqualToString:_codeText]) {
    _code = KPPhoneQRModules(url, _codeSize);
    _codeText = url;
  }
  KPFill(c, rect, 0xffffff, 18);
  if (url == nil || _codeSize == 0) return;
  const CGFloat quiet = 4, side = std::min(rect.size.width, rect.size.height);
  const CGFloat module = side / (_codeSize + 2 * quiet);
  const CGFloat x0 = CGRectGetMidX(rect) - module * _codeSize / 2, y0 = CGRectGetMidY(rect) - module * _codeSize / 2;
  CGContextSaveGState(c);
  CGContextSetShouldAntialias(c, false);
  KPSetInk(c, 0x000000);
  for (int row = 0; row < _codeSize; ++row)
    for (int column = 0; column < _codeSize; ++column)
      if (_code[static_cast<size_t>(row) * _codeSize + column])
        CGContextAddRect(c, CGRectMake(x0 + column * module, y0 + row * module, module, module));
  CGContextFillPath(c);
  CGContextRestoreGState(c);
}

// A phone joined (or came back): give it its pad, then a player if it has none and one is free,
// the way Connect a Controller seats a new controller. Aurora only sees the pad once the game loop
// has handled SDL's "gamepad added", so this waits for the roster to list it.
- (void)seatPhone:(int)phone then:(void (^)(int slot))done {
  if (_pads[phone] == 0) {
    static const char *const names[kpp::MaxPhones] = {"Phone 1", "Phone 2", "Phone 3", "Phone 4"};
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name = names[phone];  // distinct, so each phone keeps its own player and settings
    desc.userdata = reinterpret_cast<void *>(static_cast<intptr_t>(phone));
    desc.Rumble = KPPhoneRumble;
    const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
    SDL_Joystick *joystick = id ? SDL_OpenJoystick(id) : nullptr;
    if (joystick == nullptr) {
      NSLog(@"[KartPad] Phone %d: no virtual controller: %s", phone + 1, SDL_GetError());
      if (id) SDL_DetachVirtualJoystick(id);
      done(-1);
      return;
    }
    SDL_LockJoysticks();
    KPPhoneJoysticks[phone] = joystick;
    SDL_UnlockJoysticks();
    _pads[phone] = id;
    AppendSessionLine([NSString stringWithFormat:@"phoneJoined=%d", phone + 1]);
  }
  [self seatPhone:phone attempts:40 then:done];
}

- (void)seatPhone:(int)phone attempts:(int)attempts then:(void (^)(int slot))done {
  const SDL_JoystickID id = _pads[phone];
  KPControllerRoster *roster = KPControllerRoster.shared;
  [roster refresh];
  KPPadDevice *device = id ? [roster deviceWithIdentifier:[NSString stringWithFormat:@"sdl:%u", id]] : nil;
  if (device == nil) {
    if (id && attempts > 0)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self->_pads[phone] == id) [self seatPhone:phone attempts:attempts - 1 then:done];
        else done(-1);
      });
    else done(-1);
    return;
  }
  // As a controller joining by a press does (KPAutoJoinTick): the first free player, or the keyboard's
  // while the keyboard just follows free players.
  const BOOL keyboardFloats = ![[NSUserDefaults.standardUserDefaults objectForKey:KPKeyboardPlayerKey] isKindOfClass:NSNumber.class];
  if (device.slot < 0 && ![roster.benched containsObject:device.identifier])
    for (int slot = 0; slot < KPPlayerCount; ++slot) {
      KPPadDevice *occupant = [roster deviceInSlot:slot];
      if (occupant == nil || (occupant.isKeyboard && keyboardFloats)) {
        [roster move:device toSlot:slot];
        break;
      }
    }
  _toldSlot[phone] = device.slot;
  KPPhonePlayers[phone] = device.slot + 1;
  done(device.slot);
}

- (void)removePhone:(int)phone {
  const SDL_JoystickID id = _pads[phone];
  if (id == 0) return;
  SDL_LockJoysticks();
  SDL_Joystick *joystick = KPPhoneJoysticks[phone];
  KPPhoneJoysticks[phone] = nullptr;
  SDL_UnlockJoysticks();
  if (joystick) SDL_CloseJoystick(joystick);
  SDL_DetachVirtualJoystick(id);
  _pads[phone] = 0;
  _toldSlot[phone] = -2;
  KPPhonePlayers[phone] = 0;
  AppendSessionLine([NSString stringWithFormat:@"phoneLeft=%d", phone + 1]);
}

- (void)sendAway:(int)phone {
  dispatch_async(KPPhoneQueue(), ^{
    if (const KPPhoneLinkRef link = KPPhoneDriver[phone]) {
      KPPhoneLetGo(link, phone, "removed");
      return;
    }
    // Holding its player while it's away: there's no one to tell.
    KPPhoneSessions.Leave(phone);
    KPPhoneDelays[phone] = 0;
    dispatch_async(dispatch_get_main_queue(), ^{ [self removePhone:phone]; });
  });
}

- (std::vector<KPPhoneEntry>)entries {
  std::vector<KPPhoneEntry> entries;
  for (int phone = 0; phone < kpp::MaxPhones; ++phone)
    if (_pads[phone]) entries.push_back({phone, KPPhonePlayers[phone].load(), KPPhoneDelays[phone].load(), KPPhoneLinked[phone].load()});
  return entries;
}

// A phone moved to another player (Controllers, Stop playing, Player Order): tell it, so it shows
// the right number and colour.
- (void)rosterChanged {
  KPControllerRoster *roster = KPControllerRoster.shared;
  for (int phone = 0; phone < kpp::MaxPhones; ++phone) {
    if (_pads[phone] == 0 || _toldSlot[phone] == -2) continue;
    KPPadDevice *device = [roster deviceWithIdentifier:[NSString stringWithFormat:@"sdl:%u", _pads[phone]]];
    const int slot = device ? device.slot : -1;
    if (slot == _toldSlot[phone]) continue;
    _toldSlot[phone] = slot;
    KPPhonePlayers[phone] = slot + 1;
    dispatch_async(KPPhoneQueue(), ^{
      const KPPhoneLinkRef &link = KPPhoneDriver[phone];
      if (link == nullptr) return;
      KPPhoneSendText(link, kpp::PlayerMessage(slot + 1));
      if (slot >= 0) KPPhoneSendText(link, KPPhoneColorMessage(slot));
    });
  }
}

// For automated checks: the link, and each phone's player and what its pad is pressing as SDL sees it
// (SDL gamepad button bits, the stick's x and the triggers, -1 to 1).
- (NSString *)status {
  NSMutableString *text = [NSMutableString stringWithFormat:@"url=%@ tilt=%@ problem=%@", self.touchURL ?: @"-",
                                                            self.tiltURL ?: @"-", self.problem ?: @"-"];
  KPControllerRoster *roster = KPControllerRoster.shared;
  [roster refresh];
  for (int phone = 0; phone < kpp::MaxPhones; ++phone) {
    if (_pads[phone] == 0) continue;
    KPPadDevice *device = [roster deviceWithIdentifier:[NSString stringWithFormat:@"sdl:%u", _pads[phone]]];
    [text appendFormat:@" phone%d=sdl:%u,player=%d,buttons=0x%llx,x=%.2f,l=%.2f,r=%.2f,view=%d,delay=%d", phone + 1,
                       _pads[phone], device ? device.slot + 1 : 0, device ? (unsigned long long)device.buttons : 0ull,
                       device ? device->axes[SDL_GAMEPAD_AXIS_LEFTX] : 0.f, device ? device->axes[SDL_GAMEPAD_AXIS_LEFT_TRIGGER] : 0.f,
                       device ? device->axes[SDL_GAMEPAD_AXIS_RIGHT_TRIGGER] : 0.f, static_cast<int>(KPPhoneView(phone)),
                       KPPhoneDelays[phone].load()];
  }
  return text;
}
@end

// A phone in landscape with the controller page on it, for the Connect screen.
static void KPDrawPhoneArt(CGContextRef c, CGRect r, unsigned accent) {
  const CGFloat w = std::min(r.size.width, r.size.height * 2.1), h = w / 2.1;
  const CGRect body = CGRectMake(CGRectGetMidX(r) - w / 2, CGRectGetMidY(r) - h / 2, w, h);
  KPFill(c, body, 0x1d2027, h * 0.18);
  const CGRect screen = CGRectInset(body, h * 0.07, h * 0.07);
  KPFill(c, screen, 0x2a2f39, h * 0.12);
  const CGFloat u = screen.size.height;
  KPSetInk(c, 0xffffff, 0.18);
  CGContextFillEllipseInRect(c, CGRectMake(screen.origin.x + u * 0.22, screen.origin.y + u * 0.28, u * 0.5, u * 0.5));
  KPSetInk(c, accent);
  CGContextFillEllipseInRect(c, CGRectMake(screen.origin.x + u * 0.37, screen.origin.y + u * 0.43, u * 0.2, u * 0.2));
  CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(screen) - u * 0.55, screen.origin.y + u * 0.42, u * 0.42, u * 0.42));
  KPSetInk(c, 0xffffff, 0.35);
  CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(screen) - u * 0.95, screen.origin.y + u * 0.5, u * 0.3, u * 0.3));
  CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(screen) - u * 0.45, screen.origin.y + u * 0.1, u * 0.24, u * 0.24));
}
