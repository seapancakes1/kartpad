#import "KartPadMiiManager.h"
#import <TargetConditionals.h>

#if TARGET_OS_OSX && !defined(KARTPAD_MII_MANAGER_TESTING)
#include "runtime_config.h"
#endif

#include "kartpad/mii/mii_database.h"
#include "kartpad/mii/player_identity.h"
#include "kartpad/mii/appearance.h"

#if !defined(KARTPAD_MII_MANAGER_TESTING)
#include "console_identity.h"
#endif

#include <span>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <vector>
#include <sys/stat.h>

NSString *const KartPadMiiManagerErrorDomain = @"dev.kartpad.mii-manager";

namespace {

NSString *SupportRoot() {
#if defined(KARTPAD_MII_MANAGER_TESTING)
  const char *root = std::getenv("KARTPAD_MII_TEST_SUPPORT_ROOT");
  if (root == nullptr || root[0] != '/') std::abort();
  return [NSString stringWithUTF8String:root];
#elif TARGET_OS_OSX
  // Match the shell and runtime, including portable.txt/UserData. Never apply
  // another installation's pending identity changes during portable startup.
  const auto root = RuntimeConfigFile::ApplicationDataDirectory().string();
  return [NSString stringWithUTF8String:root.c_str()];
#else
  return [[NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Application Support"] stringByAppendingPathComponent:@"KartPad"];
#endif
}

NSString *DatabasePath() {
  return [SupportRoot() stringByAppendingPathComponent:
      @"NAND/shared2/menu/FaceLib/RFL_DB.dat"];
}

NSString *PendingGhostPath() { return [SupportRoot() stringByAppendingPathComponent:@"PendingGhost.plist"]; }

NSString *PendingPath() {
  return [SupportRoot() stringByAppendingPathComponent:@"PendingRFL_DB.dat"];
}

NSArray<NSDictionary<NSString *, NSString *> *> *SaveLocations() {
  NSString *support = SupportRoot();
  return @[
    @{
      @"identifier": @"original",
      @"title": @"Original Mario Kart Wii",
      @"path": [support stringByAppendingPathComponent:
          @"NAND/title/00010004/524d4350/data/rksys.dat"],
      @"backup": @"rksys-nand",
    },
    @{
      @"identifier": @"retro_rewind",
      @"title": @"Retro Rewind",
      @"path": [support stringByAppendingPathComponent:
          @"RetroRewind/riivolution/save/RetroWFC/RMCP/rksys.dat"],
      @"backup": @"rksys-retro-rewind",
    },
    @{
      @"identifier": @"retro_rewind_separate",
      @"title": @"Retro Rewind (Separate Save)",
      @"path": [support stringByAppendingPathComponent:
          @"RetroRewind/riivolution/save/RetroWFC2/RMCP/rksys.dat"],
      @"backup": @"rksys-retro-rewind-separate",
    },
  ];
}

NSString *PendingIdentityPath() {
  return [SupportRoot() stringByAppendingPathComponent:
      @"PendingPlayerIdentity.plist"];
}

NSString *PendingLicensePath() {
  return [SupportRoot() stringByAppendingPathComponent:
      @"PendingLicenseChange.plist"];
}

NSDictionary<NSString *, NSString *> *SaveLocation(NSString *identifier) {
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations()) {
    if ([location[@"identifier"] isEqualToString:identifier]) return location;
  }
  return nil;
}

NSError *ManagerError(NSInteger code, const std::string& message) {
  NSString *description = [NSString stringWithUTF8String:message.c_str()];
  if (description.length == 0) description = @"Unknown Mii database error.";
  return [NSError errorWithDomain:KartPadMiiManagerErrorDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: description}];
}

std::span<const uint8_t> Bytes(NSData *data) {
  return {static_cast<const uint8_t *>(data.bytes), data.length};
}

BOOL ValidateData(NSData *data, NSError **error) {
  const auto validation = kartpad::mii::ValidateDatabase(Bytes(data));
  if (!validation) {
    if (error != nullptr) *error = ManagerError(2, validation.message);
    return NO;
  }
  return YES;
}

BOOL ValidateSaveData(NSData *data, NSError **error) {
  const auto validation = kartpad::mii::ValidateRksys(Bytes(data));
  if (!validation) {
    if (error != nullptr) *error = ManagerError(5, validation.message);
    return NO;
  }
  return YES;
}

// A Mii or license name as it is stored: without surrounding spaces and line breaks. The editor,
// the Miis screen and the staged changes all check and save this, so they agree on what's valid.
NSString *NormalName(NSString *name) {
  return [name ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSData *PlayerNameData(NSString *name, NSError **error) {
  NSString *trimmed = NormalName(name);
  if (trimmed.length == 0 || trimmed.length > 10) {
    if (error != nullptr) {
      *error = ManagerError(6,
          "A player name must contain 1 to 10 characters.");
    }
    return nil;
  }
  NSData *encoded = [trimmed dataUsingEncoding:NSUTF16BigEndianStringEncoding
                           allowLossyConversion:NO];
  if (encoded == nil || encoded.length == 0 || encoded.length > 20) {
    if (error != nullptr) {
      *error = ManagerError(7,
          "The player name contains an unsupported character.");
    }
    return nil;
  }
  return encoded;
}

BOOL ReadCreateId(NSData *data,
                  std::array<uint8_t, kartpad::mii::kCreateIdByteSize>& result,
                  NSError **error) {
  if (data.length != result.size()) {
    if (error != nullptr) {
      *error = ManagerError(12, "The selected license identity is invalid.");
    }
    return NO;
  }
  std::copy_n(static_cast<const uint8_t *>(data.bytes), result.size(),
              result.begin());
  return YES;
}

BOOL BackupFile(NSString *source, NSString *folder, NSString *name,
                NSString *stamp, NSError **error) {
  NSFileManager *files = NSFileManager.defaultManager;
  if (![files fileExistsAtPath:source]) return YES;
  NSString *backups = [SupportRoot() stringByAppendingPathComponent:folder];
  if (![files createDirectoryAtPath:backups withIntermediateDirectories:YES
                         attributes:nil error:error]) {
    return NO;
  }
  NSString *backup = [backups stringByAppendingPathComponent:
      [NSString stringWithFormat:@"%@-%@.dat", name, stamp]];
  return [files copyItemAtPath:source toPath:backup error:error];
}

} // namespace


// A commit's journal (CommitChanges), there only while one is being written or was interrupted.
static NSString *JournalPath() {
  return [SupportRoot() stringByAppendingPathComponent:@"MiiEditorTransaction.plist"];
}

// Mii and license changes wait in a queue until the next launch, because the running game holds
// the database and saves. Each change is checked against the result of the changes queued before
// it, and the launch replays them in order over the latest files, so race progress saved in the
// meantime is kept. Older versions staged a single change in their own files; those still apply,
// and nothing is queued until they have.
static NSString *QueuePath() {
  return [SupportRoot() stringByAppendingPathComponent:@"PendingMiiChanges.plist"];
}
static BOOL OtherChangesPending() {
  NSFileManager *files = NSFileManager.defaultManager;
  return [files fileExistsAtPath:JournalPath()] || KartPadHasPendingSaveRestore() || [files fileExistsAtPath:PendingGhostPath()] ||
         [files fileExistsAtPath:PendingPath()] || [files fileExistsAtPath:PendingIdentityPath()] ||
         [files fileExistsAtPath:PendingLicensePath()];
}

namespace {

using CreateId = std::array<uint8_t, kartpad::mii::kCreateIdByteSize>;

// The database and saves as the queued changes leave them. Each file is read on first use; a file
// that does not exist reads as nil.
struct Workspace {
  NSMutableDictionary<NSString *, id> *original = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, id> *current = [NSMutableDictionary dictionary];
  BOOL Load(NSString *path, NSError **error) {
    if (current[path] != nil) return YES;
    id data = NSNull.null;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
      data = [NSData dataWithContentsOfFile:path options:0 error:error];
      if (data == nil) return NO;
    }
    original[path] = data;
    current[path] = data;
    return YES;
  }
  NSData *Data(NSString *path) {
    id data = current[path];
    return data == NSNull.null ? nil : data;
  }
  void Write(NSString *path, const std::vector<uint8_t>& bytes) {
    current[path] = [NSData dataWithBytes:bytes.data() length:bytes.size()];
  }
  // The files' data is never changed in place, so a copy shares it.
  Workspace Copy() const {
    Workspace copy;
    copy.original = [original mutableCopy];
    copy.current = [current mutableCopy];
    return copy;
  }
};

std::vector<uint8_t> Vector(NSData *data) {
  const auto bytes = Bytes(data);
  return {bytes.begin(), bytes.end()};
}

NSData *WorkspaceDatabase(Workspace& files, NSError **error) {
  if (!files.Load(DatabasePath(), error)) return nil;
  NSData *data = files.Data(DatabasePath());
  if (data == nil) {
    if (error != nullptr) *error = ManagerError(1,
        "No Mii database exists yet. Start Mario Kart Wii once, then try again.");
    return nil;
  }
  return ValidateData(data, error) ? data : nil;
}

// A save that exists and is valid, or nil. *missing says the save does not exist.
NSData *WorkspaceSave(Workspace& files, NSString *path, BOOL *missing, NSError **error) {
  *missing = NO;
  if (!files.Load(path, error)) return nil;
  NSData *data = files.Data(path);
  if (data == nil) *missing = YES;
  return data != nil && ValidateSaveData(data, error) ? data : nil;
}

NSError *InvalidChange() { return ManagerError(51, "A pending Mii change is invalid."); }

template <class T> T *Value(id value) { return [value isKindOfClass:[T class]] ? value : nil; }

NSData *NameValue(id value, NSError **error) {
  NSData *name = Value<NSData>(value);
  const auto validation = kartpad::mii::ValidateUtf16BigEndianName(Bytes(name));
  if (!validation) {
    if (error != nullptr) *error = ManagerError(21, validation.message);
    return nil;
  }
  return name;
}

// The Mii in the slot, which must still have the expected identity.
BOOL CheckMii(NSData *database, NSUInteger slot, const CreateId& expected, NSError **error) {
  for (const auto& record : kartpad::mii::ListMiis(Bytes(database))) {
    if (record.slot == slot && kartpad::mii::MiiCreateId(Bytes(database), slot) == expected) return YES;
  }
  if (error != nullptr) *error = ManagerError(20,
      "The selected Mii changed. Reopen Miis and choose it again.");
  return NO;
}

NSData *SelectedMiiName(NSData *database, NSUInteger slot, NSData *expectedId, NSError **error) {
  CreateId identity{};
  if (!ReadCreateId(expectedId, identity, error) || !CheckMii(database, slot, identity, error))
    return nil;
  const std::string text = kartpad::mii::ReadMiiName(Bytes(database),
      kartpad::mii::kMiiBlockOffset + slot * kartpad::mii::kMiiBlockSize + 0x02);
  NSData *name = [[NSString stringWithUTF8String:text.c_str()]
      dataUsingEncoding:NSUTF16BigEndianStringEncoding];
  return NameValue(name, error);
}

// Renames every license that races as the Mii, in each save that exists.
BOOL RenameLinkedLicenses(Workspace& files, const CreateId& identity, NSData *name,
                          NSError **error) {
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations()) {
    BOOL missing = NO;
    NSData *data = WorkspaceSave(files, location[@"path"], &missing, error);
    if (missing) continue;
    if (data == nil) return NO;
    auto save = Vector(data);
    std::size_t changed = 0;
    const auto result = kartpad::mii::RenameMatchingLicenses(save, identity, Bytes(name), changed);
    if (!result) {
      if (error != nullptr) *error = ManagerError(9, result.message);
      return NO;
    }
    if (changed > 0) files.Write(location[@"path"], save);
  }
  return YES;
}

std::size_t LinkedLicenseCount(Workspace& files, const CreateId& identity) {
  std::size_t count = 0;
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations()) {
    BOOL missing = NO;
    NSData *data = WorkspaceSave(files, location[@"path"], &missing, nullptr);
    for (const auto& record : kartpad::mii::ListLicenses(Bytes(data)))
      if (record.createId == identity) count++;
  }
  return count;
}

