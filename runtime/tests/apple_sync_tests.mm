// Progress sync between two devices (two support roots) through one folder: first send, choosing at
// first link, loading newer progress without asking, choosing when both changed (keep, use, later),
// progress chosen in Settings, checks while running, files that don't check out, and turning off.
#import "KartPadMiiManager.h"
#import "KartPadSync.h"
#include "kartpad/mii/player_identity.h"
#include <cassert>
#include <cstdlib>

static NSData *Data(const auto &b) { return [NSData dataWithBytes:b.data() length:b.size()]; }
static void Write(NSString *p, NSData *d) {
  assert([NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([d writeToFile:p options:NSDataWritingAtomic error:nil]);
}
static NSString *TempDir(const char *name) {
  NSString *pattern = [NSString stringWithFormat:@"/tmp/kartpad-sync-%s.XXXXXX", name];
  char *path = strdup(pattern.UTF8String);
  assert(mkdtemp(path));
  NSString *result = @(path);
  free(path);
  return result;
}

static NSString *gFolder;
struct Device {
  NSString *root;
  const char *name;
  void Use() const {
    setenv("KARTPAD_MII_TEST_SUPPORT_ROOT", root.UTF8String, 1);
    setenv("KARTPAD_SYNC_TEST_DEVICE_NAME", name, 1);
  }
  NSString *Path(NSString *relative) const { return [root stringByAppendingPathComponent:relative]; }
  NSString *OriginalPath() const { return Path(@"NAND/title/00010004/524d4350/data/rksys.dat"); }
  NSString *RetroPath() const { return Path(@"RetroRewind/riivolution/save/RetroWFC/RMCP/rksys.dat"); }
  NSString *MiiPath() const { return Path(@"NAND/shared2/menu/FaceLib/RFL_DB.dat"); }
  NSString *RatingsPath() const { return Path(@"NAND/shared2/Pulsar/RetroRewind6/RRRating.pul"); }
  NSData *Retro() const { return [NSData dataWithContentsOfFile:RetroPath()]; }
};

static std::vector<uint8_t> gSave;
static std::vector<uint8_t> gDatabase;

// A valid save whose Retro progress byte is `progress`, with one license named `license`.
static NSData *Save(uint8_t progress, const char *license) {
  using namespace kartpad::mii;
  auto save = gSave;
  WriteMiiName(save, kRksysLicenseOffset + kRksysMiiNameOffset, license);
  save[0x100] = progress;
  UpdateRksysCrc(save);
  return Data(save);
}

static NSData *Ratings() {
  std::vector<uint8_t> bytes(1640);
  const uint8_t header[] = {'R', 'R', 'R', 'T', 0, 1, 0, 100};
  std::copy(std::begin(header), std::end(header), bytes.begin());
  return Data(bytes);
}

static void Setup(const Device &device, uint8_t progress, const char *license) {
  Write(device.MiiPath(), Data(gDatabase));
  Write(device.OriginalPath(), Save(progress, license));
  Write(device.RetroPath(), Save(progress, license));
  Write(device.RatingsPath(), Ratings());
}

static int gAsked = 0;
static KartPadSyncChoice (^Answer(KartPadSyncChoice answer))(KartPadSyncProgress *, KartPadSyncProgress *) {
  return ^KartPadSyncChoice(KartPadSyncProgress *mine, KartPadSyncProgress *other) {
    gAsked++;
    assert(mine.deviceName.length > 0 && other.deviceName.length > 0);
    assert(![mine.deviceID isEqualToString:other.deviceID]);
    return answer;
  };
}
static KartPadSyncChoice (^NeverAsked)(KartPadSyncProgress *, KartPadSyncProgress *) =
    ^KartPadSyncChoice(KartPadSyncProgress *, KartPadSyncProgress *) { assert(!"asked"); return KartPadSyncChoiceLater; };

static void Enable(const Device &device) {
  device.Use();
  NSError *error = nil;
  assert(KartPadSyncChooseFolder([NSURL fileURLWithPath:gFolder], &error));
  assert(KartPadSyncEnabled());
}

int main() {
  @autoreleasepool {
    using namespace kartpad::mii;
    gDatabase = CreateSeedDatabase({2, 1, 2, 3, 4, 5});
    auto id = MiiCreateId(gDatabase, 0);
    gSave.assign(kRksysSize, 0);
    std::copy_n("RKSD0006", 8, gSave.begin());
    std::copy_n("RKPD", 4, gSave.begin() + kRksysLicenseOffset);
    std::copy(id.begin(), id.end(), gSave.begin() + kRksysLicenseOffset + kRksysCreateIdOffset);

    gFolder = TempDir("folder");
    Device mac{TempDir("mac"), "Mac"}, phone{TempDir("phone"), "iPhone"};
    Setup(mac, 0x10, "SeaPancake");
    Setup(phone, 0x01, "KartPad");

    // Off until a folder is chosen: launch does nothing.
    mac.Use();
    assert(!KartPadSyncEnabled());
    assert([KartPadSyncStatus() isEqualToString:@"Off"]);
    KartPadSyncAtLaunch(5, NeverAsked);
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:gFolder error:nil] count] == 0);

    // The first device sends without asking.
    Enable(mac);
    KartPadSyncAtLaunch(5, NeverAsked);
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:gFolder error:nil] count] == 1);
    assert([KartPadSyncStatus() hasPrefix:@"Synced"]);

    // A second device with its own progress chooses; using the Mac's replaces it after a backup.
    Enable(phone);
    NSArray<KartPadSyncProgress *> *others = KartPadSyncOtherDevices(5);
    assert(others.count == 1 && [others[0].deviceName isEqualToString:@"Mac"]);
    assert([others[0].licenses isEqualToArray:@[@"SeaPancake"]]);
    gAsked = 0;
    KartPadSyncAtLaunch(5, Answer(KartPadSyncChoiceUseOther));
    assert(gAsked == 1);
    assert([phone.Retro() isEqualToData:Save(0x10, "SeaPancake")]);
    NSArray *backups = [NSFileManager.defaultManager contentsOfDirectoryAtPath:phone.Path(@"SyncBackups") error:nil];
    assert(backups.count == 1);
    NSString *backup = [phone.Path(@"SyncBackups") stringByAppendingPathComponent:backups[0]];
    assert([[NSData dataWithContentsOfFile:[backup stringByAppendingPathComponent:@"retro_rewind.dat"]]
        isEqualToData:Save(0x01, "KartPad")]);
    // Nothing changed since: the next launch neither asks nor loads.
    KartPadSyncAtLaunch(5, NeverAsked);
    assert(!KartPadSyncNeedsRestart());

    // The phone plays and sends; the Mac, unchanged, loads it at launch without asking.
    Write(phone.RetroPath(), Save(0x20, "SeaPancake"));
    KartPadSyncSendNow(5);
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:gFolder error:nil] count] == 2);
    mac.Use();
    // While running the Mac only notes it.
    KartPadSyncSendNow(5);
    assert(KartPadSyncNeedsRestart());
    assert([KartPadSyncStatus() isEqualToString:@"Restart to load newer progress"]);
    assert([mac.Retro() isEqualToData:Save(0x10, "SeaPancake")]);
    KartPadSyncAtLaunch(5, NeverAsked);
    assert([mac.Retro() isEqualToData:Save(0x20, "SeaPancake")]);
    assert(!KartPadSyncNeedsRestart());

    // Both change: the Mac chooses to keep its own; the phone then loads it without asking.
    Write(mac.RetroPath(), Save(0x30, "SeaPancake"));
    phone.Use();
    Write(phone.RetroPath(), Save(0x31, "SeaPancake"));
    KartPadSyncSendNow(5);
    mac.Use();
    gAsked = 0;
    KartPadSyncAtLaunch(5, Answer(KartPadSyncChoiceKeepThisDevice));
    assert(gAsked == 1);
    assert([mac.Retro() isEqualToData:Save(0x30, "SeaPancake")]);
    phone.Use();
    KartPadSyncAtLaunch(5, NeverAsked);
    assert([phone.Retro() isEqualToData:Save(0x30, "SeaPancake")]);

    // Both change and the choice waits: nothing is sent or loaded, and the next launch asks again.
    Write(phone.RetroPath(), Save(0x40, "SeaPancake"));
    KartPadSyncSendNow(5);
    mac.Use();
    Write(mac.RetroPath(), Save(0x41, "SeaPancake"));
    gAsked = 0;
    KartPadSyncAtLaunch(5, Answer(KartPadSyncChoiceLater));
    assert(gAsked == 1);
    assert([KartPadSyncStatus() isEqualToString:@"Restart to choose progress"]);
    assert(KartPadSyncNeedsRestart());
    KartPadSyncSendNow(5);  // a check while running doesn't send over the waiting choice
    assert([mac.Retro() isEqualToData:Save(0x41, "SeaPancake")]);
    KartPadSyncAtLaunch(5, Answer(KartPadSyncChoiceUseOther));
    assert(gAsked == 2);
    assert([mac.Retro() isEqualToData:Save(0x40, "SeaPancake")]);

    // Progress chosen in Settings replaces this device's at the next launch, even changed progress.
    phone.Use();
    KartPadSyncAtLaunch(5, NeverAsked);  // the Mac's file now says it has the phone's progress
    Write(phone.RetroPath(), Save(0x50, "SeaPancake"));
    others = KartPadSyncOtherDevices(5);
    NSError *error = nil;
    assert(KartPadSyncUseProgressAtNextLaunch(others[0].deviceID, &error));
    assert([KartPadSyncStatus() isEqualToString:@"Restart to load chosen progress"]);
    KartPadSyncAtLaunch(5, NeverAsked);
    assert([phone.Retro() isEqualToData:Save(0x40, "SeaPancake")]);
    assert(!KartPadSyncNeedsRestart());

    // A file in the folder that doesn't check out is ignored.
    NSString *bogus = [gFolder stringByAppendingPathComponent:@"bogus.kartpadsync"];
    Write(bogus, [@"not progress" dataUsingEncoding:NSUTF8StringEncoding]);
    assert(KartPadSyncOtherDevices(5).count == 1);
    KartPadSyncAtLaunch(5, NeverAsked);

    // A save the game is mid-way through writing (bad checksum) is never sent.
    std::vector<uint8_t> torn(kRksysSize);
    std::copy_n("RKSD0006", 8, torn.begin());
    Write(phone.RetroPath(), Data(torn));
    KartPadSyncSendNow(5);
    assert([KartPadSyncStatus() isEqualToString:@"Waiting for the game to save"]);
    Write(phone.RetroPath(), Save(0x40, "SeaPancake"));

    // An unreachable folder leaves this device's progress alone.
    mac.Use();
    Write(mac.RetroPath(), Save(0x60, "SeaPancake"));
    assert([NSFileManager.defaultManager removeItemAtPath:gFolder error:nil]);
    KartPadSyncAtLaunch(1, NeverAsked);
    assert([KartPadSyncStatus() isEqualToString:@"Folder unavailable"]);
    assert([mac.Retro() isEqualToData:Save(0x60, "SeaPancake")]);

    // Turning off forgets the folder.
    KartPadSyncTurnOff();
    assert(!KartPadSyncEnabled());
    assert([KartPadSyncStatus() isEqualToString:@"Off"]);
    puts("sync tests passed");
  }
  return 0;
}
