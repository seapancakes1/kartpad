#pragma once

#include "kartpad/mii/appearance.h"
#include "kartpad/mii/mii_database.h"
#include "kartpad/mii/player_identity.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace kartpad::mii {

// Mii and license changes wait in a queue until the next launch, because the running game holds
// the database and saves. Each change carries what it expects to find. Append checks a change
// against the queue replayed before it; at launch Replay applies the queue in order over the
// latest database and saves, so race progress saved meanwhile is kept, and one change that no
// longer fits rejects the whole queue.

enum class SaveProfile : uint8_t { Original, RetroRewind, RetroRewindSeparate };
inline constexpr std::size_t kSaveProfileCount = 3;
// Android's profile names (KartPadSaveStorage) and the Miis screen's titles.
inline constexpr std::array<std::string_view, kSaveProfileCount> kSaveProfileIdentifiers{
    "original", "retro_rewind", "retro_rewind_separate"};
inline constexpr std::array<std::string_view, kSaveProfileCount> kSaveProfileTitles{
    "Mario Kart Wii", "Retro Rewind", "Retro Rewind (Separate Save)"};

using CreateIdBytes = std::array<uint8_t, kCreateIdByteSize>;
using MiiBlockBytes = std::array<uint8_t, kMiiBlockSize>;

enum class ChangeKind : uint8_t {
    SaveMii = 1,    // An editor draft: a new Mii, or one replacing `expected` in `slot`.
    ImportMii = 2,  // A .mii file, added as a new Mii.
    RemoveMii = 3,
    RenameMii = 4,  // Its licenses take the name too, keeping progress and friend codes.
    License = 5,
};
enum class LicenseOperation : uint8_t { Rename = 1, Delete = 2, SetMii = 3 };

struct PendingChange {
    ChangeKind kind = ChangeKind::ImportMii;
    std::size_t slot = 0;        // The Mii's slot, or the license's for License.
    bool replace = false;        // SaveMii: replaces `expected` in `slot`.
    MiiBlockBytes mii{};         // SaveMii, ImportMii.
    MiiBlockBytes expected{};    // SaveMii replacing a Mii.
    CreateIdBytes createId{};    // RemoveMii, RenameMii: the Mii's. License: the license's.
    std::vector<uint8_t> name;   // RenameMii, license Rename: UTF-16BE, no terminator.
    SaveProfile profile = SaveProfile::Original;
    LicenseOperation operation = LicenseOperation::Rename;
    std::size_t miiSlot = 0;     // License SetMii: the Mii to race as.
    CreateIdBytes miiCreateId{};
    std::string description;     // UTF-8 banner text, set by Append.

    bool operator==(const PendingChange&) const = default;
};

inline constexpr std::size_t kMaximumPendingChanges = 512;
inline constexpr std::size_t kMaximumChangeDescription = 512;
// Header, then each change's kind, length and largest body, then the checksum.
inline constexpr std::size_t kMaximumQueueBytes =
    8 + kMaximumPendingChanges * (3 + 2 + 2 * kMiiBlockSize + 2 + kMaximumChangeDescription) + 4;

inline PendingChange NewMiiChange(const MiiBlockBytes& mii) {
    PendingChange change;
    change.kind = ChangeKind::SaveMii;
    change.mii = mii;
    return change;
}

inline PendingChange EditMiiChange(std::size_t slot, const MiiBlockBytes& expected,
                                   const MiiBlockBytes& mii) {
    PendingChange change = NewMiiChange(mii);
    change.replace = true;
    change.slot = slot;
    change.expected = expected;
    return change;
}

inline PendingChange ImportMiiChange(const MiiBlockBytes& mii) {
    PendingChange change;
    change.kind = ChangeKind::ImportMii;
    change.mii = mii;
    return change;
}

inline PendingChange RemoveMiiChange(std::size_t slot, const CreateIdBytes& createId) {
    PendingChange change;
    change.kind = ChangeKind::RemoveMii;
    change.slot = slot;
    change.createId = createId;
    return change;
}

