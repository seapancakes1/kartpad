#pragma once
// Independent bounds-checked reader; format references: Wii RFL resources and GX texture layout.
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <map>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>
namespace kartpad::mii {
struct ResourceReader {
    std::span<const uint8_t> data;
    void Check(size_t p, size_t n) const {
        if (p > data.size() || n > data.size() - p)
            throw std::invalid_argument("Truncated Mii preview resources.");
    }
    uint8_t U8(size_t p) const {
        Check(p, 1);
        return data[p];
    }
    uint16_t U16(size_t p) const {
        Check(p, 2);
        return uint16_t(data[p] << 8 | data[p + 1]);
    }
    uint32_t U32(size_t p) const { return uint32_t(U16(p)) << 16 | U16(p + 2); }
    std::span<const uint8_t> Slice(size_t p, size_t n) const {
        Check(p, n);
        return data.subspan(p, n);
    }
};
struct Image {
    unsigned width = 0, height = 0;
    std::vector<uint8_t> rgba;
    unsigned wrapS=0,wrapT=0; // GX clamp, repeat, mirrored repeat.
};
struct Mesh {
    struct Vertex {
        float x, y, z, nx, ny, nz, u = 0, v = 0;
        float red=1, green=1, blue=1, alpha=1;
    };
    std::vector<Vertex> triangles;
    std::array<float, 9> transforms{};
};
class Resources {
    std::vector<uint8_t> storage;
    std::span<const uint8_t> resource;
    mutable std::map<unsigned, Image> textures;
    mutable std::map<unsigned, Mesh> shapes;

