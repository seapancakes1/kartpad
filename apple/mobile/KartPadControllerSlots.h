#pragma once

// Which controller plays as which player, for KartPadPhysicalControllers: SunPad's slot keeping
// (apple/third_party/sunpad/SunPadControllerSlots.h, first free player in connection order), plus
// what KartPad's Controllers screen does with it: moving a controller to another player (whoever
// was there swaps with it) and taking one out ("Stop playing"), which keeps it out until it's given
// a player again or reconnects. Instances are process-local IDs for GCController objects.

#include "SunPadControllerSlots.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

class KartPadControllerSlots {
 public:
  static constexpr std::size_t kMaxPlayers = SunPadControllerSlots::kMaxPlayers;

  SunPadControllerReconcileResult Reconcile(const std::vector<uintptr_t>& current_instances) {
    std::vector<uintptr_t> current;
    current.reserve(current_instances.size());
    for (uintptr_t instance : current_instances) {
      if (instance != 0 && std::find(current.begin(), current.end(), instance) == current.end()) {
        current.push_back(instance);
      }
    }
    // A controller taken out that has since gone comes back as a new one.
    benched_.erase(std::remove_if(benched_.begin(), benched_.end(),
                                  [&](uintptr_t instance) {
                                    return std::find(current.begin(), current.end(), instance) == current.end();
                                  }),
                   benched_.end());

    SunPadControllerReconcileResult result;
    for (std::size_t slot = 0; slot < slots_.size(); ++slot) {
      const uintptr_t instance = slots_[slot];
      if (instance != 0 && std::find(current.begin(), current.end(), instance) == current.end()) {
        result.removed.push_back({instance, slot});
        slots_[slot] = 0;
      }
    }
    for (uintptr_t instance : current) {
      if (SlotFor(instance) >= 0 || IsBenched(instance)) continue;
      auto free_slot = std::find(slots_.begin(), slots_.end(), 0);
      if (free_slot == slots_.end()) continue;
      const std::size_t slot = static_cast<std::size_t>(free_slot - slots_.begin());
      slots_[slot] = instance;
      result.assigned.push_back({instance, slot});
    }
    return result;
  }

  // Puts instance on slot (-1 takes it out). Whoever was on slot takes instance's old one, or is
  // taken out if instance had none. Returns the slots whose controller changed.
  std::vector<std::size_t> Move(uintptr_t instance, int slot) {
    std::vector<std::size_t> changed;
    if (instance == 0) return changed;
    const int from = SlotFor(instance);
    if (from == slot) return changed;
    benched_.erase(std::remove(benched_.begin(), benched_.end(), instance), benched_.end());
    if (slot < 0) {
      slots_[static_cast<std::size_t>(from)] = 0;
      benched_.push_back(instance);
      changed.push_back(static_cast<std::size_t>(from));
      return changed;
    }
    if (static_cast<std::size_t>(slot) >= slots_.size()) return changed;
    const uintptr_t occupant = slots_[static_cast<std::size_t>(slot)];
    slots_[static_cast<std::size_t>(slot)] = instance;
    changed.push_back(static_cast<std::size_t>(slot));
    if (from >= 0) {
      slots_[static_cast<std::size_t>(from)] = occupant;
      changed.push_back(static_cast<std::size_t>(from));
    } else if (occupant != 0) {
      benched_.push_back(occupant);
    }
    return changed;
  }

  int SlotFor(uintptr_t instance) const {
    auto slot = std::find(slots_.begin(), slots_.end(), instance);
    return slot == slots_.end() || instance == 0 ? -1 : static_cast<int>(slot - slots_.begin());
  }

  uintptr_t InstanceAt(std::size_t slot) const { return slot < slots_.size() ? slots_[slot] : 0; }

  bool IsBenched(uintptr_t instance) const {
    return std::find(benched_.begin(), benched_.end(), instance) != benched_.end();
  }

 private:
  std::array<uintptr_t, kMaxPlayers> slots_{};
  std::vector<uintptr_t> benched_;
};