// A saved editor draft (with the Mii it replaces) or a new Mii. A changed name renames its licenses.
BOOL ApplyMiiChange(Workspace& files, NSDictionary *change, NSError **error) {
  NSData *mii = Value<NSData>(change[@"mii"]), *expected = Value<NSData>(change[@"expected"]);
  NSNumber *slot = Value<NSNumber>(change[@"slot"]);
  if (mii == nil || (expected != nil && slot == nil)) {
    if (error != nullptr) *error = InvalidChange();
    return NO;
  }
  try {
    // An edit may keep the out-of-range fields the Mii already had (see ReplaceAppearance).
    const auto previous = expected != nil ? kartpad::mii::Appearance::Decode(Bytes(expected))
                                          : kartpad::mii::Appearance{};
    const auto validation = kartpad::mii::Appearance::Decode(Bytes(mii)).Validate(
        expected != nil ? &previous : nullptr);
    if (!validation) {
      if (error != nullptr) *error = ManagerError(50, validation.message);
      return NO;
    }
  } catch (const std::exception& e) {
    if (error != nullptr) *error = ManagerError(50, e.what());
    return NO;
  }
  NSData *original = WorkspaceDatabase(files, error);
  if (original == nil) return NO;
  auto database = Vector(original);
  const auto result = expected != nil
      ? kartpad::mii::ReplaceAppearance(database, slot.unsignedIntegerValue, Bytes(expected), Bytes(mii))
      : kartpad::mii::ImportMii(database, Bytes(mii));
  if (!result) {
    if (error != nullptr) *error = ManagerError(expected != nil ? 50 : 3, result.message);
    return NO;
  }
  files.Write(DatabasePath(), database);
  if (expected == nil || [[expected subdataWithRange:NSMakeRange(2, 20)]
                             isEqualToData:[mii subdataWithRange:NSMakeRange(2, 20)]])
    return YES;
  // Decode the terminated name rather than including padding in license names.
  const auto text = kartpad::mii::ReadMiiName(Bytes(mii), 2);
  NSData *name = PlayerNameData([NSString stringWithUTF8String:text.c_str()], error);
  return name != nil && RenameLinkedLicenses(files,
      kartpad::mii::MiiCreateId(Bytes(original), slot.unsignedIntegerValue), name, error);
}

BOOL ApplyMiiRemoval(Workspace& files, NSDictionary *change, NSError **error) {
  NSNumber *slot = Value<NSNumber>(change[@"slot"]);
  CreateId identity{};
  if (slot == nil || !ReadCreateId(Value<NSData>(change[@"createId"]), identity, error)) {
    if (error != nullptr && *error == nil) *error = InvalidChange();
    return NO;
  }
  NSData *original = WorkspaceDatabase(files, error);
  if (original == nil || !CheckMii(original, slot.unsignedIntegerValue, identity, error)) return NO;
  if (LinkedLicenseCount(files, identity) > 0) {
    if (error != nullptr) *error = ManagerError(20,
        "This Mii is linked to an existing license. Change the license first.");
    return NO;
  }
  auto database = Vector(original);
  const auto result = kartpad::mii::RemoveMii(database, slot.unsignedIntegerValue);
  if (!result) {
    if (error != nullptr) *error = ManagerError(4, result.message);
    return NO;
  }
  files.Write(DatabasePath(), database);
  return YES;
}

// A new Mii name, which its licenses take too.
BOOL ApplyMiiName(Workspace& files, NSDictionary *change, NSError **error) {
  NSNumber *slot = Value<NSNumber>(change[@"slot"]);
  CreateId identity{};
  if (slot == nil || !ReadCreateId(Value<NSData>(change[@"createId"]), identity, error)) {
    if (error != nullptr && *error == nil) *error = InvalidChange();
    return NO;
  }
  NSData *name = NameValue(change[@"name"], error);
  NSData *original = name ? WorkspaceDatabase(files, error) : nil;
  if (original == nil || !CheckMii(original, slot.unsignedIntegerValue, identity, error)) return NO;
  auto database = Vector(original);
  const auto renamed = kartpad::mii::RenameMii(database, slot.unsignedIntegerValue, Bytes(name));
  if (!renamed) {
    if (error != nullptr) *error = ManagerError(8, renamed.message);
    return NO;
  }
  files.Write(DatabasePath(), database);
  return RenameLinkedLicenses(files, identity, name, error);
}

