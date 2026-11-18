// Progress sync (KartPadSync.h). Included at the end of KartPadMiiManager.mm, which knows where the
// Mii database and saves live and how to check them.
//
// The folder holds one <device id>.kartpadsync per device: its Miis, saves and ratings with the
// generation they make and every generation they descend from. A device keeps the generation its
// files last matched (its base). Another device's file it hasn't seen is newer when it descends from
// the base; if this device changed its files too, or the two never shared a base, the player
// chooses. Keeping one side makes a generation that descends from both, so the other device loads
// it without asking. Files are only replaced at launch, after a backup.

#import "KartPadSync.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/sysctl.h>

@implementation KartPadSyncProgress
@end

namespace {
namespace sync {

NSString *const kExtension = @"kartpadsync";
const char kMagic[8] = {'K', 'P', 'S', 'Y', 'N', 'C', '0', '1'};
constexpr NSUInteger kHistoryLimit = 400;
constexpr NSUInteger kBackupsKept = 10;
constexpr NSUInteger kRatingBytes = 1640;
constexpr unsigned long long kMaxSnapshotBytes = 64ull << 20;

dispatch_queue_t Queue() {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("dev.kartpad.sync", DISPATCH_QUEUE_SERIAL); });
  return queue;
}

// Runs `work` on the sync queue and waits for it at most `timeout` seconds (forever when negative).
// Work that outlasts the wait still finishes, in order, before anything queued after it.
BOOL RunWaiting(NSTimeInterval timeout, dispatch_block_t work) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(Queue(), ^{ work(); dispatch_semaphore_signal(done); });
  const dispatch_time_t limit = timeout < 0 ? DISPATCH_TIME_FOREVER
      : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  return dispatch_semaphore_wait(done, limit) == 0;
}

std::mutex& StateLock() { static std::mutex lock; return lock; }
NSString *Problem = nil;  // under StateLock: why the last check couldn't finish

NSString *Directory() { return [SupportRoot() stringByAppendingPathComponent:@"Sync"]; }
NSString *StatePath() { return [Directory() stringByAppendingPathComponent:@"State.plist"]; }

// Only this process writes the state, so it's read from disk once (per support root) and kept.
NSString *CachedStatePath = nil;
NSDictionary *CachedState = nil;
NSMutableDictionary *LoadStateLocked() {
  NSString *path = StatePath();
  if (![CachedStatePath isEqualToString:path]) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                                 format:nil error:nil] : nil;
    CachedState = [plist isKindOfClass:NSDictionary.class] ? plist : @{};
    CachedStatePath = path;
  }
  return [CachedState mutableCopy];
}
NSMutableDictionary *LoadState() {
  std::lock_guard<std::mutex> guard(StateLock());
  return LoadStateLocked();
}
// Changes the saved state under the lock; NO when it couldn't be written.
BOOL UpdateState(void (^change)(NSMutableDictionary *state)) {
  std::lock_guard<std::mutex> guard(StateLock());
  NSMutableDictionary *state = LoadStateLocked();
  change(state);
  [NSFileManager.defaultManager createDirectoryAtPath:Directory() withIntermediateDirectories:YES
                                           attributes:nil error:nil];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
      format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  if (data == nil || ![data writeToFile:StatePath() options:NSDataWritingAtomic error:nil]) return NO;
  CachedState = [state copy];
  CachedStatePath = StatePath();
  return YES;
}
void SetProblem(NSString *problem) {
  std::lock_guard<std::mutex> guard(StateLock());
  Problem = [problem copy];
}

NSString *DeviceID() {
  __block NSString *device = LoadState()[@"device"];
  if ([device isKindOfClass:NSString.class] && device.length > 0) return device;
  UpdateState(^(NSMutableDictionary *state) {
    if (![state[@"device"] isKindOfClass:NSString.class]) state[@"device"] = NSUUID.UUID.UUIDString;
    device = state[@"device"];
  });
  return device;
}

NSString *DeviceName() {
#if defined(KARTPAD_MII_MANAGER_TESTING)
  const char *name = std::getenv("KARTPAD_SYNC_TEST_DEVICE_NAME");
  return name ? @(name) : @"Test";
#elif TARGET_OS_OSX
  NSString *name = NSHost.currentHost.localizedName;
  return name.length > 0 ? name : @"Mac";
#else
  char machine[64] = {};
  size_t size = sizeof(machine) - 1;
  NSString *model = sysctlbyname("hw.machine", machine, &size, nullptr, 0) == 0 ? @(machine) : @"";
  for (NSString *family in @[@"iPhone", @"iPad", @"AppleTV"])
    if ([model hasPrefix:family]) return [family isEqualToString:@"AppleTV"] ? @"Apple TV" : family;
  return @"iPhone";
#endif
}

