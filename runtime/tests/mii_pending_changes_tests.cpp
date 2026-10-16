#include "kartpad/mii/pending_changes.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace kartpad::mii;

namespace {

constexpr std::array<uint8_t, 6> kMac{0x02, 0x17, 0xAB, 0x10, 0x20, 0x30};

MiiBlockBytes MakeMii(const char* name, uint32_t id) {
    auto mii = CreateDefaultMii(kMac);
    WriteMiiName(mii, 0x02, name);
    WriteBigEndian32(mii, 0x18, id);
    return mii;
}

CreateIdBytes IdOf(const MiiBlockBytes& mii) {
    CreateIdBytes id{};
    std::copy_n(mii.begin() + 0x18, id.size(), id.begin());
    return id;
}

std::vector<uint8_t> MakeDatabase(std::initializer_list<MiiBlockBytes> extra) {
    auto database = CreateSeedDatabase(kMac);
    for (const auto& mii : extra) assert(ImportMii(database, mii));
    return database;
}

std::vector<uint8_t> Utf16(std::string_view ascii) {
    std::vector<uint8_t> name;
    for (const char c : ascii) {
        name.push_back(0);
        name.push_back(static_cast<uint8_t>(c));
    }
    return name;
}

std::size_t LicenseAt(std::size_t slot) { return kRksysLicenseOffset + slot * kRksysLicenseSize; }

// A save whose licenses race as the given Miis; slots left out stay empty. Progress stand-ins
// in each license must survive every change.
std::vector<uint8_t> MakeSave(std::initializer_list<std::pair<std::size_t, CreateIdBytes>> licenses,
                              uint8_t progress) {
    std::vector<uint8_t> save(kRksysSize, 0);
    std::copy_n("RKSD0006", 8, save.begin());
    for (const auto& [slot, id] : licenses) {
        const auto offset = LicenseAt(slot);
        std::copy_n("RKPD", 4, save.begin() + offset);
        std::copy(id.begin(), id.end(), save.begin() + offset + kRksysCreateIdOffset);
        WriteMiiName(save, offset + kRksysMiiNameOffset, "Player");
        save[offset + 0x90] = progress;
        save[offset + 0x4A0] = static_cast<uint8_t>(progress + slot);
    }
    UpdateRksysCrc(save);
    return save;
}

std::string LicenseName(const std::vector<uint8_t>& save, std::size_t slot) {
    return ReadMiiName(save, LicenseAt(slot) + kRksysMiiNameOffset);
}

std::string MiiName(const std::vector<uint8_t>& database, std::size_t slot) {
    return ReadMiiName(database, MiiNameOffset(slot));
}

MiiBlockBytes Record(const std::vector<uint8_t>& database, std::size_t slot) {
    MiiBlockBytes record{};
    std::copy_n(database.begin() + kMiiBlockOffset + slot * kMiiBlockSize, record.size(),
                record.begin());
    return record;
}

// Only the license names and the checksum may differ between two saves.
bool OnlyNamesChanged(const std::vector<uint8_t>& before, const std::vector<uint8_t>& after) {
    if (before.size() != after.size()) return false;
    for (std::size_t index = 0; index < before.size(); ++index) {
        bool name = false;
        for (std::size_t slot = 0; slot < kRksysLicenseCount; ++slot) {
            const auto start = LicenseAt(slot) + kRksysMiiNameOffset;
            name = name || (index >= start && index < start + kMiiNameByteSize);
        }
        const bool crc = index >= kRksysCoreCrcOffset && index < kRksysCoreCrcOffset + 4;
        if (!name && !crc && before[index] != after[index]) return false;
    }
    return true;
}

struct Fixture {
    MiiBlockBytes seed{};
    MiiBlockBytes bob = MakeMii("Bob", 0x80000002u);
    MiiBlockBytes cat = MakeMii("Cat", 0x80000003u);
    GameFiles files;