// Renames, relinks or deletes one license. A renamed license's Mii takes the name too.
BOOL ApplyLicenseChange(Workspace& files, NSDictionary *change, NSError **error) {
  NSString *operation = Value<NSString>(change[@"operation"]);
  NSDictionary<NSString *, NSString *> *location =
      SaveLocation(Value<NSString>(change[@"profileIdentifier"]));
  NSNumber *slot = Value<NSNumber>(change[@"slot"]);
  CreateId identity{};
  if (location == nil || slot == nil || slot.unsignedIntegerValue >= kartpad::mii::kRksysLicenseCount) {
    if (error != nullptr) *error = ManagerError(14, "The selected license location is invalid.");
    return NO;
  }
  if (!ReadCreateId(Value<NSData>(change[@"createId"]), identity, error)) return NO;
  BOOL missing = NO;
  NSData *data = WorkspaceSave(files, location[@"path"], &missing, error);
  if (missing && error != nullptr) *error = ManagerError(16,
      "The selected license changed. Reopen Miis and try again.");
  if (data == nil) return NO;
  auto save = Vector(data);
  kartpad::mii::DatabaseResult result{false, "The requested license change is invalid."};
  if ([operation isEqualToString:@"rename"]) {
    NSData *name = NameValue(change[@"name"], error);
    if (name == nil) return NO;
    result = kartpad::mii::RenameLicense(save, slot.unsignedIntegerValue, identity, Bytes(name));
    if (result && !files.Load(DatabasePath(), error)) return NO;
    if (result && files.Data(DatabasePath()) != nil) {
      NSData *original = WorkspaceDatabase(files, error);
      if (original == nil) return NO;
      auto database = Vector(original);
      for (const auto& record : kartpad::mii::ListMiis(database)) {
        if (kartpad::mii::MiiCreateId(database, record.slot) != identity) continue;
        const auto renamed = kartpad::mii::RenameMii(database, record.slot, Bytes(name));
        if (!renamed) {
          if (error != nullptr) *error = ManagerError(17, renamed.message);
          return NO;
        }
        files.Write(DatabasePath(), database);
        break;
      }
    }
  } else if ([operation isEqualToString:@"mii"]) {
    NSNumber *miiSlot = Value<NSNumber>(change[@"miiSlot"]);
    NSData *miiId = Value<NSData>(change[@"miiCreateId"]);
    NSData *database = WorkspaceDatabase(files, error);
    NSData *name = database && miiSlot ? SelectedMiiName(database, miiSlot.unsignedIntegerValue, miiId, error) : nil;
    if (name == nil) {
      if (error != nullptr && *error == nil) *error = InvalidChange();
      return NO;
    }
    CreateId selected{};
    std::copy_n(static_cast<const uint8_t *>(miiId.bytes), selected.size(), selected.begin());
    result = kartpad::mii::SetLicenseMii(save, slot.unsignedIntegerValue, identity, selected, Bytes(name));
  } else if ([operation isEqualToString:@"delete"]) {
    result = kartpad::mii::DeleteLicense(save, slot.unsignedIntegerValue, identity);
  }
  if (!result) {
    if (error != nullptr) *error = ManagerError(19, result.message);
    return NO;
  }
  files.Write(location[@"path"], save);
  return YES;
}

BOOL ApplyChange(Workspace& files, id value, NSError **error) {
  NSDictionary *change = Value<NSDictionary>(value);
  NSString *kind = Value<NSString>(change[@"kind"]);
  if ([kind isEqualToString:@"mii"]) return ApplyMiiChange(files, change, error);
  if ([kind isEqualToString:@"remove"]) return ApplyMiiRemoval(files, change, error);
  if ([kind isEqualToString:@"name"]) return ApplyMiiName(files, change, error);
  if ([kind isEqualToString:@"license"]) return ApplyLicenseChange(files, change, error);
  if (error != nullptr) *error = InvalidChange();
  return NO;
}

// The queue file's contents; nil when there is none (*missing) or it can't be read.
NSData *ReadQueueData(BOOL *missing, NSError **error) {
  NSFileManager *files = NSFileManager.defaultManager;
  *missing = ![files fileExistsAtPath:QueuePath()];
  if (*missing) return nil;
  NSDictionary *attributes = [files attributesOfItemAtPath:QueuePath() error:error];
  if (attributes == nil) return nil;
  return attributes.fileSize <= 4 * 1024 * 1024
      ? [NSData dataWithContentsOfFile:QueuePath() options:0 error:error] : nil;
}

// The queued changes, empty when none are waiting; nil only when the queue can't be read.
NSArray *ReadQueue(NSError **error) {
  BOOL missing = NO;
  NSData *data = ReadQueueData(&missing, error);
  if (missing) return @[];
  NSArray *queue = data ? Value<NSArray>([NSPropertyListSerialization
      propertyListWithData:data options:NSPropertyListImmutable format:nil error:error]) : nil;
  if (queue == nil && error != nullptr && *error == nil) {
    *error = ManagerError(51, "The pending Mii changes can’t be read.");
  }
  return queue;
}

BOOL Replay(Workspace& files, NSArray *queue, NSError **error) {
  for (id change in queue)
    if (!ApplyChange(files, change, error)) return NO;
  return YES;
}

// An older version's pending database applies before anything queued, so reading starts from it.
BOOL LoadOlderPendingDatabase(Workspace& files, NSError **error) {
  if (![NSFileManager.defaultManager fileExistsAtPath:PendingPath()]) return YES;
  NSData *pending = [NSData dataWithContentsOfFile:PendingPath() options:0 error:error];
  if (pending == nil) return NO;
  files.original[DatabasePath()] = pending;
  files.current[DatabasePath()] = pending;
  return YES;
}

// A file's identity and version (device, inode, size and change times), or that it's missing.
NSString *Stamp(NSString *path) {
  struct stat info {};
  if (stat(path.fileSystemRepresentation, &info) != 0) return [path stringByAppendingString:@"|-"];
  return [NSString stringWithFormat:@"%@|%llu|%llu|%lld|%ld.%09ld|%ld.%09ld", path,
      (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, (long long)info.st_size,
      (long)info.st_mtimespec.tv_sec, (long)info.st_mtimespec.tv_nsec,
      (long)info.st_ctimespec.tv_sec, (long)info.st_ctimespec.tv_nsec];
}

NSString *LicenseKey(NSString *profile, NSUInteger slot) {
  return [NSString stringWithFormat:@"%@/%lu", profile, (unsigned long)slot];
}

// The files as they will be after the next launch: the queue replayed over the live files, and
// which licenses the queued changes touch. Every Miis screen refresh reads this, and a replay
// copies the saves and checks their checksums for each change, so it is kept for the queue and the
// files it came from (key) and rebuilt only when one of them changes. Staging a change applies just
// that change on top. Launch (ApplyQueue) still replays over freshly read files.
struct Upcoming {
  NSArray *key = nil;  // The queue's contents, then every file's Stamp.
  NSArray *queue = nil;  // nil when the queue can't be read.
  Workspace files;
  NSMutableDictionary<NSString *, NSString *> *operations = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSDictionary *> *deleted = [NSMutableDictionary dictionary];
  NSError *error = nil;  // Why the queue can't be read or replayed.
  // KartPadMiiRecords and KartPadLicenseRecords, built on first use.
  NSArray *miis = nil, *licenses = nil;
  NSError *miiError = nil, *licenseError = nil;
  std::shared_ptr<Upcoming> Copy() const {
    auto copy = std::make_shared<Upcoming>();
    copy->key = key;
    copy->queue = queue;
    copy->files = files.Copy();
    copy->operations = [operations mutableCopy];
    copy->deleted = [deleted mutableCopy];
    return copy;
  }
};

NSArray *UpcomingKey() {
  BOOL missing = NO;
  NSData *queue = ReadQueueData(&missing, nullptr);
  NSMutableArray *key = [NSMutableArray arrayWithObject:queue ?: Stamp(QueuePath())];
  NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObjects:DatabasePath(), PendingPath(),
      PendingIdentityPath(), PendingLicensePath(), nil];
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations())
    [paths addObject:location[@"path"]];
  for (NSString *path in paths)
    [key addObject:Stamp(path)];
  return key;
}

// Notes the licenses a change renames, relinks or deletes (as the saves are before it), then
// applies it.
BOOL Step(Upcoming& upcoming, id entry, NSError **error) {
  NSDictionary *change = Value<NSDictionary>(entry);
  NSString *kind = Value<NSString>(change[@"kind"]);
  NSData *createId = Value<NSData>(change[@"createId"]);
  if ([kind isEqualToString:@"name"] || [kind isEqualToString:@"license"]) {
    for (NSDictionary<NSString *, NSString *> *location in SaveLocations()) {
      BOOL missing = NO;
      NSData *save = WorkspaceSave(upcoming.files, location[@"path"], &missing, nullptr);
      for (const auto& record : kartpad::mii::ListLicenses(Bytes(save))) {
        NSData *recordId = [NSData dataWithBytes:record.createId.data() length:record.createId.size()];
        NSString *profile = location[@"identifier"], *key = LicenseKey(profile, record.slot);
        if ([kind isEqualToString:@"name"] && [recordId isEqual:createId]) {
          upcoming.operations[key] = @"rename";
        } else if ([kind isEqualToString:@"license"] && [change[@"profileIdentifier"] isEqual:profile] &&
                   [change[@"slot"] isEqual:@(record.slot)]) {
          NSString *operation = Value<NSString>(change[@"operation"]);
          if (operation) upcoming.operations[key] = operation;
          if ([operation isEqualToString:@"delete"])
            upcoming.deleted[key] = @{
              @"name": [NSString stringWithUTF8String:record.name.c_str()],
              @"createId": recordId,
            };
        }
      }
    }
  }
  return ApplyChange(upcoming.files, entry, error);
}