NSString *RatingsPath() {
  return [SupportRoot() stringByAppendingPathComponent:@"NAND/shared2/Pulsar/RetroRewind6/RRRating.pul"];
}

// What travels: the Mii database, each save profile and Retro Rewind ratings, by key.
NSArray<NSArray<NSString *> *> *Items() {
  NSMutableArray *items = [NSMutableArray arrayWithObject:@[@"mii", DatabasePath()]];
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations())
    [items addObject:@[location[@"identifier"], location[@"path"]]];
  [items addObject:@[@"retro_ratings", RatingsPath()]];
  return items;
}

uint32_t Big32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

BOOL ValidRatings(NSData *data) {
  if (data.length != kRatingBytes) return NO;
  const uint8_t *p = static_cast<const uint8_t *>(data.bytes);
  if (Big32(p) != 0x52525254 || Big32(p + 4) != 0x00010064) return NO;
  for (NSUInteger entry = 0; entry < 100; entry++) {
    const uint32_t flags = Big32(p + 8 + entry * 16 + 12);
    if (flags > 1) return NO;
  }
  return YES;
}

BOOL ValidItem(NSString *key, NSData *data) {
  if ([key isEqualToString:@"mii"]) return ValidateData(data, nullptr);
  if ([key isEqualToString:@"retro_ratings"]) return ValidRatings(data);
  return ValidateRawSave(data, nullptr);
}

NSString *Hash(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *text = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (unsigned char byte : digest) [text appendFormat:@"%02x", byte];
  return text;
}

NSDictionary<NSString *, NSString *> *Fingerprint(NSDictionary<NSString *, NSData *> *files) {
  NSMutableDictionary *hashes = [NSMutableDictionary dictionary];
  for (NSString *key in files) hashes[key] = Hash(files[key]);
  return hashes;
}

// Files read and checked before, by path, with the date and size they had (sync queue only).
NSMutableDictionary<NSString *, NSArray *> *ReadCache() {
  static NSMutableDictionary *cache = [NSMutableDictionary dictionary];
  return cache;
}
id Cached(NSString *path, NSDictionary *attributes) {
  NSArray *entry = ReadCache()[path];
  return entry && [entry[0] isEqual:attributes.fileModificationDate] && [entry[1] isEqual:@(attributes.fileSize)]
      ? entry[2] : nil;
}
void Remember(NSString *path, NSDictionary *attributes, id value) {
  if (attributes.fileModificationDate && value) ReadCache()[path] = @[attributes.fileModificationDate, @(attributes.fileSize), value];
}

// This device's files, each read whole while unchanged and checked. nil when one couldn't be read
// cleanly (the game was writing it); an empty dictionary when none exist yet.
NSDictionary<NSString *, NSData *> *ReadLocal(NSDate **played) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSDate *newest = nil;
  for (NSArray<NSString *> *item in Items()) {
    NSData *data = nil;
    NSDate *modified = nil;
    BOOL read = NO;
    NSDictionary *known = [files attributesOfItemAtPath:item[1] error:nil];
    if ((data = Cached(item[1], known))) {
      modified = known.fileModificationDate;
      read = YES;
    }
    for (int attempt = 0; attempt < 4 && !read; attempt++) {
      if (attempt > 0) [NSThread sleepForTimeInterval:0.5];
      NSDictionary *before = [files attributesOfItemAtPath:item[1] error:nil];
      if (before == nil) {
        read = ![files fileExistsAtPath:item[1]];
        data = nil;
        continue;
      }
      data = [NSData dataWithContentsOfFile:item[1] options:NSDataReadingUncached error:nil];
      NSDictionary *after = [files attributesOfItemAtPath:item[1] error:nil];
      modified = after.fileModificationDate;
      read = data != nil && after != nil && [before.fileModificationDate isEqual:modified] &&
             before.fileSize == after.fileSize && data.length == after.fileSize && ValidItem(item[0], data);
      if (read) Remember(item[1], after, data);
    }
    if (!read) return nil;
    if (data == nil) continue;
    result[item[0]] = data;
    if (modified && (newest == nil || [modified compare:newest] == NSOrderedDescending)) newest = modified;
  }
  if (played) *played = newest;
  return result;
}

