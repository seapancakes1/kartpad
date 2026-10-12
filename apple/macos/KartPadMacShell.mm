#import "../mobile/KartPadPrivateServerSettings.h"
#import "KartPadMacShell.h"
#import "KartPadMiiManager.h"
#import "KartPadMiiEditor.h"
#import "KartPadGameFiles.h"
#import "KartPadWiimotePairing.h"

#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>


#include <cstdlib>

// Automated checks (KartPadQA.inc.mm: a command file, synthesised input and clicks, virtual pads,
// window captures) and the hooks they use are only in builds configured with -DKARTPAD_QA_HOOKS=ON.
#if defined(KARTPAD_QA_HOOKS) && KARTPAD_QA_HOOKS
#define KP_QA_HOOKS 1
#else
#define KP_QA_HOOKS 0
#endif

#include <aurora/aurora.h>
#include "runtime_config.h"
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
#include "kartpad_retro_rewind_release.h"
#import "KartPadLocalUpdater.inc.mm"
#endif

static NSString *KPControllerDiagnostics();
extern "C" void KartPadRequestSettingsReload();
extern "C" void KartPadRequestControllerCompatibility();

static constexpr NSInteger kKartPadMenuTag = 0x4b505344;
static NSString *const kKartPadRuntimeProfileDefaultsKey = @"KartPadRuntimeProfile";
static NSString *const kKartPadBaseProfile = @"base";
static NSString *const kKartPadRetroProfile = @"retro_rewind";
// The fullscreen mode Full Screen goes back to: borderless or exclusive.
static NSString *const kKartPadFullScreenModeDefaultsKey = @"KartPadFullScreenMode";
static NSString *const kKartPadBackgroundPauseDefaultsKey = @"KartPadPauseInBackground";

static NSURL *DirectoryURL(const std::filesystem::path &path) {
  const std::string value = path.lexically_normal().string();
  return [NSURL fileURLWithPath:[NSString stringWithUTF8String:value.c_str()]
                   isDirectory:YES];
}

static NSURL *ApplicationSupportURL() {
  return DirectoryURL(RuntimeConfigFile::ApplicationDataDirectory());
}

static NSURL *CacheURL() {
  return DirectoryURL(RuntimeConfigFile::CacheDataDirectory());
}

static NSString *YesNo(BOOL value) { return value ? @"yes" : @"no"; }

static NSString *ActiveRuntimeProfileLabel() {
  const char *profile = std::getenv("KARTPAD_RUNTIME_PROFILE");
  return profile != nullptr && strcmp(profile, "retro_rewind") == 0
      ? @"RMCP01-r0-retro-rewind" : @"RMCP01-r0-base";
}

static NSURL *SessionLogsURL() {
  return [ApplicationSupportURL() URLByAppendingPathComponent:@"Logs"
                                                   isDirectory:YES];
}

static NSURL *CurrentSessionURL() {
  return [SessionLogsURL() URLByAppendingPathComponent:@"session-current.log"];
}

static NSURL *PreviousSessionURL() {
  return [SessionLogsURL() URLByAppendingPathComponent:@"session-previous.log"];
}

static NSURL *ActiveSessionMarkerURL() {
  return [SessionLogsURL() URLByAppendingPathComponent:@".session-active"];
}

static NSString *SessionTimestamp() {
  return [NSISO8601DateFormatter stringFromDate:NSDate.date
                                       timeZone:NSTimeZone.localTimeZone
                                  formatOptions:NSISO8601DateFormatWithInternetDateTime];
}

static void AppendSessionLine(NSString *line) {
  if (line.length == 0) return;
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:CurrentSessionURL()
                                                          error:nil];
  if (handle == nil) return;
  [handle seekToEndOfFile];
  [handle writeData:[[line stringByAppendingString:@"\n"]
                        dataUsingEncoding:NSUTF8StringEncoding]];
  [handle closeFile];
}

static void MarkSessionClean() {
  @autoreleasepool {
    if (![NSFileManager.defaultManager
            fileExistsAtPath:ActiveSessionMarkerURL().path]) {
      return;
    }
    AppendSessionLine([NSString stringWithFormat:@"ended=%@", SessionTimestamp()]);
    AppendSessionLine(@"endedCleanly=yes");
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
    KPConfirmLocalUpdate();
#endif
    [NSFileManager.defaultManager removeItemAtURL:ActiveSessionMarkerURL()
                                            error:nil];
  }
}

static void MarkSessionCleanAtExit() { MarkSessionClean(); }

static void BeginSession() {
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *logs = SessionLogsURL();
  [files createDirectoryAtURL:logs
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
  const BOOL hadCurrent = [files fileExistsAtPath:CurrentSessionURL().path];
  const BOOL previousWasActive =
      [files fileExistsAtPath:ActiveSessionMarkerURL().path];
  if (hadCurrent) {
    [files removeItemAtURL:PreviousSessionURL() error:nil];
    [files moveItemAtURL:CurrentSessionURL()
                   toURL:PreviousSessionURL()
                   error:nil];
  }

  NSString *previousClean = hadCurrent ? YesNo(!previousWasActive) : @"unknown";
  NSString *manifest = [NSString stringWithFormat:
      @"KartPad bounded session log\n"
       "schema=1\n"
       "started=%@\n"
       "productProfile=%@\n"
       "rendererBackend=Metal\n"
       "guestMemoryStrategy=flat-mach-vm\n"
       "schedulerStrategy=cooperative-fibers\n"
       "previousSessionClean=%@\n"
       "currentSessionState=active\n",
      SessionTimestamp(), ActiveRuntimeProfileLabel(), previousClean];
  [manifest writeToURL:CurrentSessionURL()
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
  [@"active\n" writeToURL:ActiveSessionMarkerURL()
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
  static dispatch_once_t once;
  dispatch_once(&once, ^{ std::atexit(MarkSessionCleanAtExit); });
}

static NSString *RedactedSessionTail(NSURL *url) {
  static constexpr NSUInteger kMaximumHeaderBytes = 16384;
  static constexpr NSUInteger kMaximumTailBytes = 65536;
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
  if (handle == nil) return @"unavailable";
  NSMutableData *selected = [NSMutableData data];
  @try {
    unsigned long long size = [handle seekToEndOfFile];
    [handle seekToFileOffset:0];
    if (size <= kMaximumHeaderBytes + kMaximumTailBytes) {
      [selected appendData:[handle readDataOfLength:(NSUInteger)size]];
    } else {
      [selected appendData:[handle readDataOfLength:kMaximumHeaderBytes]];
      [selected appendData:[@"\n[... middle of session omitted ...]\n" dataUsingEncoding:NSUTF8StringEncoding]];
      [handle seekToFileOffset:size - kMaximumTailBytes];
      [selected appendData:[handle readDataOfLength:kMaximumTailBytes]];
    }
  } @catch (NSException *exception) {
    return @"unavailable";
  } @finally {
    [handle closeFile];
  }
  // Decode bounded chunks lossily so a truncated UTF-8 character cannot hide a log.
  NSString *tail = [[NSString alloc] initWithData:selected encoding:NSUTF8StringEncoding];
  if (tail == nil) tail = [[NSString alloc] initWithData:selected encoding:NSISOLatin1StringEncoding];
  if (tail == nil) return @"unreadable";

  NSMutableString *redacted = [tail mutableCopy];
  NSArray<NSString *> *patterns = @[
    @"/Users/[^/\\s]+", @"/home/[^/\\s]+", @"[A-Za-z]:\\\\Users\\\\[^\\\\\\s]+"
  ];
  for (NSString *pattern in patterns) {
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    [expression replaceMatchesInString:redacted
                               options:0
                                 range:NSMakeRange(0, redacted.length)
                          withTemplate:@"<personal-path>"];
  }
  NSString *user = NSUserName();
  if (user.length > 0) {
    [redacted replaceOccurrencesOfString:user
                              withString:@"<user>"
                                 options:0
                                   range:NSMakeRange(0, redacted.length)];
  }
  return [redacted stringByTrimmingCharactersInSet:
      NSCharacterSet.newlineCharacterSet];
}

static NSString *SHA256ForFile(NSString *path, NSError **error) {
  NSData *data = [NSData dataWithContentsOfFile:path
                                       options:NSDataReadingMappedIfSafe
                                         error:error];
  if (data == nil || data.length > UINT32_MAX) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, static_cast<CC_LONG>(data.length), digest);
  NSMutableString *result =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
    [result appendFormat:@"%02x", digest[index]];
  }
  return result;
}

static NSString *ResolvedExtractedRoot(NSURL *selectedURL) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSArray<NSString *> *candidates = @[
    selectedURL.path,
    [selectedURL.path stringByAppendingPathComponent:@"DATA"],
    [selectedURL.path stringByAppendingPathComponent:@"GameData"],
  ];
  for (NSString *candidate in candidates) {
    BOOL directory = NO;
    if ([files fileExistsAtPath:[candidate stringByAppendingPathComponent:@"files"]
                    isDirectory:&directory] && directory &&
        [files fileExistsAtPath:
            [candidate stringByAppendingPathComponent:@"sys/fst.bin"]]) {
      return candidate;
    }
  }
  return nil;
}