std::shared_ptr<Upcoming> BuildUpcoming(NSArray *key) {
  auto upcoming = std::make_shared<Upcoming>();
  upcoming->key = key;
  NSError *error = nil;
  if (!LoadOlderPendingDatabase(upcoming->files, &error) || !(upcoming->queue = ReadQueue(&error))) {
    upcoming->error = error;
    return upcoming;
  }
  // Read now, so the files match their stamps; one that can't be read fails where it's needed.
  (void)upcoming->files.Load(DatabasePath(), nullptr);
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations())
    (void)upcoming->files.Load(location[@"path"], nullptr);
  for (id change in upcoming->queue) {
    if (!Step(*upcoming, change, &error)) {
      upcoming->error = error;
      break;
    }
  }
  return upcoming;
}

// Guards the kept upcoming files; readers share them and never change them.
std::mutex& UpcomingLock() {
  static std::mutex lock;
  return lock;
}
std::shared_ptr<Upcoming>& KeptUpcoming() {
  static std::shared_ptr<Upcoming> upcoming;
  return upcoming;
}

// The upcoming files for the files as they are now.
std::shared_ptr<Upcoming> CurrentUpcoming() {
  NSArray *key = UpcomingKey();
  std::lock_guard<std::mutex> lock(UpcomingLock());
  auto& kept = KeptUpcoming();
  if (!kept || ![kept->key isEqual:key]) kept = BuildUpcoming(key);
  return kept;
}

// The database as the queue leaves it, for reading; nil with the reason when it can't be read.
NSData *UpcomingDatabase(const Upcoming& upcoming, NSError **error) {
  if (upcoming.error != nil) {
    if (error != nullptr) *error = upcoming.error;
    return nil;
  }
  Workspace files = upcoming.files.Copy();
  return WorkspaceDatabase(files, error);
}

// A copy of the upcoming files to add a change to. Nothing is queued while an older kind of
// pending change waits.
std::shared_ptr<Upcoming> StagingQueue(NSError **error) {
  if (OtherChangesPending()) {
    if (error != nullptr) *error = ManagerError(13,
        "Restart KartPad to apply the pending data change first.");
    return nullptr;
  }
  auto upcoming = CurrentUpcoming();
  if (upcoming->error != nil) {
    if (error != nullptr) *error = upcoming->error;
    return nullptr;
  }
  return upcoming->Copy();
}

// Applies the change on top of the staging copy, writes the queue, and keeps the result.
BOOL QueueChange(const std::shared_ptr<Upcoming>& next, NSDictionary *change, NSError **error) {
  if (!Step(*next, change, error)) return NO;
  NSArray *queue = [next->queue arrayByAddingObject:change];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:queue
                                                            format:NSPropertyListBinaryFormat_v1_0
                                                           options:0 error:error];
  if (data == nil ||
      ![NSFileManager.defaultManager createDirectoryAtPath:SupportRoot()
                               withIntermediateDirectories:YES attributes:nil error:error] ||
      ![data writeToFile:QueuePath() options:NSDataWritingAtomic error:error])
    return NO;
  next->queue = queue;
  NSMutableArray *key = [next->key mutableCopy];
  key[0] = data;
  next->key = key;
  std::lock_guard<std::mutex> lock(UpcomingLock());
  KeptUpcoming() = next;
  return YES;
}

NSData *IdentityData(NSData *database, NSUInteger slot) {
  const auto identity = kartpad::mii::MiiCreateId(Bytes(database), slot);
  return [NSData dataWithBytes:identity.data() length:identity.size()];
}

} // namespace

NSData *KartPadReadMii(NSUInteger slot, NSError **error) {
  NSData *data = UpcomingDatabase(*CurrentUpcoming(), error);
  if (!data)
    return nil;
  if (slot >= kartpad::mii::kMaximumMiiSlots) {
    if (error)
      *error = ManagerError(50, "Invalid Mii selection.");
    return nil;
  }
  auto block =
      Bytes(data).subspan(kartpad::mii::kMiiBlockOffset + slot * kartpad::mii::kMiiBlockSize,
                          kartpad::mii::kMiiBlockSize);
  if (kartpad::mii::IsEmptyMii(block)) {
    if (error)
      *error = ManagerError(50, "The selected Mii no longer exists.");
    return nil;
  }
  return [NSData dataWithBytes:block.data() length:block.size()];
}
NSData *KartPadNewMii(NSError **error) {
  NSData *data = UpcomingDatabase(*CurrentUpcoming(), error);
  if (!data)
    return nil;
  try {
    auto a = kartpad::mii::NewAppearance(
        Bytes(data), uint32_t((NSDate.date.timeIntervalSince1970 - 1136073600) / 4));
#if !defined(KARTPAD_MII_MANAGER_TESTING)
    auto console = kartpad::mii::CreateDefaultMii(RuntimeConsoleIdentity::Current().mac);
    std::copy_n(console.begin() + 28, 4, a.bytes.begin() + 28);
#endif

    return [NSData dataWithBytes:a.bytes.data() length:a.bytes.size()];
  } catch (const std::exception &e) {
    if (error)
      *error = ManagerError(50, e.what());
    return nil;
  }
}
NSData *KartPadDuplicateMii(NSUInteger slot, NSError **error) {
  NSData *source = KartPadReadMii(slot, error);
  NSData *identity = source ? KartPadNewMii(error) : nil;
  if (!identity)
    return nil;
  // The copy keeps every appearance and profile byte but takes a fresh Mii ID and this
  // console's ID (0x18-0x1F), so the database accepts it as a separate Mii. Being a new Mii, it
  // takes fields out of range at the values the editor shows for them.
  auto copy = kartpad::mii::Appearance::Decode(Bytes(source)).InRange();
  std::copy_n(static_cast<const uint8_t *>(identity.bytes) + 0x18, 8, copy.bytes.begin() + 0x18);
  return [NSData dataWithBytes:copy.bytes.data() length:copy.bytes.size()];
}
NSData *KartPadExportMii(NSData *edited, NSError **error) {
  try {
    auto validation = kartpad::mii::Appearance::Decode(Bytes(edited)).Validate();
    if (!validation) { if (error) *error = ManagerError(50, validation.message); return nil; }
    return edited.copy;
  } catch (const std::exception& e) { if (error) *error = ManagerError(50, e.what()); return nil; }
}

// The edited Mii with its name as PlayerNameData gives it to its licenses (see NormalName); nil
// when the name is blank.
static NSData *NormalizedMii(NSData *mii, NSError **error) {
  if (mii.length != kartpad::mii::kMiiBlockSize) return mii;  // Validation reports it.
  NSString *text = [NSString stringWithUTF8String:kartpad::mii::ReadMiiName(Bytes(mii), 2).c_str()];
  NSData *name = PlayerNameData(text, error);
  if (name == nil || [NormalName(text) isEqualToString:text]) return name ? mii : nil;
  NSMutableData *copy = mii.mutableCopy;
  memset(static_cast<uint8_t *>(copy.mutableBytes) + 2, 0, kartpad::mii::kMiiNameByteSize);
  memcpy(static_cast<uint8_t *>(copy.mutableBytes) + 2, name.bytes, name.length);
  return copy;
}

