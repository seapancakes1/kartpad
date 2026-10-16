#include <sys/eventfd.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <mutex>

#include "kartpad/android/host_screens.hpp"

// The source-only fixture app has no game: its screens "hold" at once and see only the QA pad, so
// the screens themselves can be driven on an emulator without a translated build.
namespace kartpad::android::screens {
namespace {
constexpr uint32_t kVirtualInstance = 0x7fff0001;
std::atomic_bool g_open{false};
std::mutex g_mutex;
std::vector<Event> g_events;
bool g_virtualPresent = false;
uint32_t g_held = 0, g_pressed = 0;
int32_t g_player = -1;
int g_eventFd = -1;

void WakeLocked(EventKind kind, int32_t arg) {
  g_events.push_back({kind, arg});
  if (g_eventFd >= 0) {
    const uint64_t one = 1;
    (void)write(g_eventFd, &one, sizeof(one));
  }
}
}  // namespace

void SetScreensOpen(bool open) noexcept {
  if (g_open.exchange(open) == open) return;
  std::scoped_lock lock(g_mutex);
  WakeLocked(EventKind::HoldChanged, static_cast<int32_t>(open ? HoldState::Held : HoldState::Running));
}

HoldState CurrentHoldState() noexcept { return g_open ? HoldState::Held : HoldState::Running; }

int32_t GameState() noexcept { return 0; }

std::size_t ReadPads(PadRecord* out, std::size_t capacity) noexcept {
  std::scoped_lock lock(g_mutex);
  if (!g_virtualPresent || capacity == 0) return 0;
  PadRecord& record = out[0];
  record = {};
  record.instance = kVirtualInstance;
  record.player = g_player;
  record.held = g_held;
  record.pressed = g_pressed;
  record.type = 3;  // SDL_GAMEPAD_TYPE_XBOXONE
  record.labels[0] = 1;  // A, B, X, Y
  record.labels[1] = 2;
  record.labels[2] = 3;
  record.labels[3] = 4;
  record.flags = kPadVirtual;
  std::snprintf(record.name, sizeof(record.name), "QA Pad");
  g_pressed = 0;
  return 1;
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

void Rumble(uint32_t, uint16_t, uint16_t, uint32_t) noexcept {}
void SetLight(uint32_t, uint8_t, uint8_t, uint8_t) noexcept {}

bool Assign(uint32_t instance, uint32_t player) noexcept {
  if (instance != kVirtualInstance || player >= 4) return false;
  std::scoped_lock lock(g_mutex);
  g_player = static_cast<int32_t>(player);
  return true;
}

bool ClearPlayer(uint32_t player) noexcept {
  std::scoped_lock lock(g_mutex);
  if (g_player == static_cast<int32_t>(player)) g_player = -1;
  return player < 4;
}

void QaPress(int32_t button, bool down) noexcept {
  if (button < 0 || button >= 32) return;
  std::scoped_lock lock(g_mutex);
  if (!g_virtualPresent) {
    g_virtualPresent = true;
    WakeLocked(EventKind::PadsChanged, 0);
  }
  if (down) {
    g_held |= 1u << button;
    g_pressed |= 1u << button;
  } else {
    g_held &= ~(1u << button);
  }
  // The game app's pump turns a QA HOME press into OpenHome; the fixture has no pump.
  if (down && button == 5 /* SDL_GAMEPAD_BUTTON_GUIDE */ && !g_open) {
    WakeLocked(EventKind::OpenHome, static_cast<int32_t>(kVirtualInstance));
  }
}

}  // namespace kartpad::android::screens
