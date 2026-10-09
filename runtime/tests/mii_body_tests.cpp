#include "kartpad/mii/scene.h"
#include <cassert>
#include <fstream>
#include <iostream>
int main(int argc,char**argv){using namespace kartpad::mii;assert(argc==3);auto load=[](const char*p){std::ifstream f(p,std::ios::binary);assert(f);return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});};auto archive=load(argv[1]);auto bodyBytes=load(argv[2]);Resources r(archive);BodyResources body(bodyBytes);
    for(bool female:{false,true}){auto&m=body.Model(female);assert(m.parts.size()==2&&m.neckY>100&&m.neckY<130);assert(m.parts[0].texture.width==256);assert(m.headAttachment[0]==.8f&&m.headAttachment[1]==-10&&m.headAttachment[2]==7);for(auto&p:m.parts){assert(p.texture.rgba==m.parts[0].texture.rgba);assert(p.lightMap.width==64&&p.highlightMap.width==64);}assert(m.parts[0].mesh.triangles.size()>600);for(auto&p:m.parts)for(auto&v:p.mesh.triangles)for(float f:{v.x,v.y,v.z,v.nx,v.ny,v.nz,v.u,v.v,v.red,v.green,v.blue,v.alpha})assert(std::isfinite(f));}
    for(unsigned g:{3,9})for(unsigned i=0;i<r.Count(g);i++)for(auto&v:r.Shape(g,i).triangles){assert(v.u>=-.1f&&v.u<=2.1f&&v.v>=-.1f&&v.v<=1.2f);assert(std::abs(v.nx)<=1.01f&&std::abs(v.ny)<=1.01f&&std::abs(v.nz)<=1.01f);}
    auto a=Appearance::Decode(CreateDefaultMii({2,1,2,3,4,5}));auto mask=Portrait::FaceMask(r,a);unsigned visible=0;for(size_t i=3;i<mask.rgba.size();i+=4)visible+=mask.rgba[i]>0;assert(visible>1000&&visible<60000);auto other=a;other.Set(14,47);assert(Portrait::FaceMask(r,other).rgba!=mask.rgba);
    for(unsigned field:{33u,37u}){auto tile=Portrait::AccessoryThumbnail(r,field,1);unsigned left=0,right=0;for(unsigned y=0;y<tile.height;y++)for(unsigned x=0;x<tile.width;x++)if(tile.rgba[(y*tile.width+x)*4+3]){if(x<tile.width/2)left++;else right++;}assert(left>100&&right>100);assert(std::abs(int(left)-int(right))<int(std::max(left,right))/10);}
    auto scene=PreviewScene::Build(r,a,&body);assert(scene.bottom<-50);for(unsigned i=0;i<2;i++){assert(scene.parts[i].bodyPart&&!scene.parts[i].translucent);assert(scene.parts[i].texture.width==256&&scene.parts[i].lightMap.width==64&&scene.parts[i].highlightMap.width==64);}auto missing=PreviewScene::Build(r,a);assert(missing.bottom==missing.headBottom);for(const auto&p:missing.parts)assert(!p.bodyPart);assert(scene.parts.size()==missing.parts.size()+2);other.Set(0,1);assert(PreviewScene::Build(r,other,&body).parts[0].mesh.triangles.size()!=scene.parts[0].mesh.triangles.size());
    other=a;other.Set(5,127);other.Set(6,127);assert(PreviewScene::Build(r,other,&body).bottom<scene.bottom);
    for(size_t n:{0ul,16ul,bodyBytes.size()/2}){bool failed=false;try{BodyResources bad(std::span(bodyBytes).first(n));}catch(...){failed=true;}assert(failed);}
    auto invalid=bodyBytes;invalid[4]=0xff;bool failed=false;try{BodyResources bad(invalid);}catch(...){failed=true;}assert(failed);
    std::cout<<"Imported male/female body meshes, standing pose, textures, RFL UV/normal scales, facial mask and malformed archive checks passed.\n";
}