  public:
    explicit Resources(std::span<const uint8_t> archive) : storage(archive.begin(), archive.end()) {
        ResourceReader r{storage};
        if (r.U32(0) != 0x55aa382d)
            throw std::invalid_argument("Invalid Wii Mii archive.");
        size_t root = r.U32(4), n = r.U32(root + 8);
        if (r.U8(root) != 1 || n < 2 || n > 1024)
            throw std::invalid_argument("Invalid archive entries.");
        auto strings = root + n * 12;
        r.Check(root, n * 12);
        for (size_t i = 1; i < n; i++) {
            auto entry = root + i * 12;
            auto word = r.U32(entry);
            if (word >> 24)
                continue;
            size_t name = strings + (word & 0xffffff);
            r.Check(name, 12);
            if (std::string(reinterpret_cast<const char *>(storage.data() + name), 11) ==
                "RFL_Res.dat") {
                resource = r.Slice(r.U32(entry + 4), r.U32(entry + 8));
                break;
            }
        }
        if (resource.empty() || ResourceReader{resource}.U16(0) != 18)
            throw std::invalid_argument("Mii resources are missing or unsupported.");
        for (unsigned g = 0; g < 18; g++)
            for (unsigned i = 0; i < Count(g); i++)
                (void)Entry(g, i);
    }
    unsigned Count(unsigned group) const {
        ResourceReader r{resource};
        if (group >= 18)
            throw std::invalid_argument("Invalid Mii resource group.");
        return r.U16(r.U32(4 + 4 * group));
    }
    std::span<const uint8_t> Entry(unsigned g, unsigned i) const {
        ResourceReader r{resource};
        if (i >= Count(g))
            throw std::invalid_argument("Missing Mii feature resource.");
        size_t p = r.U32(4 + 4 * g), n = r.U16(p), base = p + 8 + 4 * n;
        auto start = r.U32(p + 4 + 4 * i), end = r.U32(p + 8 + 4 * i);
        if (end < start)
            throw std::invalid_argument("Invalid Mii resource offsets.");
        return r.Slice(base + start, end - start);
    }
    Image DecodeTexture(unsigned g, unsigned index) const {
        ResourceReader r{Entry(g, index)};
        unsigned fmt = r.U8(0), w = r.U16(2), h = r.U16(4);
        size_t p = r.U32(28);
        if (p < 32 || !w || !h || w > 512 || h > 512)
            throw std::invalid_argument("Invalid Mii texture dimensions.");
        Image out{w, h, std::vector<uint8_t>(w * h * 4),r.U8(6),r.U8(7)};
        if(out.wrapS>2||out.wrapT>2)throw std::invalid_argument("Invalid Mii texture wrapping.");
        unsigned bw = (fmt <= 2 ? 8 : 4), bh = (fmt == 0 ? 8 : 4);
        unsigned tileBytes = (fmt == 0 || fmt == 1 || fmt == 2 ? 32 : fmt == 6 ? 64 : 32);
        if (fmt != 0 && fmt != 1 && fmt != 2 && fmt != 3 && fmt != 4 && fmt != 5 && fmt != 6)
            throw std::invalid_argument("Unsupported Mii texture format.");
        for (unsigned ty = 0; ty < h; ty += bh)
            for (unsigned tx = 0; tx < w; tx += bw) {
                r.Check(p, tileBytes);
                for (unsigned y = 0; y < bh; y++)
                    for (unsigned x = 0; x < bw; x++) {
                        unsigned k = y * bw + x;
                        uint8_t red = 255, green = 255, blue = 255, alpha = 255;
                        if (fmt == 0) {
                            auto v = r.U8(p + k / 2);
                            alpha = uint8_t(((k % 2) ? v & 15 : v >> 4) * 17);
                        } else if (fmt == 1) {
                            alpha = r.U8(p + k);
                        } else if (fmt == 2) {
                            auto v = r.U8(p + k);
                            alpha = uint8_t((v >> 4) * 17);
                            red = green = blue = uint8_t((v & 15) * 17);
                        } else if (fmt == 3) {
                            alpha = r.U8(p + k * 2);
                            red = green = blue = r.U8(p + k * 2 + 1);
                        } else if (fmt == 4 || fmt == 5) {
                            auto v = r.U16(p + k * 2);
                            if (fmt == 4) {
                                red = uint8_t(((v >> 11) & 31) * 255 / 31);
                                green = uint8_t(((v >> 5) & 63) * 255 / 63);
                                blue = uint8_t((v & 31) * 255 / 31);
                            } else if (v & 0x8000) {
                                red = uint8_t(((v >> 10) & 31) * 255 / 31);
                                green = uint8_t(((v >> 5) & 31) * 255 / 31);
                                blue = uint8_t((v & 31) * 255 / 31);
                            } else {
                                alpha = uint8_t(((v >> 12) & 7) * 255 / 7);
                                red = uint8_t(((v >> 8) & 15) * 17);
                                green = uint8_t(((v >> 4) & 15) * 17);
                                blue = uint8_t((v & 15) * 17);
                            }
                        } else {
                            alpha = r.U8(p + 2 * k);
                            red = r.U8(p + 2 * k + 1);
                            green = r.U8(p + 32 + 2 * k);
                            blue = r.U8(p + 32 + 2 * k + 1);
                        }
                        if (tx + x < w && ty + y < h) {
                            auto o = ((ty + y) * w + tx + x) * 4;
                            out.rgba[o] = red;
                            out.rgba[o + 1] = green;
                            out.rgba[o + 2] = blue;
                            out.rgba[o + 3] = alpha;
                        }
                    }
                p += tileBytes;
            }
        return out;
    }
    Mesh DecodeShape(unsigned g, unsigned index) const {
        ResourceReader r{Entry(g, index)};
        Mesh m;
        size_t p = 4;
        bool face = g == 3, skip = g == 0 || g == 5 || g == 8 || g == 13;
        if (face) {
            for (unsigned i = 0; i < 9; i++) {
                m.transforms[i] = std::bit_cast<float>(r.U32(p));
                p += 4;
                if (!std::isfinite(m.transforms[i]))
                    throw std::invalid_argument("Invalid face transform.");
            }
        }
        auto vectors = [&](unsigned dim, float divisor) {
            unsigned n = r.U16(p);
            p += 2;
            if (n > 4096)
                throw std::invalid_argument("Too many Mii vertices.");
            std::vector<std::array<float, 3>> v(n);
            for (auto &a : v)
                for (unsigned j = 0; j < dim; j++) {
                    a[j] = float(int16_t(r.U16(p))) / divisor;
                    p += 2;
                }
            return v;
        };
        auto positions = vectors(3,256.f), normals = vectors(3,16384.f);
        std::vector<std::array<float, 3>> uv;
        if (!skip)
            uv = vectors(2,8192.f);
        unsigned primitives = r.U8(p++);
        for (unsigned primitive = 0; primitive < primitives; primitive++) {
            unsigned n = r.U8(p++), type = r.U8(p++);
            std::vector<Mesh::Vertex> v;
            for (unsigned i = 0; i < n; i++) {
                unsigned a = r.U8(p++), b = r.U8(p++), t = 0;
                if (!skip)
                    t = r.U8(p++);
                r.Check(p, 0);
                if (a >= positions.size() || b >= normals.size() || (!skip && t >= uv.size()))
                    throw std::invalid_argument("Invalid Mii vertex index.");
                auto q = positions[a], normal = normals[b];
                v.push_back({q[0], q[1], q[2], normal[0], normal[1], normal[2], skip ? 0 : uv[t][0],
                             skip ? 0 : uv[t][1]});
            }
            auto tri = [&](unsigned a, unsigned b, unsigned c) {
                m.triangles.insert(m.triangles.end(), {v[a], v[b], v[c]});
            };
            if (type == 0x90) {
                for (unsigned i = 0; i + 2 < n; i += 3)
                    tri(i, i + 1, i + 2);
            } else if (type == 0x98) {
                for (unsigned i = 2; i < n; i++)
                    tri(i - 2 + (i % 2), i - 1 - (i % 2), i);
            } else if (type == 0xa0) {
                for (unsigned i = 2; i < n; i++)
                    tri(0, i - 1, i);
            } else if (type == 0x80) {
                for (unsigned i = 0; i + 3 < n; i += 4) {
                    tri(i, i + 1, i + 2);
                    tri(i, i + 2, i + 3);
                }
            } else if (type != 0xa8 && type != 0xb0 && type != 0xb8)
                throw std::invalid_argument("Unknown Mii primitive.");
        }
        return m;
    }
    static bool IsShape(unsigned g) {
        return g == 0 || g == 3 || g == 5 || g == 6 || g == 8 || g == 9 || g == 13 || g == 14 ||
               g == 16;
    }
    const Image &Texture(unsigned g, unsigned index) const {
        auto key = g * 1024 + index;
        auto it = textures.find(key);
        if (it == textures.end())
            it = textures.emplace(key, DecodeTexture(g, index)).first;
        return it->second;
    }
    const Mesh &Shape(unsigned g, unsigned index) const {
        auto key = g * 1024 + index;
        auto it = shapes.find(key);
        if (it == shapes.end())
            it = shapes.emplace(key, DecodeShape(g, index)).first;
        return it->second;
    }
    std::vector<uint8_t> EncodeCache() const {
        std::vector<uint8_t> out;
        auto word = [&](uint32_t v) {
            for (int n = 3; n >= 0; n--)
                out.push_back(uint8_t(v >> (n * 8)));
        };
        word(0x4d494935);
        for (unsigned g = 0; g < 18; g++) {
            word(Count(g));
            for (unsigned i = 0; i < Count(g); i++) {
                if (IsShape(g)) {
                    const auto &m = Shape(g, i);
                    for (float v : m.transforms)
                        word(std::bit_cast<uint32_t>(v));
                    word(m.triangles.size());
                    for (auto v : m.triangles)
                        for (float f : {v.x, v.y, v.z, v.nx, v.ny, v.nz, v.u, v.v})
                            word(std::bit_cast<uint32_t>(f));
                } else {
                    const auto &t = Texture(g, i);
                    word(t.width);
                    word(t.height);
                    word(t.wrapS);word(t.wrapT);
                    out.insert(out.end(), t.rgba.begin(), t.rgba.end());
                }
            }
        }
        return out;
    }
    void DecodeCache(std::span<const uint8_t> bytes) {
        ResourceReader r{bytes};
        size_t p = 0;
        auto word = [&]() {
            uint32_t v = r.U32(p);
            p += 4;
            return v;
        };
        auto number = [&]() {
            float v = std::bit_cast<float>(word());
            if (!std::isfinite(v) || std::abs(v) > 4096)
                throw std::invalid_argument("Invalid cached Mii geometry.");
            return v;
        };
        std::map<unsigned, Image> t;
        std::map<unsigned, Mesh> m;
        if (word() != 0x4d494935)
            throw std::invalid_argument("Outdated Mii preview cache.");
        for (unsigned g = 0; g < 18; g++) {
            if (word() != Count(g))
                throw std::invalid_argument("Mii cache catalog mismatch.");
            for (unsigned i = 0; i < Count(g); i++) {
                if (IsShape(g)) {
                    Mesh mesh;
                    for (auto &f : mesh.transforms)
                        f = number();
                    unsigned n = word();
                    if (n > 65536 || n % 3)
                        throw std::invalid_argument("Invalid cached Mii shape.");
                    r.Check(p, size_t(n) * 32);
                    for (unsigned v = 0; v < n; v++)
                        mesh.triangles.push_back({number(), number(), number(), number(), number(),
                                                  number(), number(), number()});
                    m.emplace(g * 1024 + i, std::move(mesh));
                } else {
                    unsigned w = word(), h = word(),wrapS=word(),wrapT=word();
                    if (!w || !h || w > 512 || h > 512 || wrapS>2 || wrapT>2)
                        throw std::invalid_argument("Invalid cached Mii texture.");
                    auto pixels = r.Slice(p, size_t(w) * h * 4);
                    p += pixels.size();
                    t.emplace(g * 1024 + i,
                              Image{w, h, std::vector<uint8_t>(pixels.begin(), pixels.end()),wrapS,wrapT});
                }
            }
        }
        if (p != bytes.size())
            throw std::invalid_argument("Unexpected cached Mii data.");
        textures = std::move(t);
        shapes = std::move(m);
    }
    Resources(const Resources &) = delete;
    Resources &operator=(const Resources &) = delete;
};
} // namespace kartpad::mii
