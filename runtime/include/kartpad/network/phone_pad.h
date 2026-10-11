#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

// Phones as controllers: a phone on the same network opens KartPad's controller
// page in its browser, then sends its buttons and stick, either over a WebSocket
// to the page the Mac serves (touch only), or over a WebRTC data channel from the
// HTTPS page that can also read tilt (the Mac's helper page swaps the WebRTC
// details). This header holds the parts with no platform code: the HTTP request
// head, the WebSocket handshake and frames (RFC 6455, server side), the phone's
// messages, the WebRTC signal, what a phone's state becomes on an SDL gamepad,
// who may connect, and the phone sessions.
namespace kartpad::phone_pad {

// ---- SHA-1 and base64, for Sec-WebSocket-Accept ----

inline std::array<uint8_t, 20> Sha1(std::string_view data) {
  uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
  std::string message(data);
  const uint64_t bits = static_cast<uint64_t>(data.size()) * 8;
  message.push_back(static_cast<char>(0x80));
  while (message.size() % 64 != 56) message.push_back('\0');
  for (int i = 7; i >= 0; --i) message.push_back(static_cast<char>((bits >> (i * 8)) & 0xff));
  const auto rotl = [](uint32_t v, int n) { return (v << n) | (v >> (32 - n)); };
  for (size_t chunk = 0; chunk < message.size(); chunk += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
      const auto *p = reinterpret_cast<const uint8_t *>(message.data() + chunk + i * 4);
      w[i] = (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
    }
    for (int i = 16; i < 80; ++i) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; ++i) {
      uint32_t f, k;
      if (i < 20) f = (b & c) | (~b & d), k = 0x5A827999;
      else if (i < 40) f = b ^ c ^ d, k = 0x6ED9EBA1;
      else if (i < 60) f = (b & c) | (b & d) | (c & d), k = 0x8F1BBCDC;
      else f = b ^ c ^ d, k = 0xCA62C1D6;
      const uint32_t t = rotl(a, 5) + f + e + k + w[i];
      e = d, d = c, c = rotl(b, 30), b = a, a = t;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e;
  }
  std::array<uint8_t, 20> out{};
  for (int i = 0; i < 20; ++i) out[i] = static_cast<uint8_t>(h[i / 4] >> (24 - (i % 4) * 8));
  return out;
}

inline std::string Base64(const uint8_t *data, size_t size) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  for (size_t i = 0; i < size; i += 3) {
    const uint32_t n = (uint32_t(data[i]) << 16) | (i + 1 < size ? uint32_t(data[i + 1]) << 8 : 0) |
                       (i + 2 < size ? uint32_t(data[i + 2]) : 0);
    out.push_back(kAlphabet[(n >> 18) & 63]);
    out.push_back(kAlphabet[(n >> 12) & 63]);
    out.push_back(i + 1 < size ? kAlphabet[(n >> 6) & 63] : '=');
    out.push_back(i + 2 < size ? kAlphabet[n & 63] : '=');
  }
  return out;
}

inline std::string WebSocketAccept(std::string_view key) {
  const auto digest = Sha1(std::string(key) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
  return Base64(digest.data(), digest.size());
}

// ---- The HTTP request head ----

inline constexpr size_t MaxRequestBytes = 8192;

struct HttpRequest {
  std::string method, path, query;
  std::string host, origin, upgrade, connection, webSocketKey, webSocketVersion;
};

enum class Parse { NeedMore, Done, Bad };

inline bool EqualsIgnoringCase(std::string_view a, std::string_view b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    const auto lower = [](char ch) { return ch >= 'A' && ch <= 'Z' ? char(ch - 'A' + 'a') : ch; };
    if (lower(a[i]) != lower(b[i])) return false;
  }
  return true;
}

inline std::string_view Trim(std::string_view s) {
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.remove_prefix(1);
  while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) s.remove_suffix(1);
  return s;
}