inline PendingChange RenameMiiChange(std::size_t slot, const CreateIdBytes& createId,
                                     std::span<const uint8_t> utf16BigEndianName) {
    PendingChange change = RemoveMiiChange(slot, createId);
    change.kind = ChangeKind::RenameMii;
    change.name.assign(utf16BigEndianName.begin(), utf16BigEndianName.end());
    return change;
}

inline PendingChange LicenseChange(SaveProfile profile, std::size_t slot,
                                   const CreateIdBytes& createId, LicenseOperation operation) {
    PendingChange change;
    change.kind = ChangeKind::License;
    change.profile = profile;
    change.slot = slot;
    change.createId = createId;
    change.operation = operation;
    return change;
}

inline PendingChange LicenseRenameChange(SaveProfile profile, std::size_t slot,
                                         const CreateIdBytes& createId,
                                         std::span<const uint8_t> utf16BigEndianName) {
    PendingChange change = LicenseChange(profile, slot, createId, LicenseOperation::Rename);
    change.name.assign(utf16BigEndianName.begin(), utf16BigEndianName.end());
    return change;
}

inline PendingChange LicenseDeleteChange(SaveProfile profile, std::size_t slot,
                                         const CreateIdBytes& createId) {
    return LicenseChange(profile, slot, createId, LicenseOperation::Delete);
}

inline PendingChange LicenseMiiChange(SaveProfile profile, std::size_t slot,
                                      const CreateIdBytes& createId, std::size_t miiSlot,
                                      const CreateIdBytes& miiCreateId) {
    PendingChange change = LicenseChange(profile, slot, createId, LicenseOperation::SetMii);
    change.miiSlot = miiSlot;
    change.miiCreateId = miiCreateId;
    return change;
}

// The database and every save; nullopt is a file that does not exist.
struct GameFiles {
    std::optional<std::vector<uint8_t>> database;
    std::array<std::optional<std::vector<uint8_t>>, kSaveProfileCount> saves;

    bool operator==(const GameFiles&) const = default;
};

// What the queue does to one license, for listing it before the launch applies it.
struct LicenseNote {
    std::optional<LicenseOperation> operation;  // The latest change that touches it.
    std::optional<LicenseRecord> deleted;        // As it was before a queued deletion.
};

// The files as the queue leaves them, and the licenses it touches.
struct ReplayState {
    GameFiles files;
    std::array<std::array<LicenseNote, kRksysLicenseCount>, kSaveProfileCount> notes{};
};

struct ReplayResult {
    bool ok = false;
    std::string message;
    std::size_t failedChange = 0;  // The change that no longer fits.
    ReplayState state;

    explicit operator bool() const { return ok; }
};

inline DatabaseResult CheckPendingDatabase(const GameFiles& files) {
    if (!files.database) {
        return {false, "No Mii database exists yet. Start Mario Kart Wii once, then try again."};
    }
    return ValidateDatabase(*files.database);
}

// The Mii in the slot must still have the expected identity.
inline DatabaseResult CheckMiiIdentity(std::span<const uint8_t> database, std::size_t slot,
                                       const CreateIdBytes& expected) {
    for (const auto& record : ListMiis(database)) {
        if (record.slot == slot && MiiCreateId(database, slot) == expected) {
            return {true, {}};
        }
    }
    return {false, "The selected Mii changed. Reopen Miis and choose it again."};
}