BOOL KartPadStageMiiEditor(NSUInteger slot, NSData *expected, NSData *edited, NSError **error) {
  edited = NormalizedMii(edited, error);
  if (edited == nil) return NO;
  auto next = StagingQueue(error);
  if (!next)
    return NO;
  NSDictionary *change = expected ? @{@"kind" : @"mii", @"slot" : @(slot), @"expected" : expected, @"mii" : edited}
                                  : @{@"kind" : @"mii", @"mii" : edited};
  return QueueChange(next, change, error);
}
// Writes each change's new contents over its file, backing the old file up first. The changes are
// journaled before any file is written, so an interrupted commit finishes on the next launch (see
// FinishInterruptedCommit). The intents that asked for the changes are removed once every file is
// written.
static BOOL CommitChanges(NSArray<NSDictionary *> *records, NSArray<NSString *> *intents,
                          BOOL recovering, NSError **error) {
  NSFileManager *files = NSFileManager.defaultManager;
  if (!recovering) {
    NSString *stamp = [NSString stringWithFormat:@"%.0f-%@", NSDate.date.timeIntervalSince1970,
                                                 NSUUID.UUID.UUIDString];
    for (NSDictionary *c in records) {
      BOOL db = [c[@"path"] isEqual:DatabasePath()];
      if (!BackupFile(c[@"path"], db ? @"MiiBackups" : @"SaveBackups", db ? @"RFL_DB" : c[@"backup"],
                      stamp, error))
        return NO;
    }
    NSData *journal = [NSPropertyListSerialization dataWithPropertyList:records
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0
                                                                  error:error];
    if (!journal || ![journal writeToFile:JournalPath() options:NSDataWritingAtomic error:error])
      return NO;
  }
  NSUInteger written = 0;
  for (NSDictionary *c in records) {
#if defined(KARTPAD_MII_MANAGER_TESTING)
    const char *fail = std::getenv("KARTPAD_MII_TEST_INTERRUPT_AFTER");
    if (fail && written == std::strtoul(fail, nullptr, 10)) {
      if (error)
        *error = ManagerError(51, "Simulated interruption.");
      return NO;
    }
#endif
    if (![c[@"after"] writeToFile:c[@"path"] options:NSDataWritingAtomic error:error])
      return NO;
    written++;
  }
  for (NSString *intent in intents)
    if ([files fileExistsAtPath:intent] && ![files removeItemAtPath:intent error:error])
      return NO;
  return ![files fileExistsAtPath:JournalPath()] ||
         [files removeItemAtPath:JournalPath() error:error];
}
// Finishes a commit that was interrupted, from its journal: every file it names must still hold
// either its old or its new contents.
static BOOL FinishInterruptedCommit(NSError **error) {
  NSFileManager *files = NSFileManager.defaultManager;
  if (![files fileExistsAtPath:JournalPath()])
    return YES;
  NSData *journal = [NSData dataWithContentsOfFile:JournalPath() options:0 error:error];
  if (!journal)
    return NO;
  id records = [NSPropertyListSerialization propertyListWithData:journal
                                                         options:NSPropertyListImmutable
                                                          format:nil
                                                           error:error];
  if (![records isKindOfClass:NSArray.class]) {
    if (error)
      *error = ManagerError(51, "Invalid Mii transaction.");
    return NO;
  }
  NSMutableSet *allowed = [NSMutableSet setWithObject:DatabasePath()];
  for (NSDictionary *l in SaveLocations())
    [allowed addObject:l[@"path"]];
  NSMutableSet *seen = [NSMutableSet set];
  for (id c in records) {
    if (![c isKindOfClass:NSDictionary.class] || ![allowed containsObject:c[@"path"]] ||
        [seen containsObject:c[@"path"]] || ![c[@"before"] isKindOfClass:NSData.class] ||
        ![c[@"after"] isKindOfClass:NSData.class]) {
      if (error)
        *error = ManagerError(51, "Invalid Mii transaction target.");
      return NO;
    }
    [seen addObject:c[@"path"]];
    BOOL db = [c[@"path"] isEqual:DatabasePath()];
    if (db ? (!ValidateData(c[@"before"], error) || !ValidateData(c[@"after"], error))
           : (!ValidateSaveData(c[@"before"], error) || !ValidateSaveData(c[@"after"], error)))
      return NO;
    NSData *current = [NSData dataWithContentsOfFile:c[@"path"] options:0 error:error];
    if (!current || (![current isEqualToData:c[@"before"]] && ![current isEqualToData:c[@"after"]])) {
      if (error)
        *error =
            ManagerError(51, "Game data changed since the Mii edit. Nothing further was applied.");
      return NO;
    }
  }
  // The commit had finished replaying the queue, which goes once every file is written.
  return CommitChanges(records, @[ QueuePath() ], YES, error);
}
// Replays the queue over the latest files and commits the files it changed.
static BOOL ApplyQueue(NSError **error) {
  if (![NSFileManager.defaultManager fileExistsAtPath:QueuePath()])
    return YES;
  NSArray *queue = ReadQueue(error);
  Workspace files;
  if (!queue || !Replay(files, queue, error))
    return NO;
  NSMutableArray *records = [NSMutableArray array];
  NSMutableArray *targets = [NSMutableArray arrayWithObject:@{@"path" : DatabasePath(), @"backup" : @"RFL_DB"}];
  [targets addObjectsFromArray:SaveLocations()];
  for (NSDictionary *target in targets) {
    NSData *before = Value<NSData>(files.original[target[@"path"]]), *after = files.Data(target[@"path"]);
    if (before && after && ![before isEqualToData:after])
      [records addObject:@{@"path" : target[@"path"], @"before" : before, @"after" : after,
                           @"backup" : target[@"backup"]}];
  }
  return CommitChanges(records, @[ QueuePath() ], NO, error);
}
static NSArray *MiiRecords(const Upcoming& upcoming, NSError **error) {
  NSData *data = UpcomingDatabase(upcoming, error);
  if (data == nil) return @[];

  NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
  for (const auto& record : kartpad::mii::ListMiis(Bytes(data))) {
    NSString *name = [NSString stringWithUTF8String:record.name.c_str()];
    NSString *creator = [NSString stringWithUTF8String:record.creatorName.c_str()];
    const auto block = Bytes(data).subspan(
        kartpad::mii::kMiiBlockOffset + record.slot * kartpad::mii::kMiiBlockSize,
        kartpad::mii::kMiiBlockSize);
    [result addObject:@{
      @"slot": @(record.slot),
      @"name": name.length > 0 ? name : @"Unnamed Mii",
      @"creator": creator.length > 0 ? creator : @"Unknown",
      @"favoriteColor": @(record.favoriteColor),
      @"createId": @(record.createId),
      @"createIdBytes": IdentityData(data, record.slot),
      @"mii": [NSData dataWithBytes:block.data() length:block.size()],
    }];
  }
  return result.copy;
}

// Built once for each state of the queue and files (see Upcoming).
NSArray<NSDictionary<NSString *, id> *> *KartPadMiiRecords(NSError **error) {
  auto upcoming = CurrentUpcoming();
  std::lock_guard<std::mutex> lock(UpcomingLock());
  if (upcoming->miis == nil) {
    NSError *failure = nil;
    upcoming->miis = MiiRecords(*upcoming, &failure);
    upcoming->miiError = failure;
  }
  if (error != nullptr && upcoming->miiError != nil) *error = upcoming->miiError;
  return upcoming->miis;
}

// Licenses as they will be after the next launch. Each one a queued change touches carries that
// change as pendingOperation, and a license queued for deletion is still listed so it can say so.
static NSArray *LicenseRecords(const Upcoming& upcoming, NSError **error) {
  NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
  NSDictionary *identity = [NSDictionary dictionaryWithContentsOfFile:PendingIdentityPath()];
  NSDictionary *license = [NSDictionary dictionaryWithContentsOfFile:PendingLicensePath()];
  if (upcoming.error != nil) {
    if (error != nullptr) *error = upcoming.error;
    return @[];
  }
  Workspace files = upcoming.files.Copy();
  NSDictionary<NSString *, NSString *> *operations = upcoming.operations;
  NSDictionary<NSString *, NSDictionary *> *deleted = upcoming.deleted;
  NSData *databaseData = WorkspaceDatabase(files, nullptr);
  const auto databaseBytes = Bytes(databaseData);
  const auto miis = kartpad::mii::ListMiis(databaseBytes);
  for (NSDictionary<NSString *, NSString *> *location in SaveLocations()) {
    BOOL missing = NO;
    NSData *saveData = WorkspaceSave(files, location[@"path"], &missing, error);
    if (missing) continue;
    if (saveData == nil) return @[];
    const auto records = kartpad::mii::ListLicenses(Bytes(saveData));
    for (NSUInteger slot = 0; slot < kartpad::mii::kRksysLicenseCount; slot++) {
      NSString *slotKey = LicenseKey(location[@"identifier"], slot);
      const auto record = std::find_if(records.begin(), records.end(),
                                       [&](const auto& r) { return r.slot == slot; });
      NSString *name = nil;
      NSData *createId = nil;
      if (record != records.end()) {
        name = [NSString stringWithUTF8String:record->name.c_str()];
        createId = [NSData dataWithBytes:record->createId.data() length:record->createId.size()];
      } else if (deleted[slotKey]) {
        name = deleted[slotKey][@"name"];
        createId = deleted[slotKey][@"createId"];
      } else {
        continue;
      }
      NSString *pendingOperation = operations[slotKey] ?: @"";
      NSData *pendingName = nil;
      if ([identity[@"createId"] isEqual:createId]) {
        pendingOperation = @"rename";
        pendingName = identity[@"name"];
      }
      if ([license[@"profileIdentifier"] isEqual:location[@"identifier"]] &&
          [license[@"slot"] isEqual:@(slot)] &&
          [license[@"createId"] isEqual:createId]) {
        pendingOperation = license[@"operation"] ?: @"";
        pendingName = license[@"name"];
      }
      if (![pendingOperation isKindOfClass:NSString.class]) pendingOperation = @"";
      if ([pendingName isKindOfClass:NSData.class] &&
          kartpad::mii::ValidateUtf16BigEndianName(Bytes(pendingName))) {
        name = [[NSString alloc] initWithData:pendingName
                                    encoding:NSUTF16BigEndianStringEncoding];
      }
      CreateId linked{};
      std::copy_n(static_cast<const uint8_t *>(createId.bytes), linked.size(), linked.begin());
      [result addObject:@{
        @"profileIdentifier": location[@"identifier"],
        @"profileTitle": location[@"title"],
        @"slot": @(slot),
        @"name": name.length > 0 ? name : @"Unnamed",
        @"createId": createId,
        @"pendingOperation": pendingOperation,
        @"missingLinkedMii": @(!std::any_of(miis.begin(), miis.end(), [&](const auto& mii) {
          return kartpad::mii::MiiCreateId(databaseBytes, mii.slot) == linked;
        })),
      }];
    }
  }
  return result.copy;
}

