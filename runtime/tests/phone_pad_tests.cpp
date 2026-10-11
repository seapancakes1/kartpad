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

std::string Sha256Hex(std::string_view data) {
  const auto digest = Sha256(data);
  return Hex(digest.data(), digest.size());
}
std::string HmacHex(std::string_view key, std::string_view message) {
  const auto digest = HmacSha256(key, message);
  return Hex(digest.data(), digest.size());
}

// FIPS 180-4's examples, the lengths either side of a block's end, and RFC 4231's
// HMAC cases (5, a truncated one, is left out).
bool Hashes() {
  bool ok = true;
  ok &= Expect(Sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 of nothing");
  ok &= Expect(Sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 abc");
  ok &= Expect(Sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
                   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
               "SHA-256 two blocks");
  ok &= Expect(Sha256Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnop"
                         "qrsmnopqrstnopqrstu") == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
               "SHA-256 896 bits");
  ok &= Expect(Sha256Hex(std::string(1000000, 'a')) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
               "SHA-256 a million a's");
  const std::pair<size_t, const char *> edges[] = {
      {55, "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072"},
      {56, "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e"},
      {63, "75220b47218278e656f2013bb8f0c455a25eaf01e86c64924e9d48d89776d6f2"},
      {64, "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c"},
      {65, "9537c5fdf120482f7d58d25e9ed583f52c02b4e304ea814db1633ad565aed7e9"},
      {119, "000b48d4edf0fa7bee3c6236ecd2785baa5db4eeb8bb54341b029e0d9fa5fb0c"},
      {120, "13f05a0b594787f5ecd315edc96141bd3243203d1b7d4f0836f37308b276ba98"}};
  for (const auto &[size, digest] : edges) ok &= Expect(Sha256Hex(std::string(size, 'x')) == digest, "SHA-256 at a block's end");

  const std::string key25 = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19";
  ok &= Expect(HmacHex(std::string(20, '\x0b'), "Hi There") ==
                   "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
               "RFC 4231 case 1");
  ok &= Expect(HmacHex("Jefe", "what do ya want for nothing?") ==
                   "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
               "RFC 4231 case 2");
  ok &= Expect(HmacHex(std::string(20, '\xaa'), std::string(50, '\xdd')) ==
                   "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
               "RFC 4231 case 3");
  ok &= Expect(HmacHex(key25, std::string(50, '\xcd')) == "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
               "RFC 4231 case 4");
  ok &= Expect(HmacHex(std::string(131, '\xaa'), "Test Using Larger Than Block-Size Key - Hash Key First") ==
                   "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
               "RFC 4231 case 6");
  ok &= Expect(HmacHex(std::string(131, '\xaa'),
                       "This is a test using a larger than block-size key and a larger than block-size data. The key needs "
                       "to be hashed before being used by the HMAC algorithm.") ==
                   "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
               "RFC 4231 case 7");
  return ok;
}

bool Requests() {
  bool ok = true;
  HttpRequest request;
  size_t consumed = 0;
  const std::string upgrade =
      "GET /ws?x=1 HTTP/1.1\r\nHost: 192.168.1.5:47800\r\nUpgrade: websocket\r\n"
      "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
      "origin:  http://192.168.1.5:47800 \r\nSec-WebSocket-Version: 13\r\n\r\nextra";
  ok &= Expect(ParseRequest(upgrade, request, consumed) == Parse::Done, "upgrade request parses");
  ok &= Expect(consumed == upgrade.size() - 5, "consumed stops at the end of the head");
  ok &= Expect(request.path == "/ws" && request.query == "x=1", "path and query");
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

  ok &= Expect(WelcomeMessage(1, 2, true) == R"({"t":"welcome","phone":1,"player":2,"resumed":true})", "welcome");
  ok &= Expect(HelloMessage("ab") == R"({"t":"hello","v":)" + std::to_string(ProtocolVersion) + R"(,"nonce":"ab"})", "hello");
  ok &= Expect(ColorMessage(255, 0, 16) == R"({"t":"color","rgb":"#ff0010"})", "colour");
  ok &= Expect(ByeMessage("full") == R"({"t":"bye","reason":"full"})", "bye");
  ok &= Expect(RaceMessage(RaceView::Start) == R"({"t":"race","view":"start"})" &&
                   RaceMessage(RaceView::Unknown) == R"({"t":"race","view":"unknown"})" &&
                   RaceMessage(RaceView::Fall) == R"({"t":"race","view":"fall"})",
               "race view");
  return ok;
}

// The page's own values for these (tests/test_phone_controller_contract.py runs its
// HMAC on them too).
constexpr std::string_view kKey = "00112233445566778899aabbccddeeff", kPhone = "0123456789abcdef0123456789abcdef",
                           kNonce = "fedcba9876543210fedcba9876543210", kOffer = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n";
constexpr std::string_view kJoinProof = "28010c4c938a0244604f3e55de9bd57945710245ae00b12b51aac1d59819c9f2",
                           kSignalProof = "2f7418b76cb336f0172fddb16a2361a334dc2b2c355c55ec1b252b0522e7e359";

bool Joins() {
  bool ok = true;
  static_assert(ProtocolVersion == 1, "the proofs below are version 1's");
  const std::string join = "join 1 " + std::string(kPhone) + " " + std::string(kJoinProof);
  Join parsed;
  ok &= Expect(MessageVersion(join, "join") == 1 && ParseJoin(join, "join", parsed) && parsed.version == 1 &&
                   parsed.phone == kPhone && parsed.proof == kJoinProof && parsed.offer.empty(),
               "join parses");
  ok &= Expect(JoinProven(parsed, kNonce) == "join 1 " + std::string(kPhone) + " " + std::string(kNonce), "what a join proves");
  ok &= Expect(Proves(kKey, JoinProven(parsed, kNonce), parsed.proof), "the page's join proof holds");
  ok &= Expect(!Proves(kKey, JoinProven(parsed, "00000000000000000000000000000000"), parsed.proof),
               "not with another connection's nonce");
  ok &= Expect(!Proves("ffeeddccbbaa99887766554433221100", JoinProven(parsed, kNonce), parsed.proof),
               "nor under another launch's key");
  ok &= Expect(!Proves("", JoinProven(parsed, kNonce), parsed.proof), "nor with no key");
  std::string flipped = parsed.proof;
  flipped[63] = flipped[63] == '0' ? '1' : '0';
  ok &= Expect(!Proves(kKey, JoinProven(parsed, kNonce), flipped), "a wrong proof");

  const std::string signal = "signal 1 " + std::string(kPhone) + " " + std::string(kSignalProof) + "\n" + std::string(kOffer);
  ok &= Expect(MessageVersion(signal, "signal") == 1 && ParseJoin(signal, "signal", parsed) && parsed.phone == kPhone &&
                   parsed.offer == kOffer && Proves(kKey, SignalProven(parsed), parsed.proof),
               "the page's signal parses and its proof holds");
  Join changed = parsed;
  changed.offer += "a=x\r\n";
  ok &= Expect(!Proves(kKey, SignalProven(changed), changed.proof), "a changed offer doesn't");
  ok &= Expect(!ParseJoin(signal, "join", parsed) && !ParseJoin(join, "signal", parsed), "kinds don't mix");

  // Another version is read before the rest, whatever the rest looks like.
  ok &= Expect(MessageVersion("join 2 something new", "join") == 2 && MessageVersion("signal 13\nv=0", "signal") == 13 &&
                   MessageVersion("join 0", "join") == 0,
               "versions");
  ok &= Expect(MessageVersion("join", "join") == -1 && MessageVersion("join x", "join") == -1 &&
                   MessageVersion("join 1x", "join") == -1 && MessageVersion("joint 1 a", "join") == -1 &&
                   MessageVersion("join 123456 a", "join") == -1 && MessageVersion("", "join") == -1 &&
                   MessageVersion("t=\nv=0", "signal") == -1,
               "not versions");
  ok &= Expect(ParseJoin("join 2 " + std::string(kPhone) + " " + std::string(kJoinProof), "join", parsed) &&
                   parsed.version == 2,
               "another version's join parses (the Mac turns it away)");
  const auto bad = [&](const std::string &text, std::string_view kind) { return !ParseJoin(text, kind, parsed); };
  const std::string phone(kPhone), proof(kJoinProof);
  ok &= Expect(bad("join 01 " + phone + " " + proof, "join"), "a version as no page writes it");
  ok &= Expect(bad("join 1 " + phone + " " + proof + " ", "join") && bad("join 1 " + phone + "  " + proof, "join") &&
                   bad("join 1 " + phone + " " + proof + "\n", "join"),
               "stray spaces or lines");
  ok &= Expect(bad("join 1 " + phone.substr(1) + " " + proof, "join") && bad("join 1 " + phone + "0 " + proof, "join"),
               "a phone id of the wrong length");
  std::string upper = phone;
  upper[0] = 'A';
  ok &= Expect(bad("join 1 " + upper + " " + proof, "join") && bad("join 1 " + phone + " " + proof.substr(1), "join"),
               "uppercase hex, short proof");
  ok &= Expect(bad("join 1 " + phone, "join") && bad("join 1", "join"), "missing parts");
  ok &= Expect(bad("signal 1 " + phone + " " + proof, "signal"), "a signal without an offer");
  ok &= Expect(bad("signal 1 " + phone + " " + proof + "\nhello", "signal"), "not an SDP offer");
  ok &= Expect(bad("signal 1 " + phone + " " + proof + "\nv=0\r\n" + std::string(MaxSignalPayload, 'x'), "signal"),
               "offer too long");
  ok &= Expect(bad("t=\nv=0\r\n", "signal"), "the old signal");

  Replays replays;
  ok &= Expect(replays.Fresh(kSignalProof) && !replays.Fresh(kSignalProof) && replays.Fresh(kJoinProof),
               "a signal is taken once");
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

  // A campus network with public addresses: phones on the Mac's own subnet get in, others don't.
  const auto mask4 = [](int bits) {
    Address m{};
    for (int i = 0; i < 96 + bits; ++i) m[i / 8] |= uint8_t(0x80 >> (i % 8));
    return m;
  };
  const std::vector<Subnet> campus = {{MappedIPv4(v4(129, 10, 116, 40)), mask4(22)}};
  ok &= Expect(PrefixLength(mask4(22)) == 118 && PrefixLength(Address{}) == 0, "prefix lengths");
  ok &= Expect(OnNetwork(MappedIPv4(v4(129, 10, 119, 200)), campus) && OnNetwork(MappedIPv4(v4(129, 10, 116, 1)), campus),
               "the Mac's public subnet");
  ok &= Expect(!OnNetwork(MappedIPv4(v4(129, 10, 120, 1)), campus) && !OnNetwork(MappedIPv4(v4(8, 8, 8, 8)), campus),
               "but not beyond it");
  ok &= Expect(OnNetwork(MappedIPv4(v4(192, 168, 0, 7)), {}) && OnNetwork(MappedIPv4(v4(100, 70, 0, 1)), {}),
               "private and shared addresses as before");
  ok &= Expect(!OnNetwork(MappedIPv4(v4(8, 8, 8, 8)), {{MappedIPv4(v4(8, 0, 0, 0)), mask4(7)}}) &&
                   !OnNetwork(MappedIPv4(v4(8, 8, 8, 8)), {{MappedIPv4(0), mask4(0)}}),
               "a prefix shorter than /8 isn't one network");
  Address global = {0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0xab, 0xcd}, mask64{};
  for (int i = 0; i < 8; ++i) mask64[i] = 0xff;
  Address neighbour = global, elsewhere = global;
  neighbour[15] = 0x01;
  elsewhere[7] = 3;
  ok &= Expect(OnNetwork(neighbour, {{global, mask64}}) && !OnNetwork(elsewhere, {{global, mask64}}), "an IPv6 /64");
  ok &= Expect(!OnNetwork(MappedIPv4(v4(129, 10, 116, 2)), {{global, mask64}}) &&
                   !OnNetwork(neighbour, campus),
               "families don't mix");

  // The code's address: Wi-Fi or Ethernet first, public ones included, never VPNs or AirDrop.
  ok &= Expect(AddressRank("en0", v4(129, 10, 116, 40), false) > AddressRank("bridge100", v4(192, 168, 2, 1), false) &&
                   AddressRank("bridge100", v4(192, 168, 2, 1), false) > AddressRank("en0", v4(100, 64, 1, 2), false) &&
                   AddressRank("en0", v4(100, 64, 1, 2), false) > AddressRank("en1", v4(169, 254, 1, 2), false) &&
                   AddressRank("en1", v4(169, 254, 1, 2), false) > 0,
               "ranks");
  ok &= Expect(AddressRank("en0", v4(192, 168, 1, 3), false) == AddressRank("en0", v4(129, 10, 116, 40), false),
               "public as good as private");
  ok &= Expect(AddressRank("utun3", v4(100, 101, 102, 103), true) == 0 && AddressRank("utun3", v4(10, 0, 0, 1), false) == 0 &&
                   AddressRank("en5", v4(10, 0, 0, 1), true) == 0 && AddressRank("lo0", v4(127, 0, 0, 1), false) == 0 &&
                   AddressRank("en0", v4(224, 0, 0, 1), false) == 0 && AddressRank("awdl0", v4(10, 1, 1, 1), false) == 0,
               "never tunnels, loopback, multicast or AirDrop");
  return ok;
}

bool Waits() {
  bool ok = true;
  std::vector<Waiting> waiting;
  ok &= Expect(WaitingToDrop(waiting, "a") == -1, "room");
  for (int i = 0; i < 3; ++i) waiting.push_back({"a", uint64_t(10 + i)});
  ok &= Expect(WaitingToDrop(waiting, "a") == -1, "three from one address");
  waiting.push_back({"a", 5});
  ok &= Expect(WaitingToDrop(waiting, "a") == 3, "a fifth from it closes its oldest");
  ok &= Expect(WaitingToDrop(waiting, "b") == -1, "others still get in");
  waiting.clear();
  for (int i = 0; i < int(MaxWaiting); ++i) waiting.push_back({"peer" + std::to_string(i % 16), uint64_t(100 - i)});
  ok &= Expect(WaitingToDrop(waiting, "phone") == int(MaxWaiting) - 1, "full: the oldest of all goes");
  return ok;
}

bool SessionTable() {
  bool ok = true;
  Sessions sessions;
  const std::string p0(32, '0'), p1(32, '1'), p2(32, '2'), p3(32, '3'), p4(32, '4');
  auto first = sessions.Join(p0, 0);
  ok &= Expect(first.index == 0 && !first.resumed && sessions[0].phone == p0, "first phone");
  ok &= Expect(sessions.Update(0, 1, {ButtonA, 0, 0}, 10), "press changes input");
  ok &= Expect(!sessions.Update(0, 2, {ButtonA, 0, 0}, 60), "repeat doesn't");
  // Quiet for a second: let go.
  ok &= Expect(sessions.Advance(1000).idle.empty(), "not idle yet");
  auto changes = sessions.Advance(1061);
  ok &= Expect(changes.idle.size() == 1 && changes.idle[0] == 0 && sessions[0].state == PadState{}, "idle");
  ok &= Expect(sessions.Advance(1100).idle.empty(), "idle once");
  ok &= Expect(sessions.Update(0, 2, {ButtonA, 0, 0}, 1200), "input after idle, even the same seq");
  ok &= Expect(sessions.Update(0, 3, {0, 0, 0}, 1210), "release");
  ok &= Expect(sessions.Update(0, 4, {0, 0, 0}, 4000) == false, "same neutral");

  // Unordered and repeated WebRTC input: only newer messages count, through seq's wrap.
  ok &= Expect(sessions.Update(0, 5, {ButtonB, 0, 0}, 4010), "B");
  ok &= Expect(!sessions.Update(0, 5, {ButtonB, 0, 0}, 4011) && !sessions.Update(0, 4, {0, 0, 0}, 4012) &&
                   sessions[0].state == PadState{ButtonB, 0, 0},
               "a copy and a late one are dropped");
  ok &= Expect(sessions.Update(0, 7, {0, 0, 0}, 4013) && !sessions.Update(0, 6, {ButtonB, 0, 0}, 4014),
               "a gap is fine, and what it skipped is late");
  ok &= Expect(sessions.Update(0, 255, {ButtonX, 0, 0}, 4020) == false && sessions[0].state == PadState{},
               "half the range behind counts as late");
  for (int seq = 8; seq < 255; ++seq) sessions.Update(0, uint8_t(seq), {}, 4030);
  ok &= Expect(sessions.Update(0, 255, {ButtonY, 0, 0}, 4040) && sessions.Update(0, 0, {ButtonX, 0, 0}, 4041) &&
                   !sessions.Update(0, 254, {}, 4042) && sessions.Update(0, 1, {}, 4043),
               "seq wraps");
  ok &= Expect(sessions.Update(0, 200, {ButtonA, 0, 0}, 4043 + ReorderMs), "after a long gap anything goes");

  // The same phone joins again while its old link is still open: it starts with nothing held, and
  // its new link counts seq afresh.
  ok &= Expect(sessions.Update(0, 201, {ButtonDown, 0, 0}, 4500), "held");
  auto again = sessions.Join(p0, 4600);
  ok &= Expect(again.index == 0 && again.resumed && again.replaced && sessions[0].state == PadState{},
               "replaced, and neutral (the Mac lets go of the pad too)");
  ok &= Expect(!sessions.Update(0, 1, {0, 0, 0}, 4610), "the new link's neutral changes nothing: the Mac already let go");
  ok &= Expect(sessions.Update(0, 2, {ButtonDown, 0, 0}, 4620), "and its seq starts afresh");

  // Dropped, then back with its id: same phone.
  sessions.Disconnected(0, 5000);
  ok &= Expect(!sessions[0].connected && sessions.Advance(30000).expired.empty(), "held");
  auto back = sessions.Join(p0, 30000);
  ok &= Expect(back.index == 0 && back.resumed && !back.replaced && sessions[0].phone == p0, "resumed");

  // Another id is another phone.
  ok &= Expect(sessions.Join(p1, 30200).index == 1, "second phone");
  ok &= Expect(sessions.Join(p2, 30300).index == 2, "third phone");
  ok &= Expect(sessions.Join(p3, 30400).index == 3, "fourth phone");
  ok &= Expect(sessions.Join(p4, 30500).index == -1, "fifth phone turned away");
  ok &= Expect(sessions.Join("", 30500).index == -1, "no id: no phone");

  // Leaving frees the phone at once; a dropped phone expires after the hold.
  sessions.Delay(2, 12);
  ok &= Expect(sessions[2].delayMs == 12, "delay kept");
  sessions.Leave(2);
  auto rejoined = sessions.Join(p2, 30600);
  ok &= Expect(!sessions[2].delayMs && rejoined.index == 2 && !rejoined.resumed, "a phone that left comes back as new");
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
  ok &= Hashes();
  ok &= Requests();
  ok &= Frames();
  ok &= Messages();
  ok &= Joins();
  ok &= Peers();
  ok &= Waits();
  ok &= SessionTable();
  ok &= RaceViews();
  return ok ? 0 : 1;
}
