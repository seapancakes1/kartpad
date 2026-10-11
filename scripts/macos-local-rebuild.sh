#!/usr/bin/env bash
# The local Mac updater's rebuild step (buildCommand in its settings; see
# docs/macos-local-auto-update.md). Retranslates Retro Rewind from RETRO_ROOT, builds KartPadDual
# with PROFILE's pins into the runtime build the Mac self-build made, and packages OUTPUT_APP with
# the updater bundled. The updater passes its settings' "environment"; run by hand, anything not
# already set is read from that same file:
#   KARTPAD_LOCAL_UPDATER_SETTINGS  the settings file, so the new app keeps updating (required)
#   KARTPAD_DISC_IMAGE              your Mario Kart Wii disc image
#   KARTPAD_RUNTIME_SOURCE          the prepared runtime source (build/self-build-macos-source)
#   KARTPAD_RUNTIME_BUILD           its CMake build folder (build/self-build-macos-build)
#   KARTPAD_RETRO_PAYLOAD           optional: the Retro-WFC payload (default: the self-build's)
#   KARTPAD_TRANSLATE               optional: the translate script (default: translate-retro-rewind.sh)
#   PATH                            every tool those scripts call: rg, dotnet, cmake, ninja, python3
set -euo pipefail

if [[ $# -ne 3 || "$3" != /*.app ]]; then
  echo "usage: $0 RETRO_ROOT PROFILE /absolute/path/to/KartPad.app" >&2
  exit 64
fi
retro_root="$1"
profile="$2"
app="$3"
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
settings="${KARTPAD_LOCAL_UPDATER_SETTINGS:?set KARTPAD_LOCAL_UPDATER_SETTINGS to the updater settings file}"
while IFS= read -r -d '' name && IFS= read -r -d '' value; do
  [[ -n "${!name+set}" ]] || export "${name}=${value}"
done < <(python3 -I -c 'import json, re, sys
for name, value in json.load(open(sys.argv[1])).get("environment", {}).items():
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name): sys.stdout.write(name + "\0" + str(value) + "\0")' "${settings}")
: "${KARTPAD_DISC_IMAGE:?set KARTPAD_DISC_IMAGE}" "${KARTPAD_RUNTIME_SOURCE:?set KARTPAD_RUNTIME_SOURCE}" \
  "${KARTPAD_RUNTIME_BUILD:?set KARTPAD_RUNTIME_BUILD}"
payload="${KARTPAD_RETRO_PAYLOAD:-${repo_root}/private/builder/retro-rewind-downloads/payload.RMCPD00.bin}"
translate="${KARTPAD_TRANSLATE:-${repo_root}/scripts/translate-retro-rewind.sh}"
header="${KARTPAD_RUNTIME_SOURCE}/third_party/kartpad-profile/kartpad_retro_rewind_release.h"
if [[ ! -f "${header}" || ! -f "${KARTPAD_RUNTIME_BUILD}/CMakeCache.txt" ]]; then
  echo "prepare the runtime once with scripts/self-build-macos.sh (or prepare-g7-game-runtime.sh ... dual)" >&2
  exit 66
fi

cd "${repo_root}"
"${translate}" --image "${KARTPAD_DISC_IMAGE}" --retro-root "${retro_root}" --payload "${payload}"
# The app checks the pack against these pins at launch.
PYTHONPATH="${repo_root}/builder" python3 -m kartpad_builder.release_header "${profile}" "${header}"
cmake --build "${KARTPAD_RUNTIME_BUILD}" --target KartPadDual --parallel 4
"${repo_root}/scripts/package-macos-runtime.sh" "${KARTPAD_RUNTIME_BUILD}" "${app}" KartPadDual
"${repo_root}/scripts/audit-macos-package.sh" "${app}" dual
