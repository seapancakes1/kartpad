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
        assert(!KartPadStageMiiEditor(0, expected, Data(edit.bytes), &error));
        assert(!KartPadNewMii(&error));
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
        assert(
            [[NSFileManager.defaultManager
                contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"MiiEditorBackups"]
                                    error:nil] count] == 4);
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
        std::filesystem::remove_all(temp);
        puts("Combined Mii/name staging, latest progress, backups, interrupted recovery, new "
             "creation and stale rejection passed.");
    }
}