// UTF-8 (as ReadMiiName gives it) as UTF-16BE. Longer names fail name validation later.
inline std::vector<uint8_t> Utf16BigEndian(std::string_view utf8) {
    std::vector<uint8_t> result;
    for (std::size_t index = 0; index < utf8.size();) {
        const uint8_t first = static_cast<uint8_t>(utf8[index]);
        const std::size_t length = first < 0x80u ? 1 : first < 0xE0u ? 2 : first < 0xF0u ? 3 : 4;
        if (index + length > utf8.size()) break;
        uint32_t codePoint = length == 1 ? first
            : length == 2 ? first & 0x1Fu : length == 3 ? first & 0x0Fu : first & 0x07u;
        for (std::size_t next = 1; next < length; ++next) {
            codePoint = (codePoint << 6) | (static_cast<uint8_t>(utf8[index + next]) & 0x3Fu);
        }
        index += length;
        const auto push = [&](uint32_t unit) {
            result.push_back(static_cast<uint8_t>(unit >> 8));
            result.push_back(static_cast<uint8_t>(unit));
        };
        if (codePoint >= 0x10000u) {
            codePoint -= 0x10000u;
            push(0xD800u + (codePoint >> 10));
            push(0xDC00u + (codePoint & 0x3FFu));
        } else {
            push(codePoint);
        }
    }
    return result;
}

// A stored name as licenses take it: decoded, so padding and unreadable units are left out.
inline std::vector<uint8_t> StoredName(std::span<const uint8_t> bytes, std::size_t offset) {
    return Utf16BigEndian(ReadMiiName(bytes, offset));
}

// A queued name (UTF-16BE, up to 10 units) as UTF-8.
inline std::string NameText(std::span<const uint8_t> utf16BigEndianName) {
    std::array<uint8_t, kMiiNameByteSize> padded{};
    std::copy_n(utf16BigEndianName.begin(),
                std::min(utf16BigEndianName.size(), padded.size()), padded.begin());
    return ReadMiiName(padded, 0);
}

inline std::size_t MiiNameOffset(std::size_t slot) {
    return kMiiBlockOffset + slot * kMiiBlockSize + 0x02;
}

// Renames every license that races as the Mii, in each save that exists.
inline DatabaseResult RenameLinkedLicenses(GameFiles& files, const CreateIdBytes& createId,
                                           std::span<const uint8_t> utf16BigEndianName) {
    for (auto& save : files.saves) {
        if (!save) continue;
        std::size_t renamed = 0;
        if (const auto result = RenameMatchingLicenses(*save, createId, utf16BigEndianName,
                                                       renamed); !result) {
            return result;
        }
    }
    return {true, {}};
}

inline std::size_t LinkedLicenseCount(const GameFiles& files, const CreateIdBytes& createId) {
    std::size_t count = 0;
    for (const auto& save : files.saves) {
        if (!save) continue;
        for (const auto& license : ListLicenses(*save)) {
            if (license.createId == createId) ++count;
        }
    }
    return count;
}

// A saved draft (with the Mii it replaces) or a new Mii. A changed name renames its licenses.
inline DatabaseResult ApplyMiiRecord(GameFiles& files, const PendingChange& change) {
    // An edit may keep the out-of-range fields the Mii already had (see ReplaceAppearance).
    const auto previous = Appearance::Decode(change.expected);
    if (const auto validation = Appearance::Decode(change.mii).Validate(
            change.replace ? &previous : nullptr); !validation) {
        return validation;
    }
    if (const auto result = CheckPendingDatabase(files); !result) return result;
    auto& database = *files.database;
    const auto result = change.replace
        ? ReplaceAppearance(database, change.slot, change.expected, change.mii)
        : ImportMii(database, change.mii);
    if (!result || !change.replace ||
        std::equal(change.expected.begin() + 2, change.expected.begin() + 2 + kMiiNameByteSize,
                   change.mii.begin() + 2)) {
        return result;
    }
    CreateIdBytes identity{};
    std::copy_n(change.mii.begin() + 0x18, identity.size(), identity.begin());
    return RenameLinkedLicenses(files, identity, StoredName(change.mii, 0x02));
}

inline DatabaseResult ApplyMiiRemoval(GameFiles& files, const PendingChange& change) {
    if (const auto result = CheckPendingDatabase(files); !result) return result;
    auto& database = *files.database;
    if (const auto result = CheckMiiIdentity(database, change.slot, change.createId); !result) {
        return result;
    }
    if (LinkedLicenseCount(files, change.createId) > 0) {
        return {false, "This Mii is linked to an existing license. Change the license first."};
    }
    return RemoveMii(database, change.slot);
}