// Built once for each state of the queue and files (see Upcoming).
NSArray<NSDictionary<NSString *, id> *> *KartPadLicenseRecords(NSError **error) {
  auto upcoming = CurrentUpcoming();
  std::lock_guard<std::mutex> lock(UpcomingLock());
  if (upcoming->licenses == nil) {
    NSError *failure = nil;
    upcoming->licenses = LicenseRecords(*upcoming, &failure);
    upcoming->licenseError = failure;
  }
  if (error != nullptr && upcoming->licenseError != nil) *error = upcoming->licenseError;
  return upcoming->licenses;
}


BOOL KartPadStageMiiImport(NSData *miiData, NSString **name, NSError **error) {
  auto next = StagingQueue(error);
  if (!next || !QueueChange(next, @{@"kind": @"mii", @"mii": miiData}, error)) return NO;
  if (name != nullptr) {
    const std::string decoded = kartpad::mii::ReadMiiName(Bytes(miiData), 0x02);
    *name = [NSString stringWithUTF8String:decoded.c_str()];
  }
  return YES;
}

BOOL KartPadStageMiiRemoval(NSUInteger slot, NSError **error) {
  auto next = StagingQueue(error);
  NSData *database = next ? WorkspaceDatabase(next->files, error) : nil;
  if (database == nil) return NO;
  return QueueChange(next, @{
    @"kind": @"remove", @"slot": @(slot), @"createId": IdentityData(database, slot),
  }, error);
}

BOOL KartPadStagePlayerName(NSUInteger slot, NSString *name,
                           NSUInteger *updatedLicenses, NSError **error) {
  if (updatedLicenses != nullptr) *updatedLicenses = 0;
  NSData *nameData = PlayerNameData(name, error);
  if (nameData == nil) return NO;
  auto next = StagingQueue(error);
  NSData *database = next ? WorkspaceDatabase(next->files, error) : nil;
  if (database == nil) return NO;
  if (slot >= kartpad::mii::kMaximumMiiSlots) {
    if (error != nullptr) *error = ManagerError(8, "The selected Mii slot is invalid.");
    return NO;
  }
  const std::size_t linked = LinkedLicenseCount(next->files, kartpad::mii::MiiCreateId(Bytes(database), slot));
  if (!QueueChange(next, @{
        @"kind": @"name", @"slot": @(slot), @"createId": IdentityData(database, slot), @"name": nameData,
      }, error)) return NO;
  if (updatedLicenses != nullptr) *updatedLicenses = linked;
  return YES;
}

// An older version's pending license change names its Mii by the live database.
static NSData *SelectedMiiName(NSUInteger slot, NSData *expectedId, NSError **error) {
  NSData *data = [NSData dataWithContentsOfFile:DatabasePath() options:0 error:error];
  if (data == nil || !ValidateData(data, error)) return nil;
  return SelectedMiiName(data, slot, expectedId, error);
}

static BOOL KartPadStageLicenseChange(NSString *profileIdentifier,
                                     NSUInteger slot, NSData *createIdData,
                                     NSString *operation, NSString *name,
                                     NSError **error,
                                     NSUInteger selectedSlot = NSNotFound,
                                     NSData *selectedId = nil) {
  NSMutableDictionary *change = [@{
    @"kind": @"license",
    @"operation": operation,
    @"profileIdentifier": profileIdentifier,
    @"slot": @(slot),
    @"createId": createIdData,
  } mutableCopy];
  if ([operation isEqualToString:@"rename"]) {
    NSData *nameData = PlayerNameData(name, error);
    if (nameData == nil) return NO;
    change[@"name"] = nameData;
  } else if ([operation isEqualToString:@"mii"]) {
    if (selectedId == nil) {
      if (error != nullptr) *error = ManagerError(20,
          "The selected Mii changed. Reopen Miis and choose it again.");
      return NO;
    }
    change[@"miiSlot"] = @(selectedSlot);
    change[@"miiCreateId"] = selectedId;
  }
  auto next = StagingQueue(error);
  return next && QueueChange(next, change, error);
}

BOOL KartPadStageLicenseRename(NSString *profileIdentifier, NSUInteger slot,
                              NSData *createId, NSString *name,
                              NSError **error) {
  return KartPadStageLicenseChange(profileIdentifier, slot, createId,
                                   @"rename", name, error);
}

BOOL KartPadStageLicenseMii(NSString *profileIdentifier, NSUInteger slot,
                           NSData *createId, NSUInteger miiSlot, NSData *miiCreateId,
                           NSError **error) {
  return KartPadStageLicenseChange(profileIdentifier, slot, createId,
                                   @"mii", nil, error, miiSlot, miiCreateId);
}

BOOL KartPadStageLicenseDeletion(NSString *profileIdentifier, NSUInteger slot,
                                NSData *createId, NSError **error) {
  return KartPadStageLicenseChange(profileIdentifier, slot, createId,
                                   @"delete", nil, error);
}

static BOOL KartPadApplyPendingGhost(NSError **error);
static BOOL KartPadApplyPendingSaveRestore(NSError **error);

// Changes staged by older versions, then the queue.
static BOOL ApplyLegacyChanges(NSError **error);
BOOL KartPadApplyPendingMiiDatabase(NSError **error) {
  return ApplyLegacyChanges(error) && ApplyQueue(error);
}

