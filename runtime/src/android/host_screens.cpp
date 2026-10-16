#include "kartpad/android/host_screens.hpp"

#include <SDL3/SDL_gamepad.h>
#include <aurora/event.h>
#include <aurora/input.hpp>
#include <sys/eventfd.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "audio_backend.h"
#include "aurora_events.h"
#include "kartpad/android/gamepad_contract.h"

extern "C" bool KartPadGameStarting();
extern "C" bool Network_HLE_HasOpenSockets();
void VI_HLE_ResyncAfterHostHold();

namespace kartpad::android::screens {
namespace {

using Clock = std::chrono::steady_clock;
constexpr auto kHoldPumpInterval = std::chrono::milliseconds(8);
constexpr auto kStartHoldOpensHome = std::chrono::seconds(1);
constexpr uint32_t kVirtualInstance = 0x7fff0001;

struct Command {
  enum Kind { Rumble, Light } kind;
  uint32_t instance;
  uint16_t low, high;
  uint32_t millis;
  uint8_t red, green, blue;
};

std::atomic_bool g_open{false};
std::atomic<int32_t> g_hold{static_cast<int32_t>(HoldState::Running)};
std::atomic<int32_t> g_game{0};  // kGameOnline | kGameStarting, from the last pump

std::mutex g_mutex;  // everything below
std::array<PadRecord, kMaxPads> g_pads{};
std::size_t g_padCount = 0;
std::unordered_map<uint32_t, uint32_t> g_pressed;  // instance -> buttons pressed since read
std::vector<Event> g_events;
std::vector<Command> g_commands;
bool g_virtualPresent = false;
uint32_t g_virtualHeld = 0, g_virtualPressed = 0;
int32_t g_virtualPlayer = -1;

// Game thread only.
std::unordered_map<uint32_t, int32_t> g_lastPlayers;  // instance -> player at the last pump
struct StartHold {
  Clock::time_point since;
  bool opened = false;
};
std::unordered_map<uint32_t, StartHold> g_startDown;
bool g_ownsPads = false;

int g_eventFd = -1;

void WakeLocked(EventKind kind, int32_t arg) {
  g_events.push_back({kind, arg});
  if (g_eventFd >= 0) {
    const uint64_t one = 1;
    (void)write(g_eventFd, &one, sizeof(one));
  }
}

void SetHold(HoldState state) {
  const int32_t value = static_cast<int32_t>(state);
  if (g_hold.exchange(value, std::memory_order_acq_rel) == value) return;
  std::scoped_lock lock(g_mutex);
  WakeLocked(EventKind::HoldChanged, value);
}

void Observe(const AuroraEvent* events) {
  if (events == nullptr) return;
  std::scoped_lock lock(g_mutex);
  for (const AuroraEvent* event = events; event->type != AURORA_NONE; ++event) {
    switch (event->type) {
    case AURORA_SDL_EVENT:
      if (event->sdl.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && event->sdl.gbutton.button < 32) {
        g_pressed[event->sdl.gbutton.which] |= 1u << event->sdl.gbutton.button;
      }
      break;
    case AURORA_CONTROLLER_ADDED:
      WakeLocked(EventKind::PadsChanged, 0);
      break;
    case AURORA_CONTROLLER_REMOVED: {
      // aurora has already let go of the player by now; the last pump remembers who it was.
      const auto found = g_lastPlayers.find(static_cast<uint32_t>(event->controller));
      if (found != g_lastPlayers.end() && found->second >= 0 && found->second < 4) {
        WakeLocked(EventKind::PlayerLost,
                   found->second | static_cast<int32_t>(found->first << 8));
      }
      WakeLocked(EventKind::PadsChanged, 0);
      break;
    }
    default:
      break;
    }
  }
}

void RunCommands() {
  std::vector<Command> commands;
  {
    std::scoped_lock lock(g_mutex);
    commands.swap(g_commands);
  }
  for (const Command& command : commands) {
    if (command.instance == kVirtualInstance) continue;
    // SDL reaches the controller through Java here, so this stays on the game thread.
    SDL_Gamepad* pad = SDL_GetGamepadFromID(command.instance);
    if (pad == nullptr) continue;
    if (command.kind == Command::Rumble) {
      (void)SDL_RumbleGamepad(pad, command.low, command.high, command.millis);
    } else {
      (void)SDL_SetGamepadLED(pad, command.red, command.green, command.blue);
    }
  }
}

void FillRecord(SDL_Gamepad* pad, uint32_t instance, int32_t player, PadRecord& record) {
  record = {};
  record.instance = instance;
  record.player = player;
  for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT && button < 32; ++button) {
    if (SDL_GetGamepadButton(pad, static_cast<SDL_GamepadButton>(button))) {
      record.held |= 1u << button;
    }
  }
  for (int axis = 0; axis < 6; ++axis) {
    record.axes[axis] = SDL_GetGamepadAxis(pad, static_cast<SDL_GamepadAxis>(axis));
  }
  record.vendor = SDL_GetGamepadVendor(pad);
  record.product = SDL_GetGamepadProduct(pad);
  record.type = static_cast<int32_t>(SDL_GetGamepadType(pad));
  const SDL_GamepadButton faces[4] = {SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST,
                                      SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH};
  for (int face = 0; face < 4; ++face) {
    record.labels[face] = static_cast<uint8_t>(SDL_GetGamepadButtonLabel(pad, faces[face]));
  }
  const SDL_PropertiesID properties = SDL_GetGamepadProperties(pad);
  if (SDL_GetBooleanProperty(properties, SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false)) {
    record.flags |= kPadRumble;
  }
  if (SDL_GetBooleanProperty(properties, SDL_PROP_GAMEPAD_CAP_RGB_LED_BOOLEAN, false)) {
    record.flags |= kPadLight;
  }
  const SDL_GUID guid = SDL_GetJoystickGUID(SDL_GetGamepadJoystick(pad));
  std::memcpy(record.guid, guid.data, sizeof(record.guid));
  const char* name = SDL_GetGamepadName(pad);
  std::snprintf(record.name, sizeof(record.name), "%s", name != nullptr ? name : "Controller");
}

// Reads every pad right after a pump, and notices HOME or a held Start while the game runs.
void Snapshot() {
  std::array<uint32_t, kMaxPads> instances{};
  std::array<int32_t, kMaxPads> players{};
  const uint32_t count =
      aurora::input::list_standard_gamepads(instances.data(), players.data(), kMaxPads);
  std::array<PadRecord, kMaxPads> records{};
  std::size_t filled = 0;
  for (uint32_t index = 0; index < count && filled < kMaxPads; ++index) {
    SDL_Gamepad* pad = SDL_GetGamepadFromID(instances[index]);
    if (pad == nullptr) continue;
    FillRecord(pad, instances[index], players[index], records[filled++]);
  }
  g_lastPlayers.clear();
  for (std::size_t index = 0; index < filled; ++index) {
    g_lastPlayers[records[index].instance] = records[index].player;
  }

  const bool open = g_open.load(std::memory_order_acquire);
  const auto now = Clock::now();
  std::scoped_lock lock(g_mutex);
  if (g_virtualPresent && filled < kMaxPads) {
    PadRecord& record = records[filled++];
    record = {};
    record.instance = kVirtualInstance;
    record.player = g_virtualPlayer;
    record.held = g_virtualHeld;
    record.type = SDL_GAMEPAD_TYPE_XBOXONE;
    record.labels[0] = SDL_GAMEPAD_BUTTON_LABEL_A;
    record.labels[1] = SDL_GAMEPAD_BUTTON_LABEL_B;
    record.labels[2] = SDL_GAMEPAD_BUTTON_LABEL_X;
    record.labels[3] = SDL_GAMEPAD_BUTTON_LABEL_Y;
    record.flags = kPadVirtual;
    std::snprintf(record.name, sizeof(record.name), "QA Pad");
    g_pressed[kVirtualInstance] |= g_virtualPressed;
    g_virtualPressed = 0;
  }
  for (std::size_t index = 0; index < filled; ++index) {
    PadRecord& record = records[index];
    const auto pressed = g_pressed.find(record.instance);
    if (pressed != g_pressed.end()) record.pressed = pressed->second;
    if (open) continue;
    constexpr uint32_t guide = 1u << SDL_GAMEPAD_BUTTON_GUIDE;
    constexpr uint32_t start = 1u << SDL_GAMEPAD_BUTTON_START;
    if ((record.pressed & guide) != 0) {
      WakeLocked(EventKind::OpenHome, static_cast<int32_t>(record.instance));
      g_pressed.erase(record.instance);
      record.pressed = 0;
    }
    if ((record.held & start) == 0) {
      g_startDown.erase(record.instance);
      continue;
    }
    StartHold& hold = g_startDown.try_emplace(record.instance, StartHold{now}).first->second;
    if (!hold.opened && now - hold.since >= kStartHoldOpensHome) {
      hold.opened = true;
      WakeLocked(EventKind::OpenHome, static_cast<int32_t>(record.instance));
    }
  }
  // While closed, presses only matter for opening HOME; don't hand stale ones to the next screen.
  if (!open) g_pressed.clear();
  g_pads = records;
  g_padCount = filled;
}

void TakePads(bool own) {
  if (own == g_ownsPads) return;
  g_ownsPads = own;
  aurora::input::set_standard_gamepads_host_owned(own, static_cast<int16_t>(kTriggerThreshold));
}

void Hold() {
  AudioBackend::Instance().SetPausedForHost(true);
  SetHold(HoldState::Held);
  std::printf("[KartPadScreens] screens opened; game held\n");
  std::fflush(stdout);
  while (g_open.load(std::memory_order_acquire) && !Network_HLE_HasOpenSockets()) {
    g_game.store(KartPadGameStarting() ? kGameStarting : 0, std::memory_order_release);
    std::this_thread::sleep_for(kHoldPumpInterval);
    const AuroraEvent* events = aurora_update();
    ProcessAuroraEvents(events);
    Observe(events);
    RunCommands();
    Snapshot();
  }
  VI_HLE_ResyncAfterHostHold();
  AudioBackend::Instance().SetPausedForHost(false);
  std::printf("[KartPadScreens] screens closed; game resumed\n");
  std::fflush(stdout);
}

}  // namespace

