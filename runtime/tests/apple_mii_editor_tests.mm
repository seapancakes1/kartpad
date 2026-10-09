#import "KartPadMiiManager.h"
#include "kartpad/mii/appearance.h"
#include "kartpad/mii/player_identity.h"
#include <cassert>
#include <filesystem>
static NSData *Data(const auto &b) { return [NSData dataWithBytes:b.data() length:b.size()]; }
static void Write(NSString *p, NSData *d) {
    assert([NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil]);
    assert([d writeToFile:p options:NSDataWritingAtomic error:nil]);
}
static std::vector<uint8_t> Vector(NSData *d) {
    auto p = (const uint8_t *)d.bytes;
    return {p, p + d.length};
}
int main() {
    @autoreleasepool {
        using namespace kartpad::mii;
        char temp[] = "/tmp/kartpad-editor-tests.XXXXXX";
        assert(mkdtemp(temp));
        setenv("KARTPAD_MII_TEST_SUPPORT_ROOT", temp, 1);
        NSString *root = @(temp);
        NSString *dbpath =
            [root stringByAppendingPathComponent:@"NAND/shared2/menu/FaceLib/RFL_DB.dat"];
        auto db = CreateSeedDatabase({2, 1, 2, 3, 4, 5});
        Write(dbpath, Data(db));
        auto id = MiiCreateId(db, 0);
        std::vector<uint8_t> save(kRksysSize);
        std::copy_n("RKSD0006", 8, save.begin());
        std::copy_n("RKPD", 4, save.begin() + kRksysLicenseOffset);
        std::copy(id.begin(), id.end(), save.begin() + kRksysLicenseOffset + kRksysCreateIdOffset);
        WriteMiiName(save, kRksysLicenseOffset + kRksysMiiNameOffset, "KartPad");
        save[0x100] = 0x51;
        UpdateRksysCrc(save);
        NSArray *paths = @[
            [root stringByAppendingPathComponent:@"NAND/title/00010004/524d4350/data/rksys.dat"],
            [root stringByAppendingPathComponent:
                      @"RetroRewind/riivolution/save/RetroWFC/RMCP/rksys.dat"],
            [root stringByAppendingPathComponent:
                      @"RetroRewind/riivolution/save/RetroWFC2/RMCP/rksys.dat"]
        ];
        for (NSString *p in paths)
            Write(p, Data(save));
        NSError *error = nil;
        NSData *expected = KartPadReadMii(0, &error);
        assert(expected.length == 74);
        auto edit = Appearance::Decode(Vector(expected));
        edit.Set(11, 71);
        WriteMiiName(edit.bytes, 2, "New Name");
        assert([KartPadExportMii(Data(edit.bytes), &error) isEqualToData:Data(edit.bytes)]);
        assert([Data(db) isEqualToData:[NSData dataWithContentsOfFile:dbpath]]);
        auto malformed = edit;
        malformed.bytes[34] = 255;
        assert(!KartPadExportMii(Data(malformed.bytes), &error));
        assert(KartPadStageMiiEditor(0, expected, Data(edit.bytes), &error));
        assert([Data(db) isEqualToData:[NSData dataWithContentsOfFile:dbpath]]);
        // Changes queue: a stale one is refused, and the next builds on the queued edit.
        assert(!KartPadStageMiiEditor(0, expected, Data(edit.bytes), &error));
        NSData *queued = KartPadReadMii(0, &error);
        assert([queued isEqualToData:Data(edit.bytes)]);
        edit.Set(11, 70);
        assert(KartPadStageMiiEditor(0, queued, Data(edit.bytes), &error));
        assert(KartPadPendingMiiChangeCount() == 2);
        assert([Data(db) isEqualToData:[NSData dataWithContentsOfFile:dbpath]]);
        assert(KartPadNewMii(&error).length == 74);
        // New race progress after staging must be retained in both save profiles.
        auto latest = save;
        latest[0x100] = 0x92;
        UpdateRksysCrc(latest);
        for (NSString *p in paths)
            Write(p, Data(latest));
        setenv("KARTPAD_MII_TEST_INTERRUPT_AFTER", "1", 1);
        assert(!KartPadApplyPendingMiiDatabase(&error));
        assert(KartPadHasPendingMiiChanges());
        assert([NSFileManager.defaultManager
            fileExistsAtPath:[root stringByAppendingPathComponent:@"MiiEditorTransaction.plist"]]);
        unsetenv("KARTPAD_MII_TEST_INTERRUPT_AFTER");
        error = nil;
        assert(KartPadApplyPendingMiiDatabase(&error));
        assert(!KartPadHasPendingMiiChanges());
        assert([KartPadReadMii(0, &error) isEqualToData:Data(edit.bytes)]);
        for (NSString *p in paths) {
            auto after = Vector([NSData dataWithContentsOfFile:p]);
            assert(ReadMiiName(after, kRksysLicenseOffset + kRksysMiiNameOffset) == "New Name");
            for (size_t byte = 0; byte < after.size(); byte++) {
                bool name = byte >= kRksysLicenseOffset + kRksysMiiNameOffset &&
                            byte < kRksysLicenseOffset + kRksysMiiNameOffset + 20;
                bool crc = byte >= kRksysCoreCrcOffset && byte < kRksysCoreCrcOffset + 4;
                if (!name && !crc)
                    assert(after[byte] == latest[byte]);
            }
        }
        for (NSString *folder in @[ @"MiiBackups", @"SaveBackups" ])
            assert([[NSFileManager.defaultManager
                       contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:folder]
                                           error:nil] count] == ([folder isEqual:@"MiiBackups"] ? 1 : 3));
        assert(!KartPadStageMiiEditor(0, expected, Data(edit.bytes), &error));
        assert(!KartPadHasPendingMiiChanges());
        NSData *newMii = KartPadNewMii(&error);
        assert(newMii.length == 74);
        auto beforeDb = [NSData dataWithContentsOfFile:dbpath];
        assert(KartPadStageMiiEditor(NSNotFound, nil, newMii, &error));
        assert([beforeDb isEqualToData:[NSData dataWithContentsOfFile:dbpath]]);
        assert(KartPadApplyPendingMiiDatabase(&error));
        assert(KartPadMiiRecords(&error).count == 2);
        assert(KartPadLicenseRecords(&error).count == 3);
        // Records carry each Mii's bytes; a duplicate keeps them except for a fresh identity.
        NSArray *records = KartPadMiiRecords(&error);
        assert([records[0][@"mii"] isEqualToData:KartPadReadMii(0, &error)]);
        auto source = Vector(KartPadReadMii(0, &error));
        NSData *copy = KartPadDuplicateMii(0, &error);
        assert(copy.length == 74);
        auto duplicate = Vector(copy);
        assert(!std::equal(source.begin() + 0x18, source.begin() + 0x1C, duplicate.begin() + 0x18));
        for (size_t byte = 0; byte < source.size(); byte++)
            if (byte < 0x18 || byte >= 0x20)
                assert(source[byte] == duplicate[byte]);
        assert(KartPadStageMiiEditor(NSNotFound, nil, copy, &error));
        // A second copy queued behind the first still gets an identity of its own.
        NSData *second = KartPadDuplicateMii(0, &error);
        assert(second && ![second isEqualToData:copy]);
        assert(KartPadStageMiiEditor(NSNotFound, nil, second, &error));
        assert(KartPadMiiRecords(&error).count == 4);
        assert(KartPadApplyPendingMiiDatabase(&error));
        assert(KartPadMiiRecords(&error).count == 4);
        assert(KartPadLicenseRecords(&error).count == 3);
        // Stale database between staging and restart must not modify any linked saves.
        expected = KartPadReadMii(0, &error);
        edit = Appearance::Decode(Vector(expected));
        edit.Set(11, 2);
        assert(KartPadStageMiiEditor(0, expected, Data(edit.bytes), &error));
        auto changed = Vector([NSData dataWithContentsOfFile:dbpath]);
        changed[24] ^= 1;
        UpdateDatabaseCrc(changed);
        Write(dbpath, Data(changed));
        assert(!KartPadApplyPendingMiiDatabase(&error));
        assert(![NSFileManager.defaultManager
            fileExistsAtPath:[root stringByAppendingPathComponent:@"MiiEditorTransaction.plist"]]);
        assert(KartPadHasPendingMiiChanges());
        assert([NSFileManager.defaultManager
            removeItemAtPath:[root stringByAppendingPathComponent:@"PendingMiiChanges.plist"]
                       error:nil]);
        // One queue across the database and every save: deleting the licenses frees their Mii,
        // which a later change in the same queue removes. Deleted licenses stay listed until then.
        NSArray *licenses = KartPadLicenseRecords(&error);
        assert(licenses.count == 3);
        assert(!KartPadStageMiiRemoval(0, &error));
        for (NSDictionary *license in licenses)
            assert(KartPadStageLicenseDeletion(license[@"profileIdentifier"],
                                               [license[@"slot"] unsignedIntegerValue],
                                               license[@"createId"], &error));
        licenses = KartPadLicenseRecords(&error);
        assert(licenses.count == 3);
        for (NSDictionary *license in licenses)
            assert([license[@"pendingOperation"] isEqual:@"delete"]);
        assert(KartPadStageMiiRemoval(0, &error));
        assert(KartPadMiiRecords(&error).count == 3 && KartPadPendingMiiChangeCount() == 4);
        NSData *liveDb = [NSData dataWithContentsOfFile:dbpath];
        assert(KartPadApplyPendingMiiDatabase(&error));
        assert(![liveDb isEqualToData:[NSData dataWithContentsOfFile:dbpath]]);
        assert(KartPadMiiRecords(&error).count == 3);
        assert(KartPadLicenseRecords(&error).count == 0);
        assert(!KartPadHasPendingMiiChanges());
        // Discarding drops every waiting change and leaves the live files alone.
        assert(!KartPadCanDiscardPendingMiiChanges());
        liveDb = [NSData dataWithContentsOfFile:dbpath];
        assert(KartPadStageMiiEditor(NSNotFound, nil, KartPadNewMii(&error), &error));
        assert(KartPadStageMiiRemoval([KartPadMiiRecords(&error)[0][@"slot"] unsignedIntegerValue], &error));
        assert(KartPadCanDiscardPendingMiiChanges() && KartPadPendingMiiChangeCount() == 2);
        assert(KartPadDiscardPendingMiiChanges(&error));
        assert(!KartPadHasPendingMiiChanges() && !KartPadCanDiscardPendingMiiChanges());
        assert(KartPadMiiRecords(&error).count == 3);
        assert(KartPadApplyPendingMiiDatabase(&error));
        assert([liveDb isEqualToData:[NSData dataWithContentsOfFile:dbpath]]);
        std::filesystem::remove_all(temp);
        puts("Combined Mii/name staging, latest progress, backups, interrupted recovery, new "
             "creation, duplication and stale rejection passed.");
    }
}
