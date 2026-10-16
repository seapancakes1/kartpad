#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// KartPad's own screens on Android (HOME, Controllers, Settings, Miis...) over the game. The UI is
// Kotlin (dev.kartpad.android.screens); this is its native side, on the game thread. The runtime
// calls KartPadAndroidServiceHostScreens on every event pump. While a screen is open the game holds
// still there (unless it's online or still starting), the pads belong to the screens, and the hold
// keeps pumping SDL so the Android lifecycle, the surface and hotplug go on working. Controllers
// reach the screens as SDL sees them, so a pad's instance is the one aurora assigns to players.
namespace kartpad::android::screens {

enum class HoldState : int32_t { Running = 0, Held = 1, Online = 2, Starting = 3 };

// One connected pad, as the screens read it. Little-endian, kPadRecordBytes each.
struct PadRecord {
  uint32_t instance = 0;
  int32_t player = -1;     // 0-3, or -1 when not playing
  uint32_t held = 0;       // 1 << SDL_GamepadButton
  uint32_t pressed = 0;    // pressed since the screens last read, even if already let go
  int16_t axes[6] = {};    // SDL_GamepadAxis order: left x/y, right x/y, left/right trigger
  uint16_t vendor = 0;
  uint16_t product = 0;
  int32_t type = 0;        // SDL_GamepadType
  uint8_t labels[4] = {};  // SDL_GamepadButtonLabel of the south, east, west and north buttons
  uint32_t flags = 0;      // kPadRumble | kPadLight | kPadVirtual
  uint8_t guid[16] = {};
  char name[52] = {};
};
inline constexpr std::size_t kPadRecordBytes = 112;
static_assert(sizeof(PadRecord) == kPadRecordBytes);
inline constexpr uint32_t kPadRumble = 1u << 0, kPadLight = 1u << 1, kPadVirtual = 1u << 2;
inline constexpr std::size_t kMaxPads = 16;

// What the screens hear about, read with TakeEvents after the event fd wakes them.
enum class EventKind : int32_t {
  OpenHome = 1,       // arg: the pad that asked (HOME, or Start held a second)
  PlayerLost = 2,     // arg: player | instance << 8
  PadsChanged = 3,    // a pad connected or disconnected
  HoldChanged = 4,    // arg: HoldState
};
struct Event {
  EventKind kind;
  int32_t arg;
};

// Kotlin's side (kartpad_screens_jni.cpp). All thread-safe.
void SetScreensOpen(bool open) noexcept;
HoldState CurrentHoldState() noexcept;
std::size_t ReadPads(PadRecord* out, std::size_t capacity) noexcept;
std::vector<Event> TakeEvents() noexcept;
int EventFd() noexcept;
void Rumble(uint32_t instance, uint16_t low, uint16_t high, uint32_t millis) noexcept;
void SetLight(uint32_t instance, uint8_t red, uint8_t green, uint8_t blue) noexcept;
// Who plays as whom: aurora's assignment, persisted. The controller already there moves to a free
// player; the screens swap two controllers with two assigns.
bool Assign(uint32_t instance, uint32_t player) noexcept;
bool ClearPlayer(uint32_t player) noexcept;
// What the game is doing, as of its last event pump: online (it won't hold) or still starting.
inline constexpr int32_t kGameOnline = 1, kGameStarting = 2;
int32_t GameState() noexcept;
// Automated checks only: a virtual pad pressed by the QA hook, taken through the same paths.
void QaPress(int32_t button, bool down) noexcept;

}  // namespace kartpad::android::screens
