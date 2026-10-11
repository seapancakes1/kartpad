#include "kartpad/network/phone_pad.h"
#include "kartpad/network/phone_race.h"

#include <iostream>
#include <map>

namespace {

using namespace kartpad::phone_pad;

bool Expect(bool condition, const char *what) {
  if (!condition) std::cerr << "failed: " << what << "\n";
  return condition;
}

// A frame as a phone sends it: whole and masked.
std::string PhoneFrame(uint8_t opcode, std::string_view payload, bool fin = true, bool masked = true) {
  std::string out;
  out.push_back(static_cast<char>((fin ? 0x80 : 0) | opcode));
  const char mask[4] = {0x12, 0x34, 0x56, 0x78};
  const char maskBit = masked ? char(0x80) : 0;
  if (payload.size() < 126) {
    out.push_back(static_cast<char>(maskBit | payload.size()));
  } else {
    out.push_back(static_cast<char>(maskBit | 126));
    out.push_back(static_cast<char>(payload.size() >> 8));
    out.push_back(static_cast<char>(payload.size() & 0xFF));
  }
  if (masked) out.append(mask, 4);
  for (size_t i = 0; i < payload.size(); ++i) out.push_back(masked ? char(payload[i] ^ mask[i % 4]) : payload[i]);
  return out;
}

std::string StateBytes(uint8_t seq, uint16_t buttons, int8_t x, int8_t y) {
  return {char(StateMessage), char(seq), char(buttons & 0xFF), char(buttons >> 8), char(x), char(y), 0, 0};
}

bool Handshake() {
  bool ok = true;
  const auto empty = Sha1("");
  ok &= Expect(Base64(empty.data(), empty.size()) == "2jmj7l5rSw0yVb/vlWAYkK/YBwk=", "SHA-1 of nothing");
  ok &= Expect(WebSocketAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept key");
  const uint8_t two[] = {'h', 'i'};
  ok &= Expect(Base64(two, 2) == "aGk=", "base64 padding");
  // 64 bytes takes a second SHA-1 block for the length.
  const auto block = Sha1(std::string(64, 'a'));
  ok &= Expect(Base64(block.data(), block.size()) == "AJi6gktcFkJ716ESKlpEKiXsZE0=", "SHA-1 across blocks");
  return ok;
}

bool Requests() {
  bool ok = true;
  HttpRequest request;
  size_t consumed = 0;
  const std::string upgrade =
      "GET /ws?k=abc123&t=tok HTTP/1.1\r\nHost: 192.168.1.5:47800\r\nUpgrade: websocket\r\n"
      "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
      "origin:  http://192.168.1.5:47800 \r\nSec-WebSocket-Version: 13\r\n\r\nextra";
  ok &= Expect(ParseRequest(upgrade, request, consumed) == Parse::Done, "upgrade request parses");
  ok &= Expect(consumed == upgrade.size() - 5, "consumed stops at the end of the head");
  ok &= Expect(request.path == "/ws" && request.query == "k=abc123&t=tok", "path and query");
  ok &= Expect(QueryValue(request.query, "k") == "abc123" && QueryValue(request.query, "t") == "tok" &&
                   QueryValue(request.query, "x").empty(),
               "query values");
  ok &= Expect(IsWebSocketUpgrade(request), "is a WebSocket upgrade");
  ok &= Expect(OriginMatchesHost(request.origin, request.host), "origin matches host");
  ok &= Expect(!OriginMatchesHost("http://evil.example", request.host), "foreign origin");
  ok &= Expect(!OriginMatchesHost("https://192.168.1.5:47800", request.host), "other scheme");
  ok &= Expect(!OriginMatchesHost("", request.host) && !OriginMatchesHost("http://", ""), "missing origin");

  ok &= Expect(ParseRequest("GET / HTTP/1.1\r\nHost: x\r\n", request, consumed) == Parse::NeedMore,
               "unfinished head");
  ok &= Expect(ParseRequest("GET / HTTP/1.1\r\nHost: x\r\n\r\n", request, consumed) == Parse::Done &&
                   request.path == "/" && !IsWebSocketUpgrade(request),
               "plain page request");
  ok &= Expect(ParseRequest("GET /\r\n\r\n", request, consumed) == Parse::Bad, "no version");
  ok &= Expect(ParseRequest("GET / SPDY/3\r\n\r\n", request, consumed) == Parse::Bad, "unknown version");
  ok &= Expect(ParseRequest("GET x HTTP/1.1\r\n\r\n", request, consumed) == Parse::Bad, "relative target");
  ok &= Expect(ParseRequest("GET / HTTP/1.1\r\nNoColon\r\n\r\n", request, consumed) == Parse::Bad,
               "header without a colon");
  ok &= Expect(ParseRequest(std::string(MaxRequestBytes, 'a'), request, consumed) == Parse::Bad, "oversize head");
  std::string longHeader = "GET / HTTP/1.1\r\nX: " + std::string(MaxRequestBytes, 'a') + "\r\n\r\n";
  ok &= Expect(ParseRequest(longHeader, request, consumed) == Parse::Bad, "oversize head that ends");

  ok &= Expect(SameSecret("abcd", "abcd") && !SameSecret("abcd", "abce") && !SameSecret("abc", "abcd") &&
                   !SameSecret("", ""),
               "secret comparison");
  ok &= Expect(HeaderHasToken("keep-alive, Upgrade", "upgrade") && !HeaderHasToken("keep-alive", "upgrade"),
               "header tokens");
  const std::string response = UpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==");
  ok &= Expect(response.find("101 Switching Protocols") != std::string::npos &&
                   response.find("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != std::string::npos,
               "upgrade response");
  ok &= Expect(HttpResponse(404, "Not Found", "text/plain", "no").find("Content-Length: 2\r\n") != std::string::npos,
               "content length");
  return ok;
}

bool Frames() {
  bool ok = true;
  Frame frame;
  size_t consumed = 0;
  const std::string binary = PhoneFrame(Binary, StateBytes(1, ButtonA, 0, 0));
  ok &= Expect(ReadFrame(binary, frame, consumed) == Parse::Done && frame.opcode == Binary &&
                   consumed == binary.size() && frame.payload == StateBytes(1, ButtonA, 0, 0),
               "masked binary frame");
  // Split across reads, and two frames in one read.
  for (size_t cut = 0; cut < binary.size(); ++cut)
    ok &= Expect(ReadFrame(std::string_view(binary).substr(0, cut), frame, consumed) == Parse::NeedMore,
                 "partial frame waits");
  const std::string two = binary + PhoneFrame(Ping, "p");
  ok &= Expect(ReadFrame(two, frame, consumed) == Parse::Done && consumed == binary.size(), "first of two");
  ok &= Expect(ReadFrame(std::string_view(two).substr(consumed), frame, consumed) == Parse::Done &&
                   frame.opcode == Ping && frame.payload == "p",
               "second of two");
  const std::string medium(300, 'x');
  ok &= Expect(ReadFrame(PhoneFrame(Text, medium), frame, consumed) == Parse::Done && frame.payload == medium,
               "16-bit length");
  ok &= Expect(ReadFrame(PhoneFrame(Close, ""), frame, consumed) == Parse::Done && frame.opcode == Close,
               "close frame");

  ok &= Expect(ReadFrame(PhoneFrame(Binary, "x", true, false), frame, consumed) == Parse::Bad, "unmasked");
  ok &= Expect(ReadFrame(PhoneFrame(Binary, "x", false), frame, consumed) == Parse::Bad, "fragmented");
  ok &= Expect(ReadFrame(PhoneFrame(0x0, "x"), frame, consumed) == Parse::Bad, "continuation");
  ok &= Expect(ReadFrame(PhoneFrame(0x3, "x"), frame, consumed) == Parse::Bad, "reserved opcode");
  ok &= Expect(ReadFrame(PhoneFrame(Ping, std::string(126, 'x')), frame, consumed) == Parse::Bad,
               "long control frame");
  ok &= Expect(ReadFrame(PhoneFrame(Binary, std::string(MaxFramePayload + 1, 'x')), frame, consumed) == Parse::Bad,
               "oversize frame");
  std::string rsv = binary;
  rsv[0] = static_cast<char>(rsv[0] | 0x40);
  ok &= Expect(ReadFrame(rsv, frame, consumed) == Parse::Bad, "reserved bits");
  const std::string huge = {char(0x82), char(0xFF), 0, 0, 0, 0, 0, 0, 0, 1};
  ok &= Expect(ReadFrame(huge, frame, consumed) == Parse::Bad, "64-bit length");
  // The helper page's offer is bigger than any input message.
  const std::string offerFrame = PhoneFrame(Text, std::string(3000, 'o'));
  ok &= Expect(ReadFrame(offerFrame, frame, consumed) == Parse::Bad, "an offer is too big for an input socket");
  ok &= Expect(ReadFrame(offerFrame, frame, consumed, MaxSignalPayload) == Parse::Done && frame.payload.size() == 3000,
               "but fits the signal socket");

  const std::string out = WriteFrame(Text, "hi");
  ok &= Expect(out == std::string("\x81\x02hi"), "server frame");
  const std::string longOut = WriteFrame(Text, std::string(200, 'y'));
  ok &= Expect(longOut.size() == 204 && static_cast<uint8_t>(longOut[1]) == 126 &&
                   static_cast<uint8_t>(longOut[2]) == 0 && static_cast<uint8_t>(longOut[3]) == 200,
               "server frame with 16-bit length");
  return ok;
}

bool Messages() {
  bool ok = true;
  Message message;
  ok &= Expect(DecodeMessage(StateBytes(255, ButtonA | ButtonHome, -127, 127), message) &&
                   message.type == StateMessage && message.seq == 255 &&
                   message.state.buttons == (ButtonA | ButtonHome) && message.state.stickX == -127 &&
                   message.state.stickY == 127,
               "state message");
  ok &= Expect(DecodeMessage(StateBytes(0, 0xFFFF, -128, 0), message) && message.state.buttons == KnownButtons &&
                   message.state.stickX == -127,
               "unknown bits dropped, -128 clamped");
  ok &= Expect(DecodeMessage(std::string(1, char(LeaveMessage)), message) && message.type == LeaveMessage,
               "leave message");
  ok &= Expect(DecodeMessage(std::string{char(PingMessage), 7, 1}, message) && message.type == PingMessage, "ping");
  ok &= Expect(!DecodeMessage(std::string{char(PingMessage), 7}, message), "short ping");
  ok &= Expect(DecodeMessage(std::string{char(DelayMessage), 0x2c, 0x01}, message) && message.type == DelayMessage &&
                   message.delayMs == 300,
               "delay report");
  ok &= Expect(!DecodeMessage(std::string{char(DelayMessage), 7}, message), "short delay report");
  ok &= Expect(!DecodeMessage("", message), "empty message");
  ok &= Expect(!DecodeMessage(StateBytes(0, 0, 0, 0).substr(0, 7), message), "short state");
  ok &= Expect(!DecodeMessage(StateBytes(0, 0, 0, 0) + "x", message), "long state");
  std::string unknown = StateBytes(0, 0, 0, 0);
  unknown[0] = 9;
  ok &= Expect(!DecodeMessage(unknown, message), "unknown type");

  GamepadValues pad = ToGamepad({});
  ok &= Expect(pad.axes[sdl::LeftTrigger] == -32768 && pad.axes[sdl::RightTrigger] == -32768 &&
                   pad.axes[sdl::LeftX] == 0 && pad.axes[sdl::LeftY] == 0,
               "neutral pad");
  for (bool button : pad.buttons) ok &= Expect(!button, "neutral buttons");
  pad = ToGamepad({ButtonA | ButtonB | ButtonL | ButtonR | ButtonZ | ButtonStart | ButtonUp | ButtonHome, 127, -127});
  ok &= Expect(pad.buttons[sdl::South] && pad.buttons[sdl::East] && pad.buttons[sdl::RightShoulder] &&
                   pad.buttons[sdl::Start] && pad.buttons[sdl::DpadUp] && pad.buttons[sdl::Guide] &&
                   !pad.buttons[sdl::West] && !pad.buttons[sdl::DpadDown],
               "buttons map");
  ok &= Expect(pad.axes[sdl::LeftTrigger] == 32767 && pad.axes[sdl::RightTrigger] == 32767, "triggers pulled");
  ok &= Expect(pad.axes[sdl::LeftX] == 32767 && pad.axes[sdl::LeftY] == -32767, "stick full");
  ok &= Expect(ToGamepad({0, 64, 0}).axes[sdl::LeftX] == 64 * 32767 / 127, "stick scales");

  ok &= Expect(WelcomeMessage(1, 2, "ab") == R"({"t":"welcome","phone":1,"player":2,"token":"ab"})", "welcome");
  ok &= Expect(ColorMessage(255, 0, 16) == R"({"t":"color","rgb":"#ff0010"})", "colour");
  ok &= Expect(ByeMessage("full") == R"({"t":"bye","reason":"full"})", "bye");
  ok &= Expect(RaceMessage(RaceView::Start) == R"({"t":"race","view":"start"})" &&
                   RaceMessage(RaceView::Unknown) == R"({"t":"race","view":"unknown"})" &&
                   RaceMessage(RaceView::Fall) == R"({"t":"race","view":"fall"})",
               "race view");
  return ok;
}

bool Signals() {
  bool ok = true;
  Signal signal;
  ok &= Expect(ParseSignal("t=\nv=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n", signal) && signal.token.empty() &&
                   signal.offer.rfind("v=0\r\n", 0) == 0,
               "new phone's offer");
  ok &= Expect(ParseSignal("t=0a1b\nv=0\nx", signal) && signal.token == "0a1b" && signal.offer == "v=0\nx", "resume token");
  ok &= Expect(!ParseSignal("v=0\r\n", signal), "no token line");
  ok &= Expect(!ParseSignal("t=\nhello", signal), "not an SDP offer");
  ok &= Expect(!ParseSignal("t=ZZ\nv=0\r\n", signal), "token that isn't hex");
  ok &= Expect(!ParseSignal("t=" + std::string(65, 'a') + "\nv=0\r\n", signal), "token too long");
  ok &= Expect(!ParseSignal("t=\nv=0\r\n" + std::string(MaxSignalPayload, 'x'), signal), "offer too long");
  ok &= Expect(!ParseSignal("t=abc", signal), "no newline");
  return ok;
}

bool Peers() {
  bool ok = true;
  const auto v4 = [](int a, int b, int c, int d) { return uint32_t(a) << 24 | uint32_t(b) << 16 | uint32_t(c) << 8 | uint32_t(d); };
  ok &= Expect(IsLanIPv4(v4(192, 168, 1, 20)) && IsLanIPv4(v4(10, 0, 0, 2)) && IsLanIPv4(v4(172, 16, 0, 1)) &&
                   IsLanIPv4(v4(172, 31, 255, 1)) && IsLanIPv4(v4(169, 254, 3, 4)) &&
                   IsLanIPv4(v4(100, 64, 0, 1)) && IsLanIPv4(v4(100, 127, 255, 255)) && IsLanIPv4(v4(127, 0, 0, 1)),
               "local IPv4");
  ok &= Expect(!IsLanIPv4(v4(8, 8, 8, 8)) && !IsLanIPv4(v4(172, 32, 0, 1)) && !IsLanIPv4(v4(192, 169, 0, 1)) &&
                   !IsLanIPv4(v4(100, 128, 0, 1)) && !IsLanIPv4(v4(11, 0, 0, 1)),
               "public IPv4");
  std::array<uint8_t, 16> a{};
  a[15] = 1;
  ok &= Expect(IsLanIPv6(a), "IPv6 loopback");
  a = {0xfe, 0x80};
  ok &= Expect(IsLanIPv6(a), "IPv6 link-local");
  a = {0xfd, 0x12};
  ok &= Expect(IsLanIPv6(a), "IPv6 unique local");
  a = {0x20, 0x01, 0x0d, 0xb8};
  ok &= Expect(!IsLanIPv6(a), "IPv6 global");
  a = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 0, 9};
  ok &= Expect(IsLanIPv6(a), "IPv4-mapped local");
  a[12] = 8;
  ok &= Expect(!IsLanIPv6(a), "IPv4-mapped public");
  return ok;
}

bool SessionTable() {
  bool ok = true;
  Sessions sessions;
  auto first = sessions.Join("", "t0", 0);
  ok &= Expect(first.index == 0 && !first.resumed && sessions[0].token == "t0", "first phone");
  ok &= Expect(sessions.Update(0, {ButtonA, 0, 0}, 10), "press changes input");
  ok &= Expect(!sessions.Update(0, {ButtonA, 0, 0}, 60), "repeat doesn't");
  // Quiet for a second: let go.
  ok &= Expect(sessions.Advance(1000).idle.empty(), "not idle yet");
  auto changes = sessions.Advance(1061);
  ok &= Expect(changes.idle.size() == 1 && changes.idle[0] == 0 && sessions[0].state == PadState{}, "idle");
  ok &= Expect(sessions.Advance(1100).idle.empty(), "idle once");
  ok &= Expect(sessions.Update(0, {ButtonA, 0, 0}, 1200), "input after idle");
  ok &= Expect(sessions.Update(0, {0, 0, 0}, 1210), "release");
  ok &= Expect(sessions.Update(0, {0, 0, 0}, 4000) == false, "same neutral");

  // Dropped, then back with its token: same phone.
  sessions.Disconnected(0, 5000);
  ok &= Expect(!sessions[0].connected && sessions.Advance(30000).expired.empty(), "held");
  auto back = sessions.Join("t0", "unused", 30000);
  ok &= Expect(back.index == 0 && back.resumed && !back.replaced && sessions[0].token == "t0", "resumed");
  // The same phone connects again before the old socket closes.
  auto again = sessions.Join("t0", "unused", 30100);
  ok &= Expect(again.index == 0 && again.replaced, "replaced");

  // A wrong token is a new phone.
  ok &= Expect(sessions.Join("nope", "t1", 30200).index == 1, "second phone");
  ok &= Expect(sessions.Join("", "t2", 30300).index == 2, "third phone");
  ok &= Expect(sessions.Join("", "t3", 30400).index == 3, "fourth phone");
  ok &= Expect(sessions.Join("", "t4", 30500).index == -1, "fifth phone turned away");

  // Leaving frees the phone at once; a dropped phone expires after the hold.
  sessions.Delay(2, 12);
  ok &= Expect(sessions[2].delayMs == 12, "delay kept");
  sessions.Leave(2);
  ok &= Expect(!sessions[2].used && sessions.Join("t2", "t5", 30600).index == 2 && sessions[2].token == "t5",
               "left phone's token no longer works");
  sessions.Disconnected(1, 31000);
  ok &= Expect(sessions.Advance(31000 + HoldMs).expired.empty(), "hold lasts");
  changes = sessions.Advance(31001 + HoldMs);
  bool expiredOne = false;
  for (int index : changes.expired) expiredOne |= index == 1;
  ok &= Expect(expiredOne && !sessions[1].used, "expired");
  return ok;
}

// A race in memory, laid out as base Mario Kart Wii's: the director with its pads,
// and the race manager with its racers.
struct FakeRace {
  std::map<uint32_t, uint32_t> words;
  static constexpr uint32_t director = 0x80900000, manager = 0x80a00000, players = 0x80a01000;
  FakeRace(uint32_t stage, bool paused = false) {
    namespace r = race;
    words[r::DirectorPointer] = director;
    words[r::RaceManagerPointer] = manager;
    words[manager + r::ManagerStage] = stage;
    words[manager + r::ManagerPlayers] = players;
    words[director + r::DirectorPaused] = paused ? 0x01000000 : 0;
    for (uint32_t pad = 0; pad < 4; ++pad) {
      const uint32_t controller = director + r::DirectorGCControllers + pad * r::GCControllerSize;
      words[controller + r::GCControllerChannel] = pad;
    }
  }
  // Racer i, played on this Mac with KPadPlayer kpad on GameCube pad `pad`, or a
  // computer racer when kpad is -1.
  void Racer(int i, int kpad, int pad, bool finished = false) {
    namespace r = race;
    const uint32_t player = 0x80b00000 + 0x100 * i;
    words[players + 4 * i] = player;
    words[player + r::PlayerFlags] = finished ? r::FinishedFlag | 1 : 1;
    if (kpad < 0) {
      words[player + r::PlayerKPad] = 0x80c00000;
      return;
    }
    const uint32_t kpadAddress = director + r::DirectorPlayers + kpad * r::KPadPlayerSize;
    words[player + r::PlayerKPad] = kpadAddress;
    words[kpadAddress + r::KPadController] = director + r::DirectorGCControllers + pad * r::GCControllerSize;
  }
  // Racer i's kart: its state's first and third flag words, and the frames left
  // after landing from a respawn.
  void Kart(int i, uint32_t flags0, uint32_t flags2 = 0, int16_t postLand = 0) {
    namespace r = race;
    const uint32_t karts = 0x80d00000, objects = karts - 0x100, kart = karts + 0x1000 * i;
    const uint32_t accessor = kart + 0x1c, state = kart + 0x200, move = kart + 0x400;
    words[r::KartManagerPointer] = karts - 0x200;
    words[karts - 0x200 + r::KartManagerObjects] = objects;
    words[objects + 4 * i] = kart;
    words[kart] = accessor;
    words[accessor + r::AccessorState] = state;
    words[accessor + r::AccessorMove] = move;
    words[state + r::StateFlags] = flags0;
    words[state + r::StateFlags + 8] = flags2;
    words[move + r::MovePostLandTimer] = static_cast<uint32_t>(static_cast<uint16_t>(postLand)) << 16 | 30;
  }
  race::Views Views() const {
    return race::ReadViews([this](uint32_t address, uint32_t &value) {
      const auto found = words.find(address);
      value = found == words.end() ? 0 : found->second;
      return true;
    });
  }
};

bool RaceViews() {
  bool ok = true;
  using V = RaceView;
  FakeRace menus(race::Racing);
  menus.words[race::RaceManagerPointer] = 0;
  ok &= Expect(menus.Views() == race::Views{V::Menus, V::Menus, V::Menus, V::Menus}, "no race: menus");
  menus.words[race::DirectorPointer] = 0;
  ok &= Expect(menus.Views() == race::Views{V::Menus, V::Menus, V::Menus, V::Menus}, "starting up: menus");

  // Player 1 (pad 0) and player 3 (pad 2) race against a computer racer.
  FakeRace start(race::Countdown);
  start.Racer(0, 0, 0);
  start.Racer(1, -1, 0);
  start.Racer(2, 1, 2);
  ok &= Expect(start.Views() == race::Views{V::Start, V::Menus, V::Start, V::Menus}, "countdown: the start, for racers only");
  start.words[start.manager + race::ManagerStage] = race::Racing;
  ok &= Expect(start.Views() == race::Views{V::Race, V::Menus, V::Race, V::Menus}, "racing");
  start.Racer(2, 1, 2, true);
  ok &= Expect(start.Views() == race::Views{V::Race, V::Menus, V::Menus, V::Menus}, "a finished racer is back in the menus");
  start.words[start.director + race::DirectorPaused] = 0x01000000;
  ok &= Expect(start.Views() == race::Views{V::Menus, V::Menus, V::Menus, V::Menus}, "paused: menus");

  // Player 1 falls off the course: off it, with Lakitu, dropped, then the frames
  // after landing for his boost. Accelerating and braking (flags 0 and 1) and the
  // boost itself running (the low half of the timer word) aren't a fall.
  FakeRace fall(race::Racing);
  fall.Racer(0, 0, 0);
  fall.Racer(1, 1, 1);
  fall.Kart(1, 0);
  fall.Kart(0, 1 | 2);
  ok &= Expect(fall.Views() == race::Views{V::Race, V::Race, V::Menus, V::Menus}, "driving: the race");
  fall.Kart(0, 1 << 4);
  ok &= Expect(fall.Views() == race::Views{V::Fall, V::Race, V::Menus, V::Menus}, "off the course: a fall");
  fall.Kart(0, 0, 1 << 13);
  ok &= Expect(fall.Views()[0] == V::Fall, "Lakitu carries the kart: a fall");
  fall.Kart(0, 0, 1 << 14);
  ok &= Expect(fall.Views()[0] == V::Fall, "dropped: a fall");
  fall.Kart(0, 1 << 18, 0, 3);
  ok &= Expect(fall.Views()[0] == V::Fall, "just landed: still a fall, for the boost");
  fall.Kart(0, 1 << 18, 1 << 12 | 1 << 15, 0);
  ok &= Expect(fall.Views()[0] == V::Race, "landed: the race");
  fall.words[fall.manager + race::ManagerStage] = race::Countdown;
  fall.Kart(0, 0, 1 << 13);
  ok &= Expect(fall.Views()[0] == V::Start, "a fall only counts in the race");
  fall.words[fall.manager + race::ManagerStage] = race::Racing;
  fall.words[race::KartManagerPointer] = 0x12345678;
  ok &= Expect(fall.Views() == race::Views{V::Race, V::Race, V::Menus, V::Menus}, "karts outside RAM: the race");

  FakeRace odd(7);
  odd.Racer(0, 0, 0);
  ok &= Expect(odd.Views()[0] == V::Unknown, "a stage that can't be: unknown");
  FakeRace elsewhere(race::Racing);
  elsewhere.words[race::DirectorPointer] = 0x12345678;
  ok &= Expect(elsewhere.Views()[0] == V::Unknown, "a director outside RAM: unknown");
  return ok;
}

}  // namespace

int main() {
  bool ok = true;
  ok &= Handshake();
  ok &= Requests();
  ok &= Frames();
  ok &= Messages();
  ok &= Signals();
  ok &= Peers();
  ok &= SessionTable();
  ok &= RaceViews();
  return ok ? 0 : 1;
}
