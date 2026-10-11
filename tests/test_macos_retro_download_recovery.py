"""The Mac Retro Rewind download recovers from an install that didn't finish."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apple/macos/KartPadRetroDownload.inc.mm"

# Without KARTPAD_RUNTIME_PRODUCT_DUAL only the recovery step compiles.
PROBE = r'''
#import <Foundation/Foundation.h>
#include "%s"
#include <cassert>
static NSString *Make(NSString *base, NSString *path, NSString *text) {
  NSString *full = [base stringByAppendingPathComponent:path];
  [NSFileManager.defaultManager createDirectoryAtPath:full.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES attributes:nil error:nil];
  [text writeToFile:full atomically:NO encoding:NSUTF8StringEncoding error:nil];
  return full;
}
static NSString *Read(NSString *base, NSString *path) {
  return [NSString stringWithContentsOfFile:[base stringByAppendingPathComponent:path] encoding:NSUTF8StringEncoding error:nil];
}
int main(int argc, char **argv) {
  @autoreleasepool {
    (void)argc;
    NSString *base = [NSString stringWithUTF8String:argv[1]];
    // A crash between the two moves: the old pack waits aside and nothing is in place.
    NSString *crashed = [base stringByAppendingPathComponent:@"crashed"];
    Make(crashed, @"Previous-A/version.txt", @"old pack");
    Make(crashed, @"Staging-B/RetroRewind6/version.txt", @"half unpacked");
    Make(crashed, @"Downloads/archive-0.zip", @"from an older KartPad");
    Make(crashed, @"Downloads/archive-OLD-0.zip", @"cancelled run");
    Make(crashed, @"Downloads/archive-NEW-0.zip", @"this run");
    Make(crashed, @"riivolution/save/rksys.dat", @"saves");
    KPRecoverRetroInstall(crashed, @"RetroRewind6", @"archive-NEW-");
    assert([Read(crashed, @"RetroRewind6/version.txt") isEqualToString:@"old pack"]);
    assert([Read(crashed, @"riivolution/save/rksys.dat") isEqualToString:@"saves"]);
    NSArray *left = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:crashed error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    assert([left isEqualToArray:(@[@"Downloads", @"RetroRewind6", @"riivolution"])]);
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:[crashed stringByAppendingPathComponent:@"Downloads"] error:nil]
        isEqualToArray:@[@"archive-NEW-0.zip"]]);
    // A crash after the new pack went in: the old one aside is no longer needed.
    NSString *finished = [base stringByAppendingPathComponent:@"finished"];
    Make(finished, @"RetroRewind6/version.txt", @"new pack");
    Make(finished, @"Previous-C/version.txt", @"old pack");
    KPRecoverRetroInstall(finished, @"RetroRewind6", nil);
    assert([Read(finished, @"RetroRewind6/version.txt") isEqualToString:@"new pack"]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[finished stringByAppendingPathComponent:@"Previous-C"]]);
    // Nothing there yet: nothing to do.
    KPRecoverRetroInstall([base stringByAppendingPathComponent:@"missing"], @"RetroRewind6", nil);
  }
  return 0;
}
'''


@unittest.skipUnless(platform.system() == "Darwin", "needs Foundation")
class RetroDownloadRecovery(unittest.TestCase):
    def test_interrupted_install_is_recovered(self):
        with tempfile.TemporaryDirectory() as directory:
            probe, exe = Path(directory) / "probe.mm", Path(directory) / "probe"
            probe.write_text(PROBE % SOURCE)
            build = subprocess.run(["clang++", "-std=c++20", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                                    "-UNDEBUG", str(probe), "-framework", "Foundation", "-o", str(exe)],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            data = Path(directory) / "data"
            data.mkdir()
            result = subprocess.run([str(exe), str(data)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_downloads_are_named_per_attempt_and_installs_take_turns(self):
        text = SOURCE.read_text()
        self.assertIn('stringWithFormat:@"%@%zu.zip", _attempt, _current]', text)
        self.assertNotIn('@"archive-%zu.zip"', text)
        self.assertIn("dispatch_async(KPRetroInstallQueue(), ^{ KPRecoverRetroInstall(base, @KARTPAD_RR_ROOT, attempt); });", text)
        self.assertEqual(text.count("dispatch_async(KPRetroInstallQueue()"), 3)


if __name__ == "__main__":
    unittest.main()
