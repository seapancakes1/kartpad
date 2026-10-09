#pragma once
#include "resources.h"
#include <algorithm>
// Bounds-checked reader for the imported MiiBody.szs, NW4R MDL0 v11, its stand pose and wait loop.
// Format reference: https://github.com/magcius/noclip.website/blob/master/src/rres/brres.ts
namespace kartpad::mii {
// Affine 3x4 joint matrix, row-major with translation in the last column.
struct BodyMatrix {
    std::array<float,12> v{1,0,0,0,0,1,0,0,0,0,1,0};
    BodyMatrix operator*(const BodyMatrix &b)const {BodyMatrix c;for(int i=0;i<3;i++)for(int j=0;j<4;j++){c.v[i*4+j]=j==3?v[i*4+3]:0;for(int k=0;k<3;k++)c.v[i*4+j]+=v[i*4+k]*b.v[k*4+j];}return c;}
    std::array<float,3> Apply(std::array<float,3>a,bool normal=false)const{std::array<float,3>b{};for(int i=0;i<3;i++){b[i]=normal?0:v[i*4+3];for(int j=0;j<3;j++)b[i]+=v[i*4+j]*a[j];}return b;}
    BodyMatrix Inverse()const{
        const auto&m=v;float a=m[0],b=m[1],c=m[2],d=m[4],e=m[5],f=m[6],g=m[8],h=m[9],k=m[10];
        float det=a*(e*k-f*h)-b*(d*k-f*g)+c*(d*h-e*g);if(std::abs(det)<1e-12f)return {};float s=1/det;
        BodyMatrix r;r.v={(e*k-f*h)*s,(c*h-b*k)*s,(b*f-c*e)*s,0,(f*g-d*k)*s,(a*k-c*g)*s,(c*d-a*f)*s,0,(d*h-e*g)*s,(b*g-a*h)*s,(a*e-b*d)*s,0};
        for(int i=0;i<3;i++)r.v[i*4+3]=-(r.v[i*4]*m[3]+r.v[i*4+1]*m[7]+r.v[i*4+2]*m[11]);return r;}
    // CHR0 scale, rotation (degrees, applied X then Y then Z) and translation.
    static BodyMatrix SRT(const std::array<float,9>&a){BodyMatrix scale;scale.v={a[0],0,0,0,0,a[1],0,0,0,0,a[2],0};BodyMatrix rx,ry,rz;float x=a[3]*.01745329252f,y=a[4]*.01745329252f,z=a[5]*.01745329252f;rx.v={1,0,0,0,0,cosf(x),-sinf(x),0,0,sinf(x),cosf(x),0};ry.v={cosf(y),0,sinf(y),0,0,1,0,0,-sinf(y),0,cosf(y),0};rz.v={cosf(z),-sinf(z),0,0,sinf(z),cosf(z),0,0,0,0,1,0};auto m=rz*ry*rx*scale;m.v[3]=a[6];m.v[7]=a[7];m.v[11]=a[8];return m;}
};
using BodyPose = std::vector<std::array<float,9>>;
struct BodyJoint { std::string name; int parent=-1; };
// mesh is posed with "stand". local/joint keep each vertex in its joint's space for re-posing.
struct BodyPart { Mesh mesh; std::vector<Mesh::Vertex> local; std::vector<unsigned> joint; Image texture, lightMap, highlightMap; bool favoriteColor=false; };
// headAttachment is the miiDispParam.bin entry for this build and gender: head scale, then Y/Z offset.
struct BodyModel {
    std::vector<BodyPart> parts; float neckY=0, neckZ=0; std::array<float,3> headAttachment{1,0,0};
    std::vector<BodyJoint> joints; unsigned faceJoint=0;
    BodyPose stand; std::vector<BodyPose> wait; // wait: the model's own "wait" clip, one pose per frame
    std::vector<BodyPose> idle; // looping idle used by the animated preview (see BodyResources)
    // Joint world matrices for a pose; parents precede children in MDL0 order.
    std::vector<BodyMatrix> World(const BodyPose&pose)const{std::vector<BodyMatrix> world(joints.size());for(size_t i=0;i<joints.size();i++){auto local=BodyMatrix::SRT(pose.at(i));world[i]=joints[i].parent>=0?world.at(size_t(joints[i].parent))*local:local;}return world;}
    // Idle pose at a fractional frame, blending neighbouring frames and wrapping at the loop.
    BodyPose IdlePose(float frame)const{if(idle.empty())return stand;float count=float(idle.size()),f=std::fmod(std::fmod(frame,count)+count,count);size_t a=size_t(f)%idle.size(),b=(a+1)%idle.size();float t=f-std::floor(f);BodyPose out(joints.size());for(size_t j=0;j<joints.size();j++)for(int k=0;k<9;k++)out[j][k]=idle[a][j][k]+(idle[b][j][k]-idle[a][j][k])*t;return out;}
    Mesh Skin(const BodyPart&part,const std::vector<BodyMatrix>&world)const{Mesh mesh=part.mesh;for(size_t i=0;i<part.local.size();i++){const auto&m=world.at(part.joint[i]);const auto&q=part.local[i];auto p=m.Apply({q.x,q.y,q.z}),n=m.Apply({q.nx,q.ny,q.nz},true);auto&v=mesh.triangles[i];v.x=p[0];v.y=p[1];v.z=p[2];v.nx=n[0];v.ny=n[1];v.nz=n[2];}return mesh;}
};
// MKW has no continuous body scaling: height + weight picks one of three body models.
// Game rule (RMCP01 0x80525FF4): sum > 150 is large, sum > 104 is medium, otherwise small.
enum class MiiBuild : unsigned { Small, Medium, Large };
inline MiiBuild BuildFor(unsigned height,unsigned weight){unsigned sum=height+weight;return sum>150?MiiBuild::Large:sum>104?MiiBuild::Medium:MiiBuild::Small;}
class BodyResources {
    struct Entry { std::string name;size_t offset; };
    using Matrix = BodyMatrix;
    std::array<std::array<BodyModel,2>,3> models;
    static float F(ResourceReader r,size_t p){float f=std::bit_cast<float>(r.U32(p));if(!std::isfinite(f))throw std::invalid_argument("Invalid Mii body coordinate.");return f;}
    static std::string Name(ResourceReader r,size_t p){std::string s;for(unsigned i=0;i<256;i++){auto c=r.U8(p+i);if(!c)return s;s+=char(c);}throw std::invalid_argument("Invalid Mii body name.");}
    static std::vector<Entry> Dictionary(ResourceReader r,size_t p){std::vector<Entry>d;if(!p)return d;auto n=r.U32(p+4);if(n>1024)throw std::invalid_argument("Invalid body resource dictionary.");for(unsigned i=0;i<n;i++){size_t e=p+24+i*16;d.push_back({Name(r,p+r.U32(e+8)),p+r.U32(e+12)});}return d;}
    static size_t Find(const std::vector<Entry>&d,const std::string&name){for(auto&e:d)if(e.name==name)return e.offset;throw std::invalid_argument("Missing Mii body resource: "+name);}
    static Matrix SRT(const std::array<float,9>&a){return BodyMatrix::SRT(a);}
    // One CHR0 component at an integer frame. Keyed formats (I4, I6, I12) use Hermite segments with
    // per-frame tangents; format 6 is one float per frame. Layouts follow BrawlBox's CHR0 reader.
    static float Keyed(ResourceReader r,size_t t,unsigned fmt,unsigned frame){
        if(fmt==6)return F(r,t+4*size_t(frame));
        struct Key{float frame,value,tangent;};std::vector<Key> keys;unsigned count=r.U16(t);if(!count||count>1024)throw std::invalid_argument("Invalid Mii body animation.");
        for(unsigned k=0;k<count;k++){
            if(fmt==1){auto w=r.U32(t+16+4*size_t(k));keys.push_back({float(w>>24),F(r,t+12)+F(r,t+8)*float((w>>12)&0xfff),float(int32_t(w<<20)>>20)/32.f});}
            else if(fmt==2){size_t q=t+16+6*size_t(k);keys.push_back({r.U16(q)/32.f,F(r,t+12)+F(r,t+8)*r.U16(q+2),int16_t(r.U16(q+4))/256.f});}
            else if(fmt==3){size_t q=t+8+12*size_t(k);keys.push_back({F(r,q),F(r,q+4),F(r,q+8)});}
            else throw std::invalid_argument("Unsupported Mii body animation.");
        }
        float f=float(frame);if(f<=keys.front().frame)return keys.front().value;if(f>=keys.back().frame)return keys.back().value;
        size_t i=0;while(i+1<keys.size()&&keys[i+1].frame<=f)i++;const auto&a=keys[i],&b=keys[i+1];float span=b.frame-a.frame,u=(f-a.frame)/span,u2=u*u,u3=u2*u;
        return a.value*(2*u3-3*u2+1)+b.value*(3*u2-2*u3)+span*(a.tangent*(u3-2*u2+u)+b.tangent*(u3-u2));
    }
    // A CHR0 clip sampled at each frame, by node name. Channels a node omits are identity (1/0).
    static std::vector<std::map<std::string,std::array<float,9>>> Clip(ResourceReader r,size_t anim){
        unsigned frames=r.U16(anim+0x20);if(!frames||frames>600)throw std::invalid_argument("Invalid Mii body animation length.");
        std::vector<std::map<std::string,std::array<float,9>>> out(frames);
        for(auto&e:Dictionary(r,anim+r.U32(anim+16))){auto flags=r.U32(e.offset+4);
            for(unsigned frame=0;frame<frames;frame++){size_t p=e.offset+8;std::array<float,9>a{1,1,1,0,0,0,0,0,0};
                auto track=[&](unsigned fmt,bool constant){float value=constant||!fmt?F(r,p):Keyed(r,e.offset+r.U32(p),fmt,frame);p+=4;return value;};
                if(!(flags&0x8a)){a[0]=track((flags>>25)&3,flags&(1<<13));if(flags&16)a[1]=a[2]=a[0];else {a[1]=track((flags>>25)&3,flags&(1<<14));a[2]=track((flags>>25)&3,flags&(1<<15));}}if(!(flags&0x126))for(int j=0;j<3;j++)a[3+j]=track((flags>>27)&7,flags&(1<<(16+j)));if(!(flags&0x246))for(int j=0;j<3;j++)a[6+j]=track((flags>>30)&3,flags&(1<<(19+j)));
                out[frame][e.name]=a;}}
        return out;
    }
    static Image Texture(ResourceReader r,size_t t){unsigned w=r.U16(t+28),h=r.U16(t+30);if(!w||!h||w>1024||h>1024||r.U32(t+32)!=14)throw std::invalid_argument("Unsupported Mii body texture.");Image out{w,h,std::vector<uint8_t>(w*h*4)};size_t p=t+r.U32(t+16);
        // GX CMPR: four 4x4 DXT1 blocks per 8x8 tile, big-endian endpoints/selectors.
        for(unsigned y=0;y<h;y+=8)for(unsigned x=0;x<w;x+=8)for(unsigned b=0;b<4;b++,p+=8){auto c0=r.U16(p),c1=r.U16(p+2);std::array<std::array<unsigned,4>,4> colors{};auto rgb=[](unsigned v){return std::array<unsigned,4>{((v>>11)&31)*255/31,((v>>5)&63)*255/63,(v&31)*255/31,255};};colors[0]=rgb(c0);colors[1]=rgb(c1);for(int c=0;c<3;c++){colors[2][c]=c0>c1?(2*colors[0][c]+colors[1][c])/3:(colors[0][c]+colors[1][c])/2;colors[3][c]=c0>c1?(colors[0][c]+2*colors[1][c])/3:0;}colors[2][3]=255;colors[3][3]=c0>c1?255:0;for(unsigned j=0;j<4;j++){auto bits=r.U8(p+4+j);for(unsigned i=0;i<4;i++){unsigned px=x+(b%2)*4+i,py=y+(b/2)*4+j;if(px>=w||py>=h)continue;auto c=colors[(bits>>(6-i*2))&3];for(unsigned k=0;k<4;k++)out.rgba[(py*w+px)*4+k]=c[k];}}}return out;
    }
    static BodyModel Decode(std::span<const uint8_t>data){ResourceReader r{data};if(r.U32(0)!=0x62726573)throw std::invalid_argument("Invalid Mii body BRRES.");auto root=Dictionary(r,r.U16(12)+8);auto md=Dictionary(r,Find(root,"3DModels(NW4R)"));size_t m=Find(md,"model");if(r.U32(m+8)!=11)throw std::invalid_argument("Unsupported Mii body model version.");auto section=[&](unsigned j){auto p=r.U32(m+16+4*j);return p?Dictionary(r,m+p):std::vector<Entry>{};};auto nodes=section(1);auto animations=Dictionary(r,Find(root,"AnmChr(NW4R)"));auto stand=Clip(r,Find(animations,"stand")).at(0);
        std::vector<std::map<std::string,std::array<float,9>>> wait;for(auto&e:animations)if(e.name=="wait")wait=Clip(r,e.offset);
        BodyModel result;BodyPose bind;std::map<size_t,unsigned> jointAt;std::map<unsigned,unsigned> matrixJoint;
        for(auto&e:nodes){std::array<float,9>a;for(int j=0;j<9;j++)a[j]=F(r,e.offset+32+j*4);int32_t parent=int32_t(r.U32(e.offset+92));
            unsigned index=unsigned(result.joints.size());result.joints.push_back({e.name,parent?int(jointAt.at(size_t(int64_t(e.offset)+parent))):-1});jointAt[e.offset]=index;matrixJoint[r.U32(e.offset+16)]=index;
            bind.push_back(a);result.stand.push_back(stand.contains(e.name)?stand.at(e.name):a);if(e.name=="face_1")result.faceJoint=index;}
        // Nodes a clip leaves out keep their bind transform, as in the stand pose.
        for(auto&frame:wait){BodyPose pose;for(size_t j=0;j<result.joints.size();j++){const auto&name=result.joints[j].name;pose.push_back(frame.contains(name)?frame.at(name):bind[j]);}result.wait.push_back(std::move(pose));}
        auto world=result.World(result.stand);result.neckY=world.at(result.faceJoint).v[7];result.neckZ=world.at(result.faceJoint).v[11];
        auto positions=section(2),normals=section(3),colors=section(4),uvs=section(5),materials=section(8),shapes=section(10);auto texDic=Dictionary(r,Find(root,"Textures(NW4R)"));Image texture,lightMap,highlightMap;for(auto&e:texDic){if(e.name.find("_all")!=std::string::npos)texture=Texture(r,e.offset);if(e.name=="lm_0")lightMap=Texture(r,e.offset);if(e.name=="lm_1")highlightMap=Texture(r,e.offset);}
        if(!texture.width||!lightMap.width||!highlightMap.width)throw std::invalid_argument("Missing Mii body material textures.");
        std::map<unsigned,unsigned> shapeMaterials;
        size_t draw=Find(section(0),"DrawOpa");
        for(unsigned command=0;command<1024;command++){
            unsigned op=r.U8(draw++);if(op==1)break;
            if(op!=4)throw std::invalid_argument("Unsupported Mii body draw command.");
            unsigned material=r.U16(draw),shape=r.U16(draw+2);draw+=7;
            if(material>=materials.size()||shape>=shapes.size())throw std::invalid_argument("Invalid Mii body draw material.");
            shapeMaterials[shape]=material;
            if(command==1023)throw std::invalid_argument("Unterminated Mii body draw commands.");
        }
        auto vector=[&](const std::vector<Entry>&buffers,int id,unsigned index,unsigned dim){if(id<0||unsigned(id)>=buffers.size())throw std::invalid_argument("Invalid body vertex buffer.");size_t b=buffers[id].offset;unsigned format=r.U32(b+24),shift=r.U8(b+28),stride=r.U8(b+29),count=r.U16(b+30);if(index>=count)throw std::invalid_argument("Invalid body vertex index.");size_t p=b+r.U32(b+8)+index*stride;std::array<float,3>v{};for(unsigned k=0;k<dim;k++){if(format==4)v[k]=F(r,p+k*4);else if(format==3)v[k]=int16_t(r.U16(p+k*2))/std::pow(2.f,shift);else if(format==2)v[k]=r.U16(p+k*2)/std::pow(2.f,shift);else if(format==1)v[k]=int8_t(r.U8(p+k))/std::pow(2.f,shift);else if(format==0)v[k]=r.U8(p+k)/std::pow(2.f,shift);else throw std::invalid_argument("Unsupported Mii body vertex format.");}return v;};
        for(size_t si=0;si<shapes.size();si++){size_t s=shapes[si].offset;BodyPart part;part.favoriteColor=materials.at(shapeMaterials.at(unsigned(si))).name=="mii_color";part.texture=texture;part.lightMap=lightMap;part.highlightMap=highlightMap;size_t pre=s+24+r.U32(s+32),end=pre+r.U32(s+28);uint32_t vcdLo=0,vcdHi=0;for(size_t p=pre;p<end;){unsigned cmd=r.U8(p++);if(cmd==0)continue;if(cmd==8){unsigned reg=r.U8(p++),value=r.U32(p);p+=4;if(reg==0x50)vcdLo=value;if(reg==0x60)vcdHi=value;}else if(cmd==0x10){size_t count=r.U16(p)+1;p+=4+count*4;r.Check(p,0);}else if(cmd==0x61)p+=4;else throw std::invalid_argument("Unsupported body vertex setup.");}
            std::array<unsigned,21> desc{};for(int j=0;j<9;j++)desc[j]=(vcdLo>>j)&1;for(int j=9;j<13;j++)desc[j]=(vcdLo>>(9+(j-9)*2))&3;for(int j=13;j<21;j++)desc[j]=(vcdHi>>((j-13)*2))&3;
            std::array<unsigned,10> slots{};int fixed=int32_t(r.U32(s+8));size_t p=s+36+r.U32(s+44),stop=p+r.U32(s+40);while(p<stop){unsigned cmd=r.U8(p++);if(!cmd)continue;if(cmd==0x20||cmd==0x28||cmd==0x30||cmd==0x38){unsigned index=r.U16(p),address=r.U16(p+2)&0xfff;p+=4;if(cmd==0x20){unsigned slot=address/12;if(slot>=slots.size())throw std::invalid_argument("Invalid body matrix slot.");slots[slot]=index;}continue;}if(cmd<0x80||cmd>0xbf)throw std::invalid_argument("Unsupported Mii body primitive.");unsigned count=r.U16(p);p+=2;std::vector<Mesh::Vertex>v,vl;std::vector<unsigned>vj;for(unsigned i=0;i<count;i++){std::array<unsigned,21> index{};for(int j=0;j<21;j++)if(desc[j]){if(desc[j]==1&&j>=9)throw std::invalid_argument("Direct body attributes unsupported.");index[j]=desc[j]==3?r.U16(p):r.U8(p);p+=desc[j]==3?2:1;}auto pos=vector(positions,int16_t(r.U16(s+72)),index[9],3),n=vector(normals,int16_t(r.U16(s+74)),index[10],3),uv=vector(uvs,int16_t(r.U16(s+80)),index[13],2);unsigned matrix=fixed>=0?unsigned(fixed):slots.at(index[0]/3);unsigned joint=matrixJoint.at(matrix);const auto&mat=world.at(joint);auto localPos=pos,localNormal=n;pos=mat.Apply(pos);n=mat.Apply(n,true);Mesh::Vertex q{pos[0],pos[1],pos[2],n[0],n[1],n[2],uv[0],uv[1]};if(desc[11]){size_t b=colors.at(int16_t(r.U16(s+76))).offset;if(index[11]>=r.U16(b+30)||r.U32(b+24)!=5)throw std::invalid_argument("Invalid body color.");size_t c=b+r.U32(b+8)+index[11]*r.U8(b+28);q.red=r.U8(c)/255.f;q.green=r.U8(c+1)/255.f;q.blue=r.U8(c+2)/255.f;q.alpha=r.U8(c+3)/255.f;}v.push_back(q);auto l=q;l.x=localPos[0];l.y=localPos[1];l.z=localPos[2];l.nx=localNormal[0];l.ny=localNormal[1];l.nz=localNormal[2];vl.push_back(l);vj.push_back(joint);}
                auto tri=[&](unsigned a,unsigned b,unsigned c){part.mesh.triangles.insert(part.mesh.triangles.end(),{v.at(a),v.at(b),v.at(c)});part.local.insert(part.local.end(),{vl.at(a),vl.at(b),vl.at(c)});part.joint.insert(part.joint.end(),{vj.at(a),vj.at(b),vj.at(c)});};switch(cmd&0xf8){case 0x80:for(unsigned j=0;j+3<count;j+=4){tri(j,j+1,j+2);tri(j,j+2,j+3);}break;case 0x90:for(unsigned j=0;j+2<count;j+=3)tri(j,j+1,j+2);break;case 0x98:for(unsigned j=2;j<count;j++)tri(j-2+j%2,j-1-j%2,j);break;case 0xa0:for(unsigned j=2;j<count;j++)tri(0,j-1,j);break;default:throw std::invalid_argument("Unsupported body primitive type.");}}
            result.parts.push_back(std::move(part));}return result;
    }
public:
    explicit BodyResources(std::span<const uint8_t>archive){std::vector<uint8_t> unpacked;if(ResourceReader{archive}.U32(0)==0x59617a30){ResourceReader r{archive};auto n=r.U32(4);if(n>16*1024*1024)throw std::invalid_argument("Oversized body archive.");size_t p=16;while(unpacked.size()<n){unsigned bits=r.U8(p++);for(unsigned b=0;b<8&&unpacked.size()<n;b++){if(bits&(128>>b))unpacked.push_back(r.U8(p++));else{unsigned a=r.U8(p++),c=r.U8(p++),distance=((a&15)<<8)+c+1,length=a>>4;length=length?length+2:r.U8(p++)+18;if(distance>unpacked.size()||length>n-unpacked.size())throw std::invalid_argument("Invalid compressed body archive.");for(unsigned k=0;k<length;k++)unpacked.push_back(unpacked[unpacked.size()-distance]);}}}archive=unpacked;}ResourceReader r{archive};if(r.U32(0)!=0x55aa382d)throw std::invalid_argument("Invalid Mii body archive.");size_t root=r.U32(4),n=r.U32(root+8),strings=root+n*12;if(n>1024)throw std::invalid_argument("Invalid Mii body entries.");auto file=[&](const std::string&name)->std::pair<size_t,size_t>{for(unsigned i=1;i<n;i++){size_t e=root+i*12;auto word=r.U32(e);if(!(word>>24)&&Name(r,strings+(word&0xffffff))==name)return {r.U32(e+4),r.U32(e+8)};}throw std::invalid_argument("Missing imported Mii body resource: "+name);};
        // miiDispParam.bin entries run small, medium, large; each has male/female pairs for outfits A-C (identical in RMCP01).
        auto [params,paramsSize]=file("miiDispParam.bin");if(paramsSize<4+18*12||r.U32(params)<18)throw std::invalid_argument("Invalid Mii attachment parameters.");
        for(unsigned build=0;build<3;build++)for(unsigned gender=0;gender<2;gender++){auto [offset,size]=file(std::string(build==0?"sa":build==1?"ma":"la")+(gender?"_mii_f.brres":"_mii_m.brres"));auto&model=models[build][gender];model=Decode(r.Slice(offset,size));
            for(unsigned j=0;j<3;j++)model.headAttachment[j]=F(r,params+4+(build*6+gender)*12+j*4);if(!(model.headAttachment[0]>0))throw std::invalid_argument("Invalid Mii head scale.");}
        // Only the medium models carry a looping "wait" (50 frames). Small and large get its motion as
        // per-frame changes on their own base pose: large's one-frame "wait" (arms down, like medium's
        // loop) and small's "stand" (its one-frame "wait" is a raised-arm wave). Same 15-joint skeleton.
        for(unsigned gender=0;gender<2;gender++){const auto&medium=models[1][gender];if(medium.wait.size()<2)continue;
            for(unsigned build=0;build<3;build++){auto&model=models[build][gender];if(build==1){model.idle=model.wait;continue;}
                bool same=model.joints.size()==medium.joints.size();for(size_t j=0;same&&j<model.joints.size();j++)same=model.joints[j].name==medium.joints[j].name;if(!same)continue;
                BodyPose base=build==2&&model.wait.size()==1?model.wait[0]:model.stand;float ratio=model.neckY/medium.neckY;
                for(const auto&frame:medium.wait){BodyPose pose=base;for(size_t j=0;j<pose.size();j++)for(int k=0;k<9;k++){float from=medium.wait[0][j][k],to=frame[j][k];pose[j][k]=k<3?base[j][k]*(from!=0?to/from:1):base[j][k]+(to-from)*(k>=6?ratio:1);}model.idle.push_back(std::move(pose));}}}
    }
    const BodyModel&Model(bool female,MiiBuild build=MiiBuild::Medium)const{return models[unsigned(build)][female?1:0];}
};
}