NSArray<NSString *> *LicenseNames(NSDictionary<NSString *, NSData *> *files) {
  NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
  for (NSString *key in @[@"retro_rewind", @"original", @"retro_rewind_separate"]) {
    NSData *save = files[key];
    if (save.length != kartpad::ghost::SaveBytes) continue;
    const uint8_t *p = static_cast<const uint8_t *>(save.bytes);
    for (int license = 0; license < 4; license++) {
      const uint8_t *entry = p + 8 + license * 0x8CC0;
      if (Big32(entry) != 0x524B5044) continue;  // RKPD
      unichar name[10];
      NSUInteger length = 0;
      while (length < 10 && (entry[0x14 + length * 2] | entry[0x15 + length * 2]) != 0) {
        name[length] = (unichar)(entry[0x14 + length * 2] << 8 | entry[0x15 + length * 2]);
        length++;
      }
      if (length > 0) [names addObject:[NSString stringWithCharacters:name length:length]];
    }
  }
  return names.array;
}

NSArray<NSString *> *MergeHistory(NSArray<NSString *> *first, NSArray<NSString *> *second) {
  NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSet];
  for (NSArray *list in @[first ?: @[], second ?: @[]])
    for (id generation in list)
      if ([generation isKindOfClass:NSString.class] && merged.count < kHistoryLimit) [merged addObject:generation];
  return merged.array;
}

#pragma mark Snapshots

NSData *Encode(NSDictionary *snapshot) {
  NSData *raw = [NSPropertyListSerialization dataWithPropertyList:snapshot
      format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  NSData *packed = [raw compressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZFSE error:nil];
  if (packed == nil) return nil;
  NSMutableData *data = [NSMutableData dataWithBytes:kMagic length:sizeof(kMagic)];
  [data appendData:packed];
  return data;
}

// A snapshot whose every field and file checks out (with "hashes" added), or nil.
NSDictionary *Decode(NSData *data) {
  if (data.length <= sizeof(kMagic) || memcmp(data.bytes, kMagic, sizeof(kMagic)) != 0) return nil;
  NSData *packed = [data subdataWithRange:NSMakeRange(sizeof(kMagic), data.length - sizeof(kMagic))];
  NSData *raw = [packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZFSE error:nil];
  if (raw == nil || raw.length > kMaxSnapshotBytes) return nil;
  NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:raw
      options:NSPropertyListImmutable format:nil error:nil];
  if (![plist isKindOfClass:NSDictionary.class] || ![plist[@"format"] isEqual:@1]) return nil;
  for (NSString *key in @[@"device", @"name", @"generation"])
    if (![plist[key] isKindOfClass:NSString.class] || [plist[key] length] == 0) return nil;
  if (![plist[@"history"] isKindOfClass:NSArray.class] || ![plist[@"files"] isKindOfClass:NSDictionary.class] ||
      ![plist[@"sent"] isKindOfClass:NSDate.class])
    return nil;
  NSMutableSet *known = [NSMutableSet set];
  for (NSArray<NSString *> *item in Items()) [known addObject:item[0]];
  NSDictionary *files = plist[@"files"];
  if (files.count == 0) return nil;
  for (id key in files)
    if (![known containsObject:key] || ![files[key] isKindOfClass:NSData.class] || !ValidItem(key, files[key])) return nil;
  NSMutableDictionary *snapshot = [plist mutableCopy];
  snapshot[@"history"] = MergeHistory(@[plist[@"generation"]], plist[@"history"]);
  snapshot[@"hashes"] = Fingerprint(files);
  return snapshot;
}

KartPadSyncProgress *Progress(NSString *device, NSString *name, NSDate *played,
                              NSDictionary<NSString *, NSData *> *files) {
  KartPadSyncProgress *progress = [KartPadSyncProgress new];
  progress.deviceID = device;
  progress.deviceName = name;
  progress.played = played;
  progress.licenses = LicenseNames(files);
  return progress;
}
KartPadSyncProgress *Progress(NSDictionary *snapshot) {
  NSDate *played = [snapshot[@"played"] isKindOfClass:NSDate.class] ? snapshot[@"played"] : snapshot[@"sent"];
  return Progress(snapshot[@"device"], snapshot[@"name"], played, snapshot[@"files"]);
}

