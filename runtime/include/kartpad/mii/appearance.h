#pragma once
#include "mii_database.h"
#include "seed_mii_database.h"
#include <array>
#include <stdexcept>
namespace kartpad::mii {
struct AppearanceField {
    const char *name;
    unsigned offset, bytes, shift, bits, minimum, maximum, category;
};
inline constexpr std::array<const char *, 8> AppearanceCategories = {
    "Identity & Body", "Face", "Hair", "Eyes", "Eyebrows", "Nose", "Mouth", "Accessories"};
inline constexpr std::array<AppearanceField, 46> AppearanceFields = {{
    {"Gender", 0, 2, 14, 1, 0, 1, 0},
    {"Birthday month", 0, 2, 10, 4, 0, 12, 0},
    {"Birthday day", 0, 2, 5, 5, 0, 31, 0},
    {"Favorite color", 0, 2, 1, 4, 0, 11, 0},
    {"Favorite", 0, 2, 0, 1, 0, 1, 0},
    {"Height", 22, 1, 0, 8, 0, 127, 0},
    {"Weight", 23, 1, 0, 8, 0, 127, 0},
    {"Face shape", 32, 2, 13, 3, 0, 7, 1},
    {"Skin color", 32, 2, 10, 3, 0, 5, 1},
    {"Facial feature", 32, 2, 6, 4, 0, 11, 1},
    {"Mingle off", 32, 2, 2, 1, 0, 1, 0},
    {"Hair type", 34, 2, 9, 7, 0, 71, 2},
    {"Hair color", 34, 2, 6, 3, 0, 7, 2},
    {"Hair reversed", 34, 2, 5, 1, 0, 1, 2},
    {"Eye type", 40, 4, 26, 6, 0, 47, 3},
    {"Eye rotation", 40, 4, 21, 3, 0, 7, 3},
    {"Eye position", 40, 4, 16, 5, 0, 18, 3},
    {"Eye color", 40, 4, 13, 3, 0, 5, 3},
    {"Eye size", 40, 4, 9, 3, 0, 7, 3},
    {"Eye spacing", 40, 4, 5, 4, 0, 12, 3},
    {"Eyebrow type", 36, 4, 27, 5, 0, 23, 4},
    {"Eyebrow rotation", 36, 4, 22, 4, 0, 11, 4},
    {"Eyebrow color", 36, 4, 13, 3, 0, 7, 4},
    {"Eyebrow size", 36, 4, 9, 4, 0, 8, 4},
    {"Eyebrow position", 36, 4, 4, 5, 3, 18, 4},
    {"Eyebrow spacing", 36, 4, 0, 4, 0, 12, 4},
    {"Nose type", 44, 2, 12, 4, 0, 11, 5},
    {"Nose size", 44, 2, 8, 4, 0, 8, 5},
    {"Nose position", 44, 2, 3, 5, 0, 18, 5},
    {"Mouth type", 46, 2, 11, 5, 0, 23, 6},
    {"Mouth color", 46, 2, 9, 2, 0, 2, 6},
    {"Mouth size", 46, 2, 5, 4, 0, 8, 6},
    {"Mouth position", 46, 2, 0, 5, 0, 18, 6},
    {"Glasses type", 48, 2, 12, 4, 0, 8, 7},
    {"Glasses color", 48, 2, 9, 3, 0, 5, 7},
    {"Glasses size", 48, 2, 5, 3, 0, 7, 7},
    {"Glasses position", 48, 2, 0, 5, 0, 20, 7},
    {"Mustache type", 50, 2, 14, 2, 0, 3, 7},
    {"Beard type", 50, 2, 12, 2, 0, 3, 7},
    {"Facial hair color", 50, 2, 9, 3, 0, 7, 7},
    {"Mustache size", 50, 2, 5, 4, 0, 8, 7},
    {"Mustache position", 50, 2, 0, 5, 0, 16, 7},
    {"Mole", 52, 2, 15, 1, 0, 1, 7},
    {"Mole size", 52, 2, 11, 4, 0, 8, 7},
    {"Mole position", 52, 2, 6, 5, 0, 30, 7},
    {"Mole horizontal", 52, 2, 1, 5, 0, 16, 7},
}};
struct Appearance {
    std::array<uint8_t, kMiiBlockSize> bytes{};
    static Appearance Decode(std::span<const uint8_t> raw) {
        if (raw.size() != kMiiBlockSize)
            throw std::invalid_argument("A Mii must contain exactly 74 bytes.");
        Appearance a;
        std::copy(raw.begin(), raw.end(), a.bytes.begin());
        return a;
    }
    unsigned Get(size_t i) const {
        const auto &f = AppearanceFields.at(i);
        uint32_t v = 0;
        for (unsigned n = 0; n < f.bytes; n++)
            v = (v << 8) | bytes[f.offset + n];
        return (v >> f.shift) & ((1u << f.bits) - 1);
    }
    void Set(size_t i, unsigned value) {
        const auto &f = AppearanceFields.at(i);
        if (value < f.minimum || value > f.maximum)
            throw std::invalid_argument(f.name);
        uint32_t v = 0;
        for (unsigned n = 0; n < f.bytes; n++)
            v = (v << 8) | bytes[f.offset + n];
        const uint32_t mask = ((1u << f.bits) - 1) << f.shift;
        v = (v & ~mask) | (value << f.shift);
        for (unsigned n = 0; n < f.bytes; n++)
            bytes[f.offset + f.bytes - 1 - n] = uint8_t(v >> (n * 8));
    }
    DatabaseResult Validate() const {
        if (auto result = ValidateMii(bytes); !result)
            return result;
        for (size_t i = 0; i < AppearanceFields.size(); i++) {
            auto v = Get(i);
            auto f = AppearanceFields[i];
            if (v < f.minimum || v > f.maximum)
                return {false, std::string("Invalid ") + f.name};
        }
        for (unsigned o : {2u, 54u}) {
            auto end = o + 20;
            unsigned length = 0;
            while (o + length < end && ReadBigEndian16(bytes, o + length))
                length += 2;
            if (length) {
                if (auto result = ValidateUtf16BigEndianName(std::span(bytes).subspan(o, length));
                    !result)
                    return result;
            }
        }
        return {true, {}};
    }
};
inline std::array<uint8_t, kMiiBlockSize> EditableMask() {
    std::array<uint8_t, kMiiBlockSize> mask{};
    for (unsigned o : {2u, 54u})
        std::fill_n(mask.begin() + o, 20, 255);
    for (auto f : AppearanceFields) {
        uint32_t bits = ((1u << f.bits) - 1) << f.shift;
        for (unsigned n = 0; n < f.bytes; n++)
            mask[f.offset + f.bytes - 1 - n] |= uint8_t(bits >> (n * 8));
    }
    return mask;
}
inline DatabaseResult ReplaceAppearance(std::span<uint8_t> database, size_t slot,
                                        std::span<const uint8_t> expected,
                                        std::span<const uint8_t> replacement) {
    if (auto v = ValidateDatabase(database); !v)
        return v;
    if (slot >= kMaximumMiiSlots || expected.size() != kMiiBlockSize ||
        replacement.size() != kMiiBlockSize)
        return {false, "Invalid Mii selection."};
    auto old = database.subspan(kMiiBlockOffset + slot * kMiiBlockSize, kMiiBlockSize);
    if (!std::equal(old.begin(), old.end(), expected.begin()))
        return {false, "This Mii changed. Reopen the editor."};
    if (!std::equal(old.begin() + 24, old.begin() + 32, replacement.begin() + 24))
        return {false, "Editing must preserve the Mii identity."};
    auto mask = EditableMask();
    for (size_t i = 0; i < kMiiBlockSize; i++)
        if ((old[i] & ~mask[i]) != (replacement[i] & ~mask[i]))
            return {false, "Editing must preserve reserved Mii data."};
    if (auto v = Appearance::Decode(replacement).Validate(); !v)
        return v;
    std::copy(replacement.begin(), replacement.end(), old.begin());
    UpdateDatabaseCrc(database);
    return {true, {}};
}
inline Appearance NewAppearance(std::span<const uint8_t> database, uint32_t timestamp) {
    if (!ValidateDatabase(database))
        throw std::invalid_argument("Invalid Mii database.");
    Appearance a;
    a.bytes = CreateDefaultMii({0, 0, 0, 0, 0, 0});
    auto records = ListMiis(database);
    if (!records.empty()) {
        auto base = kMiiBlockOffset + records[0].slot * kMiiBlockSize;
        std::copy_n(database.begin() + base + 28, 4, a.bytes.begin() + 28);
    }
    uint32_t id = 0x80000000u | (timestamp & 0x1fffffffu);
    if (id == 0x80000000u)
        id++;
    for (size_t tries = 0; tries <= kMaximumMiiSlots;
         tries++, id = 0x80000000u | ((id + 1) & 0x1fffffffu)) {
        bool used = false;
        for (auto r : records)
            if (ReadBigEndian32(database, kMiiBlockOffset + r.slot * kMiiBlockSize + 24) == id)
                used = true;
        if (!used) {
            WriteBigEndian32(a.bytes, 24, id);
            return a;
        }
    }
    throw std::invalid_argument("Could not allocate a unique Mii identity.");
}
} // namespace kartpad::mii
