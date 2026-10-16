#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "kartpad/android/gamepad_contract.h"

namespace kartpad::android {

using ControllerButtonMapping = std::array<uint8_t, 12>;

inline constexpr ControllerButtonMapping kDefaultControllerButtonMapping{
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
};

inline constexpr std::array<uint32_t, 12> kMappablePhysicalButtons{
    kGamepadSouth, kGamepadEast, kGamepadWest, kGamepadNorth,
    kGamepadLeftShoulder, kGamepadRightShoulder, kGamepadDpadUp,
    kGamepadDpadDown, kGamepadDpadLeft, kGamepadDpadRight,
    kGamepadLeftTrigger, kGamepadRightTrigger,
};

inline bool IsValidControllerButtonMapping(
    const ControllerButtonMapping& mapping) noexcept {
  for (const uint8_t physical : mapping) {
    if (physical >= kMappablePhysicalButtons.size()) return false;
  }
  return true;
}

inline uint32_t ApplyControllerButtonMapping(
    const uint32_t buttons, ControllerButtonMapping mapping) noexcept {
  if (!IsValidControllerButtonMapping(mapping)) {
    mapping = kDefaultControllerButtonMapping;
  }
  constexpr uint32_t mappedMask = kGamepadSouth | kGamepadEast |
      kGamepadWest | kGamepadNorth | kGamepadLeftShoulder |
      kGamepadRightShoulder | kGamepadDpadUp | kGamepadDpadDown |
      kGamepadDpadLeft | kGamepadDpadRight | kGamepadLeftTrigger | kGamepadRightTrigger;
  uint32_t result = buttons & ~mappedMask;
  for (std::size_t game = 0; game < mapping.size(); ++game) {
    if ((buttons & kMappablePhysicalButtons[mapping[game]]) != 0) {
      result |= kMappablePhysicalButtons[game];
    }
  }
  return result;
}

void PublishControllerButtonMapping(
    const ControllerButtonMapping& mapping) noexcept;
ControllerButtonMapping ReadControllerButtonMapping() noexcept;

// Vibration (KartPad's Settings): the game's rumble reaches controllers only while it's on.
void PublishControllerVibration(bool enabled) noexcept;
bool ControllerVibrationEnabled() noexcept;

// Nintendo button layout (KartPad's Settings): a Pro Controller, Joy-Cons in the grip or a Wii U Pro
// Controller plays with the letters printed on it, A on the right and B at the bottom, while the
// button mapping is the default (a saved mapping wins). Android hands these pads over by position.
void PublishNintendoLayout(bool enabled) noexcept;
RawGamepadState ApplyNintendoLayout(RawGamepadState input, uint16_t vendor, uint16_t product) noexcept;

// Controller auto-accelerate (off by default; the touch A button has its own).
// Apply runs on the guest input thread with the mapped Classic buttons.
void PublishControllerAutoAccelerate(bool enabled) noexcept;
uint32_t ApplyControllerAutoAccelerate(uint32_t chan, uint32_t classicButtons,
                                       bool connected) noexcept;

}  // namespace kartpad::android