void SetScreensOpen(bool open) noexcept { g_open.store(open, std::memory_order_release); }

int32_t GameState() noexcept { return g_game.load(std::memory_order_acquire); }

HoldState CurrentHoldState() noexcept {
  return static_cast<HoldState>(g_hold.load(std::memory_order_acquire));
}

std::size_t ReadPads(PadRecord* out, std::size_t capacity) noexcept {
  std::scoped_lock lock(g_mutex);
  const std::size_t count = std::min(capacity, g_padCount);
  std::copy_n(g_pads.begin(), count, out);
  for (std::size_t index = 0; index < count; ++index) g_pads[index].pressed = 0;
  g_pressed.clear();
  return count;
}

std::vector<Event> TakeEvents() noexcept {
  std::scoped_lock lock(g_mutex);
  std::vector<Event> events;
  events.swap(g_events);
  if (g_eventFd >= 0) {
    uint64_t drained = 0;
    (void)read(g_eventFd, &drained, sizeof(drained));
  }
  return events;
}

int EventFd() noexcept {
  std::scoped_lock lock(g_mutex);
  if (g_eventFd < 0) g_eventFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  return g_eventFd;
}

void Rumble(uint32_t instance, uint16_t low, uint16_t high, uint32_t millis) noexcept {
  std::scoped_lock lock(g_mutex);
  g_commands.push_back({Command::Rumble, instance, low, high, millis, 0, 0, 0});
}