#pragma mark The folder

// The chosen folder, opened for the duration of `body`; NO when it can't be reached.
BOOL WithFolder(NSDictionary *state, void (^body)(NSURL *folder)) {
  NSData *bookmark = state[@"folder"];
  if (![bookmark isKindOfClass:NSData.class]) return NO;
  BOOL stale = NO;
  NSURL *folder = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                bookmarkDataIsStale:&stale error:nil];
  if (folder == nil) return NO;
  const BOOL scoped = [folder startAccessingSecurityScopedResource];
  BOOL directory = NO;
  const BOOL reachable = [NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&directory] && directory;
  if (reachable) {
    if (stale) {
      NSData *fresh = [folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
      if (fresh) UpdateState(^(NSMutableDictionary *saved) { saved[@"folder"] = fresh; });
    }
    body(folder);
  }
  if (scoped) [folder stopAccessingSecurityScopedResource];
  return reachable;
}

NSData *CoordinatedRead(NSURL *url) {
  __block NSData *data = nil;
  NSError *error = nil;
  [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:url
      options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *readURL) {
    NSNumber *size = nil;
    [readURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue <= kMaxSnapshotBytes)
      data = [NSData dataWithContentsOfURL:readURL options:NSDataReadingUncached error:nil];
  }];
  return data;
}

// Every other device's snapshot in the folder. Files iCloud hasn't downloaded yet are fetched,
// waiting until `deadline` for them.
NSArray<NSDictionary *> *ReadOthers(NSURL *folder, NSString *device, NSDate *deadline) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSArray<NSURL *> *contents = [files contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil
                                                       options:0 error:nil];
  NSMutableOrderedSet<NSURL *> *wanted = [NSMutableOrderedSet orderedSet];
  NSString *own = [device stringByAppendingPathExtension:kExtension];
  NSString *placeholder = [@"." stringByAppendingString:kExtension];
  for (NSURL *url in contents) {
    NSString *name = url.lastPathComponent;
    // An item iCloud hasn't downloaded shows as ".<name>.icloud".
    if ([name hasPrefix:@"."] && [name hasSuffix:@".icloud"]) {
      name = [name substringWithRange:NSMakeRange(1, name.length - 1 - 7)];
      if (![name hasSuffix:placeholder]) continue;
    } else if (![name.pathExtension isEqualToString:kExtension]) {
      continue;
    }
    if ([name isEqualToString:own]) continue;
    NSURL *real = [folder URLByAppendingPathComponent:name];
    [files startDownloadingUbiquitousItemAtURL:real error:nil];
    [wanted addObject:real];
  }
  NSMutableArray *snapshots = [NSMutableArray array];
  for (NSURL *url in wanted) {
    while (![files fileExistsAtPath:url.path] && [deadline timeIntervalSinceNow] > 0)
      [NSThread sleepForTimeInterval:0.25];
    if (![files fileExistsAtPath:url.path]) continue;
    NSDictionary *attributes = [files attributesOfItemAtPath:url.path error:nil];
    NSDictionary *snapshot = Cached(url.path, attributes);
    if (snapshot == nil) {
      snapshot = Decode(CoordinatedRead(url));
      NSDictionary *after = [files attributesOfItemAtPath:url.path error:nil];
      if (snapshot && [after.fileModificationDate isEqual:attributes.fileModificationDate]) Remember(url.path, after, snapshot);
    }
    if (snapshot && ![snapshot[@"device"] isEqualToString:device]) [snapshots addObject:snapshot];
  }
  return snapshots;
}

BOOL WriteOwn(NSURL *folder, NSString *device, NSData *data) {
  NSURL *url = [folder URLByAppendingPathComponent:[device stringByAppendingPathExtension:kExtension]];
  __block BOOL written = NO;
  NSError *error = nil;
  [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:url
      options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *writeURL) {
    written = [data writeToURL:writeURL options:NSDataWritingAtomic error:nil];
  }];
  return written;
}

#pragma mark Deciding

enum class Action { Nothing, Send, Load, Adopt, Choose };

struct Look {
  BOOL reachable = NO;
  NSDictionary<NSString *, NSData *> *local = nil;  // nil: couldn't be read cleanly
  NSDate *played = nil;
  NSDictionary *base = nil;
  NSArray<NSDictionary *> *others = @[];
  Action action = Action::Nothing;
  NSDictionary *other = nil;  // the snapshot to load, adopt or choose against
};

