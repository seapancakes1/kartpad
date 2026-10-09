#pragma once
#include "portrait.h"
#include "body.h"
namespace kartpad::mii {
struct ScenePart { Mesh mesh; Color color; Image texture; bool unlit=false; bool translucent=false; bool doubleSided=false; bool bodyPart=false; Image lightMap, highlightMap; };
struct PreviewScene {
    std::vector<ScenePart> parts;
    float bottom=-85, top=82, headBottom=0, headTop=82, headRadius=33, radius=33;
    void Add(const Mesh &mesh,Color color,float scale=1,float x=0,float y=0,float z=0,bool flip=false,const Image *texture=nullptr,bool unlit=false){
        if(mesh.triangles.empty())return;
        ScenePart part{mesh,color,texture?*texture:Image{},unlit};
        for(auto &v:part.mesh.triangles){v.x=x+v.x*scale*(flip?-1:1);v.y=y+v.y*scale;v.z=z+v.z*scale;if(flip)v.nx=-v.nx;}
        if(flip)for(size_t i=0;i<part.mesh.triangles.size();i+=3)std::swap(part.mesh.triangles[i+1],part.mesh.triangles[i+2]);
        parts.push_back(std::move(part));
    }
    static PreviewScene Build(const Resources &r,const Appearance&a,const BodyResources *body=nullptr){
        PreviewScene s;auto g=[&](size_t f){return a.Get(f);};
        Color skin=Skin[g(8)],shirt=Shirt[g(3)];
        s.bottom=0;
        if(body){
            const auto&model=body->Model(g(0));
            float height=.55f+g(5)/127.f*.3f,width=.55f+g(6)/127.f*.3f;
            for(const auto&part:model.parts){
                Mesh mesh=part.mesh;
                for(auto&v:mesh.triangles){v.x*=width;v.y=(v.y-model.neckY-model.headAttachment[1])*height;v.z=(v.z-model.neckZ-model.headAttachment[2])*width;v.nx/=width;v.ny/=height;v.nz/=width;s.bottom=std::min(s.bottom,v.y);}
                s.Add(mesh,part.favoriteColor?shirt:Color{255,255,255},1,0,0,0,false,part.texture.width?&part.texture:nullptr);s.parts.back().bodyPart=true;s.parts.back().lightMap=part.lightMap;s.parts.back().highlightMap=part.highlightMap;
            }
        }
        const auto&face=r.Shape(3,g(7));
        auto faceTexture=Portrait::FaceTexture(r,a);
        s.Add(face,{255,255,255},1,0,0,0,false,&faceTexture);
        s.Add(r.Shape(0,g(38)),Hair[g(39)],1,face.transforms[3],face.transforms[4],face.transforms[5]);
        s.Add(r.Shape(5,g(11)),skin,1,face.transforms[6],face.transforms[7],face.transforms[8],g(13));
        s.Add(r.Shape(8,g(11)),Hair[g(12)],1,face.transforms[6],face.transforms[7],face.transforms[8],g(13));
        if(!r.Shape(16,g(11)).triangles.empty()){
            auto cap=Portrait::CapTexture(r,a);
            s.Add(r.Shape(16,g(11)),{255,255,255},1,face.transforms[6],face.transforms[7],face.transforms[8],g(13),&cap);
        }
        float scale=.4f+g(27)*.175f,y=face.transforms[1]+(8-int(g(28)))*1.5f;
        s.Add(r.Shape(13,g(26)),skin,scale,face.transforms[0],y,face.transforms[2]);
        auto mask=Portrait::FaceMask(r,a);s.Add(r.Shape(9,g(7)),{255,255,255},1,0,0,.02f,false,&mask,true);s.parts.back().translucent=true;
        if(!r.Shape(14,g(26)).triangles.empty()){s.Add(r.Shape(14,g(26)),{0,0,0},scale,face.transforms[0],y,face.transforms[2]+.05f,false,&r.Texture(15,g(26)),true);s.parts.back().translucent=true;}
        if(g(33)){s.Add(r.Shape(6,0),Glasses[g(34)],.4f+.15f*g(35),face.transforms[0],5+face.transforms[1]+(11-int(g(36)))*1.5f,2+face.transforms[2],false,&r.Texture(7,g(33)),true);s.parts.back().translucent=true;s.parts.back().doubleSided=true;}
        for(const auto &part:s.parts)for(const auto &v:part.mesh.triangles){
            s.top=std::max(s.top,v.y);s.bottom=std::min(s.bottom,v.y);
            s.radius=std::max(s.radius,std::hypot(v.x,v.z));
            if(!part.bodyPart){s.headBottom=std::min(s.headBottom,v.y);s.headTop=std::max(s.headTop,v.y);s.headRadius=std::max(s.headRadius,std::hypot(v.x,v.z));}
        }
        return s;
    }
};
} // namespace kartpad::mii