    Fixture() {
        files.database = MakeDatabase({bob, cat});
        seed = Record(*files.database, 0);
        // Bob races in every profile; the seed Mii only in the original save.
        files.saves[0] = MakeSave({{0, IdOf(bob)}, {1, IdOf(seed)}}, 0x72);
        files.saves[1] = MakeSave({{1, IdOf(bob)}}, 0x35);
        files.saves[2] = MakeSave({{0, IdOf(bob)}, {3, IdOf(bob)}}, 0x44);
    }
};

ReplayState Start(const GameFiles& files) {
    auto result = Replay(files, {});
    assert(result);
    return result.state;
}

void TestOrderingAndDescriptions() {
    Fixture fixture;
    auto state = Start(fixture.files);
    std::vector<PendingChange> queue;
    // Bob (slot 1) is renamed, then edited; the edit expects the renamed record.
    assert(Append(state, queue, RenameMiiChange(1, IdOf(fixture.bob), Utf16("Ann"))));
    assert(queue.back().description == "“Bob” will be renamed “" "Ann”. "
                                       "Its 4 licenses will use the new name.");
    const auto renamed = Record(*state.files.database, 1);
    auto edit = Appearance::Decode(renamed);
    edit.Set(11, 40);
    assert(!Append(state, queue, EditMiiChange(1, fixture.bob, edit.bytes)));  // Stale.
    assert(queue.size() == 1);
    assert(Append(state, queue, EditMiiChange(1, renamed, edit.bytes)));
    assert(queue.back().description == "“" "Ann” will be updated.");
    auto named = edit;
    WriteMiiName(named.bytes, 0x02, "Ann Lee");
    assert(Append(state, queue, EditMiiChange(1, edit.bytes, named.bytes)));
    assert(queue.back().description ==
           "“" "Ann” will be updated and renamed “" "Ann Lee”.");
    const auto dan = MakeMii("Dan", 0x80000004u);
    assert(Append(state, queue, ImportMiiChange(dan)));
    assert(queue.back().description == "“" "Dan” will be added.");
    assert(Append(state, queue, NewMiiChange(MakeMii("Eve", 0x80000005u))));
    assert(queue.back().description == "“" "Eve” will be added.");
    assert(Append(state, queue, RemoveMiiChange(3, IdOf(dan))));
    assert(queue.back().description == "“" "Dan” will be removed.");

    // Replaying the queue gives what appending built, change by change.
    const auto replayed = Replay(fixture.files, queue);
    assert(replayed && replayed.state.files == state.files);
    assert(MiiName(*replayed.state.files.database, 1) == "Ann Lee");
    assert(Appearance::Decode(Record(*replayed.state.files.database, 1)).Get(11) == 40);
    assert(MiiName(*replayed.state.files.database, 4) == "Eve");
    assert(IsEmptyMii(std::span(*replayed.state.files.database)
                          .subspan(kMiiBlockOffset + 3 * kMiiBlockSize, kMiiBlockSize)));
    for (const auto& save : replayed.state.files.saves) {
        for (const auto& license : ListLicenses(*save)) {
            assert(license.name == (license.createId == IdOf(fixture.bob) ? "Ann Lee" : "Player"));
        }
    }
    // Out of order, the edit no longer finds what it expects, and nothing after it applies.
    auto reversed = queue;
    std::swap(reversed[0], reversed[1]);
    const auto failed = Replay(fixture.files, reversed);
    assert(!failed && failed.failedChange == 0 &&
           failed.message == "This Mii changed. Reopen the editor.");
    // An unchanged name leaves every save alone.
    auto plain = Start(fixture.files);
    std::vector<PendingChange> only;
    auto hair = Appearance::Decode(fixture.bob);
    hair.Set(11, 12);
    assert(Append(plain, only, EditMiiChange(1, fixture.bob, hair.bytes)));
    assert(plain.files.saves == fixture.files.saves);
    std::puts("Mii pending changes: ordering, stale edits and descriptions passed");
}

void TestStaleRejectsWholeQueue() {
    Fixture fixture;
    auto state = Start(fixture.files);
    std::vector<PendingChange> queue;
    assert(Append(state, queue, ImportMiiChange(MakeMii("Dan", 0x80000004u))));
    assert(Append(state, queue, RenameMiiChange(2, IdOf(fixture.cat), Utf16("Kit"))));
    assert(Append(state, queue, LicenseRenameChange(SaveProfile::RetroRewind, 1,
                                                    IdOf(fixture.bob), Utf16("Racer"))));
    assert(Replay(fixture.files, queue));
    // Another tool replaces Cat (slot 2) after the queue was built: the second change no longer
    // fits, so the queue fails as a whole.
    auto changed = fixture.files;
    auto other = MakeMii("Cat", 0x80000009u);
    std::copy(other.begin(), other.end(),
              changed.database->begin() + kMiiBlockOffset + 2 * kMiiBlockSize);
    UpdateDatabaseCrc(*changed.database);
    auto failed = Replay(changed, queue);
    assert(!failed && failed.failedChange == 1 &&
           failed.message == "The selected Mii changed. Reopen Miis and choose it again.");
    // A license that changed identity rejects its change too.
    changed = fixture.files;
    changed.saves[1] = MakeSave({{1, IdOf(fixture.cat)}}, 0x35);
    failed = Replay(changed, queue);
    assert(!failed && failed.failedChange == 2);
    // So does a missing database or save, or a damaged one.
    changed = fixture.files;
    changed.database.reset();
    failed = Replay(changed, queue);
    assert(!failed && failed.failedChange == 0 &&
           failed.message == "No Mii database exists yet. Start Mario Kart Wii once, then try again.");
    changed = fixture.files;
    changed.saves[1].reset();
    failed = Replay(changed, queue);
    assert(!failed && failed.message == "The selected license changed. Reopen Miis and try again.");
    changed = fixture.files;
    (*changed.saves[2])[0x200] ^= 1;
    failed = Replay(changed, queue);
    assert(!failed && failed.failedChange == 1 &&
           failed.message == "The Mario Kart Wii save checksum is invalid.");
    // New race progress saved meanwhile is kept by the replay.
    changed = fixture.files;
    (*changed.saves[0])[LicenseAt(0) + 0x90] = 0x99;
    UpdateRksysCrc(*changed.saves[0]);
    const auto kept = Replay(changed, queue);
    assert(kept && (*kept.state.files.saves[0])[LicenseAt(0) + 0x90] == 0x99);
    std::puts("Mii pending changes: a stale or missing target rejects the whole queue passed");
}

} // namespace