inline DatabaseResult ApplyMiiName(GameFiles& files, const PendingChange& change) {
    if (const auto result = ValidateUtf16BigEndianName(change.name); !result) return result;
    if (const auto result = CheckPendingDatabase(files); !result) return result;
    auto& database = *files.database;
    if (const auto result = CheckMiiIdentity(database, change.slot, change.createId); !result) {
        return result;
    }
    if (const auto result = RenameMii(database, change.slot, change.name); !result) return result;
    return RenameLinkedLicenses(files, change.createId, change.name);
}

// Renames, relinks or deletes one license. A renamed license's Mii takes the name too.
inline DatabaseResult ApplyLicenseChange(GameFiles& files, const PendingChange& change) {
    const auto profile = static_cast<std::size_t>(change.profile);
    if (profile >= kSaveProfileCount || change.slot >= kRksysLicenseCount) {
        return {false, "The selected license location is invalid."};
    }
    auto& save = files.saves[profile];
    if (!save) return {false, "The selected license changed. Reopen Miis and try again."};
    switch (change.operation) {
    case LicenseOperation::Rename: {
        if (const auto result = RenameLicense(*save, change.slot, change.createId, change.name);
            !result) {
            return result;
        }
        if (!files.database) return {true, {}};
        auto& database = *files.database;
        if (const auto result = ValidateDatabase(database); !result) return result;
        for (const auto& record : ListMiis(database)) {
            if (MiiCreateId(database, record.slot) == change.createId) {
                return RenameMii(database, record.slot, change.name);
            }
        }
        return {true, {}};
    }
    case LicenseOperation::SetMii: {
        if (const auto result = CheckPendingDatabase(files); !result) return result;
        const auto& database = *files.database;
        if (const auto result = CheckMiiIdentity(database, change.miiSlot, change.miiCreateId);
            !result) {
            return result;
        }
        return SetLicenseMii(*save, change.slot, change.createId, change.miiCreateId,
                             StoredName(database, MiiNameOffset(change.miiSlot)));
    }
    case LicenseOperation::Delete:
        return DeleteLicense(*save, change.slot, change.createId);
    }
    return {false, "A pending Mii change is invalid."};
}

// One change over the files. On failure the files may be part changed; callers discard them.
inline DatabaseResult ApplyChange(GameFiles& files, const PendingChange& change) {
    switch (change.kind) {
    case ChangeKind::SaveMii:
    case ChangeKind::ImportMii:
        return ApplyMiiRecord(files, change);
    case ChangeKind::RemoveMii:
        return ApplyMiiRemoval(files, change);
    case ChangeKind::RenameMii:
        return ApplyMiiName(files, change);
    case ChangeKind::License:
        return ApplyLicenseChange(files, change);
    }
    return {false, "A pending Mii change is invalid."};
}

// Notes the licenses a change renames, relinks or deletes (as the saves are before it), then
// applies it.
inline DatabaseResult Step(ReplayState& state, const PendingChange& change) {
    if (change.kind == ChangeKind::RenameMii || change.kind == ChangeKind::License) {
        for (std::size_t profile = 0; profile < kSaveProfileCount; ++profile) {
            const auto& save = state.files.saves[profile];
            if (!save) continue;
            for (const auto& license : ListLicenses(*save)) {
                auto& note = state.notes[profile][license.slot];
                if (change.kind == ChangeKind::RenameMii) {
                    if (license.createId == change.createId) note.operation = LicenseOperation::Rename;
                } else if (static_cast<std::size_t>(change.profile) == profile &&
                           change.slot == license.slot) {
                    note.operation = change.operation;
                    if (change.operation == LicenseOperation::Delete) note.deleted = license;
                }
            }
        }
    }
    return ApplyChange(state.files, change);
}