// Reads one request head from the bytes received so far. On Done, consumed is
// the head's length. A head that hasn't ended within MaxRequestBytes is Bad.
inline Parse ParseRequest(std::string_view buffer, HttpRequest &out, size_t &consumed) {
  const size_t end = buffer.find("\r\n\r\n");
  if (end == std::string_view::npos) return buffer.size() >= MaxRequestBytes ? Parse::Bad : Parse::NeedMore;
  if (end + 4 > MaxRequestBytes) return Parse::Bad;
  std::string_view head = buffer.substr(0, end);
  out = {};
  size_t lineEnd = head.find("\r\n");
  const std::string_view requestLine = head.substr(0, lineEnd);
  const size_t sp1 = requestLine.find(' ');
  const size_t sp2 = sp1 == std::string_view::npos ? sp1 : requestLine.find(' ', sp1 + 1);
  if (sp2 == std::string_view::npos) return Parse::Bad;
  const std::string_view version = requestLine.substr(sp2 + 1);
  if (version != "HTTP/1.1" && version != "HTTP/1.0") return Parse::Bad;
  out.method = requestLine.substr(0, sp1);
  std::string_view target = requestLine.substr(sp1 + 1, sp2 - sp1 - 1);
  if (out.method.empty() || target.empty() || target.front() != '/') return Parse::Bad;
  const size_t question = target.find('?');
  out.path = target.substr(0, question);
  if (question != std::string_view::npos) out.query = target.substr(question + 1);
  while (lineEnd != std::string_view::npos) {
    const size_t start = lineEnd + 2;
    lineEnd = head.find("\r\n", start);
    const std::string_view line = head.substr(start, lineEnd == std::string_view::npos ? std::string_view::npos : lineEnd - start);
    const size_t colon = line.find(':');
    if (colon == std::string_view::npos || colon == 0) return Parse::Bad;
    const std::string_view name = line.substr(0, colon);
    const std::string value(Trim(line.substr(colon + 1)));
    if (EqualsIgnoringCase(name, "Host")) out.host = value;
    else if (EqualsIgnoringCase(name, "Origin")) out.origin = value;
    else if (EqualsIgnoringCase(name, "Upgrade")) out.upgrade = value;
    else if (EqualsIgnoringCase(name, "Connection")) out.connection = value;
    else if (EqualsIgnoringCase(name, "Sec-WebSocket-Key")) out.webSocketKey = value;
    else if (EqualsIgnoringCase(name, "Sec-WebSocket-Version")) out.webSocketVersion = value;
  }
  consumed = end + 4;
  return Parse::Done;
}

// The value of name in a query string, or empty. Only plain values are used
// (hex keys and tokens), so there's no percent-decoding.
inline std::string QueryValue(std::string_view query, std::string_view name) {
  while (!query.empty()) {
    const size_t amp = query.find('&');
    const std::string_view pair = query.substr(0, amp);
    const size_t eq = pair.find('=');
    if (eq != std::string_view::npos && pair.substr(0, eq) == name) return std::string(pair.substr(eq + 1));
    if (amp == std::string_view::npos) break;
    query.remove_prefix(amp + 1);
  }
  return {};
}

// Whether a comma-separated header value lists token, ignoring case.
inline bool HeaderHasToken(std::string_view value, std::string_view token) {
  while (true) {
    const size_t comma = value.find(',');
    if (EqualsIgnoringCase(Trim(value.substr(0, comma)), token)) return true;
    if (comma == std::string_view::npos) return false;
    value.remove_prefix(comma + 1);
  }
}

inline bool IsWebSocketUpgrade(const HttpRequest &request) {
  return request.method == "GET" && HeaderHasToken(request.upgrade, "websocket") &&
         HeaderHasToken(request.connection, "Upgrade") && request.webSocketVersion == "13" &&
         request.webSocketKey.size() == 24;
}

// A web page elsewhere can open a WebSocket to the Mac from the phone's
// browser, but its Origin names that page. Only the controller page, served
// from the same address, is accepted.
inline bool OriginMatchesHost(std::string_view origin, std::string_view host) {
  constexpr std::string_view scheme = "http://";
  if (host.empty() || origin.size() != scheme.size() + host.size()) return false;
  return EqualsIgnoringCase(origin.substr(0, scheme.size()), scheme) &&
         EqualsIgnoringCase(origin.substr(scheme.size()), host);
}