static BOOL ApplyLegacyChanges(NSError **error) {
  if (!FinishInterruptedCommit(error)) return NO;
  if (!KartPadApplyPendingSaveRestore(error)) return NO;
  if (!KartPadApplyPendingGhost(error)) return NO;
  NSString *pending = PendingPath();
  NSString *pendingIdentity = PendingIdentityPath();
  NSString *pendingLicense = PendingLicensePath();
  NSFileManager *files = NSFileManager.defaultManager;
  const BOOL hasDatabase = [files fileExistsAtPath:pending];
  const BOOL hasIdentity = [files fileExistsAtPath:pendingIdentity];
  const BOOL hasLicense = [files fileExistsAtPath:pendingLicense];
  if (!hasDatabase && !hasIdentity && !hasLicense) return YES;

  NSData *pendingData = nil;
  if (hasDatabase) {
    pendingData = [NSData dataWithContentsOfFile:pending
                                         options:NSDataReadingMappedIfSafe
                                           error:error];
    if (pendingData == nil || !ValidateData(pendingData, error)) return NO;
  }
  NSMutableArray<NSDictionary<NSString *, id> *> *saveChanges =
      [NSMutableArray array];
  if (hasIdentity) {
    NSData *identityData = [NSData dataWithContentsOfFile:pendingIdentity
                                                  options:0 error:error];
    id propertyList = identityData == nil ? nil :
        [NSPropertyListSerialization propertyListWithData:identityData
                                                  options:0 format:nil
                                                    error:error];
    NSDictionary *identity = [propertyList isKindOfClass:NSDictionary.class]
        ? propertyList : nil;
    NSData *createId = [identity[@"createId"] isKindOfClass:NSData.class]
        ? identity[@"createId"] : nil;
    NSData *name = [identity[@"name"] isKindOfClass:NSData.class]
        ? identity[@"name"] : nil;
    if (createId.length != kartpad::mii::kCreateIdByteSize ||
        name.length == 0 || name.length > kartpad::mii::kMiiNameByteSize ||
        (name.length % 2) != 0) {
      if (error != nullptr) {
        *error = ManagerError(10, "The pending player identity is invalid.");
      }
      return NO;
    }
    std::array<uint8_t, kartpad::mii::kCreateIdByteSize> createIdBytes{};
    std::copy_n(static_cast<const uint8_t *>(createId.bytes),
                createIdBytes.size(), createIdBytes.begin());
    for (NSDictionary<NSString *, NSString *> *location in SaveLocations()) {
      NSString *path = location[@"path"];
      if (![files fileExistsAtPath:path]) continue;
      NSData *saveData = [NSData dataWithContentsOfFile:path
                                                options:NSDataReadingMappedIfSafe
                                                  error:error];
      if (saveData == nil || !ValidateSaveData(saveData, error)) return NO;
      std::vector<uint8_t> updatedSave(
          static_cast<const uint8_t *>(saveData.bytes),
          static_cast<const uint8_t *>(saveData.bytes) + saveData.length);
      std::size_t changedLicenses = 0;
      const auto renameResult = kartpad::mii::RenameMatchingLicenses(
          updatedSave, createIdBytes, Bytes(name), changedLicenses);
      if (!renameResult) {
        if (error != nullptr) *error = ManagerError(11, renameResult.message);
        return NO;
      }
      if (changedLicenses > 0) {
        [saveChanges addObject:@{
          @"path": path,
          @"backup": location[@"backup"],
          @"data": [NSData dataWithBytes:updatedSave.data()
                                    length:updatedSave.size()],
        }];
      }
    }
  }
  if (hasLicense) {
    NSData *intentData = [NSData dataWithContentsOfFile:pendingLicense
                                                options:0 error:error];
    id propertyList = intentData == nil ? nil :
        [NSPropertyListSerialization propertyListWithData:intentData
                                                  options:0 format:nil
                                                    error:error];
    NSDictionary *intent = [propertyList isKindOfClass:NSDictionary.class]
        ? propertyList : nil;
    NSString *operation = [intent[@"operation"] isKindOfClass:NSString.class]
        ? intent[@"operation"] : nil;
    NSString *profileIdentifier =
        [intent[@"profileIdentifier"] isKindOfClass:NSString.class]
            ? intent[@"profileIdentifier"] : nil;
    NSNumber *slotNumber = [intent[@"slot"] isKindOfClass:NSNumber.class]
        ? intent[@"slot"] : nil;
    NSData *createIdData = [intent[@"createId"] isKindOfClass:NSData.class]
        ? intent[@"createId"] : nil;
    NSData *nameData = [intent[@"name"] isKindOfClass:NSData.class]
        ? intent[@"name"] : nil;
    NSDictionary<NSString *, NSString *> *location =
        SaveLocation(profileIdentifier);
    std::array<uint8_t, kartpad::mii::kCreateIdByteSize> createId{};
    if (operation == nil || location == nil || slotNumber == nil ||
        slotNumber.unsignedIntegerValue >= kartpad::mii::kRksysLicenseCount ||
        !ReadCreateId(createIdData, createId, error) ||
        ([operation isEqualToString:@"rename"] &&
         (nameData.length == 0 || nameData.length > kartpad::mii::kMiiNameByteSize ||
          (nameData.length % 2) != 0)) ||
        (![operation isEqualToString:@"rename"] &&
         ![operation isEqualToString:@"mii"] &&
         ![operation isEqualToString:@"delete"])) {
      if (error != nullptr && *error == nil) {
        *error = ManagerError(18, "The pending license change is invalid.");
      }
      return NO;
    }
    NSString *path = location[@"path"];
    NSData *saveData = [NSData dataWithContentsOfFile:path
                                              options:NSDataReadingMappedIfSafe
                                                error:error];
    if (saveData == nil || !ValidateSaveData(saveData, error)) return NO;
    std::vector<uint8_t> updatedSave(
        static_cast<const uint8_t *>(saveData.bytes),
        static_cast<const uint8_t *>(saveData.bytes) + saveData.length);
    std::array<uint8_t, kartpad::mii::kCreateIdByteSize> selectedId{};
    if ([operation isEqualToString:@"mii"]) {
      NSNumber *selectedSlot = [intent[@"miiSlot"] isKindOfClass:NSNumber.class] ? intent[@"miiSlot"] : nil;
      NSData *selectedData = [intent[@"miiCreateId"] isKindOfClass:NSData.class] ? intent[@"miiCreateId"] : nil;
      if (selectedSlot == nil || !ReadCreateId(selectedData, selectedId, error)) return NO;
      nameData = SelectedMiiName(selectedSlot.unsignedIntegerValue, selectedData, error);
      if (nameData == nil) return NO;
    }
    const auto result = [operation isEqualToString:@"mii"]
        ? kartpad::mii::SetLicenseMii(updatedSave,
              slotNumber.unsignedIntegerValue, createId, selectedId, Bytes(nameData))
        : [operation isEqualToString:@"rename"]
        ? kartpad::mii::RenameLicense(updatedSave,
              slotNumber.unsignedIntegerValue, createId, Bytes(nameData))
        : kartpad::mii::DeleteLicense(updatedSave,
              slotNumber.unsignedIntegerValue, createId);
    if (!result) {
      if (error != nullptr) *error = ManagerError(19, result.message);
      return NO;
    }
    [saveChanges addObject:@{
      @"path": path,
      @"backup": location[@"backup"],
      @"data": [NSData dataWithBytes:updatedSave.data()
                                length:updatedSave.size()],
    }];
  }

  NSString *database = DatabasePath();
  NSString *stamp = [NSString stringWithFormat:@"%.0f-%@",
      NSDate.date.timeIntervalSince1970, NSUUID.UUID.UUIDString];
  if (hasDatabase &&
      !BackupFile(database, @"MiiBackups", @"RFL_DB", stamp, error)) return NO;
  for (NSDictionary<NSString *, id> *change in saveChanges) {
    if (!BackupFile(change[@"path"], @"SaveBackups", change[@"backup"],
                    stamp, error)) return NO;
  }

  if (hasDatabase) {
    NSString *parent = database.stringByDeletingLastPathComponent;
    if (![files createDirectoryAtPath:parent withIntermediateDirectories:YES
                           attributes:nil error:error] ||
        ![pendingData writeToFile:database options:NSDataWritingAtomic error:error]) {
      return NO;
    }
  }
  for (NSDictionary<NSString *, id> *change in saveChanges) {
    NSString *save = change[@"path"];
    NSString *parent = save.stringByDeletingLastPathComponent;
    NSData *saveData = change[@"data"];
    if (![files createDirectoryAtPath:parent withIntermediateDirectories:YES
                           attributes:nil error:error] ||
        ![saveData writeToFile:save options:NSDataWritingAtomic error:error]) {
      return NO;
    }
  }
  if (hasDatabase && ![files removeItemAtPath:pending error:error]) return NO;
  if (hasIdentity &&
      ![files removeItemAtPath:pendingIdentity error:error]) return NO;
  if (hasLicense &&
      ![files removeItemAtPath:pendingLicense error:error]) return NO;
  return YES;
}

BOOL KartPadHasPendingMiiChanges(void) {
  return OtherChangesPending() || [NSFileManager.defaultManager fileExistsAtPath:QueuePath()];
}

BOOL KartPadCanQueueMiiChanges(void) { return !OtherChangesPending(); }

// Waiting Mii and license changes, including an older version's. An interrupted commit's journal is
// not one: it has already started writing files and must finish.
static NSArray<NSString *> *DiscardablePaths() {
  return @[ QueuePath(), PendingPath(), PendingIdentityPath(), PendingLicensePath() ];
}

BOOL KartPadCanDiscardPendingMiiChanges(void) {
  for (NSString *path in DiscardablePaths())
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
  return NO;
}

BOOL KartPadDiscardPendingMiiChanges(NSError **error) {
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *path in DiscardablePaths())
    if ([files fileExistsAtPath:path] && ![files removeItemAtPath:path error:error]) return NO;
  return YES;
}

NSUInteger KartPadPendingMiiChangeCount(void) {
  NSArray *queue = ReadQueue(nullptr);
  return queue.count + (OtherChangesPending() || queue == nil ? 1 : 0);
}

#include "kartpad/ghost/rkg.h"

NSArray<NSDictionary<NSString *, id> *> *KartPadOriginalGhosts(NSUInteger license, NSError **error) {
  NSData *save = [NSData dataWithContentsOfFile:SaveLocation(@"original")[@"path"] options:0 error:error];
  if (save == nil) return nil;
  try {
    std::span<const uint8_t> bytes((const uint8_t *)save.bytes, save.length);
    kartpad::ghost::ValidateSave(bytes, (unsigned)license);
    NSMutableArray *records = [NSMutableArray array];
    std::string firstGhostError;
    for (bool downloaded : {false, true}) {
      const auto bits = kartpad::ghost::Read32(bytes, 8 + license * 0x8cc0 + (downloaded ? 8 : 4));
      for (unsigned slot = 0; slot < 32; ++slot) if (bits & (1u << slot)) {
        try {
          auto data = kartpad::ghost::Export(bytes, (unsigned)license, slot, downloaded);
          [records addObject:@{@"name": [NSString stringWithFormat:@"%s — %@", kartpad::ghost::CourseNames[slot], downloaded ? @"Downloaded" : @"Personal Best"],
              @"data": [NSData dataWithBytes:data.data() length:data.size()]}];
        } catch (const std::exception& failure) {
          // A corrupt ghost must not prevent exporting another valid slot.
          if (firstGhostError.empty()) firstGhostError = failure.what();
        }
      }
    }
    if (records.count == 0 && !firstGhostError.empty()) {
      if (error) *error = ManagerError(40, ("This license lists saved ghosts, but they could not be exported. " + firstGhostError + ". Your save has not been changed.").c_str());
      return nil;
    }
    return records;
  } catch (const std::exception& e) {
    if (error) *error = ManagerError(40, e.what());
    return nil;
  }
}