static NSString *ValidateExtractedRoot(NSString *root, NSError **error) {
  if (root.length == 0) {
    return @"Choose an extracted Mario Kart Wii DATA folder containing files/ and sys/.";
  }
  NSArray<NSString *> *required = @[
    @"sys/boot.bin", @"sys/bi2.bin", @"sys/apploader.img", @"sys/fst.bin",
    @"sys/main.dol", @"files/rel/StaticR.rel",
  ];
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *relative in required) {
    if (![files fileExistsAtPath:[root stringByAppendingPathComponent:relative]]) {
      return [NSString stringWithFormat:
          @"The extracted game data is incomplete (missing %@).", relative];
    }
  }

  NSData *boot = [NSData dataWithContentsOfFile:
      [root stringByAppendingPathComponent:@"sys/boot.bin"]
                                             options:0
                                               error:error];
  if (boot == nil) return @"KartPad could not read sys/boot.bin.";
  if (boot.length < 0x20) return @"The selected sys/boot.bin is truncated.";
  const uint8_t *bytes = static_cast<const uint8_t *>(boot.bytes);
  if (memcmp(bytes, "RMCP01", 6) != 0 || bytes[6] != 0 || bytes[7] != 0) {
    return @"KartPad only supports the PAL version (RMCP01).";
  }
  const uint32_t magic = (static_cast<uint32_t>(bytes[0x18]) << 24) |
                         (static_cast<uint32_t>(bytes[0x19]) << 16) |
                         (static_cast<uint32_t>(bytes[0x1A]) << 8) |
                         static_cast<uint32_t>(bytes[0x1B]);
  if (magic != 0x5D1C9EA3u) {
    return @"The selected folder does not contain a valid extracted Wii disc header.";
  }

  NSString *hash = SHA256ForFile(
      [root stringByAppendingPathComponent:@"sys/main.dol"], error);
  if (hash == nil) return @"KartPad could not hash sys/main.dol.";
  if (![hash isEqualToString:
      @"80d18895b39c63bd80f457398bfcbb91b7d16ac116a41a88967e954080155b05"]) {
    return @"This game data has been modified. Use an unmodified RMCP01 copy.";
  }
  NSString *relHash = SHA256ForFile(
      [root stringByAppendingPathComponent:@"files/rel/StaticR.rel"], error);
  if (relHash == nil) return @"KartPad could not hash files/rel/StaticR.rel.";
  if (![relHash isEqualToString:
      @"16d9d146112541fefea701ecb5bc1a496f9d50e4a752fbb5b6778e7c6399f67d"]) {
    return @"This game data has been modified. Use an unmodified RMCP01 copy.";
  }
  return KartPadIncompleteGameFilesError(root,
      @"If it's in iCloud Drive, Control-click the folder in Finder, choose Download Now and wait "
      @"for it to finish. Then choose it again.");
}

static NSString *GameDataRootIn(const RuntimeUserConfig &config) {
  if (!config.dvdRoot || config.dvdRoot->empty()) return nil;
  std::filesystem::path root(*config.dvdRoot);
  if (root.is_relative()) root = RuntimeConfigFile::ResolveConfigPath().parent_path() / root;
  return [NSString stringWithUTF8String:root.lexically_normal().string().c_str()];
}

static NSString *ConfiguredGameDataRoot() { return GameDataRootIn(RuntimeConfigFile::LoadConfigFile()); }

// A file as stat sees it, to tell whether it has changed since: which file it is, its size and when
// it was written. All zero for one that isn't there.
struct KPFileStamp {
  dev_t device = 0;
  ino_t inode = 0;
  off_t size = 0;
  long seconds = 0, nanoseconds = 0;
  bool operator==(const KPFileStamp &other) const {
    return device == other.device && inode == other.inode && size == other.size && seconds == other.seconds &&
           nanoseconds == other.nanoseconds;
  }
};
static KPFileStamp KPStampFile(NSString *path) {
  struct stat info {};
  if (path.length == 0 || stat(path.fileSystemRepresentation, &info) != 0) return {};
  return {info.st_dev, info.st_ino, info.st_size, (long)info.st_mtimespec.tv_sec, (long)info.st_mtimespec.tv_nsec};
}

// Config.toml for the folders it names, read again only when the file has changed (each save
// replaces it): screens ask as they draw.
static RuntimeUserConfig KPConfigForFolders() {
  static KPFileStamp stamp;
  static RuntimeUserConfig config;
  static bool read;
  const KPFileStamp now = KPStampFile(@(RuntimeConfigFile::PathToUtf8(RuntimeConfigFile::ResolveConfigPath()).c_str()));
  if (!read || !(now == stamp)) {
    config = RuntimeConfigFile::LoadConfigFile();
    stamp = now;
    read = true;
  }
  return config;
}

// A full check of a game's files (a few SHA-256s, and for Mario Kart Wii a look at every file its
// disc lists) for a screen that shows the answer as it draws: run again only when the folder, or one
// of the files the check reads, has changed since. That covers KartPad's own choosing, setting up
// and downloading. (A file inside going missing shows at the next launch, whose check is full.)
struct KPFilesCheck {
  NSString *root;
  std::vector<KPFileStamp> stamps;
  bool known = false, ready = false;
};
static bool KPFilesReady(KPFilesCheck &check, NSString *root, NSArray<NSString *> *files, bool (^validate)(void)) {
  std::vector<KPFileStamp> stamps;
  for (NSString *file in files) stamps.push_back(KPStampFile([root stringByAppendingPathComponent:file]));
  if (check.known && (check.root == root || [check.root isEqualToString:root]) && stamps == check.stamps) return check.ready;
  check.root = root;
  check.stamps = stamps;
  check.known = true;
  check.ready = validate();
  return check.ready;
}

// Whether the configured Mario Kart Wii files pass ValidateExtractedRoot (Settings shows it).
static BOOL KPGameDataReady() {
  static KPFilesCheck check;
  NSString *root = GameDataRootIn(KPConfigForFolders());
  return KPFilesReady(check, root, @[@"sys/boot.bin", @"sys/fst.bin", @"sys/main.dol", @"files/rel/StaticR.rel"], ^bool {
    NSError *error = nil;
    return ValidateExtractedRoot(root, &error) == nil && error == nil;
  });
}

static BOOL WriteGameDataRoot(NSString *root) {
  if (root.length == 0) return NO;
  const bool wrote = RuntimeConfigFile::WriteSetting(
      "paths", "dvd_root",
      RuntimeConfigFile::FormatString(root.fileSystemRepresentation));
  if (wrote) RuntimeConfigFile::Reload();
  return wrote;
}

#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
static NSString *RetroRewindRootIn(const RuntimeUserConfig &config) {
  if (!config.retroRewindRoot || config.retroRewindRoot->empty()) return nil;
  std::filesystem::path root(*config.retroRewindRoot);
  if (root.is_relative()) root = RuntimeConfigFile::ResolveConfigPath().parent_path() / root;
  return [NSString stringWithUTF8String:root.lexically_normal().string().c_str()];
}

static NSString *ConfiguredRetroRewindRoot() { return RetroRewindRootIn(RuntimeConfigFile::LoadConfigFile()); }

static NSString *ValidateRetroRewindRoot(NSString *root, NSError **error) {
  if (root.length == 0) {
    return [NSString stringWithFormat:
        @"Choose the RetroRewind6 folder from Retro Rewind %@.", @KARTPAD_RR_VERSION];
  }
  NSDictionary<NSString *, NSDictionary<NSString *, id> *> *required = @{
    @KARTPAD_RR_CODE_PUL_PATH: @{
      @"bytes": @(KARTPAD_RR_CODE_PUL_BYTES), @"sha256": @KARTPAD_RR_CODE_PUL_SHA256},
    @KARTPAD_RR_XML_PATH: @{
      @"bytes": @(KARTPAD_RR_XML_BYTES), @"sha256": @KARTPAD_RR_XML_SHA256},
  };
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *relative in required) {
    NSString *path = [root stringByAppendingPathComponent:relative];
    NSDictionary *attributes = [files attributesOfItemAtPath:path error:error];
    if (attributes == nil) {
      return [NSString stringWithFormat:@"The Retro Rewind folder is missing %@.", relative];
    }
    if ([attributes fileSize] != [required[relative][@"bytes"] unsignedLongLongValue]) {
      return [NSString stringWithFormat:@"%@ is not from Retro Rewind %@.", relative,
                                        @KARTPAD_RR_VERSION];
    }
    NSString *hash = SHA256ForFile(path, error);
    if (hash == nil || ![hash isEqualToString:required[relative][@"sha256"]]) {
      return [NSString stringWithFormat:@"%@ failed the Retro Rewind %@ integrity check.",
                                        relative, @KARTPAD_RR_VERSION];
    }
  }
  return nil;
}

// Whether the configured Retro Rewind files pass ValidateRetroRewindRoot (HOME, Settings and setup ask).
static BOOL KPRetroRewindFilesReady() {
  static KPFilesCheck check;
  NSString *root = RetroRewindRootIn(KPConfigForFolders());
  return KPFilesReady(check, root, @[@KARTPAD_RR_CODE_PUL_PATH, @KARTPAD_RR_XML_PATH], ^bool {
    NSError *error = nil;
    return ValidateRetroRewindRoot(root, &error) == nil && error == nil;
  });
}

// The game this launch is playing (KartPadMacShellPrepareGameData sets it).
static NSString *RunningRuntimeProfile() {
  const char *profile = std::getenv("KARTPAD_RUNTIME_PROFILE");
  return profile != nullptr && strcmp(profile, "retro_rewind") == 0
      ? kKartPadRetroProfile : kKartPadBaseProfile;
}

static BOOL WriteRetroRewindRoot(NSString *root) {
  if (root.length == 0) return NO;
  const bool wrote = RuntimeConfigFile::WriteSetting(
      "paths", "retro_rewind_root",
      RuntimeConfigFile::FormatString(root.fileSystemRepresentation));
  if (wrote) RuntimeConfigFile::Reload();
  return wrote;
}

static NSString *ChooseAndValidateRetroRewindData() {
  NSOpenPanel *panel = NSOpenPanel.openPanel;
  panel.title = @"Choose Retro Rewind";
  panel.message = [NSString stringWithFormat:
      @"Choose the RetroRewind6 folder from Retro Rewind %@.",
      @KARTPAD_RR_VERSION];
  panel.prompt = @"Choose Retro Rewind";
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK || panel.URL == nil) return nil;

  NSString *root = panel.URL.path;
  if ([[root lastPathComponent] isEqualToString:@"riivolution"]) {
    root = [root stringByAppendingPathComponent:@KARTPAD_RR_ROOT];
  }
  NSError *error = nil;
  NSString *validation = ValidateRetroRewindRoot(root, &error);
  if (validation == nil && error == nil) return root;
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Unsupported Retro Rewind Data";
  NSString *detail = error.localizedDescription.length > 0
      ? error.localizedDescription : validation;
  NSString *newer = KPLocalUpdateSettings() != nil
      ? @"Retro Rewind Updates… in the Game menu installs newer packs."
      : @"To use a newer pack, first check KartPad's GitHub Releases for a KartPad build that supports it. "
         "Retro Rewind updates are not installed automatically.";
  alert.informativeText = [NSString stringWithFormat:
      @"%@\n\nThis KartPad build supports Retro Rewind %@. Choose the matching "
       "pack. %@\n\nKeep your existing game data and saves; the selected "
       "folder has not been changed.",
      detail, @KARTPAD_RR_VERSION, newer];
  [alert runModal];
  return @"";
}
#endif