void SetLight(uint32_t instance, uint8_t red, uint8_t green, uint8_t blue) noexcept {
  std::scoped_lock lock(g_mutex);
  g_commands.push_back({Command::Light, instance, 0, 0, 0, red, green, blue});
}

bool Assign(uint32_t instance, uint32_t player) noexcept {
  if (player >= 4) return false;
  if (instance == kVirtualInstance) {
    std::scoped_lock lock(g_mutex);
    g_virtualPlayer = static_cast<int32_t>(player);
    return true;
  }
  {
    std::scoped_lock lock(g_mutex);
    if (g_virtualPlayer == static_cast<int32_t>(player)) g_virtualPlayer = -1;
  }
  return aurora::input::assign_standard_gamepad(instance, player);
}

bool ClearPlayer(uint32_t player) noexcept {
  if (player >= 4) return false;
  {
    std::scoped_lock lock(g_mutex);
    if (g_virtualPlayer == static_cast<int32_t>(player)) g_virtualPlayer = -1;
  }
  return aurora::input::clear_standard_gamepad_player(player);
}

void QaPress(int32_t button, bool down) noexcept {
  if (button < 0 || button >= 32) return;
  std::scoped_lock lock(g_mutex);
  if (!g_virtualPresent) {
    g_virtualPresent = true;
    WakeLocked(EventKind::PadsChanged, 0);
  }
  if (down) {
    g_virtualHeld |= 1u << button;
    g_virtualPressed |= 1u << button;
  } else {
    g_virtualHeld &= ~(1u << button);
  }
}

}  // namespace kartpad::android::screens

using namespace kartpad::android::screens;

// Called by the runtime on every event pump, on the scheduler (aurora_events.h).
extern "C" void KartPadAndroidServiceHostScreens(const AuroraEvent* events) {
  g_game.store((Network_HLE_HasOpenSockets() ? kGameOnline : 0) | (KartPadGameStarting() ? kGameStarting : 0),
               std::memory_order_release);
  Observe(events);
  RunCommands();
  Snapshot();
  if (!g_open.load(std::memory_order_acquire)) {
    TakePads(false);
    SetHold(HoldState::Running);
    return;
  }
  TakePads(true);
  if (KartPadGameStarting()) {
    // HOME is up over the "KartPad" screen; the game holds once it's past it.
    SetHold(HoldState::Starting);
    return;
  }
  if (Network_HLE_HasOpenSockets()) {
    // Online the race can't wait: the screens have the pads and the game goes on.
    SetHold(HoldState::Online);
    return;
  }
  Hold();
  if (g_open.load(std::memory_order_acquire)) {
    SetHold(HoldState::Online);
  } else {
    TakePads(false);
    SetHold(HoldState::Running);
  }
}