BOOL KartPadStageOriginalGhost(NSData *ghost, NSUInteger license, NSError **error) {
  if (KartPadHasPendingMiiChanges()) {
    if(error) *error=ManagerError(41,"Restart to apply the pending data change first.");
    return NO;
  }
  NSString *path=SaveLocation(@"original")[@"path"];
  NSData *save=[NSData dataWithContentsOfFile:path options:0 error:error];
  if(!save)return NO;
  try {
    auto result=kartpad::ghost::Import(std::span<const uint8_t>((const uint8_t*)save.bytes,save.length),
        std::span<const uint8_t>((const uint8_t*)ghost.bytes,ghost.length),(unsigned)license);
    (void)result;
    NSDictionary *request=@{@"ghost":ghost,@"license":@(license),
        @"identity":[save subdataWithRange:NSMakeRange(8+license*0x8cc0+0x28,8)]};
    NSData *plist=[NSPropertyListSerialization dataWithPropertyList:request format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return plist && [plist writeToFile:PendingGhostPath() options:NSDataWritingAtomic error:error];
  }catch(const std::exception& e){if(error)*error=ManagerError(42,e.what());return NO;}
}

static BOOL KartPadApplyPendingGhost(NSError **error) {
  NSString *pending=PendingGhostPath();
  NSFileManager *files=NSFileManager.defaultManager;
  if(![files fileExistsAtPath:pending])return YES;
  if([files fileExistsAtPath:PendingPath()]||[files fileExistsAtPath:PendingIdentityPath()]||[files fileExistsAtPath:PendingLicensePath()]) {
    if(error)*error=ManagerError(43,"Conflicting pending changes. Existing saves and requests were retained.");return NO;
  }
  NSDictionary *attrs=[files attributesOfItemAtPath:pending error:error];
  if(!attrs || [attrs fileSize]>32*1024){if(error)*error=ManagerError(44,"Invalid pending ghost request.");return NO;}
  NSData *data=[NSData dataWithContentsOfFile:pending options:0 error:error];
  id request=data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:error] : nil;
  if(![request isKindOfClass:NSDictionary.class]||![request[@"ghost"] isKindOfClass:NSData.class]||![request[@"identity"] isKindOfClass:NSData.class]||![request[@"license"] isKindOfClass:NSNumber.class])return NO;
  NSString *active=SaveLocation(@"original")[@"path"];
  NSData *current=[NSData dataWithContentsOfFile:active options:0 error:error];
  const NSUInteger license=[request[@"license"] unsignedIntegerValue];
  if(license>=4 || current.length!=kartpad::ghost::SaveBytes || ![[current subdataWithRange:NSMakeRange(8+license*0x8cc0+0x28,8)] isEqual:request[@"identity"]]){
    if(error)*error=ManagerError(45,"The selected license changed. Cancel the pending ghost import and choose the license again.");return NO;
  }
  NSData *after=nil;
  try {
    NSData *ghost=request[@"ghost"];
    auto result=kartpad::ghost::Import(std::span<const uint8_t>((const uint8_t*)current.bytes,current.length),std::span<const uint8_t>((const uint8_t*)ghost.bytes,ghost.length),(unsigned)license);
    after=[NSData dataWithBytes:result.data() length:result.size()];
  }catch(const std::exception& e){if(error)*error=ManagerError(46,e.what());return NO;}
  if(![current isEqualToData:after]) {
    if(!BackupFile(active,@"SaveBackups",@"rksys-ghost",NSUUID.UUID.UUIDString,error))return NO;
    if(![after writeToFile:active options:NSDataWritingAtomic error:error])return NO;
  }
  return [files removeItemAtPath:pending error:error];
}

BOOL KartPadHasPendingGhost(void) { return [NSFileManager.defaultManager fileExistsAtPath:PendingGhostPath()]; }
BOOL KartPadCancelPendingGhost(NSError **error) { return !KartPadHasPendingGhost() || [NSFileManager.defaultManager removeItemAtPath:PendingGhostPath() error:error]; }

static NSString *RawSavePendingPath(){return [SupportRoot() stringByAppendingPathComponent:@"PendingSaveRestore.plist"];}
static BOOL ValidateRawSave(NSData *data,NSError **error){
  auto b=std::span<const uint8_t>((const uint8_t*)data.bytes,data.length);
  try{kartpad::ghost::Require(b.size()==kartpad::ghost::SaveBytes,"A save must be exactly 2867200 bytes.");kartpad::ghost::Require(kartpad::ghost::Read32(b,0)==0x524b5344&&kartpad::ghost::Read32(b,4)==0x30303036,"Unsupported save format.");kartpad::ghost::Require(kartpad::ghost::Read32(b,0x27ffc)==kartpad::ghost::Crc(b.first(0x27ffc)),"Save checksum mismatch.");return YES;}catch(const std::exception &e){if(error)*error=ManagerError(50,e.what());return NO;}
}
NSData *KartPadReadSave(NSString *profile,NSError **error){
  NSDictionary *location=SaveLocation(profile);if(!location){if(error)*error=ManagerError(51,"Unknown save profile.");return nil;}
  NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:location[@"path"] error:error];if(!attrs)return nil;
  if([attrs fileSize]!=kartpad::ghost::SaveBytes){if(error)*error=ManagerError(52,"Unsupported save size.");return nil;}
  NSData *data=[NSData dataWithContentsOfFile:location[@"path"] options:0 error:error];return data&&ValidateRawSave(data,error)?data:nil;
}
BOOL KartPadHasPendingSaveRestore(void){return [NSFileManager.defaultManager fileExistsAtPath:RawSavePendingPath()];}
BOOL KartPadCancelSaveRestore(NSError **error){return !KartPadHasPendingSaveRestore()||[NSFileManager.defaultManager removeItemAtPath:RawSavePendingPath() error:error];}
BOOL KartPadStageSaveRestore(NSString *profile,NSData *data,NSError **error){
  if(KartPadHasPendingMiiChanges()){if(error)*error=ManagerError(53,"Apply or cancel the pending data change first.");return NO;}
  if(!SaveLocation(profile)||!ValidateRawSave(data,error))return NO;
  NSData *request=[NSPropertyListSerialization dataWithPropertyList:@{@"profile":profile,@"data":data} format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
  return request&&[request writeToFile:RawSavePendingPath() options:NSDataWritingAtomic error:error];
}
static BOOL KartPadApplyPendingSaveRestore(NSError **error){
  if(!KartPadHasPendingSaveRestore())return YES;
  NSFileManager *files=NSFileManager.defaultManager;
  if([files fileExistsAtPath:PendingPath()]||[files fileExistsAtPath:PendingIdentityPath()]||[files fileExistsAtPath:PendingLicensePath()]||KartPadHasPendingGhost()){if(error)*error=ManagerError(54,"Conflicting pending data changes.");return NO;}
  NSDictionary *attrs=[files attributesOfItemAtPath:RawSavePendingPath() error:error];if(!attrs||[attrs fileSize]>kartpad::ghost::SaveBytes+4096)return NO;
  NSData *request=[NSData dataWithContentsOfFile:RawSavePendingPath() options:0 error:error];
  NSDictionary *plist=[NSPropertyListSerialization propertyListWithData:request options:NSPropertyListImmutable format:nil error:error];
  if(![plist isKindOfClass:NSDictionary.class]||![plist[@"profile"] isKindOfClass:NSString.class]||![plist[@"data"] isKindOfClass:NSData.class])return NO;
  NSDictionary *location=SaveLocation(plist[@"profile"]);if(!location||!ValidateRawSave(plist[@"data"],error))return NO;
  NSString *active=location[@"path"];
  if([files fileExistsAtPath:active]){NSData *current=KartPadReadSave(plist[@"profile"],error);if(!current)return NO;if(![current isEqual:plist[@"data"]]&&!BackupFile(active,@"SaveBackups",@"rksys-restore",NSUUID.UUID.UUIDString,error))return NO;}
  if(![files createDirectoryAtPath:active.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error])return NO;
  if(![plist[@"data"] writeToFile:active options:NSDataWritingAtomic error:error])return NO;
  return KartPadCancelSaveRestore(error);
}

#if !defined(KARTPAD_MII_MANAGER_TESTING) && !defined(KARTPAD_MII_EDITOR_DISABLED) && \
    (TARGET_OS_OSX || (TARGET_OS_IOS && !TARGET_OS_TV))
#include "KartPadMiiEditor.inc.mm"
#include "KartPadMiiBrowser.inc.mm"
#include "KartPadMiiPadKeyboard.inc.mm"
#include "KartPadMiiGamepad.inc.mm"
#endif