static NSString *ChooseAndValidateGameData() {
  NSOpenPanel *panel = NSOpenPanel.openPanel;
  panel.title = @"Choose Extracted Mario Kart Wii Data";
  panel.message = @"Choose your own extracted RMCP01 DATA folder containing files/ and sys/.";
  panel.prompt = @"Choose Game Data";
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK || panel.URL == nil) return nil;

  NSError *error = nil;
  NSString *root = ResolvedExtractedRoot(panel.URL);
  NSString *validation = ValidateExtractedRoot(root, &error);
  if (validation == nil && error == nil) return root;

  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Unsupported Game Data";
  alert.informativeText = error.localizedDescription.length > 0
      ? error.localizedDescription : validation;
  [alert runModal];
  return @"";
}

static NSString *DiagnosticsReport() {
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *support = ApplicationSupportURL();
  NSURL *cache = CacheURL();
  NSURL *config = [support URLByAppendingPathComponent:@"Config.toml"];
  NSURL *logs = [support URLByAppendingPathComponent:@"Logs"];
  NSURL *save = [support
      URLByAppendingPathComponent:
          @"NAND/title/00010004/524d4350/data/rksys.dat"];
  NSBundle *bundle = NSBundle.mainBundle;
  NSString *version =
      [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  if (version.length == 0) version = @"unknown";
  NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
  if (build.length == 0) build = @"unknown";
  NSString *generated = [NSISO8601DateFormatter stringFromDate:NSDate.date
                                                     timeZone:NSTimeZone.localTimeZone
                                                formatOptions:NSISO8601DateFormatWithInternetDateTime];
  NSDictionary *fingerprint = nil;
  NSURL *fingerprintURL = [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:@"build-fingerprint.json"];
  NSData *fingerprintData = [NSData dataWithContentsOfURL:fingerprintURL];
  if (fingerprintData != nil) {
    id object = [NSJSONSerialization JSONObjectWithData:fingerprintData
                                                options:0
                                                  error:nil];
    if ([object isKindOfClass:NSDictionary.class]) fingerprint = object;
  }
  NSString *sourceCommit = fingerprint[@"SourceCommit"];
  if (![sourceCommit isKindOfClass:NSString.class] || sourceCommit.length != 40) {
    sourceCommit = @"unknown";
  }
  NSString *runtimeHash = fingerprint[@"UnsignedRuntimeSHA256"];
  if (![runtimeHash isKindOfClass:NSString.class] || runtimeHash.length != 64) {
    runtimeHash = @"unknown";
  }

  const RuntimeUserConfig runtime = RuntimeConfigFile::LoadConfigFile();
  NSError *gameDataError = nil;
  NSString *gameDataRoot = ConfiguredGameDataRoot();
  const BOOL gameDataValid =
      ValidateExtractedRoot(gameDataRoot, &gameDataError) == nil && gameDataError == nil;
  const BOOL currentSessionActive =
      [files fileExistsAtPath:ActiveSessionMarkerURL().path];
  NSString *currentSessionTail = RedactedSessionTail(CurrentSessionURL());
  NSString *previousSessionTail = RedactedSessionTail(PreviousSessionURL());
  NSUInteger mappingCount = 0;
  for (const auto &mapping : runtime.controllerButtons) {
    if (mapping && !mapping->empty()) ++mappingCount;
  }
  const float resolution = runtime.resolutionMultiplier.value_or(1.0f);
  const uint32_t interpolation = runtime.frameInterpolationFps.value_or(0);
  const NSInteger volume = lroundf(
      std::clamp(runtime.audioVolume.value_or(1.0f), 0.0f, 1.0f) * 100.0f);
  NSString *displayMode = @"windowed";
  if (runtime.displayMode == "borderless") displayMode = @"borderless";
  if (runtime.displayMode == "fullscreen") displayMode = @"fullscreen";
  return [NSString stringWithFormat:
      @"KartPad diagnostics\n"
       "schema=3\n"
       "reportOrigin=KartPad (modified WiiCompiled platform integration)\n"
       "issuesURL=https://github.com/chrissotraidis/kartpad/issues\n"
       "upstreamProject=https://github.com/patchzyy/Wiicompiled\n"
       "generated=%@\n"
       "appVersion=%@\n"
       "appBuild=%@\n"
       "sourceCommit=%@\n"
       "unsignedRuntimeSHA256=%@\n"
       "os=%@\n"
       "architecture=arm64\n"
       "productProfile=%@\n"
       "rendererBackend=Metal\n"
       "guestMemoryStrategy=flat-mach-vm\n"
       "schedulerStrategy=cooperative-fibers\n"
       "displayMode=%@\n"
       "resolutionMultiplier=%.2f\n"
       "frameInterpolationFPS=%u\n"
       "audioVolumePercent=%ld\n"
       "audioMuted=%@\n"
       "networkEnabled=%@\n"
       "controllerMappingsConfigured=%lu\n%@"
       "gameDataConfigured=%@\n"
       "gameDataValidated=%@\n"
       "applicationSupportExists=%@\n"
       "cacheExists=%@\n"
       "configExists=%@\n"
       "logsExist=%@\n"
       "saveExists=%@\n"
       "currentSessionActive=%@\n"
       "sessionHeaderLimitBytes=16384\n"
       "sessionTailLimitBytes=65536\n"
       "currentSessionTailBegin\n%@\ncurrentSessionTailEnd\n"
       "previousSessionTailBegin\n%@\npreviousSessionTailEnd\n"
       "reviewWarning=Review this report before sharing. Arbitrary runtime text may still require review.\n"
       "privacy=personal paths are replaced; game data, translated code, save contents, credentials, device identifiers, signing material, and unbounded logs are omitted\n",
      generated, version, build, sourceCommit, runtimeHash,
      NSProcessInfo.processInfo.operatingSystemVersionString,
      ActiveRuntimeProfileLabel(), displayMode, resolution,
      interpolation, (long)volume, YesNo(runtime.audioMuted.value_or(false)),
      YesNo(runtime.networkEnabled.value_or(true)), (unsigned long)mappingCount, KPControllerDiagnostics(),
      YesNo(gameDataRoot.length > 0), YesNo(gameDataValid),
      YesNo([files fileExistsAtPath:support.path]),
      YesNo([files fileExistsAtPath:cache.path]),
      YesNo([files fileExistsAtPath:config.path]),
      YesNo([files fileExistsAtPath:logs.path]),
      YesNo([files fileExistsAtPath:save.path]), YesNo(currentSessionActive),
      currentSessionTail, previousSessionTail];
}

static bool KPFullscreenAcrossNotch() {
  try {
    const auto document=toml::parse(RuntimeConfigFile::ResolveConfigPath().string());
    return RuntimeConfigFile::FindConfigValue<bool>(document,"video","fullscreen_across_notch").value_or(false);
  } catch (const std::exception &) { return false; }
}

// Settings → Game & Data. On unless turned off.
static bool KPBackgroundPauseEnabled() {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:kKartPadBackgroundPauseDefaultsKey];
  return [value isKindOfClass:NSNumber.class] ? [value boolValue] : true;
}

#include "KartPadControllers.inc.mm"
#include "KartPadControllerRoster.inc.mm"
#include "KartPadPhonePage.inc.mm"
#include "KartPadPhoneControllers.inc.mm"
#include "KartPadMacMiis.inc.mm"
#include "KartPadDiscordPresence.inc.mm"
// A KartPad screen over the game from the menus and shortcuts (KartPadHomeScreen.inc.mm): "home",
// "settings", "controllers", "miis" or "pair-wii". NO when there's no game window to show it in.
static bool KPShowScreen(NSString *which);

@interface KartPadMacShellController : NSObject <NSTabViewDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSPanel *settingsPanel;
@property(nonatomic, strong) NSPanel *controlsPanel;
@property(nonatomic, strong) id settingsShortcutMonitor;
@property(nonatomic, strong) NSTabView *settingsTabs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSControl *> *settingControls;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *settingChoices;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *settingValues;
@property(nonatomic, strong) NSTextField *settingsStatus;
@property(nonatomic, strong) KPMiisWindow *miisWindow;
@property(nonatomic, strong) NSButton *backgroundPauseSwitch;
// Settings → Controllers: Off, Light, Medium or Strong.
@property(nonatomic, strong) NSPopUpButton *vibrationChoice;
// Changes waiting for a restart, by what they are. While there are any, the Game menu has Restart
// KartPad and Settings has Restart Now.
@property(nonatomic, strong) NSMutableSet<NSString *> *restartReasons;
@property(nonatomic, strong) NSButton *settingsRestart;
@property(nonatomic, strong) NSMenuItem *restartItem;
@end

static void KPRestartWithCurtain(NSString *heading, NSString *detail);  // KartPadCurtain.inc.mm
static NSString *KPGameTitle(NSString *profile);                       // KartPadHomeScreen.inc.mm

@implementation KartPadMacShellController

- (void)showSimpleAlert:(NSString *)title message:(NSString *)message {
  NSAlert *alert = [NSAlert new];
  alert.messageText = title;
  alert.informativeText = message ?: @"";
  [alert runModal];
}

// The Mii editor asks whether to save a changed draft; Keep Editing cancels and leaves a window open.
- (BOOL)closeWindows:(id)sender {
  for (NSWindow *window in NSApp.windows) {
    if (![window isKindOfClass:NSPanel.class] && window.isVisible && window.windowController != nil) {
      [window performClose:sender];
      if (window.isVisible) return NO;
    }
  }
  return YES;
}

- (void)quitKartPad:(id)sender {
  if ([self closeWindows:sender]) [self finishQuitting:sender];
}

// macOS asking KartPad to quit (the Dock's Quit, logging out) goes the way ⌘Q does. AppKit's own
// handler would exit() under the running game, through C++ teardown that isn't meant to run then.
- (void)handleQuitEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply {
  (void)event;
  (void)reply;
  [self quitKartPad:nil];
}