namespace {

void TestRenamePropagation() {
    Fixture fixture;
    auto state = Start(fixture.files);
    std::vector<PendingChange> queue;
    assert(Append(state, queue, RenameMiiChange(1, IdOf(fixture.bob), Utf16("Ann"))));
    for (std::size_t profile = 0; profile < kSaveProfileCount; ++profile) {
        const auto& before = *fixture.files.saves[profile];
        const auto& after = *state.files.saves[profile];
        assert(ValidateRksys(after) && OnlyNamesChanged(before, after));
        for (const auto& license : ListLicenses(after)) {
            assert(license.name == (license.createId == IdOf(fixture.bob) ? "Ann" : "Player"));
            // Queued renames are noted on every license they reach.
            const bool renamed = license.createId == IdOf(fixture.bob);
            assert(state.notes[profile][license.slot].operation ==
                   (renamed ? std::optional(LicenseOperation::Rename) : std::nullopt));
        }
    }
    assert(MiiName(*state.files.database, 1) == "Ann");
    // A renamed license gives its Mii the name, without rewriting other licenses.
    assert(Append(state, queue, LicenseRenameChange(SaveProfile::RetroRewindSeparate, 3,
                                                    IdOf(fixture.bob), Utf16("Zed"))));
    assert(MiiName(*state.files.database, 1) == "Zed");
    assert(LicenseName(*state.files.saves[2], 3) == "Zed" &&
           LicenseName(*state.files.saves[2], 0) == "Ann" &&
           LicenseName(*state.files.saves[0], 0) == "Ann");
    assert(queue.back().description ==
           "Retro Rewind (Separate Save) · License 4 will be renamed “Zed”.");
    // Names must be 1 to 10 valid UTF-16 units.
    for (const auto& name : {Utf16(""), Utf16("ABCDEFGHIJK"), std::vector<uint8_t>{0xD8, 0x3D},
                             std::vector<uint8_t>{0, 0x0A}}) {
        assert(!Append(state, queue, RenameMiiChange(1, IdOf(fixture.bob), name)));
        assert(!Append(state, queue, LicenseRenameChange(SaveProfile::Original, 0,
                                                         IdOf(fixture.bob), name)));
    }
    assert(queue.size() == 2);
    // A missing profile is skipped; the others still take the name.
    auto partial = fixture.files;
    partial.saves[1].reset();
    const auto replayed = Replay(partial, std::vector{queue[0]});
    assert(replayed && !replayed.state.files.saves[1] &&
           LicenseName(*replayed.state.files.saves[2], 3) == "Ann");
    std::puts("Mii pending changes: renames reach licenses in every profile, keeping progress");
}

void TestLicenseDeletionAndRemoval() {
    Fixture fixture;
    auto state = Start(fixture.files);
    std::vector<PendingChange> queue;
    // A Mii stays while any license races as it.
    const auto removal = RemoveMiiChange(1, IdOf(fixture.bob));
    assert(!CanAppend(state, queue.size(), removal));
    assert(!Append(state, queue, removal));
    // Deleting needs the license's current identity.
    assert(!Append(state, queue, LicenseDeleteChange(SaveProfile::RetroRewind, 1, IdOf(fixture.cat))));
    const std::array<std::pair<SaveProfile, std::size_t>, 4> licenses{{
        {SaveProfile::Original, 0}, {SaveProfile::RetroRewind, 1},
        {SaveProfile::RetroRewindSeparate, 0}, {SaveProfile::RetroRewindSeparate, 3}}};
    for (const auto& [profile, slot] : licenses) {
        assert(Append(state, queue, LicenseDeleteChange(profile, slot, IdOf(fixture.bob))));
    }
    assert(queue[0].description == "Mario Kart Wii · License 1 (“Player”) will be deleted.");
    // Deleted licenses are gone from the saves, other licenses keep every byte, and the
    // listing still shows them, marked.
    assert(ListLicenses(*state.files.saves[2]).empty() && ListLicenses(*state.files.saves[1]).empty());
    assert(std::equal(fixture.files.saves[0]->begin() + LicenseAt(1),
                      fixture.files.saves[0]->begin() + LicenseAt(2),
                      state.files.saves[0]->begin() + LicenseAt(1)));
    assert(std::all_of(state.files.saves[0]->begin() + LicenseAt(0),
                       state.files.saves[0]->begin() + LicenseAt(1),
                       [](uint8_t byte) { return byte == 0; }));
    auto upcoming = ListUpcomingLicenses(state);
    assert(upcoming.size() == 5);
    for (const auto& license : upcoming) {
        const bool deleted = license.createId == IdOf(fixture.bob);
        assert(license.pendingOperation ==
               (deleted ? std::optional(LicenseOperation::Delete) : std::nullopt));
        assert(license.miiSlot == std::optional<std::size_t>(deleted ? 1 : 0));
    }
    // The freed Mii can now be removed in the same queue; deleting again fails.
    assert(Append(state, queue, removal));
    assert(!Append(state, queue, LicenseDeleteChange(SaveProfile::Original, 0, IdOf(fixture.bob))));
    for (const auto& license : ListUpcomingLicenses(state)) {
        if (license.createId == IdOf(fixture.bob)) assert(!license.miiSlot);
    }
    assert(Replay(fixture.files, queue).state.files == state.files);
    // The last Mii always stays.
    GameFiles single;
    single.database = CreateSeedDatabase(kMac);
    auto alone = Start(single);
    std::vector<PendingChange> none;
    assert(!Append(alone, none, RemoveMiiChange(0, MiiCreateId(*single.database, 0))));
    std::puts("Mii pending changes: license deletion, listing and freed Mii removal passed");
}

void TestSetLicenseMii() {
    Fixture fixture;
    // An imported save whose license has no Mii in this database.
    const CreateIdBytes orphan{1, 2, 3, 4, 5, 6, 7, 8};
    fixture.files.saves[1] = MakeSave({{1, IdOf(fixture.bob)}, {2, orphan}}, 0x35);
    auto state = Start(fixture.files);
    const auto listed = ListUpcomingLicenses(state);
    const auto missing = std::find_if(listed.begin(), listed.end(),
                                      [&](const auto& license) { return license.createId == orphan; });
    assert(missing != listed.end() && !missing->miiSlot);
    std::vector<PendingChange> queue;
    // The chosen Mii must still be there with that identity.
    assert(!Append(state, queue, LicenseMiiChange(SaveProfile::RetroRewind, 2, orphan, 2, IdOf(fixture.bob))));
    assert(!Append(state, queue, LicenseMiiChange(SaveProfile::RetroRewind, 2, IdOf(fixture.cat), 2, IdOf(fixture.cat))));
    assert(Append(state, queue, LicenseMiiChange(SaveProfile::RetroRewind, 2, orphan, 2, IdOf(fixture.cat))));
    assert(queue.back().description == "Retro Rewind · License 3 will race as “" "Cat”.");
    const auto& before = *fixture.files.saves[1];
    const auto& after = *state.files.saves[1];
    const auto license = LicenseAt(2);
    for (std::size_t index = 0; index < before.size(); ++index) {
        const bool identity = index >= license + kRksysMiiNameOffset &&
                              index < license + kRksysCreateIdOffset + kCreateIdByteSize;
        const bool crc = index >= kRksysCoreCrcOffset && index < kRksysCoreCrcOffset + 4;
        if (!identity && !crc) assert(before[index] == after[index]);
    }
    assert(LicenseName(after, 2) == "Cat");
    const auto relinked = ListUpcomingLicenses(state);
    const auto repaired = std::find_if(relinked.begin(), relinked.end(), [&](const auto& entry) {
        return entry.profile == SaveProfile::RetroRewind && entry.slot == 2;
    });
    assert(repaired->miiSlot == std::optional<std::size_t>(2) &&
           repaired->pendingOperation == LicenseOperation::SetMii && repaired->createId == IdOf(fixture.cat));
    std::puts("Mii pending changes: a license moves to another Mii, keeping its progress");
}

std::vector<PendingChange> EveryKind(const Fixture& fixture) {
    auto state = Start(fixture.files);
    std::vector<PendingChange> queue;
    auto edit = Appearance::Decode(fixture.bob);
    edit.Set(11, 20);
    WriteMiiName(edit.bytes, 0x02, "B\xC3\xB6" "b");  // Not ASCII: only the low byte is written.
    WriteBigEndian16(edit.bytes, 0x04, 0x00F6);
    assert(Append(state, queue, EditMiiChange(1, fixture.bob, edit.bytes)));
    assert(Append(state, queue, NewMiiChange(MakeMii("Eve", 0x80000005u))));
    assert(Append(state, queue, ImportMiiChange(MakeMii("Dan", 0x80000004u))));
    assert(Append(state, queue, RenameMiiChange(2, IdOf(fixture.cat), Utf16("Kit"))));
    assert(Append(state, queue, LicenseRenameChange(SaveProfile::Original, 1,
                                                    MiiCreateId(*fixture.files.database, 0), Utf16("Racer"))));
    assert(Append(state, queue, LicenseMiiChange(SaveProfile::RetroRewind, 1, IdOf(fixture.bob), 2, IdOf(fixture.cat))));
    assert(Append(state, queue, LicenseDeleteChange(SaveProfile::RetroRewindSeparate, 3, IdOf(fixture.bob))));
    assert(Append(state, queue, RemoveMiiChange(4, IdOf(MakeMii("Dan", 0x80000004u)))));
    return queue;
}

void TestSerialization() {
    Fixture fixture;
    const auto queue = EveryKind(fixture);
    assert(queue.size() == 8 && queue[0].description.find("ö") != std::string::npos);
    const auto bytes = SerializeQueue(queue);
    const auto parsed = ParseQueue(bytes);
    assert(parsed && *parsed == queue && SerializeQueue(*parsed) == bytes);
    assert(Replay(fixture.files, *parsed));
    const auto empty = SerializeQueue({});
    assert(empty.size() == 12 && ParseQueue(empty) && ParseQueue(empty)->empty());

    // Every truncation and every flipped byte is rejected.
    for (std::size_t length = 0; length < bytes.size(); ++length) {
        assert(!ParseQueue(std::span(bytes).first(length)));
    }
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        for (const uint8_t flip : {0x01, 0x80, 0xFF}) {
            auto damaged = bytes;
            damaged[index] ^= flip;
            assert(!ParseQueue(damaged));
        }
    }
    auto longer = bytes;
    longer.push_back(0);
    assert(!ParseQueue(longer));

