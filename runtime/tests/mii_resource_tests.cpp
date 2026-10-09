#include "kartpad/mii/portrait.h"
#include <cassert>
#include <fstream>
#include <iostream>
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
    std::cout << shapes << " shapes and " << textures
              << " textures; malformed archive/cache bounds and portrait catalog passed.\n";
}