// Only the game starts again, as far as the player can tell: the window stays, with a card over it,
// while a new process takes over (KartPadCurtain.inc.mm). Pending Mii changes apply on the way in.
- (void)restartKartPad:(id)sender {
  (void)sender;
  NSString *heading = @"Restarting";
  if ([self.restartReasons containsObject:@"game"])
    heading = [NSString stringWithFormat:@"Starting %@",
        KPGameTitle([NSUserDefaults.standardUserDefaults stringForKey:kKartPadRuntimeProfileDefaultsKey])];
  else if (KartPadHasPendingMiiChanges())
    heading = @"Applying your Mii changes";
  KPRestartWithCurtain(heading, @"");
}

// Quits as usual, and a small helper reopens the app once this process has exited: the curtain's
// fallback when there's no game window or app bundle.
- (void)relaunchKartPad:(id)sender {
  NSString *app = NSBundle.mainBundle.bundlePath;
  if (![app.pathExtension isEqualToString:@"app"]) {
    [self showSimpleAlert:@"KartPad Can’t Restart Itself Here"
                  message:@"Quit and reopen KartPad to apply the changes."];
    return;
  }
  if (![self closeWindows:sender]) return;
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  task.arguments = @[@"-c",
      @"while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
      @"restart", [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier], app];
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  NSError *error = nil;
  if (![task launchAndReturnError:&error]) {
    [self showSimpleAlert:@"KartPad Couldn’t Restart"
                  message:@"Quit and reopen KartPad to apply the changes."];
    return;
  }
  [self finishQuitting:sender];
}

- (BOOL)restartPending { return self.restartReasons.count > 0; }

- (void)setRestartNeeded:(BOOL)needed for:(NSString *)reason {
  if (self.restartReasons == nil) self.restartReasons = [NSMutableSet set];
  if (needed) [self.restartReasons addObject:reason];
  else [self.restartReasons removeObject:reason];
  self.settingsRestart.hidden = !self.restartPending;
}

- (BOOL)askToRestart:(NSString *)title message:(NSString *)message action:(NSString *)action {
  NSAlert *alert = [NSAlert new];
  alert.messageText = title;
  alert.informativeText = message;
  [alert addButtonWithTitle:action];
  [alert addButtonWithTitle:@"Later"];
  return [alert runModal] == NSAlertFirstButtonReturn;
}

// A change that applies at launch: Restart Now, or Later, which leaves Apply Changes in the Game
// menu until then.
- (void)offerRestart:(NSString *)title message:(NSString *)message reason:(NSString *)reason {
  [self setRestartNeeded:YES for:reason];
  if ([self askToRestart:title message:message action:@"Restart Now"]) [self restartKartPad:nil];
}

- (void)finishQuitting:(id)sender {
  if (NSWindow *window = KPGameWindow()) {
    // Let Aurora observe the native close event. Its window-close path
    // flushes placement state and exits without running C++ teardown from a
    // translated guest fiber. That direct exit does not run atexit handlers,
    // so persist the clean marker immediately before handing off.
    MarkSessionClean();
    [window performClose:sender];
    return;
  }
  MarkSessionClean();
  [NSApp terminate:sender];
}

- (void)chooseGameData:(id)sender {
  (void)sender;
  NSString *root = ChooseAndValidateGameData();
  if (root == nil || root.length == 0) return;
  if (!WriteGameDataRoot(root)) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Game Data Could Not Be Saved";
    alert.informativeText = @"KartPad could not update Config.toml.";
    [alert runModal];
    return;
  }
  [self offerRestart:@"Game Data Ready"
             message:@"Restart KartPad to use it."
              reason:@"game-data"];
}

#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
- (void)chooseRetroRewindData:(id)sender {
  (void)sender;
  NSString *root = ChooseAndValidateRetroRewindData();
  if (root == nil || root.length == 0) return;
  if (!WriteRetroRewindRoot(root)) {
    [self showSimpleAlert:@"Retro Rewind Data Could Not Be Saved"
                  message:@"KartPad could not update Config.toml."];
    return;
  }
  if ([RunningRuntimeProfile() isEqualToString:kKartPadRetroProfile]) {
    [self offerRestart:@"Retro Rewind Ready"
               message:@"Restart KartPad to use it."
                reason:@"retro-data"];
    return;
  }
  if ([self askToRestart:@"Retro Rewind Ready"
                 message:@"Switch to Retro Rewind now?"
                  action:@"Switch and Restart"]) {
    [self chooseRuntimeProfile:kKartPadRetroProfile];
    [self restartKartPad:nil];
  }
}

// The game the next launch plays. The Game menu ticks it.
- (void)chooseRuntimeProfile:(NSString *)profile {
  [NSUserDefaults.standardUserDefaults setObject:profile
                                           forKey:kKartPadRuntimeProfileDefaultsKey];
  for (NSMenuItem *item in self.restartItem.menu.itemArray) {
    if (item.action == @selector(useOriginalGame:) || item.action == @selector(useRetroRewind:)) {
      const BOOL retro = item.action == @selector(useRetroRewind:);
      item.state = retro == [profile isEqualToString:kKartPadRetroProfile]
          ? NSControlStateValueOn : NSControlStateValueOff;
    }
  }
  // Going back to the game that's running needs no restart.
  [self setRestartNeeded:![profile isEqualToString:RunningRuntimeProfile()] for:@"game"];
}

- (void)selectRuntimeProfile:(NSString *)profile title:(NSString *)title {
  [self chooseRuntimeProfile:profile];
  if ([profile isEqualToString:RunningRuntimeProfile()]) return;
  if ([self askToRestart:[NSString stringWithFormat:@"Switch to %@?", title]
                 message:@"Unsaved progress will be lost."
                  action:@"Restart Now"]) {
    [self restartKartPad:nil];
  }
}

- (void)showAutomaticUpdates:(id)sender {
  (void)sender;
  KPShowLocalUpdateStatus();
}

- (void)revertAutomaticUpdate:(id)sender {
  KPRevertLocalUpdate(sender);
}

- (void)useOriginalGame:(id)sender {
  (void)sender;
  [self selectRuntimeProfile:kKartPadBaseProfile title:@"Original Mario Kart Wii"];
}

- (void)useRetroRewind:(id)sender {
  (void)sender;
  NSError *error = nil;
  NSString *validation = ValidateRetroRewindRoot(ConfiguredRetroRewindRoot(), &error);
  if (validation != nil || error != nil) {
    NSAlert *required = [NSAlert new];
    required.messageText = @"Retro Rewind Data Required";
    required.informativeText = [NSString stringWithFormat:
        @"KartPad needs the exact Retro Rewind %@ RetroRewind6 folder before it can switch games.",
        @KARTPAD_RR_VERSION];
    [required addButtonWithTitle:@"Choose Folder…"];
    [required addButtonWithTitle:@"Cancel"];
    if ([required runModal] != NSAlertFirstButtonReturn) return;
    NSString *root = ChooseAndValidateRetroRewindData();
    if (root == nil || root.length == 0 || !WriteRetroRewindRoot(root)) return;
  }
  [self selectRuntimeProfile:kKartPadRetroProfile title:@"Retro Rewind"];
}
#endif

- (KPMiisWindow *)miis {
  if (self.miisWindow == nil) {
    self.miisWindow = [KPMiisWindow new];
    self.miisWindow.owner = self;
  }
  return self.miisWindow;
}

- (void)showMiis:(id)sender {
  (void)sender;
  if (KPShowScreen(@"miis")) return;
  [self.miis show];
}

- (NSMenuItem *)playerMenuItem:(NSString *)title action:(SEL)action enabled:(BOOL)enabled {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  item.target = self;
  item.enabled = enabled;
  return item;
}

// Rebuilt each time the Player menu opens so the pending-restart state is
// current. Everything else about Miis happens in the Miis window. The Game
// menu shows Apply Changes while a change waits for one.
- (void)menuNeedsUpdate:(NSMenu *)menu {
  if ([menu.title isEqualToString:@"Game"]) {
    self.restartItem.hidden = !self.restartPending;
    NSInteger index = [menu indexOfItem:self.restartItem];
    if (index >= 0 && index + 1 < menu.numberOfItems) [menu itemAtIndex:index + 1].hidden = !self.restartPending;
    return;
  }
  if (![menu.title isEqualToString:@"Player"]) return;
  [menu removeAllItems];
  if (KartPadHasPendingMiiChanges()) {
    [menu addItem:[self playerMenuItem:@"Apply Mii Changes"
                                action:@selector(restartKartPad:) enabled:YES]];
    [menu addItem:NSMenuItem.separatorItem];
  }
  NSMenuItem *miis = [self playerMenuItem:@"Miis…" action:@selector(showMiis:) enabled:YES];
  miis.keyEquivalent = @"m";
  miis.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [menu addItem:miis];
}

// Full Screen (⌃⌘F) is the Display mode setting: windowed, or back to the fullscreen mode last
// used (borderless at first). It's kept for the next launch, as Option-Return's is.
- (void)toggleGameFullScreen:(id)sender {
  (void)sender;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  const AuroraDisplayMode active = aurora_get_display_mode();
  std::string next = "windowed";
  if (active == AURORA_DISPLAY_MODE_WINDOWED) {
    next = [[defaults stringForKey:kKartPadFullScreenModeDefaultsKey] isEqualToString:@"exclusive"]
        ? "exclusive" : "borderless";
  } else {
    [defaults setObject:active == AURORA_DISPLAY_MODE_EXCLUSIVE ? @"exclusive" : @"borderless"
                 forKey:kKartPadFullScreenModeDefaultsKey];
  }
  if (!RuntimeConfigFile::WriteSetting("video", "display_mode",
                                       RuntimeConfigFile::FormatString(next))) {
    NSBeep();
    return;
  }
  AppendSessionLine([NSString stringWithFormat:@"displayMode=%s; from=full-screen-toggle", next.c_str()]);
  KartPadRequestSettingsReload();
  if (self.settingsPanel.visible) [self refreshSettings];
}