    // With a correct checksum, malformed fields are still rejected.
    const auto resealed = [](std::vector<uint8_t> body) {
        body.resize(body.size() - 4);
        const auto crc = Crc32(body);
        for (int shift = 24; shift >= 0; shift -= 8) body.push_back(static_cast<uint8_t>(crc >> shift));
        return body;
    };
    const auto single = [&](const PendingChange& change) { return SerializeQueue(std::vector{change}); };
    const auto rename = RenameMiiChange(2, IdOf(fixture.cat), Utf16("Kit"));
    // Offsets in a one-change queue: header 8, kind 8, length 9-10, body from 11.
    const std::vector<std::pair<std::vector<uint8_t>, std::pair<std::size_t, uint8_t>>> cases{
        {single(rename), {5, 2}},                    // Version.
        {single(rename), {7, 2}},                    // Count beyond the changes.
        {single(rename), {8, 9}},                    // Kind.
        {single(rename), {8, 0}},
        {single(rename), {10, 0xFF}},                // Body longer than the queue.
        {single(rename), {11, 100}},                 // Mii slot.
        {single(rename), {20, 7}},                   // Odd name length.
        {single(rename), {20, 22}},                  // Name too long.
        {single(rename), {20, 0}},                   // Empty name.
        {single(ImportMiiChange(fixture.bob)), {10, 10}},  // Body shorter than its fields.
        {single(NewMiiChange(fixture.bob)), {11, 2}},    // Replace flag.
        {single(NewMiiChange(fixture.bob)), {12, 1}},    // A new Mii has no slot.
        {single(LicenseDeleteChange(SaveProfile::Original, 0, IdOf(fixture.bob))), {11, 4}},  // Operation.
        {single(LicenseDeleteChange(SaveProfile::Original, 0, IdOf(fixture.bob))), {12, 3}},  // Profile.
        {single(LicenseDeleteChange(SaveProfile::Original, 0, IdOf(fixture.bob))), {13, 4}},  // License slot.
        {single(LicenseMiiChange(SaveProfile::Original, 0, IdOf(fixture.bob), 1, IdOf(fixture.bob))), {22, 100}},
    };
    for (const auto& [base, edit] : cases) {
        auto malformed = base;
        malformed[edit.first] = edit.second;
        assert(!ParseQueue(resealed(malformed)));
    }
    // A description must be UTF-8 within its limit.
    auto described = rename;
    described.description = "ok";
    auto text = single(described);
    text[text.size() - 6] = 0xC3;  // Lead byte without its continuation.
    assert(!ParseQueue(resealed(text)));
    // Random bytes, sealed or not, never parse into anything that applies.
    uint32_t seed = 7;
    for (int round = 0; round < 2000; ++round) {
        std::vector<uint8_t> noise(12 + round % 300);
        for (auto& byte : noise) byte = static_cast<uint8_t>((seed = seed * 1664525u + 1013904223u) >> 24);
        std::copy(kPendingQueueMagic.begin(), kPendingQueueMagic.end(), noise.begin());
        const auto parsed = ParseQueue(resealed(noise));
        if (parsed) (void)Replay(fixture.files, *parsed);
        assert(!ParseQueue(noise) || noise.size() < 12);
    }
    std::puts("Mii pending changes: serialization round trip, truncation and corruption sweep passed");
}