// The queue in order over the live files. Any change that no longer fits fails the whole queue.
inline ReplayResult Replay(GameFiles files, std::span<const PendingChange> queue) {
    ReplayResult result;
    result.state.files = std::move(files);
    for (std::size_t index = 0; index < queue.size(); ++index) {
        if (const auto step = Step(result.state, queue[index]); !step) {
            result.message = step.message;
            result.failedChange = index;
            return result;
        }
    }
    result.ok = true;
    return result;
}

inline std::string Quoted(std::string_view text) {
    return "“" + std::string(text) + "”";
}

inline std::string MiiNameAt(const GameFiles& files, std::size_t slot) {
    std::string name;
    if (files.database && slot < kMaximumMiiSlots &&
        MiiNameOffset(slot) + kMiiNameByteSize <= files.database->size()) {
        name = ReadMiiName(*files.database, MiiNameOffset(slot));
    }
    return name.empty() ? "Unnamed Mii" : name;
}

// License titles name their game profile only when more than one has licenses.
inline std::string LicenseTitle(const ReplayState& state, SaveProfile profile, std::size_t slot) {
    std::size_t profiles = 0;
    for (std::size_t index = 0; index < kSaveProfileCount; ++index) {
        bool listed = state.files.saves[index] && !ListLicenses(*state.files.saves[index]).empty();
        for (const auto& note : state.notes[index]) listed = listed || note.deleted.has_value();
        profiles += listed ? 1 : 0;
    }
    const std::string number = "License " + std::to_string(slot + 1);
    const auto title = static_cast<std::size_t>(profile) < kSaveProfileCount
        ? kSaveProfileTitles[static_cast<std::size_t>(profile)] : kSaveProfileTitles[0];
    return profiles > 1 ? std::string(title) + " · " + number : number;
}

// The banner text for a change, from the files as the queue leaves them before it.
inline std::string DescribeChange(const ReplayState& before, const PendingChange& change) {
    switch (change.kind) {
    case ChangeKind::SaveMii: {
        const auto name = ReadMiiName(change.mii, 0x02);
        if (!change.replace) return Quoted(name) + " will be added.";
        const auto previous = ReadMiiName(change.expected, 0x02);
        return previous == name ? Quoted(name) + " will be updated."
                                : Quoted(previous) + " will be updated and renamed " +
                                      Quoted(name) + ".";
    }
    case ChangeKind::ImportMii:
        return Quoted(ReadMiiName(change.mii, 0x02)) + " will be added.";
    case ChangeKind::RemoveMii:
        return Quoted(MiiNameAt(before.files, change.slot)) + " will be removed.";
    case ChangeKind::RenameMii: {
        const auto linked = LinkedLicenseCount(before.files, change.createId);
        auto text = Quoted(MiiNameAt(before.files, change.slot)) + " will be renamed " +
                    Quoted(NameText(change.name)) + ".";
        if (linked == 1) text += " Its license will use the new name.";
        if (linked > 1) text += " Its " + std::to_string(linked) + " licenses will use the new name.";
        return text;
    }
    case ChangeKind::License: {
        const auto title = LicenseTitle(before, change.profile, change.slot);
        if (change.operation == LicenseOperation::Rename) {
            return title + " will be renamed " + Quoted(NameText(change.name)) + ".";
        }
        if (change.operation == LicenseOperation::SetMii) {
            return title + " will race as " + Quoted(MiiNameAt(before.files, change.miiSlot)) + ".";
        }
        std::string name;
        const auto profile = static_cast<std::size_t>(change.profile);
        if (profile < kSaveProfileCount && before.files.saves[profile]) {
            for (const auto& license : ListLicenses(*before.files.saves[profile])) {
                if (license.slot == change.slot) name = license.name;
            }
        }
        return title + " (" + Quoted(name.empty() ? "Unnamed" : name) + ") will be deleted.";
    }
    }
    return "A change is waiting for the next launch.";
}