// A short buzz at the chosen strength on every connected controller that says it can vibrate.
- (void)testVibration:(id)sender {
  (void)sender;
  const RuntimeUserConfig config = RuntimeConfigFile::LoadConfigFile();
  if (!config.rumbleEnabled.value_or(true)) {
    self.settingsStatus.stringValue = @"Vibration is off. Choose Light, Medium or Strong to test it.";
    return;
  }
  const auto level = static_cast<Uint16>(
      std::lround(std::clamp(config.rumbleStrength.value_or(0.5f), 0.0f, 1.0f) * 65535.0f));
  int tested = 0;
  for (unsigned i = 0; i < PADCount(); ++i) {
    SDL_Gamepad *pad = PADGetSDLGamepadForIndex(i);
    if (pad == nullptr ||
        !SDL_GetBooleanProperty(SDL_GetGamepadProperties(pad), SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false)) {
      continue;
    }
    if (SDL_RumbleGamepad(pad, level, level, 500)) ++tested;
  }
  AppendSessionLine([NSString stringWithFormat:@"vibrationTest=%d", tested]);
  self.settingsStatus.stringValue = tested > 0
      ? (tested == 1 ? @"Your controller should vibrate now. If it doesn’t, it may not support vibration on this Mac."
                     : @"Your controllers should vibrate now. One that doesn’t may not support vibration on this Mac.")
      : (PADCount() > 0 ? @"No connected controller can vibrate on this Mac."
                        : @"Connect a controller to test vibration.");
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(toggleGameFullScreen:)) {
    item.title = aurora_get_display_mode() == AURORA_DISPLAY_MODE_WINDOWED
        ? @"Enter Full Screen" : @"Exit Full Screen";
  }
  return YES;
}

- (void)toggleExperimentalWiimote:(NSMenuItem *)sender {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  const BOOL enabled = ![defaults boolForKey:KartPadExperimentalWiimoteDefaultsKey];
  if (enabled) {
    NSAlert *warning = [NSAlert new];
    warning.messageText = @"Enable Experimental Wii Remote Support?";
    warning.informativeText =
        @"For original Wii Remotes with a Nunchuk. It can stop working after a macOS update and may conflict with a DolphinBar.";
    [warning addButtonWithTitle:@"Enable and Pair"];
    [warning addButtonWithTitle:@"Cancel"];
    if ([warning runModal] != NSAlertFirstButtonReturn) return;
  }
  [defaults setBool:enabled forKey:KartPadExperimentalWiimoteDefaultsKey];
  sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  KartPadApplyExperimentalWiimotePreference();
  if (enabled) KartPadShowWiimotePairing();
}

- (void)pairWiimote:(id)sender {
  (void)sender;
  if (KPShowScreen(@"pair-wii")) return;
  [NSUserDefaults.standardUserDefaults setBool:YES
      forKey:KartPadExperimentalWiimoteDefaultsKey];
  KartPadApplyExperimentalWiimotePreference();
  KartPadShowWiimotePairing();
}

- (void)showControllerSettings:(id)sender {
  (void)sender;
  if (KPShowScreen(@"controllers")) return;
  [self showSettings:sender];
  [self.settingsTabs selectTabViewItemWithIdentifier:@"Controllers"];
}

- (void)showMultiplayer:(id)sender {
  (void)sender;
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"KartPad Multiplayer";
  alert.informativeText = @"Local: choose Multiplayer in the game, then press A on each controller.\n\nOnline with friends: everyone needs the same game and server. Swap friend codes in Nintendo WFC → Friends. Original Mario Kart Wii needs a private Wii server.";
  [alert addButtonWithTitle:@"Done"];
  [alert addButtonWithTitle:@"Private Wii Server…"];
  if ([alert runModal] == NSAlertSecondButtonReturn) [self showPrivateServer:sender];
}

- (void)showPrivateServer:(id)sender {
  (void)sender;
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Private Wii Server";
  alert.informativeText = @"Enter the server's hostname or IPv4 address. Everyone you play with needs the same server. Wii online traffic isn't encrypted. Applies after a restart.";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 26)];
  field.stringValue = KartPadPrivateServerHost();
  field.placeholderString = @"Server hostname or IPv4 address";
  field.accessibilityLabel = @"Private Wii server address";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Save for Next Launch"];
  [alert addButtonWithTitle:@"Cancel"];
  [alert addButtonWithTitle:@"Use Default Service Next Launch"];
  [alert.window setInitialFirstResponder:field];
  NSModalResponse response = [alert runModal];
  if (response == NSAlertSecondButtonReturn) return;
  if (response == NSAlertThirdButtonReturn) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"KartPadPrivateWfcHost"];
  } else {
    NSString *host = [field.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!KartPad::Network::ValidPrivateWfcHost(host.UTF8String)) {
      NSAlert *error = [NSAlert new];
      error.messageText = @"Invalid Server Address";
      error.informativeText = @"Enter a hostname or IPv4 address without a URL scheme, path, port, or spaces.";
      [error runModal];
      return;
    }
    [NSUserDefaults.standardUserDefaults setObject:host forKey:@"KartPadPrivateWfcHost"];
  }
  [self offerRestart:@"Online Service Saved"
             message:@"Applies after a restart."
              reason:@"online-service"];
}

- (void)showControls:(id)sender {
  (void)sender;
  if (self.controlsPanel == nil) {
    self.controlsPanel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 560, 480)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.controlsPanel.title = @"KartPad Controls";
    self.controlsPanel.releasedWhenClosed = NO;
  }
  {
    NSArray<NSArray<NSString *> *> *bindings = @[
      @[@"Steer", @"W A S D"],
      @[@"Accelerate / confirm", @"U or Return"],
      @[@"Brake / reverse / back", @"M or Delete"],
      @[@"Drift / manual hop", @"E"],
      @[@"Use item", @"Left Shift (Classic L)"],
      @[@"Tricks / menu directions", @"Arrow keys"],
      @[@"Start / pause", @"Space"],
      @[@"Select / minus", @"Tab"],
      @[@"Classic X / Y", @"X / C"],
      @[@"Classic ZL / ZR", @"Z / V"],
      @[@"Settings (also in fullscreen)", @"⌘, or F10 / Fn–F10"],
      @[@"Full screen", @"⌃⌘F or ⌥Return"],
      @[@"HOME from a controller", @"HOME, or hold Menu"],
    ];
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    for (NSArray<NSString *> *binding in bindings) {
      NSTextField *action = [self label:binding[0]];
      action.font = [NSFont systemFontOfSize:NSFont.systemFontSize
                                      weight:NSFontWeightMedium];
      [action.widthAnchor constraintEqualToConstant:205.0].active = YES;
      NSTextField *keys = [self label:binding[1]];
      NSStackView *row = [NSStackView stackViewWithViews:@[action, keys]];
      row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      row.alignment = NSLayoutAttributeFirstBaseline;
      row.spacing = 18.0;
      [rows addObject:row];
    }

    NSStackView *content = [NSStackView stackViewWithViews:rows];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 12.0;
    self.controlsPanel.contentView = [NSView new];
    [self.controlsPanel.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
      [content.leadingAnchor constraintEqualToAnchor:self.controlsPanel.contentView.leadingAnchor
                                             constant:24.0],
      [content.trailingAnchor constraintEqualToAnchor:self.controlsPanel.contentView.trailingAnchor
                                              constant:-24.0],
      [content.topAnchor constraintEqualToAnchor:self.controlsPanel.contentView.topAnchor
                                         constant:24.0],
      [content.bottomAnchor constraintLessThanOrEqualToAnchor:self.controlsPanel.contentView.bottomAnchor
                                                      constant:-20.0]
    ]];
  }

  [self.controlsPanel center];
  [self.controlsPanel makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (NSTextField *)label:(NSString *)text {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  return label;
}

- (NSStackView *)rowWithLabel:(NSString *)label control:(NSView *)control {
  NSTextField *title = [self label:label];
  [title.widthAnchor constraintEqualToConstant:122.0].active = YES;
  NSStackView *row = [NSStackView stackViewWithViews:@[title, control]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 12.0;
  return row;
}

#include "KartPadMacSettings.inc.mm"

- (void)showApplicationSupport:(id)sender {
  (void)sender;
  NSURL *url = ApplicationSupportURL();
  [NSFileManager.defaultManager createDirectoryAtURL:url
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil];
  [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)showCache:(id)sender {
  (void)sender;
  NSURL *url = CacheURL();
  [NSFileManager.defaultManager createDirectoryAtURL:url
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil];
  [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)reportProblem:(id)sender {
  (void)sender;
  NSBundle *bundle = NSBundle.mainBundle;
  NSURLComponents *draft = [NSURLComponents componentsWithString:
      @"https://github.com/chrissotraidis/kartpad/issues/new"];
  draft.queryItems = @[
    [NSURLQueryItem queryItemWithName:@"template" value:@"bug_report.yml"],
    [NSURLQueryItem queryItemWithName:@"revision" value:[NSString stringWithFormat:@"%@ (build %@)",
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown"]],
    [NSURLQueryItem queryItemWithName:@"platform" value:[NSString stringWithFormat:
        @"Apple Silicon Mac, %@ (add exact model if known)",
        NSProcessInfo.processInfo.operatingSystemVersionString]],
    [NSURLQueryItem queryItemWithName:@"context" value:
        @"Report origin: KartPad (modified WiiCompiled platform integration)."],
    [NSURLQueryItem queryItemWithName:@"diagnostics" value:
        @"No diagnostic file has been uploaded. Use Help → Save Diagnostics Report…, review the saved text, then attach it manually here if relevant."],
  ];
  NSAlert *choice = [NSAlert new];
  choice.messageText = @"Where should this report go?";
  choice.informativeText = @"Not sure? Choose KartPad.";
  [choice addButtonWithTitle:@"KartPad"];
  [choice addButtonWithTitle:@"WiiCompiled"];
  [choice addButtonWithTitle:@"Cancel"];
  [choice addButtonWithTitle:@"Search Both Trackers"];
  NSModalResponse response = [choice runModal];
  if (response == NSAlertThirdButtonReturn) return;
  if (response == NSAlertSecondButtonReturn) {
    draft = [NSURLComponents componentsWithString:@"https://github.com/patchzyy/Wiicompiled/issues/new/choose"];
  }
  if (response == NSAlertFirstButtonReturn + 3) {
    draft = [NSURLComponents componentsWithString:@"https://github.com/search?q=is%3Aissue+repo%3Achrissotraidis%2Fkartpad+repo%3Apatchzyy%2FWiicompiled&type=issues"];
  }
  if (draft.URL != nil) [NSWorkspace.sharedWorkspace openURL:draft.URL];
}

- (void)showReportingGuide:(id)sender {
  (void)sender;
  [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
      @"https://github.com/chrissotraidis/kartpad/blob/main/docs/REPORTING.md"]];
}

- (void)showWiiCompiled:(id)sender {
  (void)sender;
  [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
      @"https://github.com/patchzyy/Wiicompiled"]];
}

- (void)saveDiagnostics:(id)sender {
  (void)sender;
  NSSavePanel *panel = NSSavePanel.savePanel;
  panel.title = @"Save KartPad Diagnostics";
  panel.nameFieldStringValue = @"KartPad-Diagnostics.txt";
  panel.allowedContentTypes = @[UTTypePlainText];
  [panel beginWithCompletionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || panel.URL == nil) return;
    NSError *error = nil;
    if (![DiagnosticsReport() writeToURL:panel.URL
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:&error]) {
      NSAlert *alert = [NSAlert new];
      alert.messageText = @"Diagnostics Could Not Be Saved";
      NSString *description = error.localizedDescription;
      alert.informativeText =
          description.length == 0 ? @"Unknown write error." : description;
      [alert runModal];
    }
  }];
}

@end

static KartPadMacShellController *Controller() {
  static KartPadMacShellController *controller;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ controller = [KartPadMacShellController new]; });
  return controller;
}