BOOL Changed(NSDictionary *base, NSDictionary *hashes) {
  return base == nil || ![base[@"hashes"] isEqual:hashes];
}

void Decide(Look& look) {
  NSDictionary *hashes = Fingerprint(look.local);
  NSSet *known = [NSSet setWithArray:look.base[@"history"] ?: @[]];
  NSDictionary *newest = nil;
  for (NSDictionary *snapshot in look.others) {
    if ([known containsObject:snapshot[@"generation"]]) continue;
    if (newest == nil || [snapshot[@"sent"] compare:newest[@"sent"]] == NSOrderedDescending) newest = snapshot;
  }
  const BOOL changed = Changed(look.base, hashes) && hashes.count > 0;
  look.other = newest;
  if (newest == nil) {
    look.action = changed ? Action::Send : Action::Nothing;
  } else if ([newest[@"hashes"] isEqual:hashes]) {
    look.action = Action::Adopt;
  } else if (look.base && [newest[@"history"] containsObject:look.base[@"generation"]]) {
    look.action = changed ? Action::Choose : Action::Load;
  } else {
    look.action = hashes.count == 0 ? Action::Load : Action::Choose;
  }
}

// Reads both sides and decides. Runs on the sync queue.
Look Gather(NSTimeInterval wait) {
  __block Look look;
  NSDictionary *state = LoadState();
  look.base = [state[@"base"] isKindOfClass:NSDictionary.class] ? state[@"base"] : nil;
  NSString *device = DeviceID();
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait];
  look.reachable = WithFolder(state, ^(NSURL *folder) { look.others = ReadOthers(folder, device, deadline); });
  NSDate *played = nil;
  look.local = ReadLocal(&played);
  look.played = played;
  if (look.reachable && look.local) Decide(look);
  return look;
}

void Synced(NSMutableDictionary *state) {
  state[@"synced"] = NSDate.date;
  [state removeObjectForKey:@"waiting"];
}

BOOL Send(const Look& look, NSArray<NSString *> *alsoDescendsFrom) {
  NSString *generation = NSUUID.UUID.UUIDString;
  NSArray *history = MergeHistory(@[generation], MergeHistory(look.base[@"history"], alsoDescendsFrom));
  NSString *device = DeviceID();
  NSMutableDictionary *snapshot = [@{@"format": @1, @"device": device, @"name": DeviceName(),
      @"generation": generation, @"history": history, @"sent": NSDate.date, @"files": look.local} mutableCopy];
  if (look.played) snapshot[@"played"] = look.played;
  NSData *data = Encode(snapshot);
  __block BOOL written = NO;
  if (data == nil || !WithFolder(LoadState(), ^(NSURL *folder) { written = WriteOwn(folder, device, data); }) || !written)
    return NO;
  NSDictionary *hashes = Fingerprint(look.local);
  return UpdateState(^(NSMutableDictionary *state) {
    state[@"base"] = @{@"generation": generation, @"history": history, @"hashes": hashes};
    Synced(state);
  });
}

// After loading or adopting, this device's file in the folder says so too (same generation), or
// it would go on offering the progress it had before.
void Mirror(NSDictionary *snapshot, NSDictionary<NSString *, NSData *> *files, NSArray *history) {
  NSString *device = DeviceID();
  NSMutableDictionary *mirror = [@{@"format": @1, @"device": device, @"name": DeviceName(),
      @"generation": snapshot[@"generation"], @"history": history, @"sent": NSDate.date, @"files": files} mutableCopy];
  if (snapshot[@"played"]) mirror[@"played"] = snapshot[@"played"];
  NSData *data = Encode(mirror);
  if (data) WithFolder(LoadState(), ^(NSURL *folder) { WriteOwn(folder, device, data); });
}

void PruneBackups(NSString *root) {
  NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]
      sortedArrayUsingSelector:@selector(compare:)];
  for (NSUInteger i = 0; i + kBackupsKept < names.count; i++)
    [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:names[i]] error:nil];
}