// Whether the change fits on top of the replayed queue.
inline DatabaseResult CanAppend(const ReplayState& state, std::size_t queued,
                                const PendingChange& change) {
    if (queued >= kMaximumPendingChanges) {
        return {false, "Too many Mii changes are waiting. Apply them before making more."};
    }
    ReplayState next = state;
    return Step(next, change);
}

// Adds a change that fits: the state then includes it and the change carries its description.
inline DatabaseResult Append(ReplayState& state, std::vector<PendingChange>& queue,
                             PendingChange change) {
    if (queue.size() >= kMaximumPendingChanges) {
        return {false, "Too many Mii changes are waiting. Apply them before making more."};
    }
    ReplayState next = state;
    if (const auto result = Step(next, change); !result) return result;
    change.description = DescribeChange(state, change);
    state = std::move(next);
    queue.push_back(std::move(change));
    return {true, {}};
}

// Licenses as they will be after the launch, profile by profile. A license queued for deletion is
// still listed so it can say so.
struct UpcomingLicense {
    SaveProfile profile = SaveProfile::Original;
    std::size_t slot = 0;
    std::string name;
    CreateIdBytes createId{};
    std::optional<LicenseOperation> pendingOperation;
    std::optional<std::size_t> miiSlot;  // The Mii it races as; nullopt when it is missing.
};

inline std::vector<UpcomingLicense> ListUpcomingLicenses(const ReplayState& state) {
    std::vector<UpcomingLicense> result;
    const auto& database = state.files.database;
    const auto miis = database ? ListMiis(*database) : std::vector<MiiRecord>{};
    for (std::size_t profile = 0; profile < kSaveProfileCount; ++profile) {
        const auto& save = state.files.saves[profile];
        if (!save) continue;
        const auto licenses = ListLicenses(*save);
        for (std::size_t slot = 0; slot < kRksysLicenseCount; ++slot) {
            const auto& note = state.notes[profile][slot];
            const auto found = std::find_if(licenses.begin(), licenses.end(),
                                            [&](const auto& license) { return license.slot == slot; });
            std::optional<LicenseRecord> record;
            if (found != licenses.end()) record = *found;
            else if (note.deleted) record = note.deleted;
            if (!record) continue;
            UpcomingLicense entry;
            entry.profile = static_cast<SaveProfile>(profile);
            entry.slot = slot;
            entry.name = record->name;
            entry.createId = record->createId;
            entry.pendingOperation = note.operation;
            for (const auto& mii : miis) {
                if (MiiCreateId(*database, mii.slot) == entry.createId) {
                    entry.miiSlot = mii.slot;
                    break;
                }
            }
            result.push_back(std::move(entry));
        }
    }
    return result;
}

// The first save that exists but can't be read, which would stop license changes.
inline DatabaseResult CheckUpcomingSaves(const ReplayState& state) {
    for (const auto& save : state.files.saves) {
        if (!save) continue;
        if (const auto result = ValidateRksys(*save); !result) return result;
    }
    return {true, {}};
}

// Serialized queue: "KPMQ", version, count, then each change as kind, body length and body,
// then a CRC-32 of everything before it. All integers are big-endian.
inline constexpr std::array<uint8_t, 4> kPendingQueueMagic{'K', 'P', 'M', 'Q'};
inline constexpr uint16_t kPendingQueueVersion = 1;

