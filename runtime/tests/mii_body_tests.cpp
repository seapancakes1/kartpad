#include "kartpad/mii/scene.h"
#include <cassert>
#include <fstream>
#include <iostream>
int main(int argc,char**argv){using namespace kartpad::mii;assert(argc==3);auto load=[](const char*p){std::ifstream f(p,std::ios::binary);assert(f);return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});};auto archive=load(argv[1]);auto bodyBytes=load(argv[2]);Resources r(archive);BodyResources body(bodyBytes);
    // Game build rule (RMCP01 0x80525FF4) and the menu miiDispParam.bin head parameters per build and gender.
    assert(BuildFor(52,52)==MiiBuild::Small&&BuildFor(52,53)==MiiBuild::Medium&&BuildFor(75,75)==MiiBuild::Medium&&BuildFor(75,76)==MiiBuild::Large&&BuildFor(127,0)==MiiBuild::Medium);
    const float head[3][2][3]={{{.8f,-10,7},{.75f,-11,7}},{{.85f,-11,7},{.8f,-12,6}},{{1,-13,5},{.95f,-13,6}}};
    for(unsigned b=0;b<3;b++)for(bool female:{false,true})for(unsigned j=0;j<3;j++)assert(body.Model(female,MiiBuild(b)).headAttachment[j]==head[b][female][j]);
    assert(body.Model(false,MiiBuild::Small).neckY<body.Model(false,MiiBuild::Medium).neckY&&body.Model(false,MiiBuild::Medium).neckY<body.Model(false,MiiBuild::Large).neckY);
    for(bool female:{false,true}){auto&m=body.Model(female);assert(m.parts.size()==2&&m.neckY>100&&m.neckY<130);assert(m.parts[0].texture.width==256);for(auto&p:m.parts){assert(p.texture.rgba==m.parts[0].texture.rgba);assert(p.lightMap.width==64&&p.highlightMap.width==64);}assert(m.parts[0].mesh.triangles.size()>600);for(auto&p:m.parts)assert(p.alphaThreshold==(p.favoriteColor?0:128/255.f));for(auto&p:m.parts)for(auto&v:p.mesh.triangles)for(float f:{v.x,v.y,v.z,v.nx,v.ny,v.nz,v.u,v.v,v.red,v.green,v.blue,v.alpha})assert(std::isfinite(f));}
    for(unsigned g:{3,9})for(unsigned i=0;i<r.Count(g);i++)for(auto&v:r.Shape(g,i).triangles){assert(v.u>=-.1f&&v.u<=2.1f&&v.v>=-.1f&&v.v<=1.2f);assert(std::abs(v.nx)<=1.01f&&std::abs(v.ny)<=1.01f&&std::abs(v.nz)<=1.01f);}
    auto a=Appearance::Decode(CreateDefaultMii({2,1,2,3,4,5}));auto mask=Portrait::FaceMask(r,a);unsigned visible=0;for(size_t i=3;i<mask.rgba.size();i+=4)visible+=mask.rgba[i]>0;assert(visible>1000&&visible<60000);auto other=a;other.Set(14,47);assert(Portrait::FaceMask(r,other).rgba!=mask.rgba);
    for(unsigned field:{33u,37u}){auto tile=Portrait::AccessoryThumbnail(r,field,1);unsigned left=0,right=0;for(unsigned y=0;y<tile.height;y++)for(unsigned x=0;x<tile.width;x++)if(tile.rgba[(y*tile.width+x)*4+3]){if(x<tile.width/2)left++;else right++;}assert(left>100&&right>100);assert(std::abs(int(left)-int(right))<int(std::max(left,right))/10);}
    auto scene=PreviewScene::Build(r,a,&body);assert(scene.bottom<-50);for(unsigned i=0;i<2;i++){assert(scene.parts[i].bodyPart&&!scene.parts[i].translucent&&scene.parts[i].alphaThreshold==body.Model(false).parts[i].alphaThreshold);assert(scene.parts[i].texture.width==256&&scene.parts[i].lightMap.width==64&&scene.parts[i].highlightMap.width==64);}auto missing=PreviewScene::Build(r,a);assert(missing.bottom==missing.headBottom);for(const auto&p:missing.parts)assert(!p.bodyPart);assert(scene.parts.size()==missing.parts.size()+2);other.Set(0,1);assert(PreviewScene::Build(r,other,&body).parts[0].mesh.triangles.size()!=scene.parts[0].mesh.triangles.size());
    other=a;other.Set(5,127);other.Set(6,127);assert(PreviewScene::Build(r,other,&body).bottom<scene.bottom);other.Set(5,0);other.Set(6,0);assert(PreviewScene::Build(r,other,&body).bottom>scene.bottom);
    other.Set(5,127);other.Set(6,0);assert(PreviewScene::Build(r,other,&body).bottom==scene.bottom);
    // Idle animation: medium has the game's 50-frame "wait" loop; small and large reuse its motion. The clip
    // closes its loop, the head moves with the neck by a few units, and the RFL blink/smile faces differ.
    assert(body.Model(false,MiiBuild::Medium).wait.size()==50&&body.Model(false,MiiBuild::Small).wait.size()==1&&body.Model(false,MiiBuild::Large).wait.size()==1);
    for(unsigned b=0;b<3;b++)for(bool female:{false,true}){auto&m=body.Model(female,MiiBuild(b));assert(m.idle.size()==50);float seam=0;for(size_t j=0;j<m.joints.size();j++)for(int k=0;k<9;k++)seam=std::max(seam,std::abs(m.idle.back()[j][k]-m.idle.front()[j][k]));assert(seam<1);}
    {auto standWorld=body.Model(false).World(body.Model(false).stand);for(auto&p:body.Model(false).parts){auto skinned=body.Model(false).Skin(p,standWorld);for(size_t i=0;i<skinned.triangles.size();i++)assert(std::abs(skinned.triangles[i].y-p.mesh.triangles[i].y)<1e-3f);}}
    {std::vector<Mesh> posed;assert(scene.Animated());for(float frame:{0.f,12.5f,25.f,49.f}){auto head=scene.Pose(frame,posed);assert(posed.size()==2);for(int k:{3,7,11})assert(std::isfinite(head[k])&&std::abs(head[k])<10);for(int k:{0,5,10})assert(head[k]>.95f&&head[k]<1.05f);}}
    assert(scene.maskPart<scene.parts.size()&&scene.blinkMask.rgba!=scene.parts[scene.maskPart].texture.rgba&&scene.smileMask.rgba!=scene.blinkMask.rgba&&scene.smileMask.rgba!=scene.parts[scene.maskPart].texture.rgba);
    for(size_t n:{0ul,16ul,bodyBytes.size()/2}){bool failed=false;try{BodyResources bad(std::span(bodyBytes).first(n));}catch(...){failed=true;}assert(failed);}
    auto invalid=bodyBytes;invalid[4]=0xff;bool failed=false;try{BodyResources bad(invalid);}catch(...){failed=true;}assert(failed);
    std::cout<<"Imported small/medium/large male/female body meshes, game build thresholds, standing pose, idle loops, RFL blink/smile, textures, material alpha tests, RFL UV/normal scales, facial mask and malformed archive checks passed.\n";
}
