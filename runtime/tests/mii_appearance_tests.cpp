#include "kartpad/mii/appearance.h"
#include <cassert>
#include <iostream>
int main() {
    using namespace kartpad::mii;
    auto db = CreateSeedDatabase({2, 1, 2, 3, 4, 5});
    auto a = Appearance::Decode(std::span(db).subspan(kMiiBlockOffset, 74));
    assert(a.Validate());
    // Independent byte fixture in the documented big-endian Wii layout.
    const std::string hex =
        "0420004b0061007200740050006100640000000000003f3f800000010503040500004240318028a2088c084014"
        "48b88d008a008a2504004b006100720074005000610064000000000000";
    std::array<uint8_t, 74> golden{};
    for (size_t i = 0; i < 74; i++)
        golden[i] = uint8_t(std::stoul(hex.substr(i * 2, 2), nullptr, 16));
    auto decoded = Appearance::Decode(golden);
    assert(decoded.Validate());
    const std::array<unsigned, 46> expected = {
        0, 1,  1, 0, 0, 63, 63, 0, 0, 0,  0, 33, 1, 0,  2, 4, 12, 0, 4,  2, 6, 6,  1,
        4, 10, 2, 1, 4, 9,  23, 0, 4, 13, 0, 0,  4, 10, 0, 0, 0,  4, 10, 0, 4, 20, 2};
    for (size_t i = 0; i < 46; i++)
        assert(decoded.Get(i) == expected[i]);
    assert(decoded.bytes == golden);
    auto mask = EditableMask();
    for (size_t i = 0; i < AppearanceFields.size(); i++) {
        for (unsigned value : {AppearanceFields[i].minimum, AppearanceFields[i].maximum}) {
            auto b = a;
            b.Set(i, value);
            assert(b.Get(i) == value && b.Validate());
            assert(Appearance::Decode(b.bytes).bytes == b.bytes);
            auto f = AppearanceFields[i];
            for (size_t byte = 0; byte < 74; byte++) {
                uint32_t fieldMask = ((1u << f.bits) - 1) << f.shift;
                uint8_t allowed = byte >= f.offset && byte < f.offset + f.bytes
                                      ? uint8_t(fieldMask >> ((f.offset + f.bytes - 1 - byte) * 8))
                                      : 0;
                assert((a.bytes[byte] & ~allowed) == (b.bytes[byte] & ~allowed));
            }
        }
        bool failed = false;
        try {
            a.Set(i, AppearanceFields[i].maximum + 1);
        } catch (const std::invalid_argument &) {
            failed = true;
        }
        assert(failed);
        if (AppearanceFields[i].minimum) {
            failed = false;
            try {
                a.Set(i, AppearanceFields[i].minimum - 1);
            } catch (...) {
                failed = true;
            }
            assert(failed);
        }
    }
    for (size_t length : {0u, 73u, 75u}) {
        bool failed = false;
        try {
            Appearance::Decode(std::vector<uint8_t>(length));
        } catch (...) {
            failed = true;
        }
        assert(failed);
    }
    auto original = a;
    a.Set(11, 60);
    assert(ReplaceAppearance(db, 0, original.bytes, a.bytes));
    assert(!ReplaceAppearance(db, 0, original.bytes, a.bytes));
    auto changed = a;
    changed.bytes[24] ^= 1;
    assert(!ReplaceAppearance(db, 0, a.bytes, changed.bytes));
    for (size_t byte = 0; byte < 74; byte++)
        if (mask[byte] != 255) {
            changed = a;
            uint8_t bit = uint8_t(~mask[byte]) & uint8_t(-uint8_t(~mask[byte]));
            changed.bytes[byte] ^= bit;
            assert(!ReplaceAppearance(db, 0, a.bytes, changed.bytes));
        }
    auto bad = a;
    bad.bytes[2] = 0xd8;
    bad.bytes[3] = 0;
    assert(!bad.Validate());
    bad = a;
    std::fill_n(bad.bytes.begin() + 2, 20, 0);
    assert(!bad.Validate());
    auto unicode = a;
    for (unsigned n = 0; n < 5; n++) {
        WriteBigEndian16(unicode.bytes, 2 + n * 4, 0xd83d);
        WriteBigEndian16(unicode.bytes, 4 + n * 4, 0xde00);
    }
    assert(unicode.Validate());
    assert(ReadMiiName(unicode.bytes, 2).size() == 20);
    auto tooLong = std::vector<uint8_t>(22, 0x41);
    assert(!ValidateUtf16BigEndianName(tooLong));
    for (unsigned i = 1; i < kMaximumMiiSlots; i++) {
        auto newMii = NewAppearance(db, 1);
        assert(newMii.Validate());
        assert(
            std::equal(newMii.bytes.begin() + 28, newMii.bytes.begin() + 32, a.bytes.begin() + 28));
        assert(ImportMii(db, newMii.bytes));
    }
    assert(ListMiis(db).size() == 100);
    auto full = db;
    assert(!ImportMii(db, NewAppearance(db, 1).bytes));
    assert(db == full);
    std::cout << "46 field boundaries, binary round trips, Unicode, reserved bits, stale records, "
                 "unique IDs and full database passed.\n";
}