inline std::vector<uint8_t> SerializeQueue(std::span<const PendingChange> queue) {
    std::vector<uint8_t> out(kPendingQueueMagic.begin(), kPendingQueueMagic.end());
    const auto u8 = [](std::vector<uint8_t>& bytes, std::size_t value) {
        bytes.push_back(static_cast<uint8_t>(value));
    };
    const auto u16 = [](std::vector<uint8_t>& bytes, std::size_t value) {
        bytes.push_back(static_cast<uint8_t>(value >> 8));
        bytes.push_back(static_cast<uint8_t>(value));
    };
    const auto append = [](std::vector<uint8_t>& bytes, std::span<const uint8_t> data) {
        bytes.insert(bytes.end(), data.begin(), data.end());
    };
    u16(out, kPendingQueueVersion);
    u16(out, queue.size());
    for (const auto& change : queue) {
        std::vector<uint8_t> body;
        switch (change.kind) {
        case ChangeKind::SaveMii:
            u8(body, change.replace ? 1 : 0);
            u8(body, change.slot);
            append(body, change.mii);
            if (change.replace) append(body, change.expected);
            break;
        case ChangeKind::ImportMii:
            append(body, change.mii);
            break;
        case ChangeKind::RemoveMii:
        case ChangeKind::RenameMii:
            u8(body, change.slot);
            append(body, change.createId);
            if (change.kind == ChangeKind::RenameMii) {
                u8(body, change.name.size());
                append(body, change.name);
            }
            break;
        case ChangeKind::License:
            u8(body, static_cast<uint8_t>(change.operation));
            u8(body, static_cast<uint8_t>(change.profile));
            u8(body, change.slot);
            append(body, change.createId);
            if (change.operation == LicenseOperation::Rename) {
                u8(body, change.name.size());
                append(body, change.name);
            } else if (change.operation == LicenseOperation::SetMii) {
                u8(body, change.miiSlot);
                append(body, change.miiCreateId);
            }
            break;
        }
        const auto description = std::span(
            reinterpret_cast<const uint8_t*>(change.description.data()),
            std::min(change.description.size(), kMaximumChangeDescription));
        u16(body, description.size());
        append(body, description);
        u8(out, static_cast<uint8_t>(change.kind));
        u16(out, body.size());
        append(out, body);
    }
    const uint32_t crc = Crc32(out);
    for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<uint8_t>(crc >> shift));
    return out;
}

inline bool IsValidUtf8(std::span<const uint8_t> text) {
    for (std::size_t index = 0; index < text.size();) {
        const uint8_t first = text[index];
        std::size_t length = 0;
        uint32_t codePoint = 0;
        if (first < 0x80u) { length = 1; codePoint = first; }
        else if ((first & 0xE0u) == 0xC0u) { length = 2; codePoint = first & 0x1Fu; }
        else if ((first & 0xF0u) == 0xE0u) { length = 3; codePoint = first & 0x0Fu; }
        else if ((first & 0xF8u) == 0xF0u) { length = 4; codePoint = first & 0x07u; }
        else return false;
        if (index + length > text.size()) return false;
        for (std::size_t next = 1; next < length; ++next) {
            if ((text[index + next] & 0xC0u) != 0x80u) return false;
            codePoint = (codePoint << 6) | (text[index + next] & 0x3Fu);
        }
        constexpr std::array<uint32_t, 5> kSmallest{0, 0, 0x80u, 0x800u, 0x10000u};
        if (codePoint < kSmallest[length] || codePoint > 0x10FFFFu ||
            (codePoint >= 0xD800u && codePoint <= 0xDFFFu)) {
            return false;
        }
        index += length;
    }
    return true;
}

// Bounds-checked reading; any read past the end marks the reader failed.
struct QueueReader {
    std::span<const uint8_t> bytes;
    std::size_t offset = 0;
    bool ok = true;

    std::span<const uint8_t> Take(std::size_t count) {
        if (!ok || count > bytes.size() - offset) {
            ok = false;
            return {};
        }
        const auto taken = bytes.subspan(offset, count);
        offset += count;
        return taken;
    }
    uint8_t U8() {
        const auto taken = Take(1);
        return taken.empty() ? 0 : taken[0];
    }
    uint16_t U16() {
        const auto taken = Take(2);
        return taken.empty() ? 0 : ReadBigEndian16(taken, 0);
    }
    template <std::size_t N> std::array<uint8_t, N> Array() {
        std::array<uint8_t, N> result{};
        const auto taken = Take(N);
        if (!taken.empty()) std::copy(taken.begin(), taken.end(), result.begin());
        return result;
    }
    bool AtEnd() const { return ok && offset == bytes.size(); }
};