void TestCapacity() {
    // A full database takes no new Mii.
    GameFiles full;
    full.database = CreateSeedDatabase(kMac);
    for (uint32_t index = 1; index < kMaximumMiiSlots; ++index) {
        assert(ImportMii(*full.database, MakeMii("Full", 0x80000100u + index)));
    }
    auto state = Start(full);
    std::vector<PendingChange> queue;
    assert(ListMiis(*state.files.database).size() == kMaximumMiiSlots);
    const auto extra = MakeMii("Extra", 0x80000002u);
    assert(!Append(state, queue, ImportMiiChange(extra)));
    assert(!Append(state, queue, NewMiiChange(extra)));
    // Removing one frees a slot for a later change in the same queue.
    assert(Append(state, queue, RemoveMiiChange(5, MiiCreateId(*full.database, 5))));
    assert(Append(state, queue, ImportMiiChange(extra)));
    assert(!Append(state, queue, ImportMiiChange(extra)));  // Already there.
    assert(MiiName(*state.files.database, 5) == "Extra");

    // The queue holds a bounded number of changes.
    GameFiles files;
    files.database = CreateSeedDatabase(kMac);
    auto renaming = Start(files);
    std::vector<PendingChange> renames;
    const auto id = MiiCreateId(*files.database, 0);
    for (std::size_t index = 0; index < kMaximumPendingChanges; ++index) {
        assert(Append(renaming, renames, RenameMiiChange(0, id, Utf16(index % 2 ? "Odd" : "Even"))));
    }
    const auto overflow = RenameMiiChange(0, id, Utf16("More"));
    assert(!CanAppend(renaming, renames.size(), overflow) && !Append(renaming, renames, overflow));
    const auto bytes = SerializeQueue(renames);
    assert(bytes.size() <= kMaximumQueueBytes);
    const auto parsed = ParseQueue(bytes);
    assert(parsed && parsed->size() == kMaximumPendingChanges);
    assert(MiiName(*Replay(files, *parsed).state.files.database, 0) == "Odd");
    std::puts("Mii pending changes: database and queue capacity passed");
}

void TestNameHelpers() {
    // Names decode and re-encode, including characters beyond the BMP.
    const std::vector<uint8_t> emoji{0xD8, 0x3D, 0xDE, 0x00, 0, 'A'};
    assert(NameText(emoji) == "\U0001F600" "A");
    assert(Utf16BigEndian(NameText(emoji)) == emoji);
    assert(IsValidUtf8(std::span(reinterpret_cast<const uint8_t*>("·“"), 5)));
    for (const std::vector<uint8_t>& invalid : {std::vector<uint8_t>{0xC0, 0x80}, {0xED, 0xA0, 0x80},
                                               {0xF4, 0x90, 0x80, 0x80}, {0x80}, {0xE2, 0x80}}) {
        assert(!IsValidUtf8(invalid));
    }
    std::puts("Mii pending changes: name and UTF-8 helpers passed");
}

} // namespace

int main() {
    TestOrderingAndDescriptions();
    TestStaleRejectsWholeQueue();
    TestRenamePropagation();
    TestLicenseDeletionAndRemoval();
    TestSetLicenseMii();
    TestSerialization();
    TestCapacity();
    TestNameHelpers();
    return 0;
}