static void KPOpenMiisFromController() { [Controller() showMiis:nil]; }

#include "KartPadOverlay.inc.mm"
#include "KartPadUIGlyphs.inc.mm"
#include "KartPadHints.inc.mm"
#include "KartPadControllerArt.inc.mm"
#include "KartPadHomeScreen.inc.mm"
#include "KartPadRetroDownload.inc.mm"
#include "KartPadControllersScreen.inc.mm"
#include "KartPadReconnect.inc.mm"
#include "KartPadGhostsScreen.inc.mm"
#include "KartPadSettingsScreen.inc.mm"
#include "KartPadMiisScreen.inc.mm"
#include "KartPadCurtain.inc.mm"
#include "KartPadSetup.inc.mm"

static bool KPShowScreen(NSString *which) {
  if (KPGameWindow() == nil) return false;
  if ([which isEqualToString:@"home"]) {
    if (KPOverlay().active) [KPOverlay() closeAll];
    else KPOpenHome();
    return true;
  }
  if (KartPadGameStarting()) return false;
  // Under HOME, so B comes back there.
  if (!KPOverlay().active) KPOpenHome();
  if (!KPOverlay().active) return false;
  if ([which isEqualToString:@"settings"]) [KPOverlay() present:KPMakeSettingsScreen()];
  else if ([which isEqualToString:@"controllers"]) [KPOverlay() present:(KPScreen *)KPMakeControllersScreen(-1)];
  else if ([which isEqualToString:@"miis"]) [KPOverlay() present:KPMakeMiisScreen()];
  else if ([which isEqualToString:@"ghosts"]) [KPOverlay() present:KPMakeGhostsScreen()];
  else if ([which isEqualToString:@"pair-wii"]) {
    KPScreen *connect = KPMakeConnectScreen();
    [KPOverlay() present:connect];
    [(KPConnectScreen *)connect chooseKind:KPPairKind::WiiRemote];
  } else if ([which isEqualToString:@"pair-phone"]) {
    KPScreen *connect = KPMakeConnectScreen();
    [KPOverlay() present:connect];
    [(KPConnectScreen *)connect chooseKind:KPPairKind::Phone];
  }
  return true;
}

// Settings and HOME from the menus: KartPad's screens over the game, or the classic Settings window
// before the game window exists.
@implementation KartPadMacShellController (Screens)
- (void)openSettings:(id)sender {
  if (KPShowScreen(@"settings")) return;
  [self showSettings:sender];
}
- (void)openHome:(id)sender {
  (void)sender;
  KPShowScreen(@"home");
}
- (void)openGhosts:(id)sender {
  (void)sender;
  if (KPShowScreen(@"ghosts")) return;
  [self showSimpleAlert:@"Start the Game First"
                message:@"Ghosts open once Mario Kart is running. Then choose Data → Time Trial Ghosts… again."];
}
- (void)addPhoneController:(id)sender {
  (void)sender;
  if (KPShowScreen(@"pair-phone")) return;
  [self showSimpleAlert:@"Start the Game First"
                message:@"Phones join once Mario Kart is running. Then choose Controls → Add Phone Controller… again."];
}
@end

#if KP_QA_HOOKS
#include "KartPadQA.inc.mm"
#endif

// The runtime holds the game still while this is true (WaitWhileBackgroundPaused). That includes
// KartPad hidden and its window minimized (as exclusive fullscreen is on losing the focus), which
// otherwise only stop the drawing. Automated runs in the background (KARTPAD_BACKGROUND) never
// hold: they're meant to run unfocused, and the Mac's own setting is shared with the player's copy.
extern "C" bool KartPadBackgroundPauseWanted() {
  if (NSApp.active || !KPBackgroundPauseEnabled() || KPUIBackgroundAutomation()) return false;
  @autoreleasepool {
    for (NSWindow *window in NSApp.windows) {
      if (![window isKindOfClass:NSPanel.class] && window.windowController == nil) return true;
    }
    return false;
  }
}

// The title bar says so meanwhile.
extern "C" void KartPadBackgroundPauseChanged(bool paused) {
  static __weak NSWindow *window;
  static NSString *title;
  @autoreleasepool {
    AppendSessionLine(paused ? @"backgroundPause=paused" : @"backgroundPause=resumed");
    if (paused) {
      for (NSWindow *candidate in NSApp.windows) {
        if (![candidate isKindOfClass:NSPanel.class] && candidate.windowController == nil) window = candidate;
      }
      title = window.title;
      if (title.length > 0) window.title = [title stringByAppendingString:@" — Paused"];
    } else {
      if (title.length > 0) window.title = title;
      window = nil;
      title = nil;
    }
  }
}

extern "C" void KartPadOpenSettingsFromShortcut() {
  // SDL event handling can run inside a guest fiber. Open AppKit UI on the
  // next native run-loop turn rather than re-entering the event pump here.
  dispatch_async(dispatch_get_main_queue(), ^{
    // The runtime and the key monitor both hear the shortcut; Settings opens once.
    if ([KPOverlay().top isKindOfClass:KPSettingsScreen.class]) return;
    [Controller() openSettings:nil];
  });
}

static void InstallSettingsShortcutMonitor() {
  KartPadMacShellController *controller = Controller();
  if (controller.settingsShortcutMonitor != nil) return;
  controller.settingsShortcutMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
      handler:^NSEvent *(NSEvent *event) {
        const NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        const bool functionKey = event.keyCode == 109;
        const bool commandComma = event.keyCode == 47 && (modifiers & NSEventModifierFlagCommand) &&
            !(modifiers & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift));
        // ⌃⌘F from any KartPad window, and in exclusive fullscreen, where the menu doesn't hear it.
        const NSEventModifierFlags chord = modifiers & (NSEventModifierFlagControl | NSEventModifierFlagOption |
                                                        NSEventModifierFlagShift | NSEventModifierFlagCommand);
        // As the menu matches it: by the character, whatever the keyboard layout.
        if (chord == (NSEventModifierFlagControl | NSEventModifierFlagCommand) && !event.isARepeat &&
            [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"f"]) {
          dispatch_async(dispatch_get_main_queue(), ^{ [Controller() toggleGameFullScreen:nil]; });
          return nil;
        }
        if ((functionKey && !(modifiers & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand))) ||
            commandComma) {
          KartPadOpenSettingsFromShortcut();
          return nil;
        }
        // Escape opens HOME over the game (on a screen it goes back; the screen's own monitor has it).
        if (event.keyCode == kVK_Escape && !event.isARepeat && !KPOverlayActive() && event.window == KPGameWindow() &&
            !(modifiers & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand))) {
          dispatch_async(dispatch_get_main_queue(), ^{ KPShowScreen(@"home"); });
          return nil;
        }
        return event;
      }];
}

