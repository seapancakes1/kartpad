#import <MetalKit/MetalKit.h>
#include <simd/simd.h>
#include "kartpad/mii/scene.h"
struct KPMiiGPUVertex { simd_float4 position, normal; simd_float2 uv; simd_float4 color; };
struct KPMiiUniform { simd_float4x4 mvp, model; simd_float4 color; float textured, unlit, bodyMaterial, padding; };
@interface KPMiiMetalPreview : MTKView <MTKViewDelegate> {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _opaqueDepth, _overlayDepth;
    NSMutableArray<id<MTLSamplerState>> *_samplers;
    NSMutableArray<id<MTLBuffer>> *_buffers;
    NSMutableArray *_textures, *_lightMaps, *_highlightMaps;
    std::shared_ptr<kartpad::mii::PreviewScene> _scene;
}
@property(nonatomic) float yaw;
@property(nonatomic) BOOL fullBody;
@property(nonatomic,copy) void (^rotationChanged)(float);
- (void)installScene:(std::shared_ptr<kartpad::mii::PreviewScene>)scene;
- (kartpad::mii::Image)renderImageWithWidth:(unsigned)width height:(unsigned)height;
@end
@implementation KPMiiMetalPreview
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame device:MTLCreateSystemDefaultDevice()])){
        self.delegate=self; self.paused=YES; self.enableSetNeedsDisplay=YES;
        self.colorPixelFormat=MTLPixelFormatBGRA8Unorm; self.depthStencilPixelFormat=MTLPixelFormatDepth32Float;
        self.sampleCount=4;self.clearColor=MTLClearColorMake(.925,.947,.945,1);
        _queue=[self.device newCommandQueue];
        NSString *source=@R"METAL(
#include <metal_stdlib>
using namespace metal;
struct V { float4 p; float4 n; float2 uv; float4 color; };
struct U { float4x4 mvp; float4x4 model; float4 color; float textured; float unlit; float bodyMaterial; float padding; };
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
        // Neither is surface transparency. Both body sections use the same diffuse atlas.
        float2 env=float2(n.x,-n.y)*0.5+0.5;
        float4 diffuse=t.sample(s,o.uv);
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
        NSError *error=nil;id<MTLLibrary> library=[self.device newLibraryWithSource:source options:nil error:&error];
        MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
        p.vertexFunction=[library newFunctionWithName:@"miiVertex"];p.fragmentFunction=[library newFunctionWithName:@"miiFragment"];
        p.colorAttachments[0].pixelFormat=self.colorPixelFormat;p.depthAttachmentPixelFormat=self.depthStencilPixelFormat;p.rasterSampleCount=4;
        auto attachment=p.colorAttachments[0];attachment.blendingEnabled=YES;attachment.sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;attachment.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;attachment.sourceAlphaBlendFactor=MTLBlendFactorOne;attachment.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        _pipeline=[self.device newRenderPipelineStateWithDescriptor:p error:&error];
        if(error)NSLog(@"Mii preview pipeline: %@",error.localizedDescription);
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
    }return self;
}
- (void)installScene:(std::shared_ptr<kartpad::mii::PreviewScene>)scene {
    _scene=scene;_buffers=[NSMutableArray array];_textures=[NSMutableArray array];_lightMaps=[NSMutableArray array];_highlightMaps=[NSMutableArray array];
    if(!scene||!self.device||!_pipeline){[self redraw];return;}
    for(const auto&part:scene->parts){
        std::vector<KPMiiGPUVertex> vertices;vertices.reserve(part.mesh.triangles.size());
        for(auto v:part.mesh.triangles)vertices.push_back({{v.x,v.y,v.z,1},{v.nx,v.ny,v.nz,0},{v.u,v.v},{v.red,v.green,v.blue,v.alpha}});
        [_buffers addObject:[self.device newBufferWithBytes:vertices.data() length:vertices.size()*sizeof(KPMiiGPUVertex) options:MTLResourceStorageModeShared]];
        auto upload=[&](const kartpad::mii::Image &image,BOOL premultiply)->id {
            if(!image.width)return NSNull.null;
            auto pixels=image.rgba;
            if(premultiply)for(size_t i=0;i<pixels.size();i+=4)for(unsigned c=0;c<3;c++)pixels[i+c]=uint8_t(unsigned(pixels[i+c])*pixels[i+3]/255);
            auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:image.width height:image.height mipmapped:NO];
            id<MTLTexture> texture=[self.device newTextureWithDescriptor:d];
            [texture replaceRegion:MTLRegionMake2D(0,0,image.width,image.height) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:image.width*4];
            return texture;
        };
        [_textures addObject:upload(part.texture,!part.bodyPart)];
        [_lightMaps addObject:upload(part.lightMap,NO)];
        [_highlightMaps addObject:upload(part.highlightMap,NO)];
    }
    [self redraw];
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
#if TARGET_OS_OSX
- (void)mouseDragged:(NSEvent*)event{self.yaw+=event.deltaX*.015f;if(self.rotationChanged)self.rotationChanged(self.yaw);}
#else
- (void)pan:(UIPanGestureRecognizer*)gesture {CGPoint delta=[gesture translationInView:self];self.yaw+=delta.x*.015f;[gesture setTranslation:CGPointZero inView:self];if(self.rotationChanged)self.rotationChanged(self.yaw);}
#endif
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size { [self redraw]; }
- (void)encodeScene:(id<MTLRenderCommandEncoder>)encoder width:(float)width height:(float)height {
    float aspect=std::max(.1f,width/height);
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
        const auto&part=_scene->parts[i];if(part.bodyPart&&!self.fullBody)continue;KPMiiUniform u{};u.mvp=simd_mul(projection,model);u.model=model;u.color={part.color[0]/255.f,part.color[1]/255.f,part.color[2]/255.f,1};u.textured=part.texture.width?1:0;u.unlit=part.unlit;u.bodyMaterial=part.bodyPart;
        [encoder setCullMode:part.doubleSided?MTLCullModeNone:MTLCullModeBack];[encoder setDepthStencilState:part.translucent?_overlayDepth:_opaqueDepth];[encoder setVertexBuffer:_buffers[i] offset:0 atIndex:0];[encoder setVertexBytes:&u length:sizeof(u) atIndex:1];[encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
        [encoder setFragmentSamplerState:_samplers[part.texture.wrapS+part.texture.wrapT*3] atIndex:0];
        if(part.texture.width)[encoder setFragmentTexture:_textures[i] atIndex:0];else [encoder setFragmentTexture:nil atIndex:0];
        if(part.bodyPart){[encoder setFragmentTexture:_lightMaps[i] atIndex:1];[encoder setFragmentTexture:_highlightMaps[i] atIndex:2];}
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:part.mesh.triangles.size()];
    }
}
- (void)drawInMTKView:(MTKView*)view {
    if(!_pipeline)return;auto drawable=self.currentDrawable;auto pass=self.currentRenderPassDescriptor;if(!drawable||!pass)return;
    id<MTLCommandBuffer> command=[_queue commandBuffer];auto encoder=[command renderCommandEncoderWithDescriptor:pass];
    [self encodeScene:encoder width:self.drawableSize.width height:self.drawableSize.height];
    [encoder endEncoding];[command presentDrawable:drawable];[command commit];
}
- (kartpad::mii::Image)renderImageWithWidth:(unsigned)width height:(unsigned)height {
    if(!_pipeline||!width||!height||width>2048||height>2048)throw std::runtime_error("Mii render unavailable.");
    auto outputDescriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];outputDescriptor.usage=MTLTextureUsageRenderTarget;outputDescriptor.storageMode=MTLStorageModeShared;auto output=[self.device newTextureWithDescriptor:outputDescriptor];
    auto msaaDescriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];msaaDescriptor.textureType=MTLTextureType2DMultisample;msaaDescriptor.sampleCount=4;msaaDescriptor.usage=MTLTextureUsageRenderTarget;msaaDescriptor.storageMode=MTLStorageModePrivate;auto msaa=[self.device newTextureWithDescriptor:msaaDescriptor];
    msaaDescriptor.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[self.device newTextureWithDescriptor:msaaDescriptor];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=msaa;pass.colorAttachments[0].resolveTexture=output;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionMultisampleResolve;pass.colorAttachments[0].clearColor=self.clearColor;pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;
    auto command=[_queue commandBuffer];auto encoder=[command renderCommandEncoderWithDescriptor:pass];[self encodeScene:encoder width:width height:height];[encoder endEncoding];[command commit];[command waitUntilCompleted];if(command.status==MTLCommandBufferStatusError)throw std::runtime_error("Mii rendering failed.");
    kartpad::mii::Image image{width,height,std::vector<uint8_t>(width*height*4)};[output getBytes:image.rgba.data() bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];for(size_t i=0;i<image.rgba.size();i+=4)std::swap(image.rgba[i],image.rgba[i+2]);return image;
}
@end