// Replaces this device's files with the snapshot's, after backing up the ones it replaces. Files
// the snapshot doesn't have stay.
BOOL Load(const Look& look, NSDictionary *snapshot) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSDateFormatter *format = [NSDateFormatter new];
  format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  format.dateFormat = @"yyyyMMdd-HHmmss";
  NSString *root = [SupportRoot() stringByAppendingPathComponent:@"SyncBackups"];
  NSString *backup = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@",
      [format stringFromDate:NSDate.date], [NSUUID.UUID.UUIDString substringToIndex:8]]];
  NSDictionary<NSString *, NSData *> *incoming = snapshot[@"files"];
  for (NSArray<NSString *> *item in Items()) {
    if (incoming[item[0]] == nil || look.local[item[0]] == nil || [look.local[item[0]] isEqual:incoming[item[0]]]) continue;
    if (![files createDirectoryAtPath:backup withIntermediateDirectories:YES attributes:nil error:nil] ||
        ![look.local[item[0]] writeToFile:[backup stringByAppendingPathComponent:[item[0] stringByAppendingPathExtension:@"dat"]]
                                  atomically:YES])
      return NO;
  }
  NSMutableDictionary<NSString *, NSData *> *result = [look.local mutableCopy];
  for (NSArray<NSString *> *item in Items()) {
    NSData *data = incoming[item[0]];
    if (data == nil || [look.local[item[0]] isEqual:data]) continue;
    if (![files createDirectoryAtPath:item[1].stringByDeletingLastPathComponent withIntermediateDirectories:YES
                           attributes:nil error:nil] ||
        ![data writeToFile:item[1] options:NSDataWritingAtomic error:nil])
      return NO;
    result[item[0]] = data;
  }
  PruneBackups(root);
  NSArray *history = MergeHistory(snapshot[@"history"], look.base[@"history"]);
  NSDictionary *hashes = Fingerprint(result);
  const BOOL saved = UpdateState(^(NSMutableDictionary *state) {
    state[@"base"] = @{@"generation": snapshot[@"generation"], @"history": history, @"hashes": hashes};
    [state removeObjectForKey:@"use"];
    Synced(state);
  });
  if (saved) Mirror(snapshot, result, history);
  return saved;
}

BOOL Adopt(const Look& look, NSDictionary *snapshot) {
  NSArray *history = MergeHistory(snapshot[@"history"], look.base[@"history"]);
  NSDictionary *hashes = Fingerprint(look.local);
  const BOOL saved = UpdateState(^(NSMutableDictionary *state) {
    state[@"base"] = @{@"generation": snapshot[@"generation"], @"history": history, @"hashes": hashes};
    Synced(state);
  });
  if (saved) Mirror(snapshot, look.local, history);
  return saved;
}

void Wait(NSString *kind, NSDictionary *snapshot) {
  UpdateState(^(NSMutableDictionary *state) {
    state[@"waiting"] = @{@"kind": kind, @"name": snapshot[@"name"], @"device": snapshot[@"device"]};
  });
}

// A check while the game runs: sends or adopts, and only notes newer progress for the next launch.
void CheckWhileRunning() {
  if (![LoadState()[@"folder"] isKindOfClass:NSData.class]) return;
  Look look = Gather(20);
  if (!look.reachable) return SetProblem(@"Folder unavailable");
  if (look.local == nil) return SetProblem(@"Waiting for the game to save");
  SetProblem(nil);
  switch (look.action) {
    case Action::Nothing: {
      UpdateState(^(NSMutableDictionary *state) { Synced(state); });
      break;
    }
    case Action::Send:
      if (!Send(look, nil)) SetProblem(@"Couldn’t write to the folder");
      break;
    case Action::Adopt: Adopt(look, look.other); break;
    case Action::Load: Wait(@"load", look.other); break;
    case Action::Choose: Wait(@"choose", look.other); break;
  }
}

__strong dispatch_source_t& Timer() { static dispatch_source_t timer; return timer; }

} // namespace sync
} // namespace

#pragma mark Public

BOOL KartPadSyncEnabled(void) { return [sync::LoadState()[@"folder"] isKindOfClass:NSData.class]; }

NSString *KartPadSyncFolderName(void) {
  NSDictionary *state = sync::LoadState();
  if (![state[@"folder"] isKindOfClass:NSData.class]) return nil;
  return [state[@"folderName"] isKindOfClass:NSString.class] ? state[@"folderName"] : @"Folder";
}

NSString *KartPadSyncThisDeviceName(void) { return sync::DeviceName(); }