static void InstallMenu() {
  NSMenu *mainMenu = NSApp.mainMenu;
  if (mainMenu == nil) {
    mainMenu = [NSMenu new];
    NSApp.mainMenu = mainMenu;
  }

  NSMenuItem *appItem = mainMenu.itemArray.firstObject;
  if (appItem == nil) {
    appItem = [[NSMenuItem alloc] initWithTitle:@"KartPad" action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];
  }
  NSMenu *appMenu = appItem.submenu;
  if (appMenu == nil) {
    appMenu = [[NSMenu alloc] initWithTitle:@"KartPad"];
    appItem.submenu = appMenu;
  }
  if ([mainMenu itemWithTag:kKartPadMenuTag] != nil) return;

  bool hasStandardApplicationMenu = false;
  for (NSMenuItem *item in appMenu.itemArray) {
    if ([item.title hasPrefix:@"About "] ||
        item.action == @selector(orderFrontStandardAboutPanel:)) {
      hasStandardApplicationMenu = true;
      break;
    }
  }
  if (!hasStandardApplicationMenu) {
    [appMenu removeAllItems];

    NSMenuItem *about = [[NSMenuItem alloc]
        initWithTitle:@"About KartPad"
               action:@selector(orderFrontStandardAboutPanel:)
        keyEquivalent:@""];
    about.target = NSApp;
    [appMenu addItem:about];
    [appMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *settings = [[NSMenuItem alloc]
        initWithTitle:@"Settings…"
               action:@selector(openSettings:)
        keyEquivalent:@","];
    settings.target = Controller();
    [appMenu addItem:settings];
    [appMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *services = [[NSMenuItem alloc]
        initWithTitle:@"Services" action:nil keyEquivalent:@""];
    services.submenu = [[NSMenu alloc] initWithTitle:@"Services"];
    NSApp.servicesMenu = services.submenu;
    [appMenu addItem:services];
    [appMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *hide = [[NSMenuItem alloc]
        initWithTitle:@"Hide KartPad" action:@selector(hide:) keyEquivalent:@"h"];
    hide.target = NSApp;
    [appMenu addItem:hide];
    NSMenuItem *hideOthers = [[NSMenuItem alloc]
        initWithTitle:@"Hide Others"
               action:@selector(hideOtherApplications:)
        keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask =
        NSEventModifierFlagOption | NSEventModifierFlagCommand;
    hideOthers.target = NSApp;
    [appMenu addItem:hideOthers];
    NSMenuItem *showAll = [[NSMenuItem alloc]
        initWithTitle:@"Show All"
               action:@selector(unhideAllApplications:)
        keyEquivalent:@""];
    showAll.target = NSApp;
    [appMenu addItem:showAll];
    [appMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit KartPad"
               action:@selector(quitKartPad:)
        keyEquivalent:@"q"];
    quit.target = Controller();
    [appMenu addItem:quit];
  }

  for (NSMenuItem *item in appMenu.itemArray) {
    if ([item.title hasPrefix:@"Settings"] ||
        [item.title hasPrefix:@"Preferences"]) {
      item.target = Controller();
      item.action = @selector(openSettings:);
      item.enabled = YES;
    } else if (item.action == @selector(terminate:)) {
      item.target = Controller();
      item.action = @selector(quitKartPad:);
    }
  }

  // SDL makes a Window menu only when it creates the app itself; KartPad creates the app first (to
  // take the focus at launch), so it makes its own: Minimize, Zoom and the window list.
  if (NSApp.windowsMenu == nil) {
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [mainMenu addItem:windowItem];
    NSApp.windowsMenu = windowMenu;
  }

  NSInteger productMenuIndex = mainMenu.numberOfItems;
  for (NSInteger index = 0; index < mainMenu.numberOfItems; ++index) {
    if ([[mainMenu itemAtIndex:index].title isEqualToString:@"Window"]) {
      productMenuIndex = index;
      break;
    }
  }
  NSMenuItem *gameMenuItem = [[NSMenuItem alloc]
      initWithTitle:@"Game" action:nil keyEquivalent:@""];
  gameMenuItem.tag = kKartPadMenuTag;
  NSMenu *gameMenu = [[NSMenu alloc] initWithTitle:@"Game"];
  gameMenu.delegate = Controller();
  // HOME: everything players need, over the game. Escape opens it from the game window (the key
  // monitor), not as a menu shortcut, so Escape keeps its meaning in the Mii editor and text fields.
  NSMenuItem *home = [[NSMenuItem alloc] initWithTitle:@"HOME (esc)" action:@selector(openHome:) keyEquivalent:@""];
  home.target = Controller();
  [gameMenu addItem:home];
  [gameMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *restart = [[NSMenuItem alloc]
      initWithTitle:@"Apply Changes" action:@selector(restartKartPad:) keyEquivalent:@""];
  restart.target = Controller();
  Controller().restartItem = restart;
  [gameMenu addItem:restart];
  [gameMenu addItem:NSMenuItem.separatorItem];
  [Controller() menuNeedsUpdate:gameMenu];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  NSString *activeProfile = NSUserDefaults.standardUserDefaults
      ? [NSUserDefaults.standardUserDefaults stringForKey:kKartPadRuntimeProfileDefaultsKey]
      : nil;
  if (activeProfile.length == 0) activeProfile = kKartPadBaseProfile;
  NSMenuItem *original = [[NSMenuItem alloc]
      initWithTitle:@"Original Mario Kart Wii"
             action:@selector(useOriginalGame:) keyEquivalent:@"1"];
  original.target = Controller();
  original.state = [activeProfile isEqualToString:kKartPadBaseProfile]
      ? NSControlStateValueOn : NSControlStateValueOff;
  [gameMenu addItem:original];
  NSMenuItem *retro = [[NSMenuItem alloc]
      initWithTitle:@"Retro Rewind"
             action:@selector(useRetroRewind:) keyEquivalent:@"2"];
  retro.target = Controller();
  retro.state = [activeProfile isEqualToString:kKartPadRetroProfile]
      ? NSControlStateValueOn : NSControlStateValueOff;
  [gameMenu addItem:retro];
  // The Retro Rewind pack's own updates (Help → Check for Updates… is KartPad's).
  if (KPLocalUpdateSettings() != nil) {
    NSMenuItem *updates = [[NSMenuItem alloc] initWithTitle:@"Retro Rewind Updates…"
        action:@selector(showAutomaticUpdates:) keyEquivalent:@""];
    updates.target = Controller();
    [gameMenu addItem:updates];
    if (NSString *revertTitle = KPLocalUpdateRevertTitle()) {
      NSMenuItem *revert = [[NSMenuItem alloc] initWithTitle:revertTitle
          action:@selector(revertAutomaticUpdate:) keyEquivalent:@""];
      revert.target = Controller();
      [gameMenu addItem:revert];
    }
  }
  [gameMenu addItem:NSMenuItem.separatorItem];
#endif
  NSMenuItem *settings = [[NSMenuItem alloc]
      initWithTitle:@"Game Settings…" action:@selector(openSettings:)
      keyEquivalent:@""];
  settings.target = Controller();
  [gameMenu addItem:settings];
  // SDL's Window → Toggle Full Screen (⌃⌘F) is macOS full screen, which the Display mode setting
  // doesn't follow. It goes through that setting instead.
  bool fullScreenItem = false;
  for (NSMenuItem *menu in mainMenu.itemArray) {
    for (NSMenuItem *item in menu.submenu.itemArray) {
      if (item.action != @selector(toggleFullScreen:)) continue;
      item.target = Controller();
      item.action = @selector(toggleGameFullScreen:);
      fullScreenItem = true;
    }
  }
  if (!fullScreenItem) {
    NSMenuItem *fullScreen = [[NSMenuItem alloc]
        initWithTitle:@"Enter Full Screen" action:@selector(toggleGameFullScreen:) keyEquivalent:@"f"];
    fullScreen.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    fullScreen.target = Controller();
    [gameMenu addItem:fullScreen];
  }
  gameMenuItem.submenu = gameMenu;
  [mainMenu insertItem:gameMenuItem atIndex:productMenuIndex++];

  NSMenuItem *playerMenuItem = [[NSMenuItem alloc]
      initWithTitle:@"Player" action:nil keyEquivalent:@""];
  NSMenu *playerMenu = [[NSMenu alloc] initWithTitle:@"Player"];
  playerMenu.autoenablesItems = NO;
  playerMenu.delegate = Controller();
  [Controller() menuNeedsUpdate:playerMenu];
  playerMenuItem.submenu = playerMenu;
  [mainMenu insertItem:playerMenuItem atIndex:productMenuIndex++];

  NSMenuItem *dataMenuItem = [[NSMenuItem alloc]
      initWithTitle:@"Data" action:nil keyEquivalent:@""];
  NSMenu *dataMenu = [[NSMenu alloc] initWithTitle:@"Data"];
  NSMenuItem *gameData = [[NSMenuItem alloc]
      initWithTitle:@"Choose Mario Kart Wii Data…" action:@selector(chooseGameData:)
      keyEquivalent:@""];
  gameData.target = Controller();
  [dataMenu addItem:gameData];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  NSMenuItem *retroData = [[NSMenuItem alloc]
      initWithTitle:@"Choose Retro Rewind Data…"
             action:@selector(chooseRetroRewindData:) keyEquivalent:@""];
  retroData.target = Controller();
  [dataMenu addItem:retroData];
#endif
  [dataMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *ghosts = [[NSMenuItem alloc]
      initWithTitle:@"Time Trial Ghosts…" action:@selector(openGhosts:) keyEquivalent:@""];
  ghosts.target = Controller();
  [dataMenu addItem:ghosts];
  [dataMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *data = [[NSMenuItem alloc]
      initWithTitle:@"Show KartPad Data"
             action:@selector(showApplicationSupport:) keyEquivalent:@""];
  data.target = Controller();
  [dataMenu addItem:data];
  NSMenuItem *cache = [[NSMenuItem alloc]
      initWithTitle:@"Show KartPad Cache"
             action:@selector(showCache:) keyEquivalent:@""];
  cache.target = Controller();
  [dataMenu addItem:cache];
  dataMenuItem.submenu = dataMenu;
  [mainMenu insertItem:dataMenuItem atIndex:productMenuIndex++];

  NSMenuItem *controlsMenuItem = [[NSMenuItem alloc]
      initWithTitle:@"Controls" action:nil keyEquivalent:@""];
  NSMenu *controlsMenu = [[NSMenu alloc] initWithTitle:@"Controls"];
  NSMenuItem *multiplayer = [[NSMenuItem alloc]
      initWithTitle:@"Multiplayer…" action:@selector(showMultiplayer:) keyEquivalent:@""];
  multiplayer.target = Controller();
  [controlsMenu addItem:multiplayer];

  NSMenuItem *controllerSettings = [[NSMenuItem alloc]
      initWithTitle:@"Controller Settings…"
             action:@selector(showControllerSettings:) keyEquivalent:@""];
  controllerSettings.target = Controller();
  [controlsMenu addItem:controllerSettings];
  NSMenuItem *controls = [[NSMenuItem alloc]
      initWithTitle:@"Control Reference…" action:@selector(showControls:)
      keyEquivalent:@"/"];
  controls.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  controls.target = Controller();
  [controlsMenu addItem:controls];
  NSMenuItem *phone = [[NSMenuItem alloc]
      initWithTitle:@"Add Phone Controller…" action:@selector(addPhoneController:) keyEquivalent:@""];
  phone.target = Controller();
  [controlsMenu addItem:phone];
  [controlsMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *experimentalWiimote = [[NSMenuItem alloc]
      initWithTitle:@"Experimental Wii Remote + Nunchuk"
             action:@selector(toggleExperimentalWiimote:) keyEquivalent:@""];
  experimentalWiimote.target = Controller();
  experimentalWiimote.state = [NSUserDefaults.standardUserDefaults
      boolForKey:KartPadExperimentalWiimoteDefaultsKey]
      ? NSControlStateValueOn : NSControlStateValueOff;
  [controlsMenu addItem:experimentalWiimote];
  NSMenuItem *pairWiimote = [[NSMenuItem alloc]
      initWithTitle:@"Pair Wii Remote…" action:@selector(pairWiimote:)
      keyEquivalent:@""];
  pairWiimote.target = Controller();
  [controlsMenu addItem:pairWiimote];
  controlsMenuItem.submenu = controlsMenu;
  [mainMenu insertItem:controlsMenuItem atIndex:productMenuIndex];

  NSMenuItem *helpMenuItem = [[NSMenuItem alloc]
      initWithTitle:@"Help" action:nil keyEquivalent:@""];
  NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
  NSString *diagnosticsTitle =
      [@"Save Diagnostics Report" stringByAppendingString:@"…"];
  NSMenuItem *diagnostics = [[NSMenuItem alloc]
      initWithTitle:diagnosticsTitle
             action:@selector(saveDiagnostics:)
      keyEquivalent:@""];
  diagnostics.target = Controller();
  [helpMenu addItem:diagnostics];
  NSMenuItem *report = [helpMenu addItemWithTitle:@"Report a Problem…"
      action:@selector(reportProblem:) keyEquivalent:@""];
  report.target = Controller();
  NSMenuItem *guide = [helpMenu addItemWithTitle:@"Reporting and Existing Issues"
      action:@selector(showReportingGuide:) keyEquivalent:@""];
  guide.target = Controller();
  [helpMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *upstream = [helpMenu addItemWithTitle:@"Built on WiiCompiled"
      action:@selector(showWiiCompiled:) keyEquivalent:@""];
  upstream.target = Controller();
  helpMenuItem.submenu = helpMenu;
  [mainMenu addItem:helpMenuItem];
}

void KartPadMacShellInstall(void) {
  if (KPFullscreenAcrossNotch()) {
    SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES, "0");
    SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY, "never");
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApplication sharedApplication];
    InstallSettingsShortcutMonitor();
    InstallMenu();
#if KP_QA_HOOKS
    KPStartQA();
#endif
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
    KPStartLocalUpdates();
#endif
  });
}

bool KartPadMacShellPrepareGameData(void) {
  // A restart's curtain (KartPadCurtain.inc.mm) is this app started to hold a card over the window.
  if (NSString *curtain = NSProcessInfo.processInfo.environment[KPCurtainVariable]; curtain.length) {
    unsetenv(KPCurtainVariable.UTF8String);
    if ([NSFileManager.defaultManager fileExistsAtPath:curtain]) {
      @autoreleasepool { KPRunCurtain(curtain); }
      return false;
    }
  }
  // Opened from the Dock or Finder, KartPad finishes launching and takes the focus straight away,
  // while macOS still hands it over. Left to the game window (after an update check and Retro
  // Rewind's file checks), it can come too late: macOS no longer brings a starting app forward, and
  // the game opens behind whatever was in front. Automated checks never take the focus.
  NSApplication *launching = NSApplication.sharedApplication;
  [launching setActivationPolicy:NSApplicationActivationPolicyRegular];
  [launching finishLaunching];
  // After finishLaunching, which installs AppKit's quit handler (SDL doesn't run it again).
  [NSAppleEventManager.sharedAppleEventManager setEventHandler:Controller()
                                                   andSelector:@selector(handleQuitEvent:withReplyEvent:)
                                                 forEventClass:kCoreEventClass
                                                    andEventID:kAEQuitApplication];
  if (!KPUIBackgroundAutomation()) [launching activate];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  // Activation completes before any game files are opened. The helper relaunches
  // the replacement (or, after repeated failed launches, the previous) app after
  // this process exits.
  if (KPActivateLocalUpdate()) return false;
#endif
  KartPadApplyPrivateServerAtLaunch();
  @autoreleasepool {
    const std::filesystem::path configPath = RuntimeConfigFile::ResolveConfigPath();
    const bool hadConfig = std::filesystem::exists(configPath);
    NSError *miiError = nil;
    // Discarding the waiting changes lets the game start; the rest of the apply is then retried.
    while (!KartPadApplyPendingMiiDatabase(&miiError)) {
      NSLog(@"[KartPad] pending Mii changes were not applied: %@",
            miiError.localizedDescription);
      const BOOL discardable = KartPadCanDiscardPendingMiiChanges();
      KPCurtainDone();
      NSAlert *failure = [NSAlert new];
      failure.messageText = @"Pending Mii Changes Couldn’t Be Applied";
      failure.informativeText = miiError.localizedDescription ?: @"Restart KartPad to try again. Nothing was lost.";
      if (discardable) {
        failure.informativeText = [failure.informativeText stringByAppendingString:
            @"\n\nDiscard Mii Changes drops the waiting Mii and license changes and starts the game. Miis and licenses stay as they are now."];
      }
      [failure addButtonWithTitle:@"Quit"];
      if (discardable) [failure addButtonWithTitle:@"Discard Mii Changes"].hasDestructiveAction = YES;
      NSError *discardError = nil;
      if ([failure runModal] != NSAlertSecondButtonReturn ||
          !KartPadDiscardPendingMiiChanges(&discardError)) {
        if (discardError) NSLog(@"[KartPad] pending Mii changes were not discarded: %@",
                                discardError.localizedDescription);
        return false;
      }
      miiError = nil;
    }
    KartPadApplyExperimentalWiimotePreference();
    RuntimeConfigFile::EnsureConfigFile();
    const RuntimeUserConfig initialConfig = RuntimeConfigFile::LoadConfigFile();
    const bool unconfigured = !initialConfig.dvdRoot && !initialConfig.retroRewindRoot;
    if (!hadConfig || unconfigured) {
      RuntimeConfigFile::WriteSetting("video", "resolution_multiplier", "2.0");
      RuntimeConfigFile::Reload();
    }
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
    NSString *selectedProfile = [NSUserDefaults.standardUserDefaults
        stringForKey:kKartPadRuntimeProfileDefaultsKey];
    if (![selectedProfile isEqualToString:kKartPadRetroProfile]) {
      selectedProfile = kKartPadBaseProfile;
    }
    if ([selectedProfile isEqualToString:kKartPadRetroProfile]) {
      NSError *retroError = nil;
      if (ValidateRetroRewindRoot(ConfiguredRetroRewindRoot(), &retroError) != nil ||
          retroError != nil) {
        selectedProfile = kKartPadBaseProfile;
        [NSUserDefaults.standardUserDefaults setObject:selectedProfile
                                                 forKey:kKartPadRuntimeProfileDefaultsKey];
      }
    }
    setenv("KARTPAD_RUNTIME_PROFILE", selectedProfile.UTF8String, 1);
#endif
    BeginSession();

    // The command-line self-build has already extracted and validated the
    // supplied WBFS. Let it hand that private tree to the app without forcing
    // the user through an unrelated folder picker on first launch.
    if (const char *prepared = std::getenv("KARTPAD_SELF_BUILD_GAME_DATA_ROOT");
        prepared != nullptr && *prepared != '\0') {
      NSString *root = [NSString stringWithUTF8String:prepared];
      NSError *preparedError = nil;
      NSString *validation = ValidateExtractedRoot(root, &preparedError);
      BOOL configured = validation == nil && preparedError == nil &&
                        WriteGameDataRoot(root);
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
      const char *preparedRetro =
          std::getenv("KARTPAD_SELF_BUILD_RETRO_REWIND_ROOT");
      if (configured && preparedRetro != nullptr && *preparedRetro != '\0') {
        NSString *retroRoot = [NSString stringWithUTF8String:preparedRetro];
        NSError *retroError = nil;
        NSString *retroValidation = ValidateRetroRewindRoot(retroRoot, &retroError);
        configured = retroValidation == nil && retroError == nil &&
                     WriteRetroRewindRoot(retroRoot);
      }
#endif
      if (configured) {
        std::cout << "[kartpad-macos] Configured validated self-build game data."
                  << std::endl;
      } else {
        std::cerr << "[kartpad-macos] Unable to configure self-build game data: "
                  << (preparedError.localizedDescription.UTF8String ?:
                      validation.UTF8String ?: "unknown error")
                  << std::endl;
      }
      MarkSessionClean();
      return false;
    }

    NSError *error = nil;
    NSString *configured = ConfiguredGameDataRoot();
    if (ValidateExtractedRoot(configured, &error) == nil && error == nil) {
      return true;
    }

    NSApplication *app = [NSApplication sharedApplication];
    NSMenu *temporaryMainMenu = nil;
    if (app.mainMenu == nil) {
      temporaryMainMenu = [NSMenu new];
      NSMenuItem *applicationItem =
          [[NSMenuItem alloc] initWithTitle:@"KartPad" action:nil keyEquivalent:@""];
      applicationItem.submenu = [[NSMenu alloc] initWithTitle:@"KartPad"];
      [temporaryMainMenu addItem:applicationItem];
      app.mainMenu = temporaryMainMenu;
    }
    auto finishFirstRunMenu = [&] {
      if (temporaryMainMenu != nil && app.mainMenu == temporaryMainMenu) {
        app.mainMenu = nil;
      }
    };
    if (!KPUIBackgroundAutomation()) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activate]; });
    KPCurtainDone();
    // KartPad's guided setup, which a controller can finish. (KartPadClassicSetup keeps the plain
    // question and folder picker below.)
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"KartPadClassicSetup"]) {
      NSString *profile = KPRunSetup(configured.length > 0);
      finishFirstRunMenu();
      if (profile == nil) return false;
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
      [NSUserDefaults.standardUserDefaults setObject:profile forKey:kKartPadRuntimeProfileDefaultsKey];
      setenv("KARTPAD_RUNTIME_PROFILE", profile.UTF8String, 1);
#endif
      return true;
    }
    for (;;) {
      NSAlert *required = [NSAlert new];
      required.messageText = @"Game Data Required";
      required.informativeText =
          @"KartPad does not include Mario Kart Wii. Choose your own extracted RMCP01 DATA folder to continue.";
      [required addButtonWithTitle:@"Choose Extracted Folder…"];
      [required addButtonWithTitle:@"Quit"];
      if ([required runModal] != NSAlertFirstButtonReturn) {
        finishFirstRunMenu();
        return false;
      }

      NSString *root = ChooseAndValidateGameData();
      if (root == nil) {
        finishFirstRunMenu();
        return false;
      }
      if (root.length == 0) continue;
      if (WriteGameDataRoot(root)) {
        finishFirstRunMenu();
        return true;
      }

      NSAlert *writeError = [NSAlert new];
      writeError.messageText = @"Game Data Could Not Be Saved";
      writeError.informativeText = @"KartPad could not update Config.toml.";
      [writeError runModal];
    }
  }
}