// Compares the join key without returning early on the first difference.
inline bool SameSecret(std::string_view a, std::string_view b) {
  if (a.empty() || a.size() != b.size()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); ++i) diff |= static_cast<unsigned char>(a[i] ^ b[i]);
  return diff == 0;
}

inline std::string HttpResponse(int status, std::string_view reason, std::string_view contentType,
                                std::string_view body) {
  std::string out = "HTTP/1.1 " + std::to_string(status) + " " + std::string(reason) + "\r\n";
  out += "Content-Type: " + std::string(contentType) + "\r\n";
  out += "Content-Length: " + std::to_string(body.size()) + "\r\n";
  out += "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
  out += body;
  return out;
}

inline std::string UpgradeResponse(std::string_view key) {
  return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
         "Sec-WebSocket-Accept: " + WebSocketAccept(key) + "\r\n\r\n";
}

// ---- WebSocket frames ----

enum Opcode : uint8_t { Text = 0x1, Binary = 0x2, Close = 0x8, Ping = 0x9, Pong = 0xA };
inline constexpr size_t MaxFramePayload = 1024;
inline constexpr size_t MaxSignalPayload = 16384;  // a WebRTC offer, on the helper page's socket

struct Frame {
  uint8_t opcode = 0;
  std::string payload;
};

// Reads one frame from a phone. Phones' frames are masked and small, and come
// whole: continuation frames, reserved bits and unknown opcodes are Bad.
inline Parse ReadFrame(std::string_view buffer, Frame &out, size_t &consumed,
                       size_t maxPayload = MaxFramePayload) {
  if (buffer.size() < 2) return Parse::NeedMore;
  const auto b0 = static_cast<uint8_t>(buffer[0]), b1 = static_cast<uint8_t>(buffer[1]);
  const uint8_t opcode = b0 & 0x0F;
  if ((b0 & 0x80) == 0 || (b0 & 0x70) != 0) return Parse::Bad;
  if (opcode != Text && opcode != Binary && opcode != Close && opcode != Ping && opcode != Pong) return Parse::Bad;
  if ((b1 & 0x80) == 0) return Parse::Bad;
  size_t length = b1 & 0x7F, offset = 2;
  if (length == 127) return Parse::Bad;
  if (length == 126) {
    if (buffer.size() < 4) return Parse::NeedMore;
    length = (size_t(static_cast<uint8_t>(buffer[2])) << 8) | static_cast<uint8_t>(buffer[3]);
    offset = 4;
  }
  if (length > maxPayload || (opcode >= Close && length > 125)) return Parse::Bad;
  if (buffer.size() < offset + 4 + length) return Parse::NeedMore;
  const char *mask = buffer.data() + offset;
  out.opcode = opcode;
  out.payload.assign(buffer.data() + offset + 4, length);
  for (size_t i = 0; i < length; ++i) out.payload[i] = char(out.payload[i] ^ mask[i % 4]);
  consumed = offset + 4 + length;
  return Parse::Done;
}

// A frame to a phone: whole and unmasked, as servers send them.
inline std::string WriteFrame(uint8_t opcode, std::string_view payload) {
  std::string out;
  out.push_back(static_cast<char>(0x80 | opcode));
  const size_t length = std::min<size_t>(payload.size(), 0xFFFF);
  if (length < 126) {
    out.push_back(static_cast<char>(length));
  } else {
    out.push_back(static_cast<char>(126));
    out.push_back(static_cast<char>(length >> 8));
    out.push_back(static_cast<char>(length & 0xFF));
  }
  out.append(payload.data(), length);
  return out;
}

// ---- The phone's messages ----

// Bits of PadState::buttons, in the order the controller page uses.
enum Button : uint16_t {
  ButtonA = 1 << 0, ButtonB = 1 << 1, ButtonX = 1 << 2, ButtonY = 1 << 3,
  ButtonL = 1 << 4, ButtonR = 1 << 5, ButtonZ = 1 << 6, ButtonStart = 1 << 7,
  ButtonUp = 1 << 8, ButtonDown = 1 << 9, ButtonLeft = 1 << 10, ButtonRight = 1 << 11,
  ButtonHome = 1 << 12,
};
inline constexpr uint16_t KnownButtons = (1 << 13) - 1;