BOOL KartPadSyncChooseFolder(NSURL *folder, NSError **error) {
  const BOOL scoped = [folder startAccessingSecurityScopedResource];
  NSData *bookmark = [folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:error];
  if (scoped) [folder stopAccessingSecurityScopedResource];
  if (bookmark == nil) return NO;
  NSString *name = folder.lastPathComponent;
  __block BOOL saved = NO;
  sync::RunWaiting(-1, ^{
    sync::DeviceID();
    saved = sync::UpdateState(^(NSMutableDictionary *state) {
      state[@"folder"] = bookmark;
      state[@"folderName"] = name ?: @"Folder";
      // A new folder starts fresh: what's there is compared with this device's files.
      for (NSString *key in @[@"base", @"waiting", @"use", @"synced"]) [state removeObjectForKey:key];
    });
    sync::SetProblem(nil);
  });
  if (!saved && error) *error = ManagerError(70, "The sync setting couldn’t be saved.");
  return saved;
}

void KartPadSyncTurnOff(void) {
  sync::RunWaiting(-1, ^{
    sync::UpdateState(^(NSMutableDictionary *state) {
      for (NSString *key in @[@"folder", @"folderName", @"base", @"waiting", @"use", @"synced"])
        [state removeObjectForKey:key];
    });
    sync::SetProblem(nil);
  });
}

NSString *KartPadSyncStatus(void) {
  NSDictionary *state = sync::LoadState();
  if (![state[@"folder"] isKindOfClass:NSData.class]) return @"Off";
  if ([state[@"use"] isKindOfClass:NSDictionary.class])
    return @"Restart to load chosen progress";
  NSDictionary *waiting = state[@"waiting"];
  if ([waiting isKindOfClass:NSDictionary.class]) {
    return [waiting[@"kind"] isEqual:@"load"] ? @"Restart to load newer progress" : @"Restart to choose progress";
  }
  {
    std::lock_guard<std::mutex> guard(sync::StateLock());
    if (sync::Problem) return sync::Problem;
  }
  NSDate *synced = state[@"synced"];
  if (![synced isKindOfClass:NSDate.class]) return @"On";
  NSDateFormatter *format = [NSDateFormatter new];
  const BOOL today = [NSCalendar.currentCalendar isDateInToday:synced];
  format.dateStyle = today ? NSDateFormatterNoStyle : NSDateFormatterMediumStyle;
  format.timeStyle = today ? NSDateFormatterShortStyle : NSDateFormatterNoStyle;
  return [@"Synced " stringByAppendingString:[format stringFromDate:synced]];
}

NSString *KartPadSyncDescribe(KartPadSyncProgress *progress) {
  NSMutableArray *parts = [NSMutableArray array];
  if (progress.licenses.count > 0) [parts addObject:[progress.licenses componentsJoinedByString:@", "]];
  if (progress.played) {
    [parts addObject:[NSDateFormatter localizedStringFromDate:progress.played dateStyle:NSDateFormatterMediumStyle
                                                    timeStyle:NSDateFormatterShortStyle]];
  }
  return parts.count > 0 ? [parts componentsJoinedByString:@" · "] : @"No saves yet";
}

BOOL KartPadSyncNeedsRestart(void) {
  NSDictionary *state = sync::LoadState();
  return [state[@"folder"] isKindOfClass:NSData.class] &&
         ([state[@"use"] isKindOfClass:NSDictionary.class] || [state[@"waiting"] isKindOfClass:NSDictionary.class]);
}

