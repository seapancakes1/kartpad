#import <MetalKit/MetalKit.h>
#include <simd/simd.h>
// The game products are linked by the wiicompiled runtime's CMake, which does not
// list these frameworks; ask the linker for them from the file that needs them.
__asm__(".linker_option \"-framework\", \"MetalKit\"");
__asm__(".linker_option \"-framework\", \"CoreGraphics\"");
__asm__(".linker_option \"-framework\", \"QuartzCore\""); // CACurrentMediaTime for the idle animation
#include "kartpad/mii/scene.h"
#include <random>
struct KPMiiGPUVertex { simd_float4 position, normal; simd_float2 uv; simd_float4 color; };
struct KPMiiUniform { simd_float4x4 mvp, model; simd_float4 color; float textured, unlit, bodyMaterial, alphaThreshold; };
// GPU copies of one scene. The preview worker makes them (Metal resource creation is thread-safe),
// so installing a new scene on the main thread, which the game shares, is only a swap.
@interface KPMiiGPUScene : NSObject {
@public
    std::shared_ptr<kartpad::mii::PreviewScene> scene;
    NSMutableArray<id<MTLBuffer>> *buffers;
    NSMutableArray *textures, *lightMaps, *highlightMaps;
    NSMutableDictionary<NSNumber*,NSArray<id<MTLBuffer>>*> *ring;
    id blinkTexture, smileTexture;
}
- (instancetype)initWithScene:(std::shared_ptr<kartpad::mii::PreviewScene>)scene device:(id<MTLDevice>)device;
@end
@implementation KPMiiGPUScene
- (instancetype)initWithScene:(std::shared_ptr<kartpad::mii::PreviewScene>)value device:(id<MTLDevice>)device {
    if(!(self=[super init]))return nil;
    scene=value;buffers=[NSMutableArray array];textures=[NSMutableArray array];lightMaps=[NSMutableArray array];highlightMaps=[NSMutableArray array];ring=[NSMutableDictionary dictionary];
    if(!scene||!device)return self;
    for(const auto&part:scene->parts){
        std::vector<KPMiiGPUVertex> vertices;vertices.reserve(part.mesh.triangles.size());
        for(auto v:part.mesh.triangles)vertices.push_back({{v.x,v.y,v.z,1},{v.nx,v.ny,v.nz,0},{v.u,v.v},{v.red,v.green,v.blue,v.alpha}});
        [buffers addObject:[device newBufferWithBytes:vertices.data() length:vertices.size()*sizeof(KPMiiGPUVertex) options:MTLResourceStorageModeShared]];
        auto upload=[&](const kartpad::mii::Image &image,BOOL premultiply)->id {
            if(!image.width)return NSNull.null;
            auto pixels=image.rgba;
            if(premultiply)for(size_t i=0;i<pixels.size();i+=4)for(unsigned c=0;c<3;c++)pixels[i+c]=uint8_t(unsigned(pixels[i+c])*pixels[i+3]/255);
            auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:image.width height:image.height mipmapped:NO];
            id<MTLTexture> texture=[device newTextureWithDescriptor:d];
            [texture replaceRegion:MTLRegionMake2D(0,0,image.width,image.height) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:image.width*4];
            return texture;
        };
        [textures addObject:upload(part.texture,!part.bodyPart)];
        [lightMaps addObject:upload(part.lightMap,NO)];
        [highlightMaps addObject:upload(part.highlightMap,NO)];
        if(&part-&scene->parts[0]==ptrdiff_t(scene->maskPart)){blinkTexture=upload(scene->blinkMask,YES);smileTexture=upload(scene->smileMask,YES);}
    }
    if(scene->Animated())for(size_t i:scene->rig.parts){NSUInteger length=buffers[i].length;NSMutableArray *copies=[NSMutableArray array];for(int k=0;k<3;k++)[copies addObject:[device newBufferWithBytes:buffers[i].contents length:length options:MTLResourceStorageModeShared]];ring[@(i)]=copies;}
    return self;
}
@end
// The preview's render pipeline, built once per device off the main thread: compiling the shader
// took about 170 ms of the main thread (the game's, on the Mac) the first time an editor opened.
// The Miis screen starts it when it opens; each preview draws once it is ready. Main thread only.
static NSString *KPMiiShaderSource(){
    return @R"METAL(
#include <metal_stdlib>
using namespace metal;
struct V { float4 p; float4 n; float2 uv; float4 color; };
struct U { float4x4 mvp; float4x4 model; float4 color; float textured; float unlit; float bodyMaterial; float alphaThreshold; };
struct O { float4 p [[position]]; float3 n; float2 uv; float4 color; };
vertex O miiVertex(uint i [[vertex_id]], const device V *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
    O o; o.p=u.mvp*v[i].p; o.n=(u.model*v[i].n).xyz; o.uv=v[i].uv; o.color=v[i].color; return o;
}
fragment float4 miiFragment(O o [[stage_in]], constant U &u [[buffer(1)]],
                           texture2d<float> t [[texture(0)]], texture2d<float> lm [[texture(1)]],
                           texture2d<float> hm [[texture(2)]], sampler s [[sampler(0)]]) {
    float3 n=normalize(o.n);
    if(u.bodyMaterial>0.5) {
        // NW4R MiiBody TEV: vertex alpha is a lighting coefficient; texture alpha masks highlights.
        // Neither is surface transparency; the material's alpha test drops the atlas's transparent texels.
        // Both body sections use the same diffuse atlas.
        float2 env=float2(n.x,-n.y)*0.5+0.5;
        float4 diffuse=t.sample(s,o.uv);
        if(diffuse.a<u.alphaThreshold)discard_fragment();
        float3 lighting=saturate(o.color.rgb+lm.sample(s,env).rgb*o.color.a);
        float3 rgb=saturate(diffuse.rgb*lighting)*u.color.rgb;
        rgb=saturate(rgb+hm.sample(s,env).rgb*diffuse.a);
        return float4(rgb,1);
    }
    float4 c=u.color*o.color;
    if(u.textured>0.5) { float4 sample=t.sample(s,o.uv); sample.rgb/=max(sample.a,0.0001); c*=sample; }
    if(c.a<0.006)discard_fragment();
    float light=(u.unlit>0.5||length(o.n)<0.001)?1.0:0.72+0.28*max(0.0,dot(n,normalize(float3(-0.3,0.5,0.8))));
    return float4(c.rgb*light,c.a);
}
)METAL";
}
static void KPMiiPreparePipeline(id<MTLDevice> device,void(^ready)(id<MTLRenderPipelineState> pipeline)){
    static id<MTLDevice> built;static id<MTLRenderPipelineState> pipeline;static NSMutableArray *waiting;static BOOL compiling;
    if(!device)return;
    if(device==built&&pipeline){if(ready)ready(pipeline);return;}
    if(!waiting)waiting=[NSMutableArray array];
    if(ready)[waiting addObject:ready];
    if(compiling&&device==built)return;
    built=device;pipeline=nil;compiling=YES;
    auto finish=^(id<MTLRenderPipelineState> state,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        if(device!=built)return;
        if(error)NSLog(@"Mii preview pipeline: %@",error.localizedDescription);
        pipeline=state;compiling=NO;NSArray *callbacks=waiting;waiting=[NSMutableArray array];
        if(state)for(void(^callback)(id<MTLRenderPipelineState>) in callbacks)callback(state);
    });};
    [device newLibraryWithSource:KPMiiShaderSource() options:nil completionHandler:^(id<MTLLibrary> library,NSError *error){
        if(!library){finish(nil,error);return;}
        MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
        p.vertexFunction=[library newFunctionWithName:@"miiVertex"];p.fragmentFunction=[library newFunctionWithName:@"miiFragment"];
        p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;p.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;p.rasterSampleCount=4;
        auto attachment=p.colorAttachments[0];attachment.blendingEnabled=YES;
        attachment.sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;attachment.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor=MTLBlendFactorOne;attachment.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        [device newRenderPipelineStateWithDescriptor:p completionHandler:^(id<MTLRenderPipelineState> state,NSError *failure){finish(state,failure);}];
    }];
}
@interface KPMiiMetalPreview : MTKView <MTKViewDelegate> {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _opaqueDepth, _overlayDepth;
    NSMutableArray<id<MTLSamplerState>> *_samplers;
    NSMutableArray<id<MTLBuffer>> *_buffers;
    NSMutableArray *_textures, *_lightMaps, *_highlightMaps;
    std::shared_ptr<kartpad::mii::PreviewScene> _scene;
    // Animation: per-body-part rings of three vertex buffers re-posed each frame, gated by a semaphore.
    NSMutableDictionary<NSNumber*,NSArray<id<MTLBuffer>>*> *_ring;
    NSUInteger _ringIndex;
    dispatch_semaphore_t _inFlight;
    id _blinkTexture,_smileTexture;
    CFTimeInterval _start,_nextBlink,_blinkUntil,_smileUntil,_interactionAt,_frontStart;
    float _frontFrom;
    BOOL _reduceMotion,_visible;
    std::mt19937 _random;
}
@property(nonatomic) float yaw;
@property(nonatomic) BOOL fullBody;
// Idle animation: game "wait" loop on the body, RFL blink and smile on the face, and a gentle head sway.
@property(nonatomic) BOOL animated;
- (void)installScene:(KPMiiGPUScene*)scene;
- (void)react;
- (void)faceFront;
- (void)noteInteraction;
@end
@implementation KPMiiMetalPreview
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame device:MTLCreateSystemDefaultDevice()])){
        self.delegate=self; self.paused=YES; self.enableSetNeedsDisplay=YES; self.preferredFramesPerSecond=60;
        _inFlight=dispatch_semaphore_create(3);_random.seed(std::random_device{}());_start=CACurrentMediaTime();_nextBlink=_start+2;_visible=YES;
        self.colorPixelFormat=MTLPixelFormatBGRA8Unorm; self.depthStencilPixelFormat=MTLPixelFormatDepth32Float;
        self.sampleCount=4;self.clearColor=MTLClearColorMake(.925,.947,.945,1);
        _queue=[self.device newCommandQueue];
        MTLDepthStencilDescriptor *depth=[MTLDepthStencilDescriptor new];depth.depthCompareFunction=MTLCompareFunctionLessEqual;depth.depthWriteEnabled=YES;_opaqueDepth=[self.device newDepthStencilStateWithDescriptor:depth];depth.depthWriteEnabled=NO;_overlayDepth=[self.device newDepthStencilStateWithDescriptor:depth];
        _samplers=[NSMutableArray array];
        const MTLSamplerAddressMode modes[]={MTLSamplerAddressModeClampToEdge,MTLSamplerAddressModeRepeat,MTLSamplerAddressModeMirrorRepeat};
        if(self.device)for(unsigned t=0;t<3;t++)for(unsigned s=0;s<3;s++){
            MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.minFilter=MTLSamplerMinMagFilterLinear;sampler.magFilter=MTLSamplerMinMagFilterLinear;sampler.sAddressMode=modes[s];sampler.tAddressMode=modes[t];[_samplers addObject:[self.device newSamplerStateWithDescriptor:sampler]];
        }
#if TARGET_OS_OSX
        self.wantsLayer=YES;self.layer.cornerRadius=12;self.layer.masksToBounds=YES;
        [self setAccessibilityLabel:@"Mii preview. Drag to rotate."];
#else
        self.layer.cornerRadius=12;self.layer.masksToBounds=YES;
        self.isAccessibilityElement=YES;self.accessibilityLabel=@"Mii preview";self.accessibilityHint=@"Use the rotation buttons to inspect all sides.";
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(pan:)]];
#endif
#if TARGET_OS_OSX
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(motionPreferenceChanged) name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
#else
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(motionPreferenceChanged) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(visibilityChanged) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(visibilityChanged) name:UIApplicationDidBecomeActiveNotification object:nil];
#endif
        [self motionPreferenceChanged];
        // Drawn once the shared pipeline is ready (KPMiiPreparePipeline); until then the view stays clear.
        __weak KPMiiMetalPreview *weak=self;
        KPMiiPreparePipeline(self.device,^(id<MTLRenderPipelineState> pipeline){KPMiiMetalPreview *view=weak;if(!view)return;view->_pipeline=pipeline;[view updateRunning];[view redraw];});
    }return self;
}
- (void)dealloc{
#if TARGET_OS_OSX
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
#endif
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)motionPreferenceChanged{
#if TARGET_OS_OSX
    _reduceMotion=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
#else
    _reduceMotion=UIAccessibilityIsReduceMotionEnabled();
#endif
    [self updateRunning];
}
// The view only renders continuously while animating, on screen and in an active app.
- (void)visibilityChanged{
#if TARGET_OS_OSX
    _visible=self.window&&(self.window.occlusionState&NSWindowOcclusionStateVisible);
#else
    _visible=self.window&&UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground&&UIApplication.sharedApplication.applicationState!=UIApplicationStateInactive;
#endif
    [self updateRunning];
}
#if TARGET_OS_OSX
- (void)viewDidMoveToWindow{[super viewDidMoveToWindow];[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];if(self.window)[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(visibilityChanged) name:NSWindowDidChangeOcclusionStateNotification object:self.window];[self visibilityChanged];}
#else
- (void)didMoveToWindow{[super didMoveToWindow];[self visibilityChanged];}
#endif
- (void)updateRunning{BOOL run=self.animated&&_visible&&_scene;self.enableSetNeedsDisplay=!run;self.paused=!run;if(!run)[self redraw];}
- (void)setAnimated:(BOOL)value{_animated=value;if(!value)_smileUntil=_blinkUntil=_frontStart=0;[self updateRunning];}
- (void)react{if(self.animated)_smileUntil=CACurrentMediaTime()+1.0;}
- (void)noteInteraction{_interactionAt=CACurrentMediaTime();_frontStart=0;}
// Ease the turntable back to the front; Reduce Motion snaps instead.
- (void)faceFront{if(!self.animated)return;float yaw=std::remainder(self.yaw,float(2*M_PI));if(std::abs(yaw)<.01f){_yaw=0;return;}if(_reduceMotion||!_visible){self.yaw=0;return;}_frontFrom=yaw;_frontStart=CACurrentMediaTime();}
- (void)installScene:(KPMiiGPUScene*)gpu {
    _scene=gpu?gpu->scene:nullptr;_blinkTexture=_smileTexture=nil;
    if(!_scene||!self.device||gpu->buffers.count!=_scene->parts.size()){_buffers=[NSMutableArray array];_textures=[NSMutableArray array];_lightMaps=[NSMutableArray array];_highlightMaps=[NSMutableArray array];_ring=[NSMutableDictionary dictionary];[self updateRunning];return;}
    _buffers=gpu->buffers;_textures=gpu->textures;_lightMaps=gpu->lightMaps;_highlightMaps=gpu->highlightMaps;_ring=gpu->ring;_blinkTexture=gpu->blinkTexture;_smileTexture=gpu->smileTexture;
    [self updateRunning];
}
- (void)redraw {
#if TARGET_OS_OSX
    self.needsDisplay=YES;
#else
    [self setNeedsDisplay];
#endif
}
- (void)setYaw:(float)value {_yaw=value;[self redraw];}
- (void)setFullBody:(BOOL)value {_fullBody=value;[self redraw];}
- (void)setClearColor:(MTLClearColor)value {[super setClearColor:value];[self redraw];}
#if TARGET_OS_OSX
- (void)mouseDragged:(NSEvent*)event{[self noteInteraction];self.yaw+=event.deltaX*.015f;}
#else
- (void)pan:(UIPanGestureRecognizer*)gesture {[self noteInteraction];CGPoint delta=[gesture translationInView:self];self.yaw+=delta.x*.015f;[gesture setTranslation:CGPointZero inView:self];}
#endif
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size { [self redraw]; }
static simd_float4x4 KPMiiMatrix(const std::array<float,12>&m){simd_float4x4 out=matrix_identity_float4x4;for(int c=0;c<4;c++)out.columns[c]={m[c],m[4+c],m[8+c],c==3?1.f:0.f};return out;}
static simd_float4x4 KPMiiRotation(float yaw,float pitch,float roll){
    float cy=cosf(yaw),sy=sinf(yaw),cp=cosf(pitch),sp=sinf(pitch),cr=cosf(roll),sr=sinf(roll);
    simd_float4x4 y=matrix_identity_float4x4,p=matrix_identity_float4x4,r=matrix_identity_float4x4;
    y.columns[0]={cy,0,-sy,0};y.columns[2]={sy,0,cy,0};p.columns[1]={0,cp,sp,0};p.columns[2]={0,-sp,cp,0};r.columns[0]={cr,sr,0,0};r.columns[1]={-sr,cr,0,0};
    return simd_mul(y,simd_mul(p,r));
}
- (void)encodeScene:(id<MTLRenderCommandEncoder>)encoder width:(float)width height:(float)height {
    float aspect=std::max(.1f,width/height);
    // Animation state for this frame. Reduce Motion keeps blink and smile but drops body, sway and turns.
    CFTimeInterval now=CACurrentMediaTime();BOOL animate=self.animated&&_scene,move=animate&&!_reduceMotion;
    if(_frontStart>0){float t=std::min(1.,(now-_frontStart)/.45);float ease=1-(1-t)*(1-t)*(1-t);_yaw=_frontFrom*(1-ease);if(t>=1){_yaw=0;_frontStart=0;}}
    if(animate&&now>=_nextBlink){std::uniform_real_distribution<double> wait(2.4,6.0),chance(0,1);_blinkUntil=now+.11;_nextBlink=chance(_random)<.15?now+.3:now+wait(_random);}
    id faceTexture=animate&&now<_smileUntil?_smileTexture:animate&&now<_blinkUntil?_blinkTexture:nil;
    std::array<float,12> neck{1,0,0,0,0,1,0,0,0,0,1,0};std::vector<kartpad::mii::Mesh> bodyMeshes;
    BOOL posed=move&&self.fullBody&&_scene&&_scene->Animated()&&_ring.count;
    if(posed){neck=_scene->Pose(float((now-_start)*60),bodyMeshes); // one CHR0 frame per 60 Hz tick (NW4R default rate)
        for(size_t k=0;k<_scene->rig.parts.size()&&k<bodyMeshes.size();k++){id<MTLBuffer> buffer=_ring[@(_scene->rig.parts[k])][_ringIndex%3];auto *out=(KPMiiGPUVertex*)buffer.contents;size_t n=std::min(bodyMeshes[k].triangles.size(),size_t(buffer.length/sizeof(KPMiiGPUVertex)));for(size_t v=0;v<n;v++){const auto&q=bodyMeshes[k].triangles[v];out[v].position={q.x,q.y,q.z,1};out[v].normal={q.nx,q.ny,q.nz,0};}}}
    // Head sway: a slow drift of a few degrees, fading out while the Mii is being turned by hand.
    float sway=0;if(move){double since=now-_interactionAt;sway=float(std::clamp((since-1.5)/1.5,0.,1.));sway=sway*sway*(3-2*sway);}
    double t=now-_start;simd_float4x4 headSway=KPMiiRotation(sway*float(.105*sin(t*2*M_PI/7.3)+.035*sin(t*2*M_PI/3.1)),sway*float(.035*sin(t*2*M_PI/5.2)),sway*float(.026*sin(t*2*M_PI/6.1)));
    simd_float4x4 head=simd_mul(KPMiiMatrix(neck),headSway);
    float center=_scene?(self.fullBody?(_scene->top+_scene->bottom)/2:(_scene->headTop+_scene->headBottom)/2):42;
    float half=_scene?(self.fullBody?(_scene->top-_scene->bottom)*.57f:(_scene->headTop-_scene->headBottom)*.56f):47;
    float cs=cosf(self.yaw),sn=sinf(self.yaw),horizontal=0;
    if(_scene)for(const auto &part:_scene->parts)if(self.fullBody||!part.bodyPart)for(const auto &v:part.mesh.triangles)horizontal=std::max(horizontal,std::abs(cs*v.x+sn*v.z));
    half=std::max(half,std::max(30.f,horizontal*1.08f)/aspect);
    simd_float4x4 model=matrix_identity_float4x4;
    model.columns[0]={cs,0,-sn,0};model.columns[2]={sn,0,cs,0};
    simd_float4x4 projection=matrix_identity_float4x4;
    projection.columns[0].x=1/(half*aspect);projection.columns[1].y=1/half;projection.columns[2].z=-1/300.f;projection.columns[3]={0,-center/half,.5,1};
    [encoder setRenderPipelineState:_pipeline];[encoder setFrontFacingWinding:MTLWindingClockwise];
    for(size_t i=0;_scene&&i<_scene->parts.size();i++){
        const auto&part=_scene->parts[i];if(part.bodyPart&&!self.fullBody)continue;simd_float4x4 world=part.bodyPart?model:simd_mul(model,head);KPMiiUniform u{};u.mvp=simd_mul(projection,world);u.model=world;u.color={part.color[0]/255.f,part.color[1]/255.f,part.color[2]/255.f,1};u.textured=part.texture.width?1:0;u.unlit=part.unlit;u.bodyMaterial=part.bodyPart;u.alphaThreshold=part.alphaThreshold;
        [encoder setCullMode:part.doubleSided?MTLCullModeNone:MTLCullModeBack];[encoder setDepthStencilState:part.translucent?_overlayDepth:_opaqueDepth];[encoder setVertexBuffer:posed&&_ring[@(i)]?_ring[@(i)][_ringIndex%3]:_buffers[i] offset:0 atIndex:0];[encoder setVertexBytes:&u length:sizeof(u) atIndex:1];[encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
        [encoder setFragmentSamplerState:_samplers[part.texture.wrapS+part.texture.wrapT*3] atIndex:0];
        if(part.texture.width)[encoder setFragmentTexture:i==_scene->maskPart&&faceTexture&&faceTexture!=NSNull.null?faceTexture:_textures[i] atIndex:0];else [encoder setFragmentTexture:nil atIndex:0];
        if(part.bodyPart){[encoder setFragmentTexture:_lightMaps[i] atIndex:1];[encoder setFragmentTexture:_highlightMaps[i] atIndex:2];}
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:part.mesh.triangles.size()];
    }
}
- (void)drawInMTKView:(MTKView*)view {
    if(!_pipeline)return;auto drawable=self.currentDrawable;auto pass=self.currentRenderPassDescriptor;if(!drawable||!pass)return;
    dispatch_semaphore_wait(_inFlight,DISPATCH_TIME_FOREVER);dispatch_semaphore_t inFlight=_inFlight;
    id<MTLCommandBuffer> command=[_queue commandBuffer];[command addCompletedHandler:^(id<MTLCommandBuffer>){dispatch_semaphore_signal(inFlight);}];auto encoder=[command renderCommandEncoderWithDescriptor:pass];
    [self encodeScene:encoder width:self.drawableSize.width height:self.drawableSize.height];
    [encoder endEncoding];[command presentDrawable:drawable];[command commit];_ringIndex++;
}
@end
