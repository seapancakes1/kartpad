#pragma once
#include "portrait.h"
#include "body.h"
namespace kartpad::mii {
struct ScenePart { Mesh mesh; Color color; Image texture; bool unlit=false; bool translucent=false; bool doubleSided=false; bool bodyPart=false; float alphaThreshold=0; Image lightMap, highlightMap; };
// What the animated preview needs to re-pose the body each frame, in head units like the parts.
struct PreviewRig {
    std::vector<BodyJoint> joints; std::vector<BodyPose> idle; BodyMatrix standFace, idleFace; unsigned face=0;
    std::vector<size_t> parts; std::vector<std::vector<Mesh::Vertex>> local; std::vector<std::vector<unsigned>> joint;
    std::array<float,3> origin{}; float inverse=1;
};
struct PreviewScene {
    std::vector<ScenePart> parts;
    // Face mask part and its RFL blink/smile variants (same mesh, other textures).
    size_t maskPart=SIZE_MAX; Image blinkMask, smileMask;
    PreviewRig rig;
    bool Animated()const{return rig.idle.size()>1;}
    // Re-poses the body for an idle frame into bodyMeshes (aligned with rig.parts) and returns the
    // head's 3x4 transform in head units. The head follows the neck joint's position (relative to
    // "stand", where it was placed) and only the loop's own turning (relative to the loop's first
    // frame): the neck joint's base orientation differs between clips, but the head stays upright.
    std::array<float,12> Pose(float frame,std::vector<Mesh>&bodyMeshes)const{
        BodyModel model;model.joints=rig.joints;model.idle=rig.idle;model.stand=rig.idle.empty()?BodyPose(rig.joints.size(),{1,1,1,0,0,0,0,0,0}):rig.idle[0];
        auto world=model.World(model.IdlePose(frame));bodyMeshes.resize(rig.parts.size());
        for(size_t i=0;i<rig.parts.size();i++){Mesh&mesh=bodyMeshes[i];mesh=parts.at(rig.parts[i]).mesh;
            for(size_t k=0;k<rig.local[i].size()&&k<mesh.triangles.size();k++){const auto&m=world.at(rig.joint[i][k]);const auto&q=rig.local[i][k];auto p=m.Apply({q.x,q.y,q.z}),n=m.Apply({q.nx,q.ny,q.nz},true);auto&v=mesh.triangles[k];
                v.x=p[0]*rig.inverse;v.y=(p[1]-rig.origin[1])*rig.inverse;v.z=(p[2]-rig.origin[2])*rig.inverse;v.nx=n[0];v.ny=n[1];v.nz=n[2];}}
        const auto&face=world.at(rig.face);auto turn=face*rig.idleFace.Inverse();std::array<float,12> head=turn.v;
        for(int row=0;row<3;row++)head[row*4+3]=rig.inverse*(face.v[row*4+3]-rig.standFace.v[row*4+3]);
        return head;
    }
    float bottom=-85, top=82, headBottom=0, headTop=82, headRadius=33, radius=33;
    void Add(const Mesh &mesh,Color color,float scale=1,float x=0,float y=0,float z=0,bool flip=false,const Image *texture=nullptr,bool unlit=false){
        if(mesh.triangles.empty())return;
        ScenePart part{mesh,color,texture?*texture:Image{},unlit};
        for(auto &v:part.mesh.triangles){v.x=x+v.x*scale*(flip?-1:1);v.y=y+v.y*scale;v.z=z+v.z*scale;if(flip)v.nx=-v.nx;}
        if(flip)for(size_t i=0;i<part.mesh.triangles.size();i+=3)std::swap(part.mesh.triangles[i+1],part.mesh.triangles[i+2]);
        parts.push_back(std::move(part));
    }
    static PreviewScene Build(const Resources &r,const Appearance&a,const BodyResources *body=nullptr){
        // Fields out of range draw as their nearest valid value (Appearance::Clamped).
        PreviewScene s;auto g=[&](size_t f){return a.Clamped(f);};
        Color skin=At(Skin,g(8)),shirt=At(Shirt,g(3));
        s.bottom=0;
        if(body){
            // The game picks the body by build and places the head at the neck plus the miiDispParam offset,
            // scaled by its head scale. Work in head units: shift the body to the head origin and divide by that scale.
            const auto&model=body->Model(g(0),BuildFor(g(5),g(6)));
            float inverse=1/model.headAttachment[0];
            s.rig.joints=model.joints;s.rig.idle=model.idle;s.rig.face=model.faceJoint;s.rig.standFace=model.World(model.stand).at(model.faceJoint);if(!model.idle.empty())s.rig.idleFace=model.World(model.idle[0]).at(model.faceJoint);
            s.rig.origin={0,model.neckY+model.headAttachment[1],model.neckZ+model.headAttachment[2]};s.rig.inverse=inverse;
            for(const auto&part:model.parts){s.rig.parts.push_back(s.parts.size());s.rig.local.push_back(part.local);s.rig.joint.push_back(part.joint);
                Mesh mesh=part.mesh;
                for(auto&v:mesh.triangles){v.x*=inverse;v.y=(v.y-model.neckY-model.headAttachment[1])*inverse;v.z=(v.z-model.neckZ-model.headAttachment[2])*inverse;s.bottom=std::min(s.bottom,v.y);}
                s.Add(mesh,part.favoriteColor?shirt:Color{255,255,255},1,0,0,0,false,part.texture.width?&part.texture:nullptr);s.parts.back().bodyPart=true;s.parts.back().lightMap=part.lightMap;s.parts.back().highlightMap=part.highlightMap;s.parts.back().alphaThreshold=part.alphaThreshold;
            }
        }
        const auto&face=r.Shape(3,g(7));
        auto faceTexture=Portrait::FaceTexture(r,a);
        s.Add(face,{255,255,255},1,0,0,0,false,&faceTexture);
        s.Add(r.Shape(0,g(38)),At(Hair,g(39)),1,face.transforms[3],face.transforms[4],face.transforms[5]);
        s.Add(r.Shape(5,g(11)),skin,1,face.transforms[6],face.transforms[7],face.transforms[8],g(13));
        s.Add(r.Shape(8,g(11)),At(Hair,g(12)),1,face.transforms[6],face.transforms[7],face.transforms[8],g(13));
        if(!r.Shape(16,g(11)).triangles.empty()){
            auto cap=Portrait::CapTexture(r,a);
            s.Add(r.Shape(16,g(11)),{255,255,255},1,face.transforms[6],face.transforms[7],face.transforms[8],g(13),&cap);
        }
        float scale=.4f+g(27)*.175f,y=face.transforms[1]+(8-int(g(28)))*1.5f;
        s.Add(r.Shape(13,g(26)),skin,scale,face.transforms[0],y,face.transforms[2]);
        auto mask=Portrait::FaceMask(r,a);size_t before=s.parts.size();s.Add(r.Shape(9,g(7)),{255,255,255},1,0,0,.02f,false,&mask,true);s.parts.back().translucent=true;
        if(s.parts.size()>before){s.maskPart=before;s.blinkMask=Portrait::FaceMask(r,a,Portrait::Expression::Blink);s.smileMask=Portrait::FaceMask(r,a,Portrait::Expression::Smile);}
        if(!r.Shape(14,g(26)).triangles.empty()){s.Add(r.Shape(14,g(26)),{0,0,0},scale,face.transforms[0],y,face.transforms[2]+.05f,false,&r.Texture(15,g(26)),true);s.parts.back().translucent=true;}
        if(g(33)){s.Add(r.Shape(6,0),At(Glasses,g(34)),.4f+.15f*g(35),face.transforms[0],5+face.transforms[1]+(11-int(g(36)))*1.5f,2+face.transforms[2],false,&r.Texture(7,g(33)),true);s.parts.back().translucent=true;s.parts.back().doubleSided=true;}
        for(const auto &part:s.parts)for(const auto &v:part.mesh.triangles){
            s.top=std::max(s.top,v.y);s.bottom=std::min(s.bottom,v.y);
            s.radius=std::max(s.radius,std::hypot(v.x,v.z));
            if(!part.bodyPart){s.headBottom=std::min(s.headBottom,v.y);s.headTop=std::max(s.headTop,v.y);s.headRadius=std::max(s.headRadius,std::hypot(v.x,v.z));}
        }
        return s;
    }
};
} // namespace kartpad::mii