// The stick is -127..127 on each axis, with down positive, as on an SDL gamepad.
struct PadState {
  uint16_t buttons = 0;
  int8_t stickX = 0, stickY = 0;
  bool operator==(const PadState &) const = default;
};

// Binary messages from the phone. State: {type, seq, buttons (LE16), x, y,
// reserved (LE16)}, sent when anything changes and every 50 ms. Leave: {type}.
// Ping: {type, id (LE16)}, sent back unchanged so the phone can time the link.
// Delay: {type, milliseconds (LE16)}, the round trip the phone has been timing,
// for the Mac's list of phones.
enum MessageType : uint8_t { StateMessage = 1, LeaveMessage = 2, PingMessage = 3, DelayMessage = 4 };
inline constexpr size_t StateMessageSize = 8, PingMessageSize = 3, DelayMessageSize = 3;

struct Message {
  MessageType type = StateMessage;
  uint8_t seq = 0;
  PadState state;
  uint16_t delayMs = 0;
};

inline bool DecodeMessage(std::string_view payload, Message &out) {
  if (payload.empty()) return false;
  const auto type = static_cast<uint8_t>(payload[0]);
  if (type == LeaveMessage && payload.size() == 1) {
    out = {LeaveMessage, 0, {}};
    return true;
  }
  const auto byte = [&](size_t i) { return static_cast<uint8_t>(payload[i]); };
  if (type == PingMessage && payload.size() == PingMessageSize) {
    out = {PingMessage, 0, {}};
    return true;
  }
  if (type == DelayMessage && payload.size() == DelayMessageSize) {
    out = {DelayMessage, 0, {}, static_cast<uint16_t>(byte(1) | (byte(2) << 8))};
    return true;
  }
  if (type != StateMessage || payload.size() != StateMessageSize) return false;
  out.type = StateMessage;
  out.seq = byte(1);
  out.state.buttons = static_cast<uint16_t>((byte(2) | (byte(3) << 8)) & KnownButtons);
  out.state.stickX = static_cast<int8_t>(std::max<int>(-127, static_cast<int8_t>(byte(4))));
  out.state.stickY = static_cast<int8_t>(std::max<int>(-127, static_cast<int8_t>(byte(5))));
  return true;
}

// ---- The WebRTC signal ----

// The helper page's one message: "t=" and the phone's resume token (empty for a
// new phone), a newline, then the phone's WebRTC offer. KartPad answers with its
// own SDP as one text frame, or "error:" and why.
struct Signal {
  std::string token, offer;
};

inline bool ParseSignal(std::string_view text, Signal &out) {
  if (text.size() > MaxSignalPayload || text.substr(0, 2) != "t=") return false;
  const size_t newline = text.find('\n');
  if (newline == std::string_view::npos) return false;
  const std::string_view token = text.substr(2, newline - 2);
  if (token.size() > 64 ||
      !std::all_of(token.begin(), token.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }))
    return false;
  const std::string_view offer = text.substr(newline + 1);
  if (offer.substr(0, 4) != "v=0\r" && offer.substr(0, 4) != "v=0\n") return false;
  out = {std::string(token), std::string(offer)};
  return true;
}

// ---- What a phone's state becomes on an SDL gamepad ----

// SDL_GamepadButton and SDL_GamepadAxis values (SDL 3); the Mac side checks
// them against SDL's headers. A virtual joystick with every gamepad button and
// axis gives joystick button i to gamepad button i, so these are also the
// virtual joystick's indices.
namespace sdl {
inline constexpr int South = 0, East = 1, West = 2, North = 3, Guide = 5, Start = 6,
                     RightShoulder = 10, DpadUp = 11, DpadDown = 12, DpadLeft = 13, DpadRight = 14;
inline constexpr int ButtonCount = 15;  // the ones used here; the virtual pad has all 26
inline constexpr int LeftX = 0, LeftY = 1, LeftTrigger = 4, RightTrigger = 5, AxisCount = 6;
}  // namespace sdl

