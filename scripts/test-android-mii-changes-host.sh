#!/usr/bin/env bash
# Host tests for the Android Mii change queue (KartPadMiiChanges): the production Kotlin queue
# over the real JNI library built with host clang, on synthetic databases and saves.
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
jdk="${KARTPAD_TEST_JDK:-$repo/.android-bootstrap/jdk-17.0.20.1+1/Contents/Home}"
modules="$HOME/.gradle/caches/modules-2/files-2.1"

# A library jar: the pinned version, else the wanted one, else the newest found in Gradle's module
# cache or in a Gradle distribution's lib folder.
jar() {
  local group=$1 name=$2 found=""
  shift 2
  for version in "$@"; do
    [[ -n $version ]] || continue
    found=$(find "$modules/$group/$name/$version" "$HOME"/.gradle/wrapper/dists/*/*/*/lib \
      -name "$name-$version.jar" 2>/dev/null | head -n 1 || true)
    [[ -z $found ]] || { echo "$found"; return; }
  done
  found=$(find "$modules/$group/$name" "$HOME"/.gradle/wrapper/dists/*/*/*/lib -name "$name-[0-9]*.jar" \
    ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null |
    awk -F/ '{print $NF "\t" $0}' | sort -V | tail -n 1 | cut -f2 || true)
  [[ -n $found ]] || { echo "No $group:$name jar under ~/.gradle; build the Android app once." >&2; exit 1; }
  echo "$found"
}
compiler=$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.21)
kotlin=$(basename "$compiler" .jar); kotlin=${kotlin#kotlin-compiler-embeddable-}
stdlib=$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.21 "$kotlin")
reflect=$(jar org.jetbrains.kotlin kotlin-reflect 2.2.21 "$kotlin")
coroutines=$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0)
annotations=$(jar org.jetbrains annotations 13.0)
json=$(find "$modules/org.json/json" -name 'json-[0-9]*.jar' ! -name '*-sources.jar' 2>/dev/null | sort -V | tail -n 1)
[[ -n $json ]] || { echo "No org.json jar under ~/.gradle; build the Android app once." >&2; exit 1; }

out="$repo/.android-bootstrap/mii-changes-host-tests"
mkdir -p "$out"
case "$(uname -s)" in
  Darwin) shared=(-dynamiclib) platform=darwin library=libmii-changes-test.dylib ;;
  *) shared=(-shared -fPIC) platform=linux library=libmii-changes-test.so ;;
esac
runtime="$repo/vendor/runtimes/android/runtime"
clang++ -std=c++20 -O1 "${shared[@]}" -I"$jdk/include" -I"$jdk/include/$platform" -I"$repo/runtime/include" \
  -I"$runtime/include" "$repo/android/app/src/main/cpp/kartpad_mii_jni.cpp" -o "$out/$library"
# The fixtures take the console MAC from the runtime's own derivation, whose headers need toml11.
clang++ -std=c++20 -I"$repo/runtime/include" -I"$runtime/include" -isystem "$runtime/third_party/toml11" \
  "$repo/tests/android_mii_changes/Fixtures.cpp" -o "$out/fixtures"
"$out/fixtures" "$out"
sources="$repo/android/app/src/main/java/dev/kartpad/android"
"$jdk/bin/java" -cp "$compiler:$stdlib:$annotations:$coroutines:$reflect" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 -nowarn -classpath "$stdlib:$json" -d "$out/tests.jar" \
  "$repo/tests/android_identity/AtomicFile.kt" "$repo/tests/android_mii_changes/Os.kt" \
  "$repo/tests/android_mii_changes/MiiChangesTests.kt" \
  "$sources/KartPadMiiChanges.kt" "$sources/KartPadMiiStorage.kt" "$sources/KartPadIdentityStorage.kt" \
  "$sources/KartPadSaveStorage.kt" "$sources/KartPadAtomicFile.kt" "$sources/KartPadRatingStorage.kt" \
  "$sources/KartPadRatingCompanion.kt"
"$jdk/bin/java" -cp "$out/tests.jar:$stdlib:$json" dev.kartpad.android.MiiChangesTestsKt "$out/$library" "$out"
