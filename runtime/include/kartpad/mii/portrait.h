#pragma once
#include "appearance.h"
#include "resources.h"
#include <algorithm>
namespace kartpad::mii {
using Color = std::array<uint8_t, 3>;
inline constexpr std::array<Color, 6> Skin = {Color{240, 216, 196}, Color{255, 188, 128},
                                              Color{216, 136, 80},  Color{255, 176, 144},
                                              Color{152, 80, 48},   Color{82, 46, 28}};
inline constexpr std::array<Color, 8> Hair = {
    Color{30, 26, 24},    Color{56, 32, 21}, Color{85, 38, 23},  Color{112, 64, 36},
    Color{114, 114, 120}, Color{73, 54, 26}, Color{122, 89, 40}, Color{193, 159, 100}};
inline constexpr std::array<Color, 12> Shirt = {
    Color{184, 64, 48},  Color{240, 120, 40}, Color{248, 216, 32},  Color{128, 200, 40},
    Color{0, 116, 40},   Color{32, 72, 152},  Color{64, 160, 216},  Color{232, 96, 120},
    Color{112, 44, 168}, Color{72, 56, 24},   Color{224, 224, 224}, Color{24, 24, 20}};
inline constexpr std::array<Color, 6> Glasses = {Color{16, 16, 16},  Color{96, 56, 16},
                                                 Color{152, 24, 16}, Color{32, 48, 96},
                                                 Color{144, 88, 0},  Color{96, 88, 80}};
inline constexpr std::array<Color, 6> Eyes = {Color{0, 0, 0},      Color{124, 128, 128},
                                              Color{112, 80, 64},  Color{112, 110, 64},
                                              Color{88, 104, 184}, Color{72, 128, 104}};
inline constexpr std::array<Color, 3> Lip0 = {Color{190, 78, 38}, Color{216, 48, 40},
                                              Color{207, 68, 71}};
inline constexpr std::array<Color, 3> Lip1 = {Color{113, 42, 4}, Color{120, 21, 16},
                                              Color{126, 37, 40}};
inline constexpr std::array<unsigned, 50> EyeRotation = {
    29, 28, 28, 28, 29, 28, 28, 28, 29, 28, 28, 28, 28, 29, 29, 28, 28,
    28, 29, 29, 28, 29, 28, 29, 29, 28, 29, 28, 28, 29, 28, 28, 28, 29,
    29, 29, 28, 28, 29, 29, 29, 28, 28, 29, 29, 29, 29, 29, 28, 28};
inline constexpr std::array<unsigned, 24> BrowRotation = {
    26, 26, 27, 25, 26, 25, 26, 25, 28, 25, 26, 24, 27, 27, 26, 26, 25, 25, 26, 26, 27, 26, 25, 27};
class Portrait {
    Image out{512, 512, std::vector<uint8_t>(512 * 512 * 4, 0)};
    std::vector<float> depth = std::vector<float>(512 * 512, -1e9f);
    float pixelsPerUnit=4,originY=382;
    void Pixel(int x, int y, float z, Color color, float light = 1, float alpha = 1) {
        if (x < 0 || y < 0 || x >= 512 || y >= 512)
            return;
        auto k = y * 512 + x;
        if (z < depth[k])
            return;
        float oldAlpha = out.rgba[k * 4 + 3] / 255.f;
        float resultAlpha = alpha + oldAlpha * (1 - alpha);
        for (unsigned c = 0; c < 3; c++) {
            float premultiplied = float(color[c]) * light * alpha +
                out.rgba[k * 4 + c] * oldAlpha * (1 - alpha);
            out.rgba[k * 4 + c] = uint8_t(std::clamp(premultiplied / std::max(resultAlpha, .0001f), 0.f, 255.f));
        }
        out.rgba[k * 4 + 3] = uint8_t(resultAlpha * 255);
        if (alpha >= .99f) depth[k] = z;
    }
    void MeshDraw(const Mesh &mesh, Color color, float scale = 1, float dx = 0, float dy = 0,
                  float dz = 0, bool flip = false, const Image *texture = nullptr, bool unlit=false) {
        // A shared triangle edge belongs to one sample. Blending it twice draws a diagonal seam.
        std::vector<float> coverage(512*512,-1e9f);
        for (size_t i = 0; i + 2 < mesh.triangles.size(); i += 3) {
            auto a = mesh.triangles[i], b = mesh.triangles[i + 1], c = mesh.triangles[i + 2];
            auto project = [&](Mesh::Vertex &v) {
                v.x = 256 + (dx + v.x * scale * (flip ? -1 : 1)) * pixelsPerUnit;
                v.y = originY - (dy + v.y * scale) * pixelsPerUnit;
                v.z = dz + v.z * scale;
                if (flip)
                    v.nx = -v.nx;
            };
            project(a);
            project(b);
            project(c);
            float area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
            if (area * (flip ? -1 : 1) < .01)
                continue;
            int x0 = std::max(0, int(std::floor(std::min({a.x, b.x, c.x})))),
                x1 = std::min(511, int(std::ceil(std::max({a.x, b.x, c.x}))));
            int y0 = std::max(0, int(std::floor(std::min({a.y, b.y, c.y})))),
                y1 = std::min(511, int(std::ceil(std::max({a.y, b.y, c.y}))));
            for (int y = y0; y <= y1; y++)
                for (int x = x0; x <= x1; x++) {
                    float u = ((b.x - x) * (c.y - y) - (b.y - y) * (c.x - x)) / area,
                          v = ((c.x - x) * (a.y - y) - (c.y - y) * (a.x - x)) / area, w = 1 - u - v;
                    if (u < 0 || v < 0 || w < 0)
                        continue;
                    float nx = u * a.nx + v * b.nx + w * c.nx, ny = u * a.ny + v * b.ny + w * c.ny,
                          nz = u * a.nz + v * b.nz + w * c.nz;
                    float n = std::sqrt(nx * nx + ny * ny + nz * nz);
                    float light =
                        unlit?1:n > 0 ? .68f + .32f * std::max(0.f, (-.3f * nx + .5f * ny + .8f * nz) / n)
                              : 1;
                    Color shade = color;
                    float alpha = 1;
                    if (texture) {
                        float tx = u * a.u + v * b.u + w * c.u, ty = u * a.v + v * b.v + w * c.v;
                        float px=tx*texture->width-.5f,py=ty*texture->height-.5f;
                        int ix=int(std::floor(px)),iy=int(std::floor(py));float fx=px-ix,fy=py-iy;alpha=0;std::array<float,3> rgb{};
                        for(int j=0;j<2;j++)for(int i=0;i<2;i++){
                            auto address=[](int index,unsigned size,unsigned wrap){if(!wrap)return unsigned(std::clamp(index,0,int(size)-1));int period=int(size)*(wrap==2?2:1);index=(index%period+period)%period;return unsigned(wrap==2&&index>=int(size)?period-1-index:index);};
                            unsigned sx=address(ix+i,texture->width,texture->wrapS),sy=address(iy+j,texture->height,texture->wrapT);auto k=(sy*texture->width+sx)*4;
                            float weight=(i?fx:1-fx)*(j?fy:1-fy)*texture->rgba[k+3]/255.f;alpha+=weight;
                            for(unsigned channel=0;channel<3;channel++)rgb[channel]+=texture->rgba[k+channel]*weight;
                        }
                        for(unsigned channel=0;channel<3;channel++)shade[channel]=uint8_t(std::clamp(rgb[channel]/std::max(alpha,.0001f)*color[channel]/255.f,0.f,255.f));
                    }
                    float z=u*a.z+v*b.z+w*c.z;
                    if(alpha>.01f&&z>coverage[y*512+x]+.0001f){coverage[y*512+x]=z;Pixel(x,y,z,shade,light,alpha);}
                }
        }
    }
    void TextureDraw(const Image &image, float cx, float cy, float width, float height, Color color,
                     float rotation = 0, bool flip = false, float origin = 0) {
        float angle = rotation * 3.14159265f / 180, cs = std::cos(angle), sn = std::sin(angle);
        int radius = int(std::ceil(std::hypot(width, height)));
        for (int y = int(cy) - radius; y <= cy + radius; y++)
            for (int x = int(cx) - radius; x <= cx + radius; x++) {
                float dx = (x - cx) / .88961464f, dy = (y - cy) / .9276675f;
                float u = (cs * dx + sn * dy) / width + .5f - origin,
                      v = (-sn * dx + cs * dy) / height + .5f;
                if (flip)
                    u = 1 - u;
                if (u < 0 || u >= 1 || v < 0 || v >= 1)
                    continue;
                float px=u*image.width-.5f,py=v*image.height-.5f;int ix=int(std::floor(px)),iy=int(std::floor(py));float fx=px-ix,fy=py-iy,alpha=0;std::array<float,3> rgb{};
                for(int j=0;j<2;j++)for(int i=0;i<2;i++){unsigned sx=std::clamp(ix+i,0,int(image.width)-1),sy=std::clamp(iy+j,0,int(image.height)-1);auto k=(sy*image.width+sx)*4;float weight=(i?fx:1-fx)*(j?fy:1-fy)*image.rgba[k+3]/255.f;alpha+=weight;for(unsigned c=0;c<3;c++)rgb[c]+=image.rgba[k+c]*weight;}
                if(alpha<.001f)continue;
                Color tinted;for(unsigned c=0;c<3;c++)tinted[c]=uint8_t(std::clamp(rgb[c]/alpha*color[c]/255.f,0.f,255.f));
                Pixel(x, y, 50, tinted, 1, alpha);
            }
    }

