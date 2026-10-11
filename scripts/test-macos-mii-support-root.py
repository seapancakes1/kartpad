#!/usr/bin/env python3
"""Compile production Mii manager with real prepared runtime paths; no app launch."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
runtime = Path(sys.argv[1]).resolve()
# Optional old manager source allows a safe before/after regression check.
manager = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else repo / 'apple/shared/KartPadMiiManager.mm'
# runtime_config.h's fatal paths call into the runtime, which the fixture doesn't link; they are
# never reached here.
HOOKS = """#include "system_bridge.h"
#include <cstdlib>
void SetRuntimeExitCode(int) {}
void MarkFatalErrorReported() {}
void ShowRuntimeFatalPopup(std::string_view, std::string_view) noexcept {}
namespace RuntimeCrash {
void WriteCrashArtifacts(std::string_view, std::string_view, const uint32_t *) noexcept {}
[[noreturn]] void RuntimeTerminate(int, std::string_view) noexcept { std::abort(); }
}
"""
with tempfile.TemporaryDirectory(prefix='kartpad-mii-path-') as directory:
    temporary = Path(directory).resolve()
    binary = temporary / 'fixture'
    hooks = temporary / 'runtime_hooks.cpp'
    hooks.write_text(HOOKS)
    subprocess.run([
        'clang++', '-std=c++20', '-fobjc-arc', '-UNDEBUG',
        '-DNSHomeDirectory=KartPadTestHomeDirectory', '-DKARTPAD_MII_EDITOR_DISABLED',
        '-I' + str(repo / 'apple/shared'), '-I' + str(repo / 'runtime/include'),
        '-I' + str(runtime / 'include'), '-isystem', str(runtime / 'third_party/toml11'),
        str(repo / 'runtime/tests/apple_mii_support_root_tests.mm'), str(manager), str(hooks),
        '-framework', 'Foundation', '-o', str(binary),
    ], check=True)
    for mode in ('portable', 'normal'):
        case = temporary / mode
        executable = case / 'app/bin/fixture'
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        home = case / 'home'
        home.mkdir()
        normal = home / 'Library/Application Support/KartPad'
        portable = case / 'app/UserData'
        if mode == 'portable':
            (case / 'app/portable.txt').touch()
        selected, untouched = (portable, normal) if mode == 'portable' else (normal, portable)
        environment = os.environ.copy()
        environment['HOME'] = str(home)
        subprocess.run([str(executable), str(selected), str(untouched)],
                       env=environment, check=True)
        print(mode + ': passed', flush=True)