void KartPadSyncAtLaunch(NSTimeInterval timeout,
                         KartPadSyncChoice (^choose)(KartPadSyncProgress *, KartPadSyncProgress *)) {
  if (!KartPadSyncEnabled()) return;
  __block sync::Look look;
  __block NSDictionary *use = nil;
  if (!sync::RunWaiting(timeout, ^{
        NSDictionary *wanted = sync::LoadState()[@"use"];
        use = [wanted isKindOfClass:NSDictionary.class] ? wanted : nil;
        look = sync::Gather(timeout * 0.75);  // downloads stop waiting before the launch does
      })) {
    return sync::SetProblem(@"Folder unavailable");
  }
  if (!look.reachable) return sync::SetProblem(@"Folder unavailable");
  if (look.local == nil) return sync::SetProblem(@"A save couldn’t be read");
  sync::SetProblem(nil);
  // Progress chosen in Settings replaces this device's, whatever changed here.
  if (use) {
    for (NSDictionary *snapshot in look.others) {
      if (![snapshot[@"device"] isEqualToString:use[@"device"]]) continue;
      sync::RunWaiting(-1, ^{ sync::Load(look, snapshot); });
      return;
    }
    sync::UpdateState(^(NSMutableDictionary *state) { [state removeObjectForKey:@"use"]; });
  }
  NSDictionary *other = look.other;
  switch (look.action) {
    case sync::Action::Nothing: {
      sync::RunWaiting(-1, ^{ sync::UpdateState(^(NSMutableDictionary *state) { sync::Synced(state); }); });
      break;
    }
    case sync::Action::Send: {
      sync::RunWaiting(timeout, ^{ if (!sync::Send(look, nil)) sync::SetProblem(@"Couldn’t write to the folder"); });
      break;
    }
    case sync::Action::Adopt: { sync::RunWaiting(-1, ^{ sync::Adopt(look, other); }); break; }
    case sync::Action::Load: { sync::RunWaiting(-1, ^{ sync::Load(look, other); }); break; }
    case sync::Action::Choose: {
      KartPadSyncProgress *mine = sync::Progress(sync::DeviceID(), sync::DeviceName(), look.played, look.local);
      switch (choose(mine, sync::Progress(other))) {
        case KartPadSyncChoiceKeepThisDevice: {
          sync::RunWaiting(timeout, ^{
            if (!sync::Send(look, other[@"history"])) sync::SetProblem(@"Couldn’t write to the folder");
          });
          break;
        }
        case KartPadSyncChoiceUseOther: { sync::RunWaiting(-1, ^{ sync::Load(look, other); }); break; }
        case KartPadSyncChoiceLater: { sync::Wait(@"choose", other); break; }
      }
      break;
    }
  }
}

void KartPadSyncStartWatching(void) {
  dispatch_async(sync::Queue(), ^{
    if (sync::Timer()) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sync::Queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), 60 * NSEC_PER_SEC,
                              10 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ sync::CheckWhileRunning(); });
    dispatch_resume(timer);
    sync::Timer() = timer;
  });
}

void KartPadSyncSendNow(NSTimeInterval timeout) {
  if (!KartPadSyncEnabled()) return;
  sync::RunWaiting(timeout, ^{ sync::CheckWhileRunning(); });
}

void KartPadSyncSendSoon(void (^done)(void)) {
  dispatch_async(sync::Queue(), ^{
    sync::CheckWhileRunning();
    if (done) dispatch_async(dispatch_get_main_queue(), done);
  });
}

NSArray<KartPadSyncProgress *> *KartPadSyncOtherDevices(NSTimeInterval timeout) {
  __block NSArray<NSDictionary *> *others = @[];
  if (!sync::RunWaiting(timeout, ^{
        NSDictionary *state = sync::LoadState();
        NSString *device = sync::DeviceID();
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        sync::WithFolder(state, ^(NSURL *folder) { others = sync::ReadOthers(folder, device, deadline); });
      }))
    return @[];
  NSMutableArray<KartPadSyncProgress *> *result = [NSMutableArray array];
  for (NSDictionary *snapshot in others) [result addObject:sync::Progress(snapshot)];
  [result sortUsingComparator:^NSComparisonResult(KartPadSyncProgress *a, KartPadSyncProgress *b) {
    return [b.played ?: NSDate.distantPast compare:a.played ?: NSDate.distantPast];
  }];
  return result;
}

BOOL KartPadSyncUseProgressAtNextLaunch(NSString *deviceID, NSError **error) {
  NSString *name = nil;
  for (KartPadSyncProgress *progress in KartPadSyncOtherDevices(10))
    if ([progress.deviceID isEqualToString:deviceID]) name = progress.deviceName;
  if (name == nil) {
    if (error) *error = ManagerError(71, "That device’s progress isn’t in the folder.");
    return NO;
  }
  __block BOOL saved = NO;
  sync::RunWaiting(-1, ^{
    saved = sync::UpdateState(^(NSMutableDictionary *state) { state[@"use"] = @{@"device": deviceID, @"name": name}; });
  });
  if (!saved && error) *error = ManagerError(70, "The sync setting couldn’t be saved.");
  return saved;
}

BOOL KartPadSyncCancelUseProgress(void) {
  __block BOOL saved = NO;
  sync::RunWaiting(-1, ^{ saved = sync::UpdateState(^(NSMutableDictionary *state) { [state removeObjectForKey:@"use"]; }); });
  return saved;
}