struct GamepadValues {
  std::array<bool, sdl::ButtonCount> buttons{};
  std::array<int16_t, sdl::AxisCount> axes{};
};

// Mario Kart's GameCube layout as KartPad's Mac controls map it: A, B, X, Y on
// the face buttons, Z on the right shoulder, and L (item) and R (drift) as
// fully pulled triggers, since the game's digital L/R need a near-full pull.
// Home is KartPad HOME. Triggers rest at -32768 on an SDL virtual joystick.
inline GamepadValues ToGamepad(const PadState &state) {
  GamepadValues out;
  const auto on = [&](uint16_t bit) { return (state.buttons & bit) != 0; };
  out.buttons[sdl::South] = on(ButtonA);
  out.buttons[sdl::East] = on(ButtonB);
  out.buttons[sdl::West] = on(ButtonX);
  out.buttons[sdl::North] = on(ButtonY);
  out.buttons[sdl::RightShoulder] = on(ButtonZ);
  out.buttons[sdl::Start] = on(ButtonStart);
  out.buttons[sdl::DpadUp] = on(ButtonUp);
  out.buttons[sdl::DpadDown] = on(ButtonDown);
  out.buttons[sdl::DpadLeft] = on(ButtonLeft);
  out.buttons[sdl::DpadRight] = on(ButtonRight);
  out.buttons[sdl::Guide] = on(ButtonHome);
  const auto axis = [](int8_t v) { return static_cast<int16_t>(int(v) * 32767 / 127); };
  out.axes[sdl::LeftX] = axis(state.stickX);
  out.axes[sdl::LeftY] = axis(state.stickY);
  out.axes[sdl::LeftTrigger] = on(ButtonL) ? 32767 : -32768;
  out.axes[sdl::RightTrigger] = on(ButtonR) ? 32767 : -32768;
  return out;
}

// ---- Who may connect ----

// The same network only: private, link-local and shared-address (CGNAT, as
// used by some VPNs) ranges, and this Mac itself. Host byte order.
inline bool IsLanIPv4(uint32_t a) {
  return (a >> 24) == 10 || (a >> 24) == 127 || (a >> 20) == 0xAC1 || (a >> 16) == 0xC0A8 ||
         (a >> 16) == 0xA9FE || (a >> 22) == (0x64400000u >> 22);
}

inline bool IsLanIPv6(const std::array<uint8_t, 16> &a) {
  static constexpr std::array<uint8_t, 12> kMapped = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
  if (std::equal(kMapped.begin(), kMapped.end(), a.begin()))
    return IsLanIPv4((uint32_t(a[12]) << 24) | (uint32_t(a[13]) << 16) | (uint32_t(a[14]) << 8) | a[15]);
  const bool loopback = std::all_of(a.begin(), a.begin() + 15, [](uint8_t b) { return b == 0; }) && a[15] == 1;
  return loopback || (a[0] & 0xFE) == 0xFC || (a[0] == 0xFE && (a[1] & 0xC0) == 0x80);
}

// ---- Messages to the phone (JSON text) ----

// Player is 1-4, or 0 while the phone has no player (every player taken).
inline std::string WelcomeMessage(int phone, int player, std::string_view token) {
  return "{\"t\":\"welcome\",\"phone\":" + std::to_string(phone) + ",\"player\":" + std::to_string(player) +
         ",\"token\":\"" + std::string(token) + "\"}";
}
inline std::string PlayerMessage(int player) { return "{\"t\":\"player\",\"player\":" + std::to_string(player) + "}"; }
inline std::string ColorMessage(uint8_t r, uint8_t g, uint8_t b) {
  char hex[8];
  std::snprintf(hex, sizeof hex, "#%02x%02x%02x", r, g, b);
  return std::string("{\"t\":\"color\",\"rgb\":\"") + hex + "\"}";
}
inline std::string RumbleMessage(bool on) { return std::string("{\"t\":\"rumble\",\"on\":") + (on ? "true" : "false") + "}"; }
// What the phone's player is doing, so the page shows the controls for it: the
// menus (also a paused race, or a race that player has finished), the start (the
// course intro and the countdown, where accelerating is up to the player, for a
// rocket start), or the race. Unknown: KartPad can't tell (the page offers a switch).
// Fall: off the course and back with Lakitu, until just after landing, where
// accelerating is up to the player again, for his boost.
enum class RaceView : uint8_t { Menus, Start, Race, Unknown, Fall };
inline constexpr const char *RaceViewNames[] = {"menus", "start", "race", "unknown", "fall"};
inline std::string RaceMessage(RaceView view) {
  return std::string("{\"t\":\"race\",\"view\":\"") + RaceViewNames[static_cast<int>(view)] + "\"}";
}
// Why a phone is sent away: "full", "replaced" (the same phone connected
// again), "left", "removed" (from the Mac), "expired" or "closed" (KartPad is quitting).
inline std::string ByeMessage(std::string_view reason) { return "{\"t\":\"bye\",\"reason\":\"" + std::string(reason) + "\"}"; }

