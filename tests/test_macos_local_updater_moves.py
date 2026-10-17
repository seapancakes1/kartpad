"""The Mac app keeps updating after its installed copy moves, as the local updater's helper does."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apple/macos/KartPadLocalUpdater.inc.mm"
SHELL = ROOT / "apple/macos/KartPadMacShell.mm"

# The updater compiled on its own, with the shell's file digest and launch curtain stubbed in.
PROBE = r'''
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <cassert>
#define KARTPAD_RR_VERSION "6.13.1"
static NSString *SHA256ForFile(NSString *path, NSError **error) {
  NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
  if (data == nil) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString string];
  for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) [result appendFormat:@"%%02x", digest[index]];
  return result;
}
#include "%s"
static void KPCurtainDone() {}
static NSString *App(NSString *base, NSString *path, NSString *binary) {
  NSString *app = [base stringByAppendingPathComponent:path];
  NSString *macos = [app stringByAppendingPathComponent:@"Contents/MacOS"];
  [NSFileManager.defaultManager createDirectoryAtPath:macos withIntermediateDirectories:YES attributes:nil error:nil];
  [binary writeToFile:[macos stringByAppendingPathComponent:@"KartPad"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
  return app;
}
static BOOL Moved(NSDictionary *settings, NSDictionary *record, NSString *app) {
  return KPLocalUpdateIsMovedInstall(settings, record, app, [app stringByAppendingPathComponent:@"Contents/MacOS/KartPad"]);
}
int main(int argc, char **argv) {
  @autoreleasepool {
    (void)argc;
    NSString *base = [NSString stringWithUTF8String:argv[1]];
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *installed = App(base, @"Applications/KartPad.app", @"build");
    NSDictionary *record = @{@"app": installed, @"version": @"6.13.1",
                             @"runtimeSha256": SHA256ForFile([installed stringByAppendingPathComponent:@"Contents/MacOS/KartPad"], nil)};
    NSDictionary *settings = @{@"state": [base stringByAppendingPathComponent:@"State"]};
    // A copy while the installed app is still where it was recorded.
    NSString *copy = App(base, @"Applications/Games/KartPad.app", @"build");
    assert(!Moved(settings, record, copy));
    // The installed app moved: the same build, with nothing left at the old place.
    [files removeItemAtPath:installed error:nil];
    assert(Moved(settings, record, copy));
    assert(!Moved(@{@"state": settings[@"state"], @"app": installed}, record, copy));  // settings pin the place
    assert(!Moved(settings, @{@"app": installed, @"runtimeSha256": @"00"}, copy));  // another build
    assert(!Moved(settings, @{}, copy));
    assert(!Moved(settings, record, App(base, @".Trash/KartPad.app", @"build")));
    assert(!Moved(settings, record, App(base, @"State/Backups.noindex/KartPad-6.13.1.app", @"build")));
  }
  return 0;
}
'''


@unittest.skipUnless(platform.system() == "Darwin", "needs AppKit")
class LocalUpdaterMoves(unittest.TestCase):
    def test_moved_install_is_recognised(self):
        with tempfile.TemporaryDirectory() as directory:
            probe, exe = Path(directory) / "probe.mm", Path(directory) / "probe"
            probe.write_text(PROBE % SOURCE)
            build = subprocess.run(["clang++", "-std=c++20", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                                    "-Wno-unused-function", "-Wno-unused-parameter", "-UNDEBUG", str(probe),
                                    "-framework", "AppKit", "-o", str(exe)],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            data = Path(directory) / "data"
            data.mkdir()
            result = subprocess.run([str(exe), str(data)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_shell_defines_the_digest_the_updater_uses(self):
        self.assertIn("static NSString *SHA256ForFile(NSString *path, NSError **error) {", SHELL.read_text())


if __name__ == "__main__":
    unittest.main()
