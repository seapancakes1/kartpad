#!/usr/bin/env bash
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d /private/tmp/kartpad-mii-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang++ -O2 -std=c++20 -UNDEBUG -I "$repo/runtime/include" "$repo/runtime/tests/mii_appearance_tests.cpp" -o "$work/appearance"
"$work/appearance"
clang++ -O2 -std=c++20 -UNDEBUG -I "$repo/runtime/include" "$repo/runtime/tests/mii_editor_history_tests.cpp" -o "$work/history"
"$work/history"
if [[ $# -ge 1 ]]; then
 clang++ -O2 -std=c++20 -UNDEBUG -I "$repo/runtime/include" "$repo/runtime/tests/mii_resource_tests.cpp" -o "$work/resources"
 "$work/resources" "$1"
fi
if [[ $# -ge 2 ]]; then
 clang++ -O2 -std=c++20 -UNDEBUG -I "$repo/runtime/include" "$repo/runtime/tests/mii_body_tests.cpp" -o "$work/body"
 "$work/body" "$1" "$2"
fi
if [[ $(uname -s) == Darwin ]]; then
 for fixture in apple_mii_editor_tests apple_player_identity_tests; do
  clang++ -std=c++20 -fobjc-arc -UNDEBUG -DKARTPAD_MII_MANAGER_TESTING=1 -I "$repo/apple/shared" -I "$repo/runtime/include" "$repo/runtime/tests/$fixture.mm" "$repo/apple/shared/KartPadMiiManager.mm" -framework Foundation -o "$work/$fixture"
  "$work/$fixture"
 done
fi