// ---- Phone sessions ----

inline constexpr int MaxPhones = 4;
inline constexpr size_t MaxConnections = 8;
inline constexpr uint64_t IdleNeutralMs = 1000;  // no message for this long: let go of everything
inline constexpr uint64_t HoldMs = 60000;        // a dropped phone keeps its pad and player this long

struct Session {
  bool used = false;
  bool connected = false;
  bool idle = false;  // input let go after IdleNeutralMs
  std::string token;
  uint64_t lastMessage = 0, disconnectedAt = 0;
  PadState state;
  uint16_t delayMs = 0;  // as the phone last reported it; 0 before its first report
};

// Up to four phones, by index: phone i is shown as "Phone i+1" and keeps its
// index while it reconnects with its token. Times are milliseconds from any
// steady clock.
class Sessions {
 public:
  struct Joined {
    int index = -1;  // -1: four phones already
    bool resumed = false;
    bool replaced = false;  // the session was still connected: drop that connection
  };

  Joined Join(std::string_view token, const std::string &newToken, uint64_t now) {
    Joined joined;
    for (int i = 0; i < MaxPhones && !token.empty(); ++i) {
      if (sessions_[i].used && SameSecret(sessions_[i].token, token)) {
        joined = {i, true, sessions_[i].connected};
        break;
      }
    }
    if (joined.index < 0) {
      for (int i = 0; i < MaxPhones; ++i) {
        if (!sessions_[i].used) {
          joined.index = i;
          sessions_[i] = {};
          sessions_[i].used = true;
          sessions_[i].token = newToken;
          break;
        }
      }
      if (joined.index < 0) return joined;
    }
    Session &s = sessions_[joined.index];
    s.connected = true;
    s.idle = false;
    s.lastMessage = now;
    s.state = {};
    return joined;
  }

  // A state message. Returns whether the pad's input changed.
  bool Update(int index, const PadState &state, uint64_t now) {
    Session &s = sessions_[index];
    s.lastMessage = now;
    const bool changed = s.idle || !(s.state == state);
    s.idle = false;
    s.state = state;
    return changed;
  }

  void Disconnected(int index, uint64_t now) {
    Session &s = sessions_[index];
    if (!s.used) return;
    s.connected = false;
    s.disconnectedAt = now;
    s.state = {};
  }

  void Leave(int index) { sessions_[index] = {}; }

  void Delay(int index, uint16_t ms) { sessions_[index].delayMs = ms; }

  struct Changes {
    std::vector<int> idle;     // let go of this pad's input
    std::vector<int> expired;  // remove this pad
  };

  Changes Advance(uint64_t now) {
    Changes changes;
    for (int i = 0; i < MaxPhones; ++i) {
      Session &s = sessions_[i];
      if (!s.used) continue;
      if (s.connected && !s.idle && now - s.lastMessage > IdleNeutralMs) {
        s.idle = true;
        s.state = {};
        changes.idle.push_back(i);
      } else if (!s.connected && now - s.disconnectedAt > HoldMs) {
        s = {};
        changes.expired.push_back(i);
      }
    }
    return changes;
  }

  const Session &operator[](int index) const { return sessions_[index]; }

 private:
  std::array<Session, MaxPhones> sessions_{};
};

}  // namespace kartpad::phone_pad
