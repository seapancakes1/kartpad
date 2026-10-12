// KartPadControllerSlots (apple/mobile/KartPadControllerSlots.h): who plays as which player on
// iPhone and iPad, and what Controllers does with it.
#include "KartPadControllerSlots.h"

#include <cassert>
#include <cstdio>

int main() {
  KartPadControllerSlots slots;
  // Connection order fills the first free player.
  auto result = slots.Reconcile({11, 22});
  assert(result.assigned.size() == 2 && slots.SlotFor(11) == 0 && slots.SlotFor(22) == 1);

  // Moving onto a taken player swaps the two.
  auto changed = slots.Move(22, 0);
  assert(changed.size() == 2 && slots.SlotFor(22) == 0 && slots.SlotFor(11) == 1);

  // Onto a free player: the old one is left free.
  slots.Move(11, 3);
  assert(slots.SlotFor(11) == 3 && slots.InstanceAt(1) == 0);

  // Taken out: no player, and reconciling doesn't bring it back while it's connected.
  slots.Move(11, -1);
  assert(slots.SlotFor(11) == -1 && slots.IsBenched(11));
  slots.Reconcile({11, 22});
  assert(slots.SlotFor(11) == -1);

  // A newcomer takes the first free player, not the benched one's.
  slots.Reconcile({11, 22, 33});
  assert(slots.SlotFor(33) == 1);

  // A controller without a player, put on a taken one: the occupant is taken out.
  slots.Move(11, 1);
  assert(slots.SlotFor(11) == 1 && slots.SlotFor(33) == -1 && slots.IsBenched(33));

  // A benched controller that disconnects and comes back is a new arrival.
  slots.Reconcile({11, 22});
  assert(!slots.IsBenched(33));
  slots.Reconcile({11, 22, 33});
  assert(slots.SlotFor(33) >= 0);

  // A controller that leaves frees its player.
  result = slots.Reconcile({11});
  assert(slots.SlotFor(22) == -1 && !result.removed.empty());

  std::puts("KartPadControllerSlots tests passed");
  return 0;
}
