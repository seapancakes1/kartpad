#include "kartpad/mii/scene.h"
#include <cassert>
#include <fstream>
#include <iostream>
// Writes a field's bits as a database can hold them, past the range Set allows.
static void SetRaw(kartpad::mii::Appearance &a, size_t i, unsigned value) {
    const auto &f = kartpad::mii::AppearanceFields[i];
    uint32_t v = 0;
    for (unsigned n = 0; n < f.bytes; n++)
        v = (v << 8) | a.bytes[f.offset + n];
    const uint32_t mask = ((1u << f.bits) - 1) << f.shift;
    v = (v & ~mask) | ((value << f.shift) & mask);
    for (unsigned n = 0; n < f.bytes; n++)
        a.bytes[f.offset + f.bytes - 1 - n] = uint8_t(v >> (n * 8));
}
int main(int argc, char **argv) {
    using namespace kartpad::mii;
    assert(argc == 2);
    std::ifstream f(argv[1], std::ios::binary);
    assert(f);
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), {});
    Resources r(d);
    unsigned shapes = 0, textures = 0;
    for (unsigned g = 0; g < 18; g++)
        for (unsigned i = 0; i < r.Count(g); i++) {
            if (Resources::IsShape(g)) {
                r.Shape(g, i);
                shapes++;
            } else {
                r.Texture(g, i);
                textures++;
            }
        }
    for(unsigned i=0;i<=AppearanceFields[33].maximum;i++)assert(r.Texture(7,i).wrapS==2&&r.Texture(7,i).wrapT==0);
    auto catalog = r.EncodeCache();
    Resources restored(d);
    restored.DecodeCache(catalog);
    assert(restored.EncodeCache() == catalog);
    for (size_t n : {0ul, 4ul, 32ul, d.size() / 2}) {
        bool fail = false;
        try {
            Resources bad(std::span(d).first(n));
        } catch (...) {
            fail = true;
        }
        assert(fail);
    }
    for (unsigned offset : {4u, 32u + 8, 56u + 4, 56u + 8}) {
        auto corrupt = d;
        std::fill_n(corrupt.begin() + offset, 4, 255);
        bool fail = false;
        try {
            Resources bad(corrupt);
        } catch (...) {
            fail = true;
        }
        assert(fail);
    }
    for (size_t n : {0ul, 4ul, catalog.size() / 2, catalog.size() - 1}) {
        bool fail = false;
        try {
            restored.DecodeCache(std::span(catalog).first(n));
        } catch (...) {
            fail = true;
        }
        assert(fail);
    }
    auto a = Appearance::Decode(CreateDefaultMii({2, 1, 2, 3, 4, 5}));
    auto portrait = Portrait::Render(r, a);
    assert(portrait.rgba == Portrait::Render(restored, a).rgba);
    // Exercise every editable resource ID and both position/size boundaries.
    for (size_t field = 0; field < AppearanceFields.size(); field++) {
        for (unsigned value : {AppearanceFields[field].minimum, AppearanceFields[field].maximum}) {
            auto b = a;
            b.Set(field, value);
            assert(Portrait::Render(r, b).rgba.size() == 512 * 512 * 4);
        }
        if (std::string(AppearanceFields[field].name).find("type") != std::string::npos ||
            field == 7 || field == 9)
            for (unsigned v = AppearanceFields[field].minimum; v <= AppearanceFields[field].maximum;
                 v++) {
                auto b = a;
                b.Set(field, v);
                Portrait::Render(r, b);
            }
    }
    // A Mii whose fields are out of range (a database can hold one) draws exactly as its nearest
    // valid values, in the portrait, the face masks and the preview scene, without reading past a
    // palette, rotation table or resource catalog.
    auto same = [&](const Appearance &odd) {
        auto shown = odd.InRange();
        assert(Portrait::Render(r, odd).rgba == Portrait::Render(r, shown).rgba);
        for (auto e : {Portrait::Expression::Normal, Portrait::Expression::Blink, Portrait::Expression::Smile})
            assert(Portrait::FaceMask(r, odd, e).rgba == Portrait::FaceMask(r, shown, e).rgba);
        auto scene = PreviewScene::Build(r, odd), expected = PreviewScene::Build(r, shown);
        assert(scene.parts.size() == expected.parts.size());
        for (size_t i = 0; i < scene.parts.size(); i++)
            assert(scene.parts[i].color == expected.parts[i].color &&
                   scene.parts[i].texture.rgba == expected.parts[i].texture.rgba &&
                   scene.parts[i].mesh.triangles.size() == expected.parts[i].mesh.triangles.size());
    };
    auto everything = a;
    unsigned outOfRange = 0;
    for (size_t field = 0; field < AppearanceFields.size(); field++) {
        const auto f = AppearanceFields[field];
        for (unsigned raw : {0u, (1u << f.bits) - 1}) {
            if (raw >= f.minimum && raw <= f.maximum)
                continue;
            auto odd = a;
            SetRaw(odd, field, raw);
            same(odd);
            SetRaw(everything, field, raw);
            outOfRange++;
        }
    }
    same(everything);
    // Glasses on, so their color and texture are looked up too.
    SetRaw(everything, 33, 15);
    same(everything);
    std::cout << shapes << " shapes and " << textures
              << " textures; malformed archive/cache bounds, portrait catalog and " << outOfRange
              << " out-of-range fields passed.\n";
}