// The queue, or nullopt when the bytes are not one this version wrote.
inline std::optional<std::vector<PendingChange>> ParseQueue(std::span<const uint8_t> bytes) {
    if (bytes.size() < 12 || bytes.size() > kMaximumQueueBytes ||
        !std::equal(kPendingQueueMagic.begin(), kPendingQueueMagic.end(), bytes.begin()) ||
        ReadBigEndian32(bytes, bytes.size() - 4) != Crc32(bytes.first(bytes.size() - 4))) {
        return std::nullopt;
    }
    QueueReader reader{bytes.first(bytes.size() - 4), 4};
    if (reader.U16() != kPendingQueueVersion) return std::nullopt;
    const std::size_t count = reader.U16();
    if (count > kMaximumPendingChanges) return std::nullopt;
    std::vector<PendingChange> queue;
    queue.reserve(count);
    const auto name = [](QueueReader& body, PendingChange& change) {
        const std::size_t length = body.U8();
        if (length == 0 || length > kMiiNameByteSize || length % 2 != 0) body.ok = false;
        const auto bytes = body.Take(length);
        change.name.assign(bytes.begin(), bytes.end());
    };
    for (std::size_t index = 0; index < count; ++index) {
        PendingChange change;
        const uint8_t kind = reader.U8();
        const std::size_t length = reader.U16();
        QueueReader body{reader.Take(length)};
        if (!reader.ok) return std::nullopt;
        switch (kind) {
        case static_cast<uint8_t>(ChangeKind::SaveMii): {
            const uint8_t replace = body.U8();
            change.slot = body.U8();
            change.mii = body.Array<kMiiBlockSize>();
            if (replace > 1 || change.slot >= kMaximumMiiSlots || (!replace && change.slot != 0)) {
                return std::nullopt;
            }
            change.replace = replace == 1;
            if (change.replace) change.expected = body.Array<kMiiBlockSize>();
            break;
        }
        case static_cast<uint8_t>(ChangeKind::ImportMii):
            change.mii = body.Array<kMiiBlockSize>();
            break;
        case static_cast<uint8_t>(ChangeKind::RemoveMii):
        case static_cast<uint8_t>(ChangeKind::RenameMii):
            change.slot = body.U8();
            change.createId = body.Array<kCreateIdByteSize>();
            if (change.slot >= kMaximumMiiSlots) return std::nullopt;
            if (kind == static_cast<uint8_t>(ChangeKind::RenameMii)) name(body, change);
            break;
        case static_cast<uint8_t>(ChangeKind::License): {
            const uint8_t operation = body.U8();
            const uint8_t profile = body.U8();
            change.slot = body.U8();
            change.createId = body.Array<kCreateIdByteSize>();
            if (operation < 1 || operation > 3 || profile >= kSaveProfileCount ||
                change.slot >= kRksysLicenseCount) {
                return std::nullopt;
            }
            change.operation = static_cast<LicenseOperation>(operation);
            change.profile = static_cast<SaveProfile>(profile);
            if (change.operation == LicenseOperation::Rename) name(body, change);
            if (change.operation == LicenseOperation::SetMii) {
                change.miiSlot = body.U8();
                change.miiCreateId = body.Array<kCreateIdByteSize>();
                if (change.miiSlot >= kMaximumMiiSlots) return std::nullopt;
            }
            break;
        }
        default:
            return std::nullopt;
        }
        change.kind = static_cast<ChangeKind>(kind);
        const auto description = body.Take(body.U16());
        if (!body.AtEnd() || description.size() > kMaximumChangeDescription ||
            !IsValidUtf8(description)) {
            return std::nullopt;
        }
        change.description.assign(description.begin(), description.end());
        queue.push_back(std::move(change));
    }
    if (!reader.AtEnd()) return std::nullopt;
    return queue;
}

} // namespace kartpad::mii