  public:
    static Image ColorMask(Image image, Color first, Color second) {
        for (size_t k = 0; k < image.rgba.size(); k += 4) {
            unsigned r = image.rgba[k], g = image.rgba[k + 1], b = image.rgba[k + 2];
            for (unsigned c = 0; c < 3; c++)
                image.rgba[k + c] =
                    uint8_t(std::min(255u, (r * first[c] + g * second[c] + b * 255) / 255));
        }
        return image;
    }

  public:
    static Image FaceTexture(const Resources&r,const Appearance&a){
        auto texture=r.Texture(4,a.Get(9));auto skin=Skin[a.Get(8)];
        for(size_t i=0;i<texture.rgba.size();i+=4){float alpha=texture.rgba[i+1]/255.f;Color marking{texture.rgba[i],texture.rgba[i+3],texture.rgba[i+2]};for(unsigned c=0;c<3;c++)texture.rgba[i+c]=uint8_t(skin[c]*(1-alpha)+marking[c]*alpha);texture.rgba[i+3]=255;}return texture;
    }
    static Image CapTexture(const Resources&r,const Appearance&a){
        auto texture=r.Texture(17,a.Get(11));auto shirt=Shirt[a.Get(3)];
        for(size_t i=0;i<texture.rgba.size();i+=4){for(unsigned c=0;c<3;c++)texture.rgba[i+c]=uint8_t(shirt[c]*(texture.rgba[i+c]/255.f+1)*.5f);texture.rgba[i+3]=255;}return texture;
    }
    static Image FaceMask(const Resources &r, const Appearance &a) {
        auto get = [&](size_t f) { return a.Get(f); };
        Portrait mask;
        float unit = 8, vertical = 1.1600001f * .9276675f;
        auto scale = [](unsigned value) { return 1.f + .4f * value; };
        if (get(42))
            mask.TextureDraw(r.Texture(10, 1), (17.766165f + 2 * .88961464f * get(45)) * unit,
                             (17.95986f + vertical * get(44)) * unit, scale(get(43)) * unit,
                             scale(get(43)) * unit, {18, 15, 15});
        float eyeWidth = (342.f / 64) * scale(get(18)) * unit,
              eyeHeight = 4.5f * scale(get(18)) * unit;
        float eyeX = .88961464f * get(19) * unit, eyeY = (18.451525f + vertical * get(16)) * unit;
        float eyeAngle = ((get(15) + EyeRotation[get(14)]) % 32) * 11.25f;
        Color eyeFirst = get(14) == 9    ? Color{255, 130, 0}
                         : get(14) == 20 ? Color{0, 255, 255}
                                         : Color{0, 0, 0};
        auto eye = ColorMask(r.Texture(1, get(14)), eyeFirst, Eyes[get(17)]);
        mask.TextureDraw(eye, 256 - eyeX, eyeY, eyeWidth, eyeHeight,
                         {255, 255, 255}, eyeAngle, false, -.5f);
        mask.TextureDraw(eye, 256 + eyeX, eyeY, eyeWidth, eyeHeight,
                         {255, 255, 255}, -eyeAngle, true, .5f);
        float browWidth = (324.f / 64) * scale(get(23)) * unit,
              browHeight = 4.5f * scale(get(23)) * unit;
        float browX = .88961464f * get(25) * unit, browY = (16.549807f + vertical * get(24)) * unit;
        float browAngle = ((get(21) + BrowRotation[get(20)]) % 32) * 11.25f;
        const auto &brow = r.Texture(2, get(20));
        mask.TextureDraw(brow, 256 - browX, browY, browWidth, browHeight,
                         Hair[get(22)], browAngle, false, -.5f);
        mask.TextureDraw(brow, 256 + browX, browY, browWidth, browHeight,
                         Hair[get(22)], -browAngle, true, .5f);
        auto mouth = ColorMask(r.Texture(11, get(29)), Lip0[get(30)], Lip1[get(30)]);
        mask.TextureDraw(mouth, 256, (29.25885f + vertical * get(32)) * unit,
                         (396.f / 64) * scale(get(31)) * unit, 4.5f * scale(get(31)) * unit,
                         {255, 255, 255});
        if (get(37)) {
            float width = 4.5f * scale(get(40)) * unit, height = 9.f * scale(get(40)) * unit,
                  y = (31.763554f + vertical * get(41)) * unit;
            const auto &mustache = r.Texture(12, get(37));
            mask.TextureDraw(mustache, 256, y, width, height, Hair[get(39)], 0, false, -.5f);
            mask.TextureDraw(mustache, 256, y, width, height, Hair[get(39)], 0, true, .5f);
        }
        return mask.out;
    }
    static Image AccessoryThumbnail(const Resources &r,unsigned field,unsigned value) {
        Portrait p;
        if(field==33){p.originY=256;p.MeshDraw(r.Shape(6,0),Glasses[0],1,0,0,0,false,&r.Texture(7,value),true);}
        else if(field==37){const auto &texture=r.Texture(12,value);p.TextureDraw(texture,256,256,150,240,Hair[0],0,false,-.5f);p.TextureDraw(texture,256,256,150,240,Hair[0],0,true,.5f);}
        return p.out;
    }
    static Image Render(const Resources &r, const Appearance &a) {
        if (auto valid = a.Validate(); !valid)
            throw std::invalid_argument(valid.message);
        Portrait p;
        auto get = [&](size_t f) { return a.Get(f); };
        Color shirt=Shirt[get(3)];
        auto face=r.Shape(3,get(7));auto faceTexture=FaceTexture(r,a);
        float low=0,high=82,radius=33;
        auto bounds=[&](const Mesh &mesh,float x=0,float y=0,float z=0){for(auto&v:mesh.triangles){low=std::min(low,v.y+y);high=std::max(high,v.y+y);radius=std::max(radius,std::hypot(v.x+x,v.z+z));}};
        bounds(face);for(unsigned group:{0u,5u,8u,16u}){bool beard=group==0;bounds(r.Shape(group,get(beard?38:11)),face.transforms[beard?3:6],face.transforms[beard?4:7],face.transforms[beard?5:8]);}
        p.pixelsPerUnit=std::min(440.f/(high-low),440.f/(radius*2));p.originY=256+(low+high)*.5f*p.pixelsPerUnit;
        p.MeshDraw(face,{255,255,255},1,0,0,0,false,&faceTexture);
        p.MeshDraw(r.Shape(0, get(38)), Hair[get(39)], 1, face.transforms[3], face.transforms[4],
                   face.transforms[5]);
        p.MeshDraw(r.Shape(5, get(11)), Skin[get(8)], 1, face.transforms[6], face.transforms[7],
                   face.transforms[8], get(13));
        p.MeshDraw(r.Shape(8, get(11)), Hair[get(12)], 1, face.transforms[6], face.transforms[7],
                   face.transforms[8], get(13));
        const auto &cap = r.Shape(16, get(11));
        if (!cap.triangles.empty()) {
            auto texture = CapTexture(r,a);
            p.MeshDraw(cap, {255,255,255}, 1, face.transforms[6], face.transforms[7], face.transforms[8],
                       get(13), &texture);
        }
        float noseScale = .4f + get(27) * .175f;
        p.MeshDraw(r.Shape(13, get(26)), Skin[get(8)], noseScale, face.transforms[0],
                   face.transforms[1] + (8 - int(get(28))) * 1.5f, face.transforms[2]);
        const auto &noseLine = r.Shape(14, get(26));
        if (!noseLine.triangles.empty()) {
            const auto &lineTexture = r.Texture(15, get(26));
            p.MeshDraw(noseLine, {0, 0, 0}, noseScale, face.transforms[0],
                       face.transforms[1] + (8 - int(get(28))) * 1.5f, face.transforms[2] + .05f,
                       false, &lineTexture,true);
        }
        auto maskImage = FaceMask(r, a);
        p.MeshDraw(r.Shape(9, get(7)), {255, 255, 255}, 1, 0, 0, 0, false, &maskImage,true);
        if (get(33)) {
            const auto &glassTexture = r.Texture(7, get(33));
            p.MeshDraw(r.Shape(6, 0), Glasses[get(34)], .4f + .15f * get(35), face.transforms[0],
                       5 + face.transforms[1] + (11 - int(get(36))) * 1.5f, 2 + face.transforms[2],
                       false, &glassTexture,true);
        }
        return p.out;
    }
};
} // namespace kartpad::mii
