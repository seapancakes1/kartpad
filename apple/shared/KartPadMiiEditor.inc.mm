#import "KartPadMiiEditor.h"
#import <CommonCrypto/CommonDigest.h>
#include "kartpad/mii/editor.h"
#include <memory>
#include <atomic>
#include "KartPadStyle.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
__asm__(".linker_option \"-framework\", \"UniformTypeIdentifiers\"");
#include "KartPadMiiPreview.inc.mm"
#include "KartPadMiiSounds.inc.mm"
static NSString *KPMiiResourcePath() {
#if TARGET_OS_OSX
#if defined(KARTPAD_MII_MANAGER_TESTING)
    return [SupportRoot() stringByAppendingPathComponent:@"GameData/files/contents/RFLRes01.arc"];
#else
    auto config = RuntimeConfigFile::LoadConfigFile();
    if (config.dvdRoot) {
        auto root = RuntimeConfigFile::ResolveRelativeToConfig(*config.dvdRoot);
        return
            [NSString stringWithUTF8String:(root / "files/contents/RFLRes01.arc").string().c_str()];
    }
#endif
#else
    NSString *support =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/KartPad"];
    NSString *config =
        [NSString stringWithContentsOfFile:[support stringByAppendingPathComponent:@"Config.toml"]
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*dvd_root\\s*=\\s*\"([^\"]+)\""
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:config ?: @""
                                                    options:0
                                                      range:NSMakeRange(0, config.length)];
    NSString *root = match ? [config substringWithRange:[match rangeAtIndex:1]] : @"GameData";
    if (!root.isAbsolutePath)
        root = [support stringByAppendingPathComponent:root];
    return [root stringByAppendingPathComponent:@"files/contents/RFLRes01.arc"];
#endif
    return nil;
}
static NSString *KPMiiSoundArchivePath(){return [[[KPMiiResourcePath() stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"sound/revo_kart.brsar"];}
static NSString *KPMiiDigest(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *s = [NSMutableString string];
    for (auto v : hash)
        [s appendFormat:@"%02x", v];
    return s;
}
static NSString *KPMiiName(NSData *data, NSUInteger offset) {
    return [NSString stringWithUTF8String:kartpad::mii::ReadMiiName(Bytes(data), offset).c_str()];
}
static BOOL KPMiiSetName(NSMutableData *data, NSString *name, NSUInteger offset) {
    NSData *bytes = [name dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    if (!bytes || bytes.length > 20)
        return NO;
    if (bytes.length && !kartpad::mii::ValidateUtf16BigEndianName(Bytes(bytes)))
        return NO;
    memset((uint8_t *)data.mutableBytes + offset, 0, 20);
    memcpy((uint8_t *)data.mutableBytes + offset, bytes.bytes, bytes.length);
    return YES;
}
// Wording and checks shared by the editor and the Miis screen, so names, files and restarts read
// the same everywhere. A name holds 10 UTF-16 units; NSString lengths count the same units.
static NSString *const KPMiiNameRule=@"Up to 10 characters. Emoji and some symbols take up more than one.";
static NSString *KPMiiNameCount(NSString *text){return [NSString stringWithFormat:@"%lu of 10 characters",(unsigned long)text.length];}
// nil when the name can be stored. An empty name is only a problem where one is required.
static NSString *KPMiiNameProblem(NSString *text,BOOL required){
    if(!text.length)return required?@"Enter a name.":nil;
    if(text.length>10)return @"This name is too long. Please shorten it.";
    NSData *bytes=[text dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    return bytes&&kartpad::mii::ValidateUtf16BigEndianName(Bytes(bytes))?nil:@"This name has a character a Mii can’t use.";
}
static NSString *KPMiiFileName(NSString *name){
    NSString *clean=[[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"-"];
    return [(clean.length?clean:@"Mii") stringByAppendingPathExtension:@"mii"];
}
// Mac restarts KartPad itself; iPhone and iPad are closed from the app switcher.
static NSString *KPMiiRestartAdvice(NSUInteger count){
#if TARGET_OS_OSX
    return count>1?@"Restart KartPad to apply them.":@"Restart KartPad to apply it.";
#else
    return count>1?@"Fully close KartPad from the app switcher and reopen it to apply them.":@"Fully close KartPad from the app switcher and reopen it to apply it.";
#endif
}
// A pending ghost import or save restore waits alone, so Mii changes wait for it.
static NSString *KPMiiRestartFirstTitle(){
#if TARGET_OS_OSX
    return @"Restart KartPad First";
#else
    return @"Reopen KartPad First";
#endif
}
static NSString *KPMiiRestartFirstMessage(){return [@"A ghost import or save restore is waiting for the next launch. " stringByAppendingString:KPMiiRestartAdvice(1)];}
// The Miis screen hears about each saved Mii, so its banner names the change and it can select the Mii.
@protocol KPMiiEditorListener <NSObject>
- (void)miiEditorSaved:(NSString*)description mii:(NSData*)mii slot:(NSUInteger)slot;
@end
static __weak id<KPMiiEditorListener> KPMiiSaveListener;
static KPMiiImage *KPMiiImageFromPixels(const kartpad::mii::Image &image, BOOL cropHead=NO) {
    NSData *data=[NSData dataWithBytes:image.rgba.data() length:image.rgba.size()];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGImageRef cg=CGImageCreate(image.width,image.height,8,32,image.width*4,color,kCGImageAlphaLast,provider,nullptr,true,kCGRenderingIntentDefault);
    CGColorSpaceRelease(color);CGDataProviderRelease(provider);
    if(cropHead){
        unsigned left=image.width,top=image.height,right=0,bottom=0;
        for(unsigned y=0;y<image.height;y++)for(unsigned x=0;x<image.width;x++)if(image.rgba[(y*image.width+x)*4+3]>4){left=std::min(left,x);right=std::max(right,x);top=std::min(top,y);bottom=std::max(bottom,y);}
        if(left<=right){CGFloat pad=std::max(2.,std::round(std::max(image.width,image.height)*.05));CGRect rect=CGRectIntersection(CGRectMake(0,0,image.width,image.height),CGRectMake(left-pad,top-pad,right-left+1+2*pad,bottom-top+1+2*pad));CGImageRef crop=CGImageCreateWithImageInRect(cg,rect);CGImageRelease(cg);cg=crop;}
    }
#if TARGET_OS_OSX
    NSImage *result=[[NSImage alloc]initWithCGImage:cg size:NSMakeSize(CGImageGetWidth(cg),CGImageGetHeight(cg))];
#else
    UIImage *result=[UIImage imageWithCGImage:cg];
#endif
    CGImageRelease(cg);return result;
}
static dispatch_queue_t KPMiiWorkQueue(){static dispatch_queue_t q;static dispatch_once_t once;dispatch_once(&once,^{q=dispatch_queue_create("dev.kartpad.mii-preview",DISPATCH_QUEUE_SERIAL);});return q;}
// Path, size and date: unchanged files skip the read and hash that every preview refresh used to pay.
static NSString *KPMiiFileStamp(NSString *path){NSDictionary *a=path?[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil]:nil;return a?[NSString stringWithFormat:@"%@|%@|%f",path,a[NSFileSize],a.fileModificationDate.timeIntervalSince1970]:nil;}
// Only touched on the serial worker; platform images and GPU state are installed on main.
static std::shared_ptr<kartpad::mii::Resources> KPMiiLoadResources(){
    static std::shared_ptr<kartpad::mii::Resources> resource;static NSString *digest,*stamp;
    NSString *path=KPMiiResourcePath(),*now=KPMiiFileStamp(path);if(resource&&now&&[now isEqual:stamp])return resource;
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(!data)throw std::runtime_error("Preview resources unavailable. Reimport your game-data folder.");
    NSString *key=KPMiiDigest(data);if(resource&&[key isEqual:digest]){stamp=now;return resource;}
    auto next=std::make_shared<kartpad::mii::Resources>(Bytes(data));
    NSString *folder=[SupportRoot() stringByAppendingPathComponent:@"Caches/MiiPreview"];
    NSString *file=[folder stringByAppendingPathComponent:@"catalog-v6.plist"];
    NSDictionary *disk=[NSDictionary dictionaryWithContentsOfFile:file];BOOL loaded=NO;
    if([disk[@"digest"] isEqual:key]&&[disk[@"catalog"] isKindOfClass:NSData.class]&&[disk[@"catalog"] length]<64*1024*1024){try{next->DecodeCache(Bytes(disk[@"catalog"]));loaded=YES;}catch(...){}}
    if(!loaded){auto decoded=next->EncodeCache();[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];[@{@"digest":key,@"catalog":[NSData dataWithBytes:decoded.data() length:decoded.size()]}writeToFile:file atomically:YES];}
    resource=next;digest=key;stamp=now;return resource;
}
static std::shared_ptr<kartpad::mii::BodyResources> KPMiiLoadBody(){
    static std::shared_ptr<kartpad::mii::BodyResources> body;static NSString *digest,*stamp;
    NSString *path=[[[KPMiiResourcePath() stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Scene/Model/MiiBody.szs"];
    NSString *now=KPMiiFileStamp(path);if(body&&now&&[now isEqual:stamp])return body;
    NSData *data=[NSData dataWithContentsOfFile:path];if(!data)return nullptr;
    NSString *key=KPMiiDigest(data);if(body&&[key isEqual:digest]){stamp=now;return body;}
    auto next=std::make_shared<kartpad::mii::BodyResources>(Bytes(data));body=next;digest=key;stamp=now;return body;
}
// Tiles show each feature in the Mii's own colours, as the Mii Channel does.
static KPMiiImage *KPMiiFeatureImage(const kartpad::mii::Resources&r,unsigned field,unsigned value,const kartpad::mii::Appearance&current){
    using namespace kartpad::mii;
    // Feature textures sit off-centre in their canvases; crop to the drawn pixels so tiles centre them.
    if(field==14){Color first=value==9?Color{255,130,0}:value==20?Color{0,255,255}:Color{0,0,0};return KPMiiImageFromPixels(Portrait::ColorMask(r.Texture(1,value),first,Eyes[current.Get(17)]),YES);}
    if(field==20){Image image=r.Texture(2,value);Color color=Hair[current.Get(22)];for(size_t i=0;i<image.rgba.size();i+=4)for(int c=0;c<3;c++)image.rgba[i+c]=color[c];return KPMiiImageFromPixels(image,YES);}
    if(field==29)return KPMiiImageFromPixels(Portrait::ColorMask(r.Texture(11,value),Lip0[current.Get(30)],Lip1[current.Get(30)]),YES);
    if((field==33||field==37||field==38)&&value==0)return nil;
    if((field==33||field==37)&&value)return KPMiiImageFromPixels(Portrait::AccessoryThumbnail(r,field,value,current.Get(field==33?34:39)),YES);
    // Face shapes share one framing (no per-tile crop) so their outlines can be compared.
    if(field==7)return KPMiiImageFromPixels(Portrait::FaceShapeThumbnail(r,value,Skin[current.Get(8)]));
    // Other features sit on the Mii's own face shape so tiles match the preview.
    auto a=Appearance::Decode(CreateDefaultMii({0,0,0,0,0,0}));a.Set(field,value);
    a.Set(7,current.Get(7));a.Set(8,current.Get(8));a.Set(12,current.Get(12));a.Set(39,current.Get(39));
    if(field==9)a.Set(11,30);
    return KPMiiImageFromPixels(Portrait::Render(r,a),YES);
}
// Face shape and colours that feed the tiles; part of the thumbnail cache key so changing them re-renders the tiles.
static NSString *KPMiiTileColors(const kartpad::mii::Appearance&a){return [NSString stringWithFormat:@"%u.%u.%u.%u.%u.%u.%u.%u",a.Get(7),a.Get(8),a.Get(12),a.Get(17),a.Get(22),a.Get(30),a.Get(34),a.Get(39)];}
static void KPDrawImage(KPMiiImage *image,CGRect rect){
    CGSize size=image.size;if(size.width<=0||size.height<=0)return;
    CGFloat scale=std::min(rect.size.width/size.width,rect.size.height/size.height);
    CGRect fit=CGRectMake(CGRectGetMidX(rect)-size.width*scale/2,CGRectGetMidY(rect)-size.height*scale/2,size.width*scale,size.height*scale);
#if TARGET_OS_OSX
    [image drawInRect:fit fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
#else
    [image drawInRect:fit];
#endif
}
// Head portraits (the Miis screen and Create Mii) render on the resource worker and are kept by the Mii's 74 bytes, so an
// unchanged Mii renders once per session. Without the imported RFL archive, tiles fall back to a
// silhouette in the Mii's favorite color.
// Not an NSCache: once macOS reports memory pressure, which a running game brings on, an NSCache
// evicts each portrait as it is stored, so the screens kept the silhouette. This keeps the most
// recently used ones instead, enough for a full Mii database and Create Mii's faces. Main thread only.
@interface KPMiiPortraitStore:NSObject
- (KPMiiImage*)objectForKey:(NSData*)mii;
- (void)setObject:(KPMiiImage*)image forKey:(NSData*)mii;
@end
@implementation KPMiiPortraitStore{NSMutableDictionary<NSData*,KPMiiImage*> *_images;NSMutableOrderedSet<NSData*> *_recent;}
// 100 Miis, plus room for Create Mii's look-alikes and blank faces.
static const NSUInteger KPMiiPortraitLimit=128;
- (instancetype)init{if((self=[super init])){_images=[NSMutableDictionary dictionary];_recent=[NSMutableOrderedSet orderedSet];}return self;}
- (void)touch:(NSData*)mii{[_recent removeObject:mii];[_recent addObject:mii];}
- (KPMiiImage*)objectForKey:(NSData*)mii{KPMiiImage *image=_images[mii];if(image)[self touch:mii];return image;}
- (void)setObject:(KPMiiImage*)image forKey:(NSData*)mii{
    _images[mii]=image;[self touch:mii];
    while(_recent.count>KPMiiPortraitLimit){[_images removeObjectForKey:_recent.firstObject];[_recent removeObjectAtIndex:0];}
}
@end
static KPMiiPortraitStore *KPMiiPortraits(){static KPMiiPortraitStore *store;static dispatch_once_t once;dispatch_once(&once,^{store=[KPMiiPortraitStore new];});return store;}
static NSString *KPMiiPortraitProblem;
static NSMutableSet<NSData*> *KPMiiPortraitsRendering(){static NSMutableSet *set;static dispatch_once_t once;dispatch_once(&once,^{set=[NSMutableSet set];});return set;}
static void KPMiiRequestPortrait(NSData *mii,void(^ready)(void)){
    if(mii.length!=kartpad::mii::kMiiBlockSize||[KPMiiPortraits() objectForKey:mii]||[KPMiiPortraitsRendering() containsObject:mii])return;
    [KPMiiPortraitsRendering() addObject:mii];
    dispatch_async(KPMiiWorkQueue(),^{
        KPMiiImage *image=nil;NSString *problem=nil;
        try{auto resources=KPMiiLoadResources();image=KPMiiImageFromPixels(kartpad::mii::Portrait::Render(*resources,kartpad::mii::Appearance::Decode(Bytes(mii))),YES);}
        catch(const std::exception &e){problem=@(e.what());}
        dispatch_async(dispatch_get_main_queue(),^{
            [KPMiiPortraitsRendering() removeObject:mii];
            if(image){[KPMiiPortraits() setObject:image forKey:mii];KPMiiPortraitProblem=nil;}else KPMiiPortraitProblem=problem;
            ready();
        });
    });
}
// Category silhouettes on a 40-unit grid, one stroke weight, drawn in the tab's ink.
static void KPIcon(CGContextRef c,unsigned category,CGRect rect,unsigned ink){
    CGContextSaveGState(c);CGContextTranslateCTM(c,rect.origin.x,rect.origin.y);CGContextScaleCTM(c,rect.size.width/40,rect.size.height/40);
    KPSetInk(c,ink);CGContextSetLineWidth(c,2.8);CGContextSetLineCap(c,kCGLineCapRound);CGContextSetLineJoin(c,kCGLineJoinRound);
    switch(category){
    case 0:{ // Profile: an ID card with a bust and text lines.
        CGPathRef card=CGPathCreateWithRoundedRect(CGRectMake(3,8,34,25),5,5,nullptr);CGContextAddPath(c,card);CGContextStrokePath(c);CGPathRelease(card);
        CGContextFillEllipseInRect(c,CGRectMake(9,13,8,8));
        CGContextMoveToPoint(c,7,29.5);CGContextAddCurveToPoint(c,7,21.5,19,21.5,19,29.5);CGContextClosePath(c);CGContextFillPath(c);
        CGContextSetLineWidth(c,2.6);KPLine(c,23,16,32,16);KPLine(c,23,21,32,21);KPLine(c,23,26,28,26);break;}
    case 1:{ // Body: a Mii beside a height gauge with end stops.
        CGContextFillEllipseInRect(c,CGRectMake(7.5,3,13,13));
        CGContextMoveToPoint(c,9,18);CGContextAddLineToPoint(c,19,18);CGContextAddQuadCurveToPoint(c,22,18,22.5,21);CGContextAddLineToPoint(c,23.5,29);CGContextAddLineToPoint(c,20,29);CGContextAddLineToPoint(c,19.5,37);CGContextAddLineToPoint(c,15.2,37);CGContextAddLineToPoint(c,14,30.5);CGContextAddLineToPoint(c,12.8,37);CGContextAddLineToPoint(c,8.5,37);CGContextAddLineToPoint(c,8,29);CGContextAddLineToPoint(c,4.5,29);CGContextAddLineToPoint(c,5.5,21);CGContextAddQuadCurveToPoint(c,6,18,9,18);CGContextClosePath(c);CGContextFillPath(c);
        CGContextSetLineWidth(c,2.6);KPLine(c,32,7,32,33);KPLine(c,28,3.5,36,3.5);KPLine(c,28,36.5,36,36.5);
        CGContextMoveToPoint(c,32,4.5);CGContextAddLineToPoint(c,28.5,9.5);CGContextAddLineToPoint(c,35.5,9.5);CGContextClosePath(c);CGContextFillPath(c);
        CGContextMoveToPoint(c,32,35.5);CGContextAddLineToPoint(c,28.5,30.5);CGContextAddLineToPoint(c,35.5,30.5);CGContextClosePath(c);CGContextFillPath(c);break;}
    case 11:case 10:{ // Male and female Miis in Mii Channel proportions: a large round head over a short body,
        // mitten arms and stubby legs; female wears an A-line dress. The arms are cut out of the body so they read apart.
        BOOL female=category==10;CGFloat arm=female?4:4.4;
        CGContextBeginTransparencyLayer(c,nullptr);
        CGContextFillEllipseInRect(c,CGRectMake(12,1,16,15.5));
        auto rounded=[&](CGRect r,CGFloat radius){CGPathRef path=CGPathCreateWithRoundedRect(r,radius,radius,nullptr);CGContextAddPath(c,path);CGContextFillPath(c);CGPathRelease(path);};
        if(female){
            CGContextMoveToPoint(c,16.5,17.5);CGContextAddLineToPoint(c,23.5,17.5);CGContextAddQuadCurveToPoint(c,26,17.5,26.6,20);CGContextAddLineToPoint(c,29.2,29.5);CGContextAddQuadCurveToPoint(c,29.8,32,27.2,32);
            CGContextAddLineToPoint(c,12.8,32);CGContextAddQuadCurveToPoint(c,10.2,32,10.8,29.5);CGContextAddLineToPoint(c,13.4,20);CGContextAddQuadCurveToPoint(c,14,17.5,16.5,17.5);CGContextClosePath(c);CGContextFillPath(c);
            for(CGFloat x:{15.4,20.8})rounded(CGRectMake(x,30,3.8,8),1.8);
        }else{rounded(CGRectMake(13.5,17.5,13,12.5),4);for(CGFloat x:{14.2,20.9})rounded(CGRectMake(x,27,4.9,11),2.4);}
        CGFloat inner=female?13.2:12.4,outer=female?10:9.4,top=female?20.5:20,bottom=female?27.5:28;
        CGContextSetBlendMode(c,kCGBlendModeClear);CGContextSetLineWidth(c,arm+2.4);KPLine(c,inner,top,outer,bottom);KPLine(c,40-inner,top,40-outer,bottom);
        CGContextSetBlendMode(c,kCGBlendModeNormal);CGContextSetLineWidth(c,arm);KPLine(c,inner,top,outer,bottom);KPLine(c,40-inner,top,40-outer,bottom);
        CGContextEndTransparencyLayer(c);break;}
    case 12:{ // Start from scratch, when portraits can't render: a plain face with a plus.
        KPIcon(c,2,CGRectMake(0,4,34,34),ink);CGContextSetLineWidth(c,3);KPLine(c,34,2,34,12);KPLine(c,29,7,39,7);break;}
    case 13:{ // Look-alikes, when portraits can't render: three faces.
        CGContextBeginTransparencyLayer(c,nullptr);
        KPIcon(c,2,CGRectMake(0,9,19,19),ink);KPIcon(c,2,CGRectMake(21,9,19,19),ink);
        CGContextSetBlendMode(c,kCGBlendModeClear);CGContextFillEllipseInRect(c,CGRectMake(9,5,22,30));CGContextSetBlendMode(c,kCGBlendModeNormal);
        KPIcon(c,2,CGRectMake(8,6,24,28),ink);CGContextEndTransparencyLayer(c);break;}
    case 2: // Face: a jaw outline with simple features.
        CGContextMoveToPoint(c,20,4);CGContextAddCurveToPoint(c,29,4,34,10,34,18);CGContextAddCurveToPoint(c,34,27,27,36,20,36);CGContextAddCurveToPoint(c,13,36,6,27,6,18);CGContextAddCurveToPoint(c,6,10,11,4,20,4);CGContextClosePath(c);CGContextStrokePath(c);
        CGContextFillEllipseInRect(c,CGRectMake(13,16,3.6,3.6));CGContextFillEllipseInRect(c,CGRectMake(23.4,16,3.6,3.6));
        CGContextSetLineWidth(c,2.4);CGContextMoveToPoint(c,15,26);CGContextAddQuadCurveToPoint(c,20,30,25,26);CGContextStrokePath(c);break;
    case 3: // Hair: a filled cap with a fringe over the face outline.
        CGContextMoveToPoint(c,5,21);CGContextAddCurveToPoint(c,4,9,12,3,20,3);CGContextAddCurveToPoint(c,28,3,36,9,35,21);CGContextAddLineToPoint(c,31,15);CGContextAddLineToPoint(c,27,18);CGContextAddLineToPoint(c,24,12);CGContextAddLineToPoint(c,19,17);CGContextAddLineToPoint(c,14,12);CGContextAddLineToPoint(c,10,17);CGContextClosePath(c);CGContextFillPath(c);
        CGContextMoveToPoint(c,7.5,22);CGContextAddCurveToPoint(c,8,31,14,37,20,37);CGContextAddCurveToPoint(c,26,37,32,31,32.5,22);CGContextStrokePath(c);break;
    case 4: // Eyebrows: Wii-style tapered brows, a fine outer tip swelling to a blunt inner end that dips toward the nose.
        for(int side:{0,1}){CGContextSaveGState(c);if(side){CGContextTranslateCTM(c,40,0);CGContextScaleCTM(c,-1,1);}
            CGContextMoveToPoint(c,1.5,19);CGContextAddCurveToPoint(c,7,15,13.5,15,17.5,18.5);CGContextAddCurveToPoint(c,19.2,20,19,24,16.8,24);CGContextAddCurveToPoint(c,12,22.5,6.5,20.8,1.5,19);CGContextClosePath(c);CGContextFillPath(c);
            CGContextRestoreGState(c);}
        break;
    case 5: // Eyes: almonds with pupils.
        CGContextSetLineWidth(c,2.4);for(CGFloat x:{2.,22.}){CGContextMoveToPoint(c,x,20);CGContextAddQuadCurveToPoint(c,x+8,9,x+16,20);CGContextAddQuadCurveToPoint(c,x+8,31,x,20);CGContextClosePath(c);CGContextStrokePath(c);CGContextFillEllipseInRect(c,CGRectMake(x+4.5,16.5,7,7));}break;
    case 6: // Nose: side profile with a nostril.
        CGContextSetLineWidth(c,3.2);CGContextMoveToPoint(c,15,5);CGContextAddCurveToPoint(c,18,14,26,19,29.5,25.5);CGContextAddCurveToPoint(c,31,29,28.5,31.5,25,31);CGContextAddCurveToPoint(c,23,34,18.5,34,15.5,31.5);CGContextStrokePath(c);
        CGContextSetLineWidth(c,2.4);CGContextMoveToPoint(c,19,28);CGContextAddQuadCurveToPoint(c,21.5,25.5,24,28);CGContextStrokePath(c);break;
    case 7: // Mouth: Wii-style full lips, a cupid's-bow upper lip over a slimmer lower lip, parted by a straight line.
        CGContextMoveToPoint(c,3,22);CGContextAddCurveToPoint(c,4,15,9.5,10,14.5,10);CGContextAddCurveToPoint(c,17,10,18.5,11.5,20,13.5);CGContextAddCurveToPoint(c,21.5,11.5,23,10,25.5,10);CGContextAddCurveToPoint(c,30.5,10,36,15,37,22);CGContextClosePath(c);CGContextFillPath(c);
        CGContextMoveToPoint(c,3.5,25);CGContextAddLineToPoint(c,36.5,25);CGContextAddCurveToPoint(c,35,30.5,28.5,33,20,33);CGContextAddCurveToPoint(c,11.5,33,5,30.5,3.5,25);CGContextClosePath(c);CGContextFillPath(c);break;
    case 8: // Facial hair: a curled mustache.
        CGContextMoveToPoint(c,20,17);CGContextAddCurveToPoint(c,15,10,8,12,7,18);CGContextAddCurveToPoint(c,6,21,3,21,2,19);CGContextAddCurveToPoint(c,2,26,10,29,16,25.5);CGContextAddQuadCurveToPoint(c,19,23.5,20,22);
        CGContextAddQuadCurveToPoint(c,21,23.5,24,25.5);CGContextAddCurveToPoint(c,30,29,38,26,38,19);CGContextAddCurveToPoint(c,37,21,34,21,33,18);CGContextAddCurveToPoint(c,32,12,25,10,20,17);CGContextClosePath(c);CGContextFillPath(c);break;
    case 9: // Glasses: lenses, bridge and arms.
        for(CGFloat x:{2.5,22.5}){CGPathRef lens=CGPathCreateWithRoundedRect(CGRectMake(x,13,15,13),5.5,5.5,nullptr);CGContextAddPath(c,lens);CGContextStrokePath(c);CGPathRelease(lens);}
        CGContextMoveToPoint(c,17.5,18);CGContextAddQuadCurveToPoint(c,20,15,22.5,18);CGContextStrokePath(c);KPLine(c,2.5,16,1.5,12.5);KPLine(c,37.5,16,38.5,12.5);break;
    }
    CGContextRestoreGState(c);
}

static constexpr unsigned KPLookAlikeCount=12;
enum class KPAction{Category,Select,Adjust,Page,Mode,Section,Toggle,Rotate,Front,Quit,Save,Discard,Birthday,Undo,Redo,More,Gender,Start,LookAlike,Shuffle,Back,Slider,Sound};
struct KPItem{KPAction action;CGRect rect;unsigned field=0;int value=0;NSString *__strong label;BOOL enabled=YES;BOOL selected=NO;};
@class KPMiiCanvas, KPMiiWiiButton;
#if TARGET_OS_OSX
@interface KPMiiEditor : NSWindowController <NSWindowDelegate,NSTextFieldDelegate>
#else
@interface KPMiiEditor : UIViewController <UITextFieldDelegate,UIPickerViewDataSource,UIPickerViewDelegate>
#endif
{
@public
    kartpad::mii::DraftHistory _history;
    kartpad::mii::PreviewRevision _revision;
    std::shared_ptr<std::atomic<uint64_t>> _ticket;
}
@property(nonatomic,strong) NSMutableData *draft;
@property(nonatomic,strong) NSData *original;
@property(nonatomic) NSUInteger slot;
@property(nonatomic) NSInteger category;
@property(nonatomic) unsigned feature,page;
// The part of a split page showing: the grid (or Name), Color (or Details), Adjust.
@property(nonatomic) unsigned section;
@property(nonatomic) BOOL creating,duplicating,allowClose,previewLoaded;
@property(nonatomic) unsigned gender;
// Create Mii: the look-alike grid, and its faces (one seed per tile, so changing gender keeps the shuffle).
@property(nonatomic) BOOL pickingLookAlike;
@property(nonatomic,copy) NSArray<NSNumber*> *lookSeeds;
@property(nonatomic,copy) NSArray<NSData*> *lookAlikes;
// The new Mii before a face was chosen, so Start Over can return to the create screen.
@property(nonatomic,copy) NSData *blank;
@property(nonatomic,strong) KPMiiCanvas *canvas;
@property(nonatomic,strong) KPMiiMetalPreview *preview;
@property(nonatomic,strong) NSMutableDictionary<NSString*,KPMiiImage*> *thumbnails;
@property(nonatomic,copy) NSString *previewMessage,*validationMessage;
@property(nonatomic,strong) NSMutableArray *nameFields,*nameHints;
@property(nonatomic) NSUInteger validationField;
@property(nonatomic,weak) id buildLabel;
// The last adjustment press, so held repeats tick instead of replaying the step sound.
@property(nonatomic) CFTimeInterval adjustTime;
@property(nonatomic) unsigned adjustField;
@property(nonatomic) int adjustDirection;
#if !TARGET_OS_OSX
@property(nonatomic,strong) UIPickerView *birthdayPicker;
@property(nonatomic) unsigned birthdayMonth;
#endif
- (void)performItem:(const KPItem&)item;
- (void)refreshPreview;
- (void)applyAppearance:(const kartpad::mii::Appearance&)a;
- (void)categoryChangedTo:(unsigned)category;
- (void)quit;
- (void)save;
- (void)discard;
- (BOOL)dirty;
#if TARGET_OS_OSX
- (void)birthday:(unsigned)field;
#else
- (void)birthday;
#endif
- (void)showMore;
- (void)rebuild;
- (BOOL)commitNames;
- (void)setBody:(unsigned)field value:(unsigned)value;
- (NSData*)scratch;
- (void)shuffle;
- (void)makeLookAlikes;
- (void)begin:(NSData*)face;
- (void)startOver;
@end
#if TARGET_OS_OSX
@interface KPMiiCanvas : NSView
#else
@interface KPMiiCanvas : UIView
#endif
{
@public
    std::vector<KPItem> _items;
    CGRect _previewRect,_panelRect;
    CGFloat _footerY;
    BOOL _stacked,_shortHeader;
    CGFloat _statusWidth;
    CGRect _nameRect;
    NSUInteger _hoverIndex;
}
@property(nonatomic,weak) KPMiiEditor *editor;
@property(nonatomic,strong) NSMutableArray *buttons;
@property(nonatomic) CGSize previousSize;
- (void)rebuild;
- (void)redraw;
- (void)drawItem:(NSUInteger)i context:(CGContextRef)c pressed:(BOOL)pressed;
@end
#if TARGET_OS_OSX
@interface KPMiiWiiButton : NSButton
#else
@interface KPMiiWiiButton : UIButton
#endif
@property(nonatomic,weak) KPMiiCanvas *canvas;
@property(nonatomic) NSUInteger index;
@property(nonatomic,strong) NSTimer *repeatTimer;
// What the face last showed (state bits and tile artwork); redraw repaints only buttons that changed.
@property(nonatomic) NSUInteger look;
@property(nonatomic,strong) id art;
- (void)setHovered:(BOOL)hovered;
- (void)activate;
@end
#if TARGET_OS_OSX
static NSView *KPPadNearest(NSArray<NSView*> *candidates,NSView *from,int dx,int dy);
#endif
@implementation KPMiiWiiButton
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)keyDown:(NSEvent*)event{
    NSString *key=event.charactersIgnoringModifiers;
    if([key isEqual:@" "]||[key isEqual:@"\r"]){self.canvas.editor->_history.Begin();[self activate];self.canvas.editor->_history.End();return;}
    if(event.keyCode>=123&&event.keyCode<=126){
        // Arrows move as the controller's D-pad does (KartPadMiiGamepad.inc.mm).
        NSMutableArray *enabled=[NSMutableArray array];for(KPMiiWiiButton *candidate in self.canvas.buttons)if(candidate.enabled)[enabled addObject:candidate];
        int dx=event.keyCode==123?-1:event.keyCode==124?1:0,dy=event.keyCode==126?-1:event.keyCode==125?1:0;
        if(NSView *best=KPPadNearest(enabled,self,dx,dy)){[self.window makeFirstResponder:best];[best scrollRectToVisible:best.bounds];}
        return;
    }
    [self.canvas keyDown:event];
}
- (void)drawRect:(NSRect)rect{[self.canvas drawItem:self.index context:NSGraphicsContext.currentContext.CGContext pressed:self.highlighted];if(self.window.firstResponder==self)KPStroke(NSGraphicsContext.currentContext.CGContext,CGRectInset(self.bounds,1,1),KPP->accentBottom,2.5,std::min(CGFloat(14),self.bounds.size.height/2));}
// NSButton's own mouseDown runs a modal tracking loop until release. SDL pumps AppKit events from
// the game loop on this thread, so that loop froze the game (and the preview) for every press.
// Plain mouse events track the press instead; held adjustments repeat on a timer as on iPhone.
- (void)mouseDown:(NSEvent*)event{if(!self.enabled)return;[self highlight:YES];if([self holds])[self down];}
- (void)mouseDragged:(NSEvent*)event{BOOL inside=NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds);if(inside!=self.highlighted)[self highlight:inside];}
- (void)mouseUp:(NSEvent*)event{BOOL inside=self.highlighted;[self highlight:NO];if([self holds]){[self up];return;}if(inside)[self tap];}
- (void)viewDidMoveToWindow{[super viewDidMoveToWindow];if(!self.window)[self up];}
- (BOOL)becomeFirstResponder{self.needsDisplay=YES;return [super becomeFirstResponder];}
- (BOOL)resignFirstResponder{self.needsDisplay=YES;return [super resignFirstResponder];}
#else
- (void)drawRect:(CGRect)rect{[self.canvas drawItem:self.index context:UIGraphicsGetCurrentContext() pressed:self.highlighted];}
- (void)hover:(UIHoverGestureRecognizer*)gesture{[self setHovered:gesture.state==UIGestureRecognizerStateBegan||gesture.state==UIGestureRecognizerStateChanged];}
- (void)didMoveToWindow{if(!self.window)[self up];}
#endif
- (BOOL)holds{return self.index<self.canvas->_items.size()&&self.canvas->_items[self.index].action==KPAction::Adjust;}
// Adjustments act on press and repeat while held (only while the pointer stays on the button).
- (void)down{
    if(![self holds])return;
    KPMiiEditor *editor=self.canvas.editor;editor->_history.Begin();[self activate];
    if(!self.window)return;
    __weak KPMiiWiiButton *weak=self;
    self.repeatTimer=[NSTimer scheduledTimerWithTimeInterval:.35 repeats:NO block:^(NSTimer*t){
        KPMiiWiiButton *button=weak;if(!button||!button.enabled)return;
        button.repeatTimer=[NSTimer scheduledTimerWithTimeInterval:.085 repeats:YES block:^(NSTimer*repeat){KPMiiWiiButton *button=weak;if(!button.enabled){[repeat invalidate];return;}if(button.highlighted)[button activate];}];
    }];
}
- (void)tap{if([self holds])return;KPMiiEditor *editor=self.canvas.editor;editor->_history.Begin();[self activate];editor->_history.End();}
// The editor can be gone when the window tears down its buttons.
- (void)up{[self.repeatTimer invalidate];self.repeatTimer=nil;if(KPMiiEditor *editor=self.canvas.editor)editor->_history.End();}
- (void)setHovered:(BOOL)hovered{
    KPMiiCanvas *canvas=self.canvas;if(!canvas)return;NSUInteger previous=canvas->_hoverIndex;
    if(hovered)canvas->_hoverIndex=self.index;else if(previous==self.index)canvas->_hoverIndex=NSNotFound;else return;
    if(hovered&&previous!=self.index&&self.enabled)KPPlay(KPSound::Hover);
    for(KPMiiWiiButton *button in canvas.buttons)if(button.index==previous||button==self){
#if TARGET_OS_OSX
        button.needsDisplay=YES;
#else
        [button setNeedsDisplay];
#endif
    }
}
#if TARGET_OS_OSX
- (void)updateTrackingAreas{[super updateTrackingAreas];for(NSTrackingArea *area in self.trackingAreas.copy)[self removeTrackingArea:area];[self addTrackingArea:[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]];}
- (void)mouseEntered:(NSEvent*)event{[self setHovered:YES];}
- (void)mouseExited:(NSEvent*)event{[self setHovered:NO];}
- (void)resetCursorRects{if(self.enabled)[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];}
#endif
- (void)activate{if(self.index<self.canvas->_items.size()&&self.canvas->_items[self.index].enabled)[self.canvas.editor performItem:self.canvas->_items[self.index]];}
@end
// Height/weight gauge drawn like the rest of the editor: a recessed track with notches, a Wii-blue
// fill and a ledged handle, with small and large Mii silhouettes at the ends. The draft is the only
// source of the value; one drag or key press is one history entry.
#if TARGET_OS_OSX
@interface KPMiiBodySlider : NSControl
#else
@interface KPMiiBodySlider : UIControl
#endif
@property(nonatomic,weak) KPMiiEditor *editor;
@property(nonatomic) unsigned field;
@property(nonatomic) BOOL dragging;
@end
@implementation KPMiiBodySlider
- (unsigned)value{return kartpad::mii::Appearance::Decode(Bytes(self.editor.draft)).Get(self.field);}
- (CGRect)track{CGFloat inset=48;return CGRectMake(inset,CGRectGetMidY(self.bounds)-7,self.bounds.size.width-2*inset,14);}
- (void)setValueAt:(CGFloat)x{CGRect t=[self track];unsigned before=[self value];[self.editor setBody:self.field value:unsigned(lround(std::clamp((x-t.origin.x)/t.size.width,CGFloat(0),CGFloat(1))*127))];if([self value]/8!=before/8)KPPlay(KPSound::Tick);[self refresh];}
- (void)step:(int)delta{unsigned before=[self value];self.editor->_history.Begin();[self.editor setBody:self.field value:unsigned(std::clamp(int(before)+delta,0,127))];self.editor->_history.End();KPPlay([self value]==before?KPSound::Reject:KPSound::Tick);[self refresh];}
- (NSString*)spoken{return [NSString stringWithFormat:@"%u percent",unsigned(lround([self value]/127.*100))];}
- (void)refresh{
#if TARGET_OS_OSX
    self.needsDisplay=YES;
#else
    [self setNeedsDisplay];
#endif
}
- (void)drawRect:(CGRect)rect{
#if TARGET_OS_OSX
    CGContextRef c=NSGraphicsContext.currentContext.CGContext;BOOL focused=self.window.firstResponder==self;
#else
    CGContextRef c=UIGraphicsGetCurrentContext();BOOL focused=NO;
#endif
    KPUsePalette(self);CGRect t=[self track];CGFloat mid=CGRectGetMidY(t);BOOL height=self.field==5;
    // End silhouettes: short/tall for height, thin/wide for weight.
    CGRect small=height?CGRectMake(8,mid-8,30,22):CGRectMake(12,mid-15,22,30),large=height?CGRectMake(self.bounds.size.width-38,mid-19,30,40):CGRectMake(self.bounds.size.width-44,mid-15,40,30);
    KPIcon(c,11,small,KPP->icon);KPIcon(c,11,large,KPP->icon);
    KPFill(c,CGRectOffset(t,0,-1),KPP->ledge,7);KPFill(c,t,KPP->well,7);KPStroke(c,t,KPP->buttonStroke,1,7);
    CGFloat x=t.origin.x+[self value]/127.*t.size.width;
    if(x>t.origin.x+2)KPGradientFill(c,CGRectMake(t.origin.x+2,t.origin.y+2,x-t.origin.x-2,t.size.height-4),5,KPP->accentTop,KPP->accentBottom);
    KPSetInk(c,KPP->buttonStroke);CGContextSetLineWidth(c,1.5);for(int i=0;i<=8;i++){CGFloat tx=t.origin.x+t.size.width*i/8;KPLine(c,tx,CGRectGetMaxY(t)+5,tx,CGRectGetMaxY(t)+(i%4?9:12));}
    CGRect knob=CGRectMake(x-14,mid-19,28,38);KPButtonFace(c,knob,KPStyle::Plain,self.dragging,YES,self.dragging);
    KPSetInk(c,KPP->buttonStroke);CGContextSetLineWidth(c,1.5);CGFloat gy=mid-1.5+(self.dragging?2:0);for(int i=-1;i<=1;i++)KPLine(c,x+i*5,gy-6,x+i*5,gy+6);
    if(focused)KPStroke(c,CGRectInset(knob,-3,-3),KPP->accentBottom,2.5,11);
}
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)becomeFirstResponder{[self refresh];return YES;}
- (BOOL)resignFirstResponder{[self refresh];return YES;}
- (void)mouseDown:(NSEvent*)event{self.dragging=YES;self.editor->_history.Begin();[self.window makeFirstResponder:self];[self setValueAt:[self convertPoint:event.locationInWindow fromView:nil].x];}
- (void)mouseDragged:(NSEvent*)event{[self setValueAt:[self convertPoint:event.locationInWindow fromView:nil].x];}
- (void)mouseUp:(NSEvent*)event{self.dragging=NO;self.editor->_history.End();[self refresh];}
- (void)keyDown:(NSEvent*)event{
    int step=(event.modifierFlags&NSEventModifierFlagShift)?8:1;
    if(event.keyCode==123||event.keyCode==125)[self step:-step];else if(event.keyCode==124||event.keyCode==126)[self step:step];else [super keyDown:event];
}
- (BOOL)isAccessibilityElement{return YES;}
- (NSAccessibilityRole)accessibilityRole{return NSAccessibilitySliderRole;}
- (id)accessibilityValue{return [self spoken];}
- (BOOL)accessibilityPerformIncrement{[self step:4];return YES;}
- (BOOL)accessibilityPerformDecrement{[self step:-4];return YES;}
#else
- (BOOL)beginTrackingWithTouch:(UITouch*)touch withEvent:(UIEvent*)event{self.dragging=YES;self.editor->_history.Begin();[self setValueAt:[touch locationInView:self].x];return YES;}
- (BOOL)continueTrackingWithTouch:(UITouch*)touch withEvent:(UIEvent*)event{[self setValueAt:[touch locationInView:self].x];return YES;}
- (void)endTrackingWithTouch:(UITouch*)touch withEvent:(UIEvent*)event{self.dragging=NO;self.editor->_history.End();[self refresh];}
- (void)cancelTrackingWithEvent:(UIEvent*)event{self.dragging=NO;self.editor->_history.End();[self refresh];}
- (BOOL)isAccessibilityElement{return YES;}
- (UIAccessibilityTraits)accessibilityTraits{return UIAccessibilityTraitAdjustable;}
- (NSString*)accessibilityValue{return [self spoken];}
- (void)accessibilityIncrement{[self step:4];}
- (void)accessibilityDecrement{[self step:-4];}
#endif
@end
// Preview idle animation (blink, smile, body loop, head sway). On unless the player turns it off.
static NSString *const KPMiiPreviewAnimationKey=@"KartPadMiiPreviewAnimation";
static BOOL KPMiiPreviewAnimation(){id value=[NSUserDefaults.standardUserDefaults objectForKey:KPMiiPreviewAnimationKey];return value?[value boolValue]:YES;}
static unsigned KPBirthdayDays(unsigned month){return kartpad::mii::BirthdayDays(month);}
static NSArray<NSString*> *KPBirthdayMonths(){return @[@"Not set",@"January",@"February",@"March",@"April",@"May",@"June",@"July",@"August",@"September",@"October",@"November",@"December"];}
static NSString *KPBirthdayLabel(const kartpad::mii::Appearance &a){return a.Get(1)&&a.Get(2)?[NSString stringWithFormat:@"%@ %u",KPBirthdayMonths()[a.Get(1)],a.Get(2)]:@"Not set";}
// Field 1 is the month, field 2 the day (shown as “Day” until a month is chosen).
static NSString *KPBirthdayPart(const kartpad::mii::Appearance &a,unsigned field){return field==1?KPBirthdayMonths()[a.Get(1)]:a.Get(1)&&a.Get(2)?[NSString stringWithFormat:@"%u",a.Get(2)]:@"Day";}
static id KPLabelView(NSString *text,CGRect frame,CGFloat size=16,BOOL bold=NO,BOOL secondary=NO){
    KPMiiColor *color=KPColor(secondary?KPP->secondaryText:KPP->text);auto weight=bold?NSFontWeightSemibold:NSFontWeightRegular;
#if TARGET_OS_OSX
    NSTextField *label=[NSTextField wrappingLabelWithString:text];label.frame=frame;label.font=KPStyleFont(size,weight);label.textColor=color;
#else
    UILabel *label=[[UILabel alloc]initWithFrame:frame];label.text=text;label.font=[UIFontMetrics.defaultMetrics scaledFontForFont:KPStyleFont(size,weight) maximumPointSize:std::max(size,std::min(size*1.3,frame.size.height*.75))];label.adjustsFontForContentSizeCategory=YES;label.textColor=color;label.numberOfLines=0;
#endif
    return label;
}
// Mingle (field 10) stores "doesn't mingle", so its switch is inverted.
static BOOL KPToggleOn(const KPItem &item,const kartpad::mii::Appearance &a){return item.field==10?!a.Get(10):a.Get(item.field)!=0;}
static NSString *KPBuildName(const kartpad::mii::Appearance &a){auto build=kartpad::mii::BuildFor(a.Get(5),a.Get(6));return build==kartpad::mii::MiiBuild::Small?@"Small build":build==kartpad::mii::MiiBuild::Medium?@"Medium build":@"Large build";}
static BOOL KPColorField(unsigned field){return field==3||field==8||field==12||field==17||field==22||field==30||field==34||field==39;}
@implementation KPMiiCanvas
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)layout{[super layout];if(!CGSizeEqualToSize(self.bounds.size,self.previousSize)){self.previousSize=self.bounds.size;[self rebuild];}}
- (void)viewDidChangeEffectiveAppearance{[super viewDidChangeEffectiveAppearance];if(self.editor)[self rebuild];}
- (void)keyDown:(NSEvent*)event{if([event.charactersIgnoringModifiers isEqual:@"\033"]){[self.editor quit];return;}if([event.charactersIgnoringModifiers isEqual:@"z"]&&(event.modifierFlags&NSEventModifierFlagCommand)){KPItem item{};item.action=(event.modifierFlags&NSEventModifierFlagShift)?KPAction::Redo:KPAction::Undo;[self.editor performItem:item];return;}[super keyDown:event];}
#else
- (void)layoutSubviews{[super layoutSubviews];if(!CGSizeEqualToSize(self.bounds.size,self.previousSize)){self.previousSize=self.bounds.size;[self rebuild];}}
- (void)traitCollectionDidChange:(UITraitCollection*)previous{[super traitCollectionDidChange:previous];if(self.editor&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])[self rebuild];}
#endif
- (void)redraw{
    KPUsePalette(self);
#if TARGET_OS_OSX
    self.needsDisplay=YES;
#else
    [self setNeedsDisplay];
#endif
    // Each name field counts what it holds, or says what is wrong with it.
    for(id hint in self.editor.nameHints){BOOL invalid=self.editor.validationMessage.length&&[hint tag]==self.editor.validationField;NSString *text=nil;for(id field in self.editor.nameFields)if([field tag]==[hint tag]){
#if TARGET_OS_OSX
            text=[field stringValue];
#else
            text=[field text];
#endif
        }
        NSString *message=invalid?self.editor.validationMessage:KPMiiNameCount(text?:@"");
#if TARGET_OS_OSX
        [hint setStringValue:message];[hint setTextColor:invalid?NSColor.systemRedColor:KPColor(KPP->secondaryText)];
#else
        [hint setText:message];[hint setTextColor:invalid?UIColor.systemRedColor:KPColor(KPP->secondaryText)];
#endif
    }
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));BOOL sound=[KPMiiSounds shared].enabled;
#if TARGET_OS_OSX
    // The close button's dot marks unsaved changes, and the title names the Mii.
    if(NSWindow *window=self.editor.window){NSString *base=self.editor.slot!=NSNotFound?@"Edit Mii":self.editor.duplicating?@"Duplicate Mii":@"Create Mii",*name=KPMiiName(self.editor.draft,2);
        window.title=self.editor.creating||!name.length?base:[NSString stringWithFormat:@"%@ — %@",base,name];window.documentEdited=!self.editor.creating&&[self.editor dirty];}
#endif
    for(KPMiiWiiButton *button in self.buttons){auto &item=_items[button.index];
        if(item.action==KPAction::Adjust){auto f=kartpad::mii::AppearanceFields[item.field];int value=int(a.Get(item.field))+item.value;item.enabled=value>=int(f.minimum)&&value<=int(f.maximum);}
        if(item.action==KPAction::Undo)item.enabled=self.editor->_history.CanUndo();
        if(item.action==KPAction::Redo)item.enabled=self.editor->_history.CanRedo();
        if(item.action==KPAction::Save)item.enabled=[self.editor dirty];
        button.enabled=item.enabled;
        NSString *value=item.action==KPAction::Toggle?(KPToggleOn(item,a)?@"On":@"Off"):item.action==KPAction::Sound?(sound?@"On":@"Off"):(item.action==KPAction::Mode||item.action==KPAction::Section)&&item.selected?@"Selected":item.action==KPAction::Birthday&&item.field?KPBirthdayPart(a,item.field):nil;
        // Adjustments say where they are in their range.
        if(item.action==KPAction::Adjust){auto f=kartpad::mii::AppearanceFields[item.field];value=[NSString stringWithFormat:@"%u of %u",a.Get(item.field)-f.minimum+1,f.maximum-f.minimum+1];}
#if TARGET_OS_OSX
        if(item.action==KPAction::Sound)[button setAccessibilityValue:@(sound)];else [button setAccessibilityValue:value];
#else
        BOOL selected=item.action==KPAction::Category||item.action==KPAction::Mode||item.action==KPAction::Section?item.selected:item.action==KPAction::Select?a.Get(item.field)==unsigned(item.value):item.action==KPAction::Sound?sound:item.action==KPAction::Toggle&&KPToggleOn(item,a);button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0)|(!item.enabled?UIAccessibilityTraitNotEnabled:0);button.accessibilityValue=value;
#endif
        // Every state drawItem reads besides hover, press and focus, which repaint themselves.
        BOOL chosen=item.action==KPAction::Select?a.Get(item.field)==unsigned(item.value):item.selected;
        NSUInteger look=NSUInteger(item.enabled)|NSUInteger(chosen)<<1|NSUInteger(item.action==KPAction::Toggle&&KPToggleOn(item,a))<<2|NSUInteger(item.action==KPAction::Sound&&sound)<<3|(item.action==KPAction::Birthday?NSUInteger(a.Get(1))<<4|NSUInteger(a.Get(2))<<8:0);
        id art=item.action==KPAction::Select&&item.field&&!KPColorField(item.field)?self.editor.thumbnails[[NSString stringWithFormat:@"%u:%d",item.field,item.value]]:nil;
        if(item.action==KPAction::LookAlike&&NSUInteger(item.value)<self.editor.lookAlikes.count)art=[KPMiiPortraits() objectForKey:self.editor.lookAlikes[item.value]];
        if(item.action==KPAction::Start&&item.value==0)art=[KPMiiPortraits() objectForKey:[self.editor scratch]];
        if(item.action==KPAction::Start&&item.value==1){NSUInteger ready=0;for(NSUInteger k=0;k<4&&k<self.editor.lookAlikes.count;k++)ready+=[KPMiiPortraits() objectForKey:self.editor.lookAlikes[k]]!=nil;look|=ready<<16;}
        if(look==button.look&&art==button.art)continue;
        button.look=look;button.art=art;
#if TARGET_OS_OSX
        button.needsDisplay=YES;
#else
        [button setNeedsDisplay];
#endif
    }
}
- (void)rebuild{
    if(!self.editor.draft)return;KPUsePalette(self);
    for(id view in self.subviews.copy)if(view!=self.editor.preview)[view removeFromSuperview];
    _hoverIndex=NSNotFound;self.buttons=[NSMutableArray array];self.editor.nameFields=[NSMutableArray array];self.editor.nameHints=[NSMutableArray array];_items.clear();
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;BOOL compact=w<680;
    // Portrait phones stack the preview above the panel; short screens (landscape phones) put the
    // category tabs in the title row.
    _stacked=compact&&h>w;_shortHeader=!_stacked&&h<540;
    CGFloat margin=compact?12:24,top=_stacked?154:_shortHeader?58:114;
    _footerY=h-44-(compact?10:16);
    CGFloat previewWidth=_stacked?w-2*margin:(w-3*margin)*.34;
    if(_stacked){
        // Footer actions sit on the bottom edge with the status line beside them.
        CGFloat contentBottom=_footerY-10;
        _previewRect=CGRectMake(margin,top,previewWidth,std::min(CGFloat(216),std::max(CGFloat(124),(contentBottom-top)*.3)));
        _panelRect=CGRectMake(margin,CGRectGetMaxY(_previewRect)+10,previewWidth,std::max(CGFloat(140),contentBottom-CGRectGetMaxY(_previewRect)-10));
    }else{
        // Save and Cancel sit under the preview, below the status line, so the panel runs to the bottom.
        _previewRect=CGRectMake(margin,top,previewWidth,std::max(CGFloat(120),_footerY-30-top));
        CGFloat panelX=CGRectGetMaxX(_previewRect)+margin;
        _panelRect=CGRectMake(panelX,top,w-margin-panelX,std::max(CGFloat(140),_footerY+44-top));
    }
    // The card header holds the name and turn controls; the Metal view fills the rest on a matching background.
    BOOL tight=compact||h<560;CGFloat header=tight?42:50,turn=tight?32:38;
    _nameRect=CGRectMake(_previewRect.origin.x+16,_previewRect.origin.y+2,_previewRect.size.width-32-3*turn-20,header);
    self.editor.preview.frame=CGRectMake(_previewRect.origin.x+8,_previewRect.origin.y+header,_previewRect.size.width-16,_previewRect.size.height-header-8);
    self.editor.preview.clearColor=MTLClearColorMake(((KPP->well>>16)&255)/255.,((KPP->well>>8)&255)/255.,(KPP->well&255)/255.,1);
    self.editor.preview.hidden=self.editor.creating;
    auto add=[&](KPAction action,CGRect rect,NSString *label,unsigned field=0,int value=0,BOOL selected=NO){_items.push_back({action,rect,field,value,label,YES,selected});};
    id form=nil;CGFloat x=_panelRect.origin.x+12,y=_panelRect.origin.y+12,pw=_panelRect.size.width-24,ph=_panelRect.size.height-24;
    if(self.editor.creating){
        // Title block, a small gender switch, then either the two ways to start or the look-alike grid.
        CGFloat available=_footerY-16-54;BOOL picking=self.editor.pickingLookAlike;
        CGFloat cardW=std::min(CGFloat(250),(w-2*margin-16)/2),cardH=std::max(CGFloat(96),std::min({CGFloat(220),cardW*.9,available-150}));
        CGFloat block=picking?available:136+cardH,top=54+std::max(CGFloat(0),(available-block)/2);
        _nameRect=CGRectMake(margin,top,w-2*margin,66);
        CGFloat pillW=compact?118:128,pillY=top+76;
        add(KPAction::Gender,CGRectMake(w/2-pillW-6,pillY,pillW,44),@"Male",0,0,self.editor.gender==0);
        add(KPAction::Gender,CGRectMake(w/2+6,pillY,pillW,44),@"Female",0,1,self.editor.gender==1);
        CGFloat bodyY=pillY+44+(picking?18:24);
        if(picking){
            unsigned cols=compact?3:4,rows=KPLookAlikeCount/cols;CGFloat gap=compact?8:12,gridH=_footerY-16-bodyY;
            CGFloat side=std::max(CGFloat(40),std::min({CGFloat(150),(w-2*margin-gap*(cols-1))/cols,(gridH-gap*(rows-1))/rows}));
            CGFloat gx=(w-cols*side-gap*(cols-1))/2;
            for(unsigned i=0;i<KPLookAlikeCount;i++)add(KPAction::LookAlike,CGRectMake(gx+(i%cols)*(side+gap),bodyY+(i/cols)*(side+gap),side,side),[NSString stringWithFormat:@"Look-alike %u",i+1],0,int(i));
            add(KPAction::Back,CGRectMake(margin,_footerY,120,44),@"Back");
            add(KPAction::Shuffle,CGRectMake(w-margin-140,_footerY,140,44),@"Shuffle");
        }else{
            add(KPAction::Start,CGRectMake(w/2-cardW-8,bodyY,cardW,cardH),@"Start from scratch",0,0);
            add(KPAction::Start,CGRectMake(w/2+8,bodyY,cardW,cardH),@"Choose a look-alike",0,1);
            add(KPAction::Quit,CGRectMake(margin,_footerY,120,44),@"Cancel");
        }
        add(KPAction::Sound,CGRectMake(w-margin-96,6,96,40),@"Sound effects");
        __weak KPMiiCanvas *weak=self;void(^ready)(void)=^{[weak redraw];};
        KPMiiRequestPortrait([self.editor scratch],ready);for(NSData *mii in self.editor.lookAlikes)KPMiiRequestPortrait(mii,ready);
    }else{
        // Category tabs: one row, two on portrait phones, or beside undo, redo and ⋯ on short screens
        // (where Sound effects moves into the ⋯ menu).
        CGFloat gap=compact?5:8;int cols=_stacked?5:10;CGFloat tabsW=_shortHeader?w-2*margin-136-12:w-2*margin,tw=(tabsW-gap*(cols-1))/cols,tabY=_shortHeader?8:54;
        for(unsigned i=0;i<10;i++)add(KPAction::Category,CGRectMake(margin+(i%cols)*(tw+gap),tabY+(i/cols)*48,tw,_shortHeader?40:46),[NSString stringWithUTF8String:kartpad::mii::EditorCategories[i]],i,0,self.editor.category==i);
        CGFloat tx=CGRectGetMaxX(_previewRect)-8-turn,ty=_previewRect.origin.y+(header-turn)/2+2;
        add(KPAction::Rotate,CGRectMake(tx-2*(turn+6),ty,turn,turn),@"Turn left",0,-1);
        add(KPAction::Front,CGRectMake(tx-turn-6,ty,turn,turn),@"Face front");
        add(KPAction::Rotate,CGRectMake(tx,ty,turn,turn),@"Turn right",0,1);
        CGFloat saveW=compact?150:164,cancelW=compact?110:120;
        if(_stacked){
            saveW=std::min(saveW,(w-2*margin)*.3);cancelW=std::min(cancelW,(w-2*margin)*.24);_statusWidth=w-2*margin-saveW-cancelW-20;
            add(KPAction::Save,CGRectMake(w-margin-saveW,_footerY,saveW,44),@"Save");
            add(KPAction::Discard,CGRectMake(w-margin-saveW-10-cancelW,_footerY,cancelW,44),@"Cancel");
        }else{
            if(saveW+10+cancelW>previewWidth){saveW=(previewWidth-10)*.56;cancelW=previewWidth-10-saveW;}
            add(KPAction::Save,CGRectMake(CGRectGetMaxX(_previewRect)-saveW,_footerY,saveW,44),@"Save");
            add(KPAction::Discard,CGRectMake(CGRectGetMaxX(_previewRect)-saveW-10-cancelW,_footerY,cancelW,44),@"Cancel");
        }
        CGFloat ay=_shortHeader?8:6;
        if(!_shortHeader)add(KPAction::Sound,CGRectMake(w-margin-136-12-96,6,96,40),@"Sound effects");
        add(KPAction::Undo,CGRectMake(w-margin-136,ay,40,40),@"Undo");add(KPAction::Redo,CGRectMake(w-margin-88,ay,40,40),@"Redo");add(KPAction::More,CGRectMake(w-margin-40,ay,40,40),@"More");
        auto appearance=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));
        CGRect frame=CGRectInset(_panelRect,12,12);
#if TARGET_OS_OSX
        // Every page fits its panel, so the form is a plain view.
        KPMiiCanvas *document=[[KPMiiCanvas alloc]initWithFrame:frame];[self addSubview:document];form=document;
#else
        // Every page fits its panel; the scroll view is only there to lift a name field above the keyboard.
        UIScrollView *scroll=[[UIScrollView alloc]initWithFrame:frame];scroll.contentSize=frame.size;scroll.showsVerticalScrollIndicator=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self addSubview:scroll];form=scroll;
#endif
        // A page that can't show everything at once splits into parts, picked from a strip of tabs on
        // the panel's right edge (as the Mii Maker does on small screens). Returns the width left of it.
        auto strip=[&](std::vector<KPItem> tabs)->CGFloat{
            CGFloat sw=compact?76:84;for(size_t i=0;i<tabs.size();i++){tabs[i].rect=CGRectMake(x+pw-sw,y+i*50,sw,44);_items.push_back(tabs[i]);}
            return pw-sw-12;};
        if(self.editor.category==0){
            // Laid out at a given width, all at once (part -1) or as the Name (0) or Details (1) part, with
            // roomy or dense spacing. Returns the height used; only adds controls when emit is set.
            auto profile=[&](CGFloat cw,int part,BOOL dense,CGFloat g,BOOL emit)->CGFloat{
                BOOL two=cw>=432;CGFloat fy=0,labelH=dense?18:22,below=dense?20:26,button=dense?40:44,block=below+button;
                auto label=[&](NSString *text,CGFloat lx,CGFloat ly,CGFloat lw){if(emit)[form addSubview:KPLabelView(text,CGRectMake(lx+2,ly,lw-2,labelH),dense?13:14,YES,YES)];};
                auto birthday=[&](CGFloat bx,CGFloat bw){
                    label(@"Birthday",bx,fy,bw);if(!emit)return;
#if TARGET_OS_OSX
                    // Month and day: Wii faces like Male/Female that open a menu of choices.
                    CGFloat mw=(bw-8)*.62;
                    add(KPAction::Birthday,CGRectMake(x+bx,y+fy+below,mw,button),@"Birthday month",1);
                    add(KPAction::Birthday,CGRectMake(x+bx+mw+8,y+fy+below,bw-8-mw,button),@"Birthday day",2);_items.back().enabled=appearance.Get(1)>0;
#else
                    add(KPAction::Birthday,CGRectMake(x+bx,y+fy+below,bw,button),KPBirthdayLabel(appearance));
#endif
                };
                if(part!=1){
                    // Nickname and Creator side by side when there is room; each has its count below.
                    BOOL pair=cw>=300;CGFloat nw=pair?(cw-16)/2:cw,fieldH=dense?32:34,name=below+fieldH+(dense?18:24);
                    for(unsigned n=0;n<2&&emit;n++){
                        CGFloat fx=pair?n*(nw+16):0,ry=pair?0:n*(name+g);
                        label(n?@"Creator":@"Nickname",fx,ry,nw);
#if TARGET_OS_OSX
                        NSTextField *field=[NSTextField textFieldWithString:KPMiiName(self.editor.draft,n?54:2)];field.font=[NSFont systemFontOfSize:18];field.delegate=self.editor;field.frame=CGRectMake(fx,ry+below,nw,fieldH);field.bezelStyle=NSTextFieldRoundedBezel;
                        field.toolTip=KPMiiNameRule;
#else
                        UITextField *field=[[UITextField alloc]initWithFrame:CGRectMake(fx,ry+below,nw,fieldH+2)];field.text=KPMiiName(self.editor.draft,n?54:2);field.font=[UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:18] maximumPointSize:24];field.adjustsFontForContentSizeCategory=YES;field.borderStyle=UITextBorderStyleRoundedRect;field.autocorrectionType=UITextAutocorrectionTypeNo;field.delegate=self.editor;[field addTarget:self.editor action:@selector(nameChanged:) forControlEvents:UIControlEventEditingChanged];
                        field.accessibilityHint=KPMiiNameRule;
#endif
                        field.tag=n?54:2;[form addSubview:field];[self.editor.nameFields addObject:field];
                        id hint=KPLabelView(KPMiiNameCount(KPMiiName(self.editor.draft,field.tag)),CGRectMake(fx+2,ry+below+fieldH+4,nw-2,dense?16:20),12,NO,YES);[hint setTag:field.tag];[form addSubview:hint];[self.editor.nameHints addObject:hint];
                    }
                    fy+=(pair?name:2*name+g)+g;
                    CGFloat gw=two?(cw-16)/2:cw;
                    label(@"Gender",0,fy,gw);
                    if(emit){add(KPAction::Select,CGRectMake(x,y+fy+below,(gw-8)/2,button),@"Male",0,0);add(KPAction::Select,CGRectMake(x+(gw+8)/2,y+fy+below,(gw-8)/2,button),@"Female",0,1);}
                    if(two&&part<0)birthday(gw+16,gw);
                    fy+=block+g;
                }
                if(part==0)return fy-g;
                if(!(two&&part<0)){birthday(0,two?(cw-16)/2:cw);fy+=block+g;}
                // Favorite and Mingle side by side when there is room.
                BOOL pair=cw>=272;CGFloat sw=pair?(cw-12)/2:cw,toggle=dense?40:46;
                if(emit){add(KPAction::Toggle,CGRectMake(x,y+fy,sw,toggle),@"Favorite",4);add(KPAction::Toggle,CGRectMake(pair?x+sw+12:x,pair?y+fy:y+fy+toggle+8,sw,toggle),@"Mingle",10);}
                fy+=(pair?toggle:2*toggle+8)+g;
                label(@"Favorite color",0,fy,cw);
                unsigned perRow=cw>=12*36+11*6?12:cw>=6*34+5*6?6:4;CGFloat chipW=std::min(CGFloat(50),(cw-(perRow-1)*6)/perRow),chipH=std::min(CGFloat(46),std::max(CGFloat(dense?36:38),chipW));
                for(unsigned i=0;i<12&&emit;i++)add(KPAction::Select,CGRectMake(x+(i%perRow)*(chipW+6),y+fy+labelH+6+(i/perRow)*(chipH+6),chipW,chipH),@"Favorite color",3,i);
                return fy+labelH+6+((11+perRow)/perRow)*(chipH+6)-6;
            };
            // Roomy, then tighter, then dense on one page; failing that, split into Name and Details.
            if(profile(pw,-1,NO,16,NO)<=ph)profile(pw,-1,NO,16,YES);
            else if(profile(pw,-1,NO,10,NO)<=ph)profile(pw,-1,NO,10,YES);
            else if(profile(pw,-1,YES,8,NO)<=ph)profile(pw,-1,YES,8,YES);
            else{
                self.editor.section=std::min(self.editor.section,1u);
                CGFloat cw=strip({{KPAction::Section,{},0,0,@"Name",YES,self.editor.section==0},{KPAction::Section,{},0,1,@"Details",YES,self.editor.section==1}});
                BOOL dense=profile(cw,int(self.editor.section),NO,10,NO)>ph;profile(cw,int(self.editor.section),dense,dense?8:10,YES);
            }
        }else if(self.editor.category==1){
            // Height and weight rows give up space down to a compact gauge before the note does.
            CGFloat noteH=pw<400?66:44,row=std::clamp((ph-32-noteH)/2,CGFloat(76),CGFloat(124));
            for(unsigned n=0;n<2;n++){
                CGFloat sy=n*row;
                [form addSubview:KPLabelView(n?@"Weight":@"Height",CGRectMake(4,sy,pw-8,26),18,YES)];
                KPMiiBodySlider *slider=[[KPMiiBodySlider alloc]initWithFrame:CGRectMake(0,sy+28,pw,std::min(CGFloat(64),row-32))];slider.editor=self.editor;slider.field=n?6:5;
#if TARGET_OS_OSX
                [slider setAccessibilityLabel:n?@"Weight":@"Height"];
#else
                slider.accessibilityLabel=n?@"Weight":@"Height";slider.backgroundColor=UIColor.clearColor;slider.opaque=NO;
#endif
                [form addSubview:slider];
            }
            // The game snaps height + weight to one of three body models; say which one the preview shows.
            id build=KPLabelView(KPBuildName(appearance),CGRectMake(4,2*row+4,pw-8,24),17,YES);[form addSubview:build];self.editor.buildLabel=build;
            id note=KPLabelView(@"Mario Kart Wii uses height and weight together to pick a small, medium or large Mii. This also sets its kart and bike size.",CGRectMake(4,2*row+32,pw-8,noteH),13,NO,YES);[form addSubview:note];
        }else{
            auto ids=kartpad::mii::FeatureIds(self.editor.feature);unsigned pages=unsigned((ids.size()+11)/12);self.editor.page=std::min(self.editor.page,std::max(1u,pages)-1);
            unsigned category=unsigned(self.editor.category);
            unsigned colorField=category==2?8:category==3?12:category==4?22:category==5?17:category==7?30:category==8?39:category==9?34:99;
            unsigned colors=colorField!=99?kartpad::mii::AppearanceFields[colorField].maximum+1:0;
            // Two-part switches name both grids and highlight the one showing.
            std::vector<std::pair<unsigned,NSString*>> modes;
            if(category==2)modes={{7,@"Shape"},{9,@"Details"}};
            if(category==8)modes={{37,@"Mustache"},{38,@"Beard"}};
            unsigned toggleField=category==3?13:category==8?42:0;NSString *toggleLabel=category==3?@"Flip hair":@"Mole";
            // Each adjustment names its section and spells out both directions for VoiceOver and tooltips.
            struct KPAdjustment{unsigned field;NSString *title,*less,*more;};
            NSString *up=@"Move up",*down=@"Move down",*smaller=@"Smaller",*larger=@"Larger";
            std::vector<KPAdjustment> adjustments;
            switch(category){
            case 4:adjustments={{24,@"Position",up,down},{23,@"Size",smaller,larger},{21,@"Tilt",@"Tilt outer ends down",@"Tilt outer ends up"},{25,@"Spacing",@"Closer together",@"Farther apart"}};break;
            case 5:adjustments={{16,@"Position",up,down},{18,@"Size",smaller,larger},{15,@"Tilt",@"Tilt outer ends down",@"Tilt outer ends up"},{19,@"Spacing",@"Closer together",@"Farther apart"}};break;
            case 6:adjustments={{28,@"Position",up,down},{27,@"Size",smaller,larger}};break;
            case 7:adjustments={{32,@"Position",up,down},{31,@"Size",smaller,larger}};break;
            case 8:adjustments=appearance.Get(42)?std::vector<KPAdjustment>{{44,@"Mole position",up,down},{43,@"Mole size",smaller,larger},{45,@"Mole sideways",@"Move left",@"Move right"}}:std::vector<KPAdjustment>{{41,@"Position",up,down},{40,@"Size",smaller,larger}};break;
            case 9:adjustments={{36,@"Position",up,down},{35,@"Size",smaller,larger}};break;
            }
            CGFloat pager=pages>1?52:0,tileGap=compact?7:10,gap2=compact?8:14;
            // The style grid: three across, four down, with the pager above it only when there is more than one page.
            auto grid=[&](CGFloat gw){
                CGFloat tileW=(gw-2*tileGap)/3,tileH=std::max(CGFloat(40),std::min(tileW,(ph-pager-3*tileGap)/4));
                if(pages>1){
                    add(KPAction::Page,CGRectMake(x,y,44,44),@"Previous page",0,-1);_items.back().enabled=self.editor.page>0;
                    add(KPAction::Page,CGRectMake(x+gw-44,y,44,44),@"Next page",0,1);_items.back().enabled=self.editor.page+1<pages;
                    id label=KPLabelView([NSString stringWithFormat:gw-104<110?@"%u / %u":@"Page %u of %u",self.editor.page+1,pages],CGRectMake(52,11,gw-104,22),14,YES,YES);
#if TARGET_OS_OSX
                    [label setAlignment:NSTextAlignmentCenter];
#else
                    [label setTextAlignment:NSTextAlignmentCenter];
#endif
                    [form addSubview:label];
                }
                for(unsigned i=0;i<12&&self.editor.page*12+i<ids.size();i++){unsigned value=ids[self.editor.page*12+i];add(KPAction::Select,CGRectMake(x+(i%3)*(tileW+tileGap),y+pager+(i/3)*(tileH+tileGap),tileW,tileH),@"Feature",self.editor.feature,value);}
            };
            // Color chips perRow across, at most chipMax tall.
            auto chips=[&](CGFloat sx,CGFloat sy,CGFloat cw,unsigned perRow,CGFloat chipMax,BOOL emit)->CGFloat{
                CGFloat chipW=std::min(chipMax*1.25,(cw-(perRow-1)*6)/perRow),chipH=std::min(chipMax,chipW);
                for(unsigned i=0;i<colors&&emit;i++)add(KPAction::Select,CGRectMake(sx+(i%perRow)*(chipW+6),sy+(i/perRow)*(chipH+6),chipW,chipH),@"Color",colorField,i);
                return ((colors+perRow-1)/perRow)*(chipH+6)-6;};
            // A column wide enough for the longest title puts each adjustment on one row (less, title, more);
            // a narrower one stacks the title above the two buttons.
            CGFloat oneRow=176;
            for(const auto &adjustment:adjustments){CGFloat size=TARGET_OS_OSX?12:14;oneRow=std::max(oneRow,std::ceil([adjustment.title sizeWithAttributes:@{NSFontAttributeName:KPStyleFont(size,NSFontWeightSemibold)}].width)+108);}
            auto adjust=[&](CGFloat sx,CGFloat sy,CGFloat cw,BOOL emit)->CGFloat{
                BOOL inline_=cw>=oneRow;CGFloat sy0=sy;
                for(const auto &adjustment:adjustments){
                    CGFloat lx=inline_?sx+52:sx+2,lw=inline_?cw-104:cw-4,ly=inline_?sy+13:sy;
                    if(emit){
                        [form addSubview:KPLabelView(adjustment.title,CGRectMake(lx-x,ly-y,lw,18),12,YES,YES)];
                        if(inline_){add(KPAction::Adjust,CGRectMake(sx,sy,44,44),adjustment.less,adjustment.field,-1);add(KPAction::Adjust,CGRectMake(sx+cw-44,sy,44,44),adjustment.more,adjustment.field,1);}
                        else{add(KPAction::Adjust,CGRectMake(sx,sy+24,(cw-6)/2,44),adjustment.less,adjustment.field,-1);add(KPAction::Adjust,CGRectMake(sx+(cw+6)/2,sy+24,(cw-6)/2,44),adjustment.more,adjustment.field,1);}
                    }
                    sy+=inline_?52:76;}
                return std::max(CGFloat(0),sy-sy0-8);};
            auto modeSwitch=[&](CGFloat sx,CGFloat sy,CGFloat cw){CGFloat half=(cw-4)/2;for(size_t i=0;i<modes.size();i++)add(KPAction::Mode,CGRectMake(sx+i*(half+4),sy,half,44),modes[i].second,modes[i].first,0,self.editor.feature==modes[i].first);};
            // Everything on one page: the grid, then a column of colors, switches and adjustments.
            CGFloat side=compact?138:std::min(CGFloat(164),pw*.36);
            if(!adjustments.empty()&&side<oneRow&&(pw-oneRow-gap2-2*tileGap)/3>=56)side=oneRow;
            auto column=[&](BOOL emit)->CGFloat{
                CGFloat sx=x+pw-side,sy=y;
                if(colors){sy+=chips(sx,sy,side,3,46,emit)+10;}
                if(!modes.empty()){if(emit)modeSwitch(sx,sy,side);sy+=54;}
                if(toggleField){if(emit)add(KPAction::Toggle,CGRectMake(sx,sy,side,46),toggleLabel,toggleField);sy+=56;}
                sy+=adjust(sx,sy,side,emit);
                return sy-y;};
            CGFloat gridW=pw-side-gap2,tileW=(gridW-2*tileGap)/3,tileH=std::min(tileW,(ph-pager-3*tileGap)/4);
            if(column(NO)<=ph&&tileH>=44){grid(gridW);column(YES);}
            else{
                // Split: the grid (one tab per switch position), the colors, then the switch and adjustments.
                std::vector<KPItem> tabs;
                for(const auto &mode:modes)tabs.push_back({KPAction::Mode,{},mode.first,0,mode.second,YES,self.editor.section==0&&self.editor.feature==mode.first});
                if(modes.empty())tabs.push_back({KPAction::Section,{},0,0,@"Style",YES,self.editor.section==0});
                if(colors)tabs.push_back({KPAction::Section,{},0,1,@"Color",YES,self.editor.section==1});
                if(toggleField||!adjustments.empty())tabs.push_back({KPAction::Section,{},0,2,@"Adjust",YES,self.editor.section==2});
                if(std::none_of(tabs.begin(),tabs.end(),[&](const KPItem &tab){return tab.action==KPAction::Mode?self.editor.section==0:tab.value==int(self.editor.section);})){self.editor.section=0;for(auto &tab:tabs)tab.selected=tab.action==KPAction::Mode?self.editor.feature==tab.field:tab.value==0;}
                CGFloat cw=strip(tabs);
                if(self.editor.section==0)grid(cw);
                else if(self.editor.section==1){
                    // As few rows as fit, with chips no larger than 64 points.
                    unsigned perRow=3;while(perRow<colors&&chips(x,y,cw,perRow,64,NO)>ph)perRow++;
                    chips(x,y,cw,perRow,64,YES);
                }else{
                    CGFloat sy=y;
                    if(toggleField){add(KPAction::Toggle,CGRectMake(x,sy,std::min(cw,CGFloat(240)),46),toggleLabel,toggleField);sy+=56;}
                    adjust(x,sy,std::min(cw,std::max(oneRow,CGFloat(360))),YES);
                }
            }
        }
    }
    for(NSUInteger i=0;i<_items.size();i++){
        auto &item=_items[i];KPMiiWiiButton *button=[[KPMiiWiiButton alloc]initWithFrame:item.rect];button.canvas=self;button.index=i;button.look=NSUIntegerMax;
        NSString *label=item.action==KPAction::Select?[NSString stringWithFormat:@"%@, choice %d",item.label,item.value+1]:item.label;
#if TARGET_OS_OSX
        button.bordered=NO;button.title=@"";button.target=button;button.action=@selector(activate);[button setAccessibilityLabel:label];[button setAccessibilityRole:item.action==KPAction::Sound?NSAccessibilityCheckBoxRole:NSAccessibilityButtonRole];
        if(item.action!=KPAction::Select&&item.action!=KPAction::Toggle)button.toolTip=item.label;
#else
        button.accessibilityLabel=label;button.accessibilityTraits=UIAccessibilityTraitButton;[button addGestureRecognizer:[[UIHoverGestureRecognizer alloc]initWithTarget:button action:@selector(hover:)]];[button addTarget:button action:@selector(down) forControlEvents:UIControlEventTouchDown];
        [button addTarget:button action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];[button addTarget:button action:@selector(up) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel|UIControlEventTouchDragExit];
#endif
        if(form&&item.action!=KPAction::Save&&item.action!=KPAction::Discard&&item.rect.origin.x>=x&&item.rect.origin.y>=y){CGRect frame=item.rect;frame.origin.x-=x;frame.origin.y-=y;button.frame=frame;[form addSubview:button];}else [self addSubview:button];[self.buttons addObject:button];
    }
    [self redraw];
}
- (void)drawRect:(CGRect)rect{
    // Scroll documents are transparent over the panel the main canvas draws.
    if(!self.editor)return;
#if TARGET_OS_OSX
    CGContextRef c=NSGraphicsContext.currentContext.CGContext;
#else
    CGContextRef c=UIGraphicsGetCurrentContext();
#endif
    KPUsePalette(self);KPFill(c,self.bounds,KPP->background);CGFloat w=self.bounds.size.width,h=self.bounds.size.height;BOOL compact=w<680;
    // Wii menu pinstripes.
    KPSetInk(c,KPP->stripe);CGContextSetLineWidth(c,1);for(CGFloat y=1.5;y<h;y+=4)KPLine(c,0,y,w,y);
    if(self.editor.creating){BOOL picking=self.editor.pickingLookAlike;
        NSString *note=!picking?@"Start from scratch, or pick from random look-alikes.":KPMiiPortraitProblem.length?@"Faces appear once game data is imported.":@"Pick a face to start from, or shuffle for new ones.";
        KPText(picking?@"Choose a look-alike":@"Create a Mii",CGRectMake(_nameRect.origin.x,_nameRect.origin.y,_nameRect.size.width,38),28,KPP->text,YES);
        KPText(note,CGRectMake(_nameRect.origin.x,_nameRect.origin.y+40,_nameRect.size.width,24),16,KPP->secondaryText);
        return;}
    // Short screens show the category only as the selected tab.
    if(!_shortHeader)KPText([NSString stringWithUTF8String:kartpad::mii::EditorCategories[self.editor.category]],CGRectMake(compact?12:24,13,w-200,28),21,KPP->text,YES,NSTextAlignmentLeft);
    for(CGRect card:{_previewRect,_panelRect}){KPFill(c,CGRectOffset(card,0,2),0x000000,18,KPP->shadow*.6);KPFill(c,card,KPP->panel,18);KPStroke(c,card,KPP->panelStroke,1,18);}
    CGRect well=CGRectInset(self.editor.preview.frame,-4,-4);KPFill(c,well,KPP->well,13);
    KPCenteredText(KPMiiName(self.editor.draft,2),_nameRect,_nameRect.size.height<46?16:18,KPP->text,YES,NSTextAlignmentLeft);
    NSString *message=self.editor.validationMessage.length?self.editor.validationMessage:self.editor.previewMessage;
    unsigned tone=self.editor.validationMessage.length?0xd64545:KPP->secondaryText;
    CGFloat margin=compact?12:24;
    // Beside Save and Cancel when stacked; otherwise under the preview, above them.
    if(message.length){if(_stacked)KPText(message,CGRectMake(margin,_footerY+4,_statusWidth,36),11,tone,NO,NSTextAlignmentLeft);else KPText(message,CGRectMake(margin+4,_footerY-25,_previewRect.size.width-8,18),compact?11:12,tone,NO,NSTextAlignmentLeft);}
}
- (void)drawItem:(NSUInteger)i context:(CGContextRef)c pressed:(BOOL)pressed{
    if(i>=_items.size())return;KPUsePalette(self);const auto &item=_items[i];auto a=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));
    CGRect r=CGRectMake(1,1,item.rect.size.width-2,item.rect.size.height-2),face=CGRectMake(r.origin.x,r.origin.y,r.size.width,r.size.height-3);
    if(item.action==KPAction::Sound){
        BOOL on=[KPMiiSounds shared].enabled;CGFloat side=26;CGRect box=CGRectMake(2,(r.size.height-side-3)/2+1,side,side+3);
        KPButtonFace(c,box,KPStyle::Plain,on,YES,pressed,i==_hoverIndex);
        if(on)KPControlIcon(c,CGRectMake(box.origin.x+3,box.origin.y+3+(pressed?2:0),side-6,side-6),KPGlyph::Check,0,KPP->accentBottom);
        KPCenteredText(@"Sound",CGRectMake(side+10,0,r.size.width-side-10,r.size.height),15,KPP->text,YES,NSTextAlignmentLeft);return;
    }
    BOOL selected=item.selected;if(item.action==KPAction::Select)selected=a.Get(item.field)==unsigned(item.value);
    KPAction action=item.action;BOOL round=action==KPAction::Undo||action==KPAction::Redo||action==KPAction::More||action==KPAction::Rotate||action==KPAction::Front||action==KPAction::Page;
    KPStyle style=action==KPAction::Category?KPStyle::Tab:action==KPAction::Save?KPStyle::Primary:action==KPAction::Start?KPStyle::Card:action==KPAction::LookAlike?KPStyle::Art:action==KPAction::Select&&item.field!=0?(KPColorField(item.field)?KPStyle::Tile:KPStyle::Art):round?KPStyle::Round:KPStyle::Plain;
    KPButtonFace(c,r,style,selected,item.enabled,pressed,i==_hoverIndex);
    CGContextSaveGState(c);if(!item.enabled)CGContextSetAlpha(c,.42);if(pressed)CGContextTranslateCTM(c,0,2);
    unsigned ink=style==KPStyle::Primary||(style==KPStyle::Tab&&selected)?0xffffff:KPP->icon;
    CGFloat glyphSide=std::min(face.size.width,face.size.height)*(round?.6:.68);CGRect glyph=CGRectMake(CGRectGetMidX(face)-glyphSide/2,CGRectGetMidY(face)-glyphSide/2,glyphSide,glyphSide);
    switch(action){
    case KPAction::Category:{CGFloat side=std::min(CGFloat(32),face.size.height-10);KPIcon(c,item.field,CGRectMake(CGRectGetMidX(face)-side/2,CGRectGetMidY(face)-side/2,side,side),ink);break;}
    case KPAction::Gender:{CGFloat side=face.size.height-12;CGSize text=CGSizeMake(item.value?66:46,face.size.height);CGFloat left=CGRectGetMidX(face)-(side+6+text.width)/2;
        KPIcon(c,item.value?10:11,CGRectMake(left,6,side,side),selected?KPP->accentStroke:KPP->icon);KPCenteredText(item.label,CGRectMake(left+side+6,0,text.width,face.size.height),16,selected?KPP->accentStroke:KPP->text,YES,NSTextAlignmentLeft);break;}
    case KPAction::Start:{
        // Light portrait wells, as on the Miis screen, so dark hair shows in dark mode.
        CGFloat label=34,side=std::min(face.size.width-28,face.size.height-label-18);CGRect well=CGRectMake(CGRectGetMidX(face)-side/2,12,side,side);
        KPFill(c,well,KPLightPalette.well,side*.12);
        if(item.value==0){if(KPMiiImage *image=[KPMiiPortraits() objectForKey:[self.editor scratch]])KPDrawImage(image,CGRectInset(well,side*.1,side*.1));else KPIcon(c,12,CGRectInset(well,side*.16,side*.16),KPLightPalette.icon);}
        else{// A 2 × 2 sample of the look-alike pool.
            NSArray<NSData*> *faces=self.editor.lookAlikes;BOOL any=NO;CGFloat cell=side*.42,gap=side*.04;
            for(NSUInteger k=0;k<4&&k<faces.count;k++)if(KPMiiImage *image=[KPMiiPortraits() objectForKey:faces[k]]){any=YES;KPDrawImage(image,CGRectMake(CGRectGetMidX(well)+(k%2?gap/2:-gap/2-cell),CGRectGetMidY(well)+(k/2?gap/2:-gap/2-cell),cell,cell));}
            if(!any)KPIcon(c,13,CGRectInset(well,side*.12,side*.12),KPLightPalette.icon);}
        KPCenteredText(item.label,CGRectMake(4,CGRectGetMaxY(well)+4,face.size.width-8,face.size.height-CGRectGetMaxY(well)-6),face.size.width<200?16:18,KPP->text,YES);break;}
    case KPAction::LookAlike:{
        NSData *mii=NSUInteger(item.value)<self.editor.lookAlikes.count?self.editor.lookAlikes[item.value]:nil;CGRect well=CGRectInset(face,face.size.width*.08,face.size.height*.08);
        if(KPMiiImage *image=mii?[KPMiiPortraits() objectForKey:mii]:nil)KPDrawImage(image,well);
        else{CGContextSetAlpha(c,.3);KPIcon(c,2,CGRectInset(well,well.size.width*.14,well.size.height*.14),KPLightPalette.icon);}
        break;}
    case KPAction::Select:
        if(item.field==0){KPCenteredText(item.label,face,16,KPP->text,selected);break;}
        if(KPColorField(item.field)){
            using namespace kartpad::mii;Color color=item.field==3?Shirt[item.value]:item.field==8?Skin[item.value]:item.field==17?Eyes[item.value]:item.field==30?Lip0[item.value]:item.field==34?Glasses[item.value]:Hair[item.value];
            unsigned hex=(color[0]<<16)|(color[1]<<8)|color[2];CGRect chip=CGRectInset(face,5,5);KPFill(c,chip,hex,8);KPStroke(c,chip,0x000000,1,8,.16);
            if(selected){CGFloat luma=(.299*color[0]+.587*color[1]+.114*color[2])/255;CGFloat side=std::min(chip.size.width,chip.size.height)*.62;KPControlIcon(c,CGRectMake(CGRectGetMidX(chip)-side/2,CGRectGetMidY(chip)-side/2,side,side),KPGlyph::Check,0,luma>.62?0x263238:0xffffff);}
            break;
        }
        if(KPMiiImage *image=self.editor.thumbnails[[NSString stringWithFormat:@"%u:%d",item.field,item.value]]){
            CGSize size=image.size;CGRect box=CGRectInset(face,face.size.width*.13,face.size.height*.13);CGFloat scale=std::min(box.size.width/size.width,box.size.height/size.height);
            CGRect destination=CGRectMake(CGRectGetMidX(face)-size.width*scale/2,CGRectGetMidY(face)-size.height*scale/2,size.width*scale,size.height*scale);
#if TARGET_OS_OSX
            [image drawInRect:destination fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
#else
            [image drawInRect:destination];
#endif
        }else if((item.field==33||item.field==37||item.field==38)&&item.value==0){CGFloat side=std::min(face.size.width,face.size.height)*.42;KPControlIcon(c,CGRectMake(CGRectGetMidX(face)-side/2,CGRectGetMidY(face)-side/2-7,side,side),KPGlyph::None,0,KPLightPalette.icon);KPText(@"None",CGRectMake(0,CGRectGetMidY(face)+side/2-4,face.size.width,18),12,KPLightPalette.secondaryText,YES);}
        else{CGContextSetAlpha(c,.25);KPIcon(c,self.editor.category,CGRectInset(face,face.size.width*.25,face.size.height*.25),KPLightPalette.icon);}
        break;
    case KPAction::Page:KPControlIcon(c,glyph,KPGlyph::Chevron,item.value,ink);break;
    case KPAction::Rotate:KPControlIcon(c,glyph,KPGlyph::Turn,item.value,ink);break;
    case KPAction::Front:KPControlIcon(c,glyph,KPGlyph::Front,0,ink);break;
    case KPAction::Undo:case KPAction::Redo:KPControlIcon(c,glyph,KPGlyph::Undo,action==KPAction::Undo?-1:1,ink);break;
    case KPAction::More:KPControlIcon(c,glyph,KPGlyph::More,0,ink);break;
    case KPAction::Adjust:{
        unsigned f=item.field;BOOL move=f==16||f==24||f==28||f==32||f==36||f==41||f==44,spacing=f==19||f==25,rotation=f==15||f==21;
        KPControlIcon(c,glyph,f==45?KPGlyph::Across:move?KPGlyph::Move:spacing?KPGlyph::Spacing:rotation?KPGlyph::Rotate:KPGlyph::Size,item.value,ink);break;}
    case KPAction::Toggle:{
        CGRect track=CGRectMake(CGRectGetMaxX(face)-12-40,CGRectGetMidY(face)-12,40,24);
        KPCenteredText(item.label,CGRectMake(14,0,track.origin.x-20,face.size.height),face.size.width<150?13:15,KPP->text,NO,NSTextAlignmentLeft);KPSwitch(c,track,KPToggleOn(item,a));break;}
    case KPAction::Birthday:
        if(!item.field){KPCenteredText(KPBirthdayLabel(a),face,16,KPP->text);break;}
        {// A small down chevron marks the menu.
            CGFloat cx=face.size.width-20,cy=CGRectGetMidY(face);
            KPCenteredText(KPBirthdayPart(a,item.field),CGRectMake(14,0,cx-26,face.size.height),16,KPP->text,NO,NSTextAlignmentLeft);
            KPSetInk(c,KPP->icon);CGContextSetLineWidth(c,2.6);CGContextSetLineCap(c,kCGLineCapRound);CGContextSetLineJoin(c,kCGLineJoinRound);
            CGContextMoveToPoint(c,cx-6,cy-3);CGContextAddLineToPoint(c,cx,cy+3);CGContextAddLineToPoint(c,cx+6,cy-3);CGContextStrokePath(c);
        }
        break;
    case KPAction::Mode:case KPAction::Section:KPCenteredText(item.label,face,face.size.width<80?13:14,selected?KPP->accentStroke:KPP->text,YES);break;
    default:KPCenteredText(item.label,face,style==KPStyle::Primary?16:15,style==KPStyle::Primary?0xffffff:KPP->text,YES);break;
    }
    CGContextRestoreGState(c);
}
@end
@implementation KPMiiEditor
// A new Mii is unsaved until it is saved; otherwise only edits since opening count.
- (BOOL)dirty{return (!self.creating&&self.slot==NSNotFound)||[self edited];}
// Changed since the editor opened, or since a new Mii's face was chosen.
- (BOOL)edited{
    if(![self.draft isEqualToData:self.original])return YES;
    for(id field in self.nameFields){
#if TARGET_OS_OSX
        NSString *text=[field stringValue];
#else
        NSString *text=[field text]?:@"";
#endif
        if(![text isEqual:KPMiiName(self.original,[field tag])])return YES;
    }return NO;
}
- (void)rebuild{[self.canvas rebuild];}
// The blank face for the chosen gender; female starts with the Mii Channel's female hair, eyes and eyebrows.
- (NSData*)scratch{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));a.Set(0,self.gender);if(self.gender){a.Set(11,12);a.Set(14,4);a.Set(20,0);}
    return [NSData dataWithBytes:a.bytes.data() length:a.bytes.size()];
}
- (void)shuffle{NSMutableArray *seeds=[NSMutableArray array];for(unsigned i=0;i<KPLookAlikeCount;i++)[seeds addObject:@(arc4random())];self.lookSeeds=seeds;[self makeLookAlikes];}
- (void)makeLookAlikes{
    auto base=kartpad::mii::Appearance::Decode(Bytes(self.draft));NSMutableArray *faces=[NSMutableArray array];
    for(NSNumber *seed in self.lookSeeds){auto a=kartpad::mii::LookAlike(base,self.gender,seed.unsignedIntValue);[faces addObject:[NSData dataWithBytes:a.bytes.data() length:a.bytes.size()]];}
    self.lookAlikes=faces;
}
// Leaves the create screen with the chosen face and opens Face.
- (void)begin:(NSData*)face{
    KPPlay(KPSound::NewMii);self.draft=face.mutableCopy;self.original=face.copy;self.creating=NO;self.pickingLookAlike=NO;self.lookAlikes=nil;[self categoryChangedTo:2];
}
- (void)applyAppearance:(const kartpad::mii::Appearance&)appearance{
    auto before=kartpad::mii::Appearance::Decode(Bytes(self.draft));_history.Record(before,appearance);
    self.draft=[NSMutableData dataWithBytes:appearance.bytes.data() length:appearance.bytes.size()];
    self.validationMessage=nil;[self.canvas redraw];[self refreshPreview];
}
- (void)categoryChangedTo:(unsigned)category{
    if(![self commitNames])return;
    self.category=category;self.feature=kartpad::mii::PrimaryFeatures[category];self.section=0;
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.page=kartpad::mii::FeaturePage(self.feature,a.Get(self.feature));
    self.preview.fullBody=category<=1;if(category>=2)[self.preview faceFront];[self rebuild];[self refreshPreview];
}
- (void)refreshPreview{
    auto appearance=kartpad::mii::Appearance::Decode(Bytes(self.draft));uint64_t revision=_revision.Next();_ticket->store(revision);auto ticket=_ticket;
    unsigned field=self.feature,page=self.page;BOOL needsTiles=self.category>=2;NSString *colors=KPMiiTileColors(appearance);id<MTLDevice> device=self.preview.device;
    __weak KPMiiEditor *weak=self;
    if(!self.previewLoaded)self.previewMessage=@"Loading preview…";
    dispatch_async(KPMiiWorkQueue(),^{@autoreleasepool{
        try{
            if(ticket->load()!=revision)return;
            auto resource=KPMiiLoadResources();
            if(ticket->load()!=revision)return;
            std::shared_ptr<kartpad::mii::BodyResources> body;
            try{body=KPMiiLoadBody();}catch(const std::exception&){/* Keep the valid head preview when the body archive is unsupported. */}
            auto scene=std::make_shared<kartpad::mii::PreviewScene>(kartpad::mii::PreviewScene::Build(*resource,appearance,body.get()));
            if(ticket->load()!=revision)return;
            KPMiiGPUScene *gpu=[[KPMiiGPUScene alloc]initWithScene:scene device:device];
            NSString *previewStatus=body?nil:@"Body assets missing. Reimport game data. Head preview available.";
            static std::weak_ptr<kartpad::mii::Resources> previous;static NSMutableDictionary *cache;
            if(previous.lock().get()!=resource.get()){cache=[NSMutableDictionary dictionary];previous=resource;}
            NSMutableDictionary *images=[NSMutableDictionary dictionary];
            if(needsTiles){auto ids=kartpad::mii::FeatureIds(field);for(size_t i=page*12;i<std::min(ids.size(),size_t(page*12+12));i++){NSString *key=[NSString stringWithFormat:@"%u:%u",field,ids[i]],*cacheKey=[NSString stringWithFormat:@"%@:%@",key,colors];if(ticket->load()!=revision)return;
                if(!cache[cacheKey]){auto thumbnail=KPMiiFeatureImage(*resource,field,ids[i],appearance);if(thumbnail)cache[cacheKey]=thumbnail;}if(cache[cacheKey])images[key]=cache[cacheKey];}}
            dispatch_async(dispatch_get_main_queue(),^{KPMiiEditor *editor=weak;if(!editor||!editor->_revision.Accept(revision))return;[editor.preview installScene:gpu];[editor.thumbnails removeAllObjects];[editor.thumbnails addEntriesFromDictionary:images];editor.previewLoaded=YES;editor.previewMessage=editor.preview.device?previewStatus:@"Metal preview unavailable. Editing and export are available.";[editor.canvas redraw];});
        }catch(const std::exception&error){NSString *message=[NSString stringWithUTF8String:error.what()];dispatch_async(dispatch_get_main_queue(),^{KPMiiEditor *editor=weak;if(!editor||!editor->_revision.Accept(revision))return;[editor.preview installScene:nil];editor.previewLoaded=YES;editor.previewMessage=message;[editor.canvas redraw];});}
    }});
}
- (void)performItem:(const KPItem&)item{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));
    switch(item.action){
    case KPAction::Category:if(![self commitNames])return;KPPlay(item.field==unsigned(self.category)?KPSound::Same:KPSound::Tab);[self categoryChangedTo:item.field];return;
    case KPAction::Page:KPPlay(item.value>0?KPSound::PageNext:KPSound::PagePrevious);self.page+=item.value;[self rebuild];[self refreshPreview];return;
    case KPAction::Section:if(![self commitNames])return;KPPlay(unsigned(item.value)==self.section?KPSound::Same:KPSound::Tab);self.section=unsigned(item.value);[self rebuild];return;
    case KPAction::Mode:KPPlay(item.field==self.feature&&!self.section?KPSound::Same:KPSound::Tab);self.feature=item.field;self.section=0;self.page=kartpad::mii::FeaturePage(item.field,a.Get(item.field));[self rebuild];[self refreshPreview];return;
    case KPAction::Gender:KPPlay(self.gender==unsigned(item.value)?KPSound::Same:KPSound::Confirm);self.gender=item.value;[self makeLookAlikes];[self rebuild];return;
    case KPAction::Start:if(item.value){KPPlay(KPSound::Press);self.pickingLookAlike=YES;[self rebuild];return;}[self begin:[self scratch]];return;
    case KPAction::LookAlike:if(NSUInteger(item.value)<self.lookAlikes.count)[self begin:self.lookAlikes[item.value]];return;
    case KPAction::Shuffle:KPPlay(KPSound::PageNext);[self shuffle];[self rebuild];return;
    case KPAction::Back:KPPlay(KPSound::PagePrevious);self.pickingLookAlike=NO;[self rebuild];return;
    case KPAction::Select:{BOOL changed=a.Get(item.field)!=unsigned(item.value);KPPlay(!changed?KPSound::Same:item.field==0?KPSound::Confirm:KPColorField(item.field)?KPSound::Tab:KPSound::Press);a.Set(item.field,item.value);[self applyAppearance:a];if(changed)[self.preview react];return;}
    case KPAction::Adjust:{
        int value=int(a.Get(item.field))+item.value;auto f=kartpad::mii::AppearanceFields[item.field];
        // The first press plays the step; held repeats tick, and a hold that reaches the limit is rejected.
        CFTimeInterval now=CACurrentMediaTime();BOOL repeat=now-self.adjustTime<.4&&self.adjustField==item.field&&self.adjustDirection==item.value;self.adjustTime=now;self.adjustField=item.field;self.adjustDirection=item.value;
        if(value>=int(f.minimum)&&value<=int(f.maximum)){BOOL limit=value==int(f.minimum)||value==int(f.maximum);KPPlay(repeat?(limit?KPSound::Reject:KPSound::Tick):item.value>0?KPSound::Right:KPSound::Left);a.Set(item.field,value);[self applyAppearance:a];}else KPPlay(KPSound::Reject);
        return;}
    case KPAction::Toggle:a.Set(item.field,!a.Get(item.field));KPPlay(KPToggleOn(item,a)?KPSound::Confirm:KPSound::Same);[self applyAppearance:a];if(item.field==42)[self rebuild];return;
    case KPAction::Rotate:KPPlay(item.value<0?KPSound::Left:KPSound::Right);[self.preview noteInteraction];self.preview.yaw+=item.value*.35f;return;
    case KPAction::Front:KPPlay(KPSound::Tab);[self.preview noteInteraction];self.preview.yaw=0;return;
    case KPAction::Sound:[self toggleSound];return;
    case KPAction::Undo:if(![self commitNames])return;if(!_history.CanUndo()){KPPlay(KPSound::Same);return;}KPPlay(KPSound::PagePrevious);a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.draft=[NSMutableData dataWithBytes:_history.Undo(a).bytes.data() length:74];[self historyChanged];return;
    case KPAction::Redo:if(![self commitNames])return;if(!_history.CanRedo()){KPPlay(KPSound::Same);return;}KPPlay(KPSound::PageNext);a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.draft=[NSMutableData dataWithBytes:_history.Redo(a).bytes.data() length:74];[self historyChanged];return;
    case KPAction::Quit:[self quit];return;
    case KPAction::Save:[self save];return;
    case KPAction::Discard:[self discard];return;
#if TARGET_OS_OSX
    case KPAction::Birthday:[self birthday:item.field];return;
#else
    case KPAction::Birthday:[self birthday];return;
#endif
    case KPAction::More:KPPlay(KPSound::Press);[self showMore];return;
    default:return;
    }
}
- (void)historyChanged{auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.page=kartpad::mii::FeaturePage(self.feature,a.Get(self.feature));[self rebuild];[self refreshPreview];}
- (void)setBody:(unsigned)field value:(unsigned)value{auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));if(a.Get(field)==value)return;a.Set(field,value);[self applyAppearance:a];
#if TARGET_OS_OSX
    [self.buildLabel setStringValue:KPBuildName(a)];
#else
    [self.buildLabel setText:KPBuildName(a)];
#endif
}
- (BOOL)commitNames{
    for(id field in self.nameFields){
#if TARGET_OS_OSX
        NSString *text=[field stringValue];if([(NSTextView*)[field currentEditor] hasMarkedText]){self.validationField=[field tag];self.validationMessage=@"Finish entering this name first.";[self.canvas redraw];KPPlay(KPSound::Reject);return NO;}
#else
        NSString *text=[field text]?:@"";if([field markedTextRange]){self.validationField=[field tag];self.validationMessage=@"Finish entering this name first.";[self.canvas redraw];KPPlay(KPSound::Reject);return NO;}
#endif
        NSMutableData *data=self.draft.mutableCopy;NSString *problem=KPMiiNameProblem(text,[field tag]==2);
        if(problem||!KPMiiSetName(data,text,[field tag])){
            self.validationField=[field tag];self.validationMessage=problem?:@"This name is too long. Please shorten it.";[self.canvas redraw];KPPlay(KPSound::Reject);return NO;
        }
        if(![data isEqual:self.draft]){auto a=kartpad::mii::Appearance::Decode(Bytes(data));[self applyAppearance:a];}
    }self.validationMessage=nil;return YES;
}
#if TARGET_OS_OSX
- (void)controlTextDidBeginEditing:(NSNotification*)note{_history.Begin();}
- (void)controlTextDidEndEditing:(NSNotification*)note{[self commitNames];_history.End();}
- (void)controlTextDidChange:(NSNotification*)note{
    NSTextField *field=note.object;NSTextView *editor=(NSTextView*)field.currentEditor;if(editor.hasMarkedText)return;
    NSMutableData *data=self.draft.mutableCopy;NSUInteger before=KPMiiName(self.draft,field.tag).length;
    if(KPMiiSetName(data,field.stringValue,field.tag)){KPPlay(field.stringValue.length<before?KPSound::Erase:KPSound::Key);[self applyAppearance:kartpad::mii::Appearance::Decode(Bytes(data))];}else{KPPlay(KPSound::Reject);self.validationField=field.tag;self.validationMessage=KPMiiNameProblem(field.stringValue,NO)?:@"This name is too long. Please shorten it.";[self.canvas redraw];}
}
#else
- (void)textFieldDidBeginEditing:(UITextField*)field{_history.Begin();}
- (void)textFieldDidEndEditing:(UITextField*)field{[self commitNames];_history.End();}
- (BOOL)textFieldShouldReturn:(UITextField*)field{if([self commitNames]){[field resignFirstResponder];return YES;}return NO;}
- (void)nameChanged:(UITextField*)field{if(field.markedTextRange)return;NSMutableData *data=self.draft.mutableCopy;NSUInteger before=KPMiiName(self.draft,field.tag).length;if(KPMiiSetName(data,field.text?:@"",field.tag)){KPPlay(field.text.length<before?KPSound::Erase:KPSound::Key);[self applyAppearance:kartpad::mii::Appearance::Decode(Bytes(data))];}else{KPPlay(KPSound::Reject);self.validationField=field.tag;self.validationMessage=KPMiiNameProblem(field.text?:@"",NO)?:@"This name is too long. Please shorten it.";[self.canvas redraw];}}
- (NSArray<UIKeyCommand*>*)keyCommands{return @[[UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand action:@selector(undoCommand:)],[UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift action:@selector(redoCommand:)],[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(quit)]];}
- (void)undoCommand:(id)sender{KPItem i{};i.action=KPAction::Undo;[self performItem:i];}
- (void)redoCommand:(id)sender{KPItem i{};i.action=KPAction::Redo;[self performItem:i];}
#endif
#if TARGET_OS_OSX
// The month or day menu drops from its button, with the current choice checked.
- (void)birthday:(unsigned)field{
    if(![self commitNames])return;
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));
    KPMiiWiiButton *anchor=nil;for(KPMiiWiiButton *button in self.canvas.buttons){const auto &item=self.canvas->_items[button.index];if(item.action==KPAction::Birthday&&item.field==field)anchor=button;}
    if(!anchor)return;
    NSMenu *menu=[NSMenu new];menu.autoenablesItems=NO;menu.minimumWidth=anchor.bounds.size.width;
    unsigned first=field==1?0:1,last=field==1?12:KPBirthdayDays(a.Get(1));
    for(unsigned value=first;value<=last;value++){
        NSMenuItem *entry=[[NSMenuItem alloc]initWithTitle:field==1?KPBirthdayMonths()[value]:[NSString stringWithFormat:@"%u",value] action:@selector(birthdayChosen:) keyEquivalent:@""];
        entry.target=self;entry.tag=NSInteger(field*100+value);entry.state=a.Get(field)==value?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:entry];
        if(field==1&&value==0)[menu addItem:NSMenuItem.separatorItem];
    }
    KPPlay(KPSound::Press);[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,anchor.bounds.size.height+2) inView:anchor];
}
- (void)birthdayChosen:(NSMenuItem*)sender{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));unsigned field=unsigned(sender.tag)/100,value=unsigned(sender.tag)%100;
    if(a.Get(field)==value){KPPlay(KPSound::Same);return;}
    if(field==1){a.Set(1,value);a.Set(2,value?std::min(std::max(1u,a.Get(2)),KPBirthdayDays(value)):0);}
    else a.Set(2,value);
    KPPlay(KPSound::Tab);[self applyAppearance:a];[self rebuild];
}
#else
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView*)picker{return 2;}
- (NSInteger)pickerView:(UIPickerView*)picker numberOfRowsInComponent:(NSInteger)component{return component?std::max(1u,KPBirthdayDays(self.birthdayMonth)):13;}
- (NSString*)pickerView:(UIPickerView*)picker titleForRow:(NSInteger)row forComponent:(NSInteger)component{return component?(self.birthdayMonth?[NSString stringWithFormat:@"%ld",long(row+1)]:@"—"):KPBirthdayMonths()[row];}
- (void)pickerView:(UIPickerView*)picker didSelectRow:(NSInteger)row inComponent:(NSInteger)component{if(!component){self.birthdayMonth=unsigned(row);NSInteger day=[picker selectedRowInComponent:1];[picker reloadComponent:1];[picker selectRow:std::min(day,NSInteger(std::max(1u,KPBirthdayDays(unsigned(row)))-1)) inComponent:1 animated:NO];}}
- (void)birthdayDone:(id)sender{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));unsigned month=unsigned([self.birthdayPicker selectedRowInComponent:0]);a.Set(1,month);a.Set(2,month?unsigned([self.birthdayPicker selectedRowInComponent:1]+1):0);
    KPPlay(KPSound::Confirm);[self applyAppearance:a];[self dismissViewControllerAnimated:YES completion:^{self.birthdayPicker=nil;}];
}
- (void)birthdayCancel:(id)sender{KPPlay(KPSound::Close);[self dismissViewControllerAnimated:YES completion:^{self.birthdayPicker=nil;}];}
- (void)birthday{
    if(![self commitNames])return;[self.view endEditing:YES];
    auto birthdayAppearance=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.birthdayMonth=birthdayAppearance.Get(1);
    UIViewController *sheet=[UIViewController new];sheet.view.backgroundColor=UIColor.systemBackgroundColor;sheet.view.accessibilityViewIsModal=YES;sheet.modalPresentationStyle=UIModalPresentationPageSheet;sheet.preferredContentSize=CGSizeMake(420,300);
    if(@available(iOS 15.0,*)){sheet.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.mediumDetent];sheet.sheetPresentationController.prefersGrabberVisible=YES;}
    UILabel *title=KPLabelView(@"Birthday",CGRectZero,20);title.textAlignment=NSTextAlignmentCenter;title.translatesAutoresizingMaskIntoConstraints=NO;[sheet.view addSubview:title];
    UIPickerView *picker=[UIPickerView new];self.birthdayPicker=picker;picker.delegate=self;picker.dataSource=self;picker.translatesAutoresizingMaskIntoConstraints=NO;picker.accessibilityLabel=@"Birthday month and day";[sheet.view addSubview:picker];
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));[picker selectRow:a.Get(1) inComponent:0 animated:NO];[picker reloadComponent:1];[picker selectRow:a.Get(2)?a.Get(2)-1:0 inComponent:1 animated:NO];
    UIButton *cancel=[UIButton buttonWithType:UIButtonTypeSystem],*done=[UIButton buttonWithType:UIButtonTypeSystem];[cancel setTitle:@"Cancel" forState:UIControlStateNormal];[done setTitle:@"Done" forState:UIControlStateNormal];[cancel addTarget:self action:@selector(birthdayCancel:) forControlEvents:UIControlEventTouchUpInside];[done addTarget:self action:@selector(birthdayDone:) forControlEvents:UIControlEventTouchUpInside];
    for(UIButton *button in @[cancel,done]){button.translatesAutoresizingMaskIntoConstraints=NO;button.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];[sheet.view addSubview:button];}
    UILayoutGuide *safe=sheet.view.safeAreaLayoutGuide;[NSLayoutConstraint activateConstraints:@[[title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],[title.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],[title.heightAnchor constraintEqualToConstant:30],[picker.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],[picker.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],[picker.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],[picker.bottomAnchor constraintEqualToAnchor:done.topAnchor constant:-8],[cancel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],[done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],[cancel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],[done.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],[cancel.heightAnchor constraintEqualToConstant:44],[done.heightAnchor constraintEqualToConstant:44],[cancel.widthAnchor constraintEqualToConstant:90],[done.widthAnchor constraintEqualToConstant:90]]];
    KPPlay(KPSound::Open);[self presentViewController:sheet animated:YES completion:nil];
}
#endif
- (void)discard{
    // Cancel closes an untouched draft straight away; changed drafts confirm first.
    if(![self dirty]){self.allowClose=YES;KPPlay(KPSound::Close);
#if TARGET_OS_OSX
        [self close];
#else
        [self dismissViewControllerAnimated:YES completion:nil];
#endif
        return;}
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=@"Discard Your Changes?";alert.informativeText=self.slot==NSNotFound?@"This new Mii won’t be saved.":@"This Mii will stay as it was before you opened the editor.";[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Discard Changes"];KPPlay(KPSound::Dialog);if([alert runModal]==NSAlertSecondButtonReturn){KPPlay(KPSound::PagePrevious);self.allowClose=YES;[self close];}else KPPlay(KPSound::Close);
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Discard Your Changes?" message:self.slot==NSNotFound?@"This new Mii won’t be saved.":@"This Mii will stay as it was before you opened the editor." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Discard Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){KPPlay(KPSound::PagePrevious);self.allowClose=YES;[self dismissViewControllerAnimated:YES completion:nil];}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)tell:(NSString*)title message:(NSString*)message{
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=message?:@"";[alert runModal];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
#endif
}
// Saving closes the editor and hands the change to the Miis screen, whose banner names it and
// explains the restart; that screen also offers Use for a License… for a new Mii.
- (void)save{
    if(![self commitNames])return;
    NSError *error=nil;if(!KartPadStageMiiEditor(self.slot,self.slot==NSNotFound?nil:self.original,self.draft,&error)){KPPlay(KPSound::Reject);[self tell:@"Mii Couldn’t Be Saved" message:error.localizedDescription?:@"This Mii couldn’t be saved."];return;}
    KPPlay(KPSound::Saved);
    NSString *name=KPMiiName(self.draft,2),*before=KPMiiName(self.original,2),*description;
    if(self.slot==NSNotFound)description=[NSString stringWithFormat:@"“%@” will be added.",name];
    else if(![name isEqual:before])description=[NSString stringWithFormat:@"“%@” will be updated and renamed “%@”.",before,name];
    else description=[NSString stringWithFormat:@"“%@” will be updated.",name];
    NSData *mii=self.draft.copy;NSUInteger slot=self.slot;id<KPMiiEditorListener> listener=KPMiiSaveListener;self.allowClose=YES;
#if TARGET_OS_OSX
    // Without the Miis screen (not expected), say what happens next here instead.
    if(!listener)[self tell:@"Mii Saved" message:[NSString stringWithFormat:@"%@ %@",description,KPMiiRestartAdvice(1)]];
    // Tell the Miis screen before closing: closing makes it reload, and it finds a new Mii by
    // comparing against the Miis it had.
    [listener miiEditorSaved:description mii:mii slot:slot];[self close];
#else
    if(!listener){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Mii Saved" message:[NSString stringWithFormat:@"%@ %@",description,KPMiiRestartAdvice(1)] preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self dismissViewControllerAnimated:YES completion:nil];}]];[self presentViewController:alert animated:YES completion:nil];return;}
    [listener miiEditorSaved:description mii:mii slot:slot];[self dismissViewControllerAnimated:YES completion:nil];
#endif
}
- (void)resetConfirmed{auto a=kartpad::mii::Appearance::Decode(Bytes(self.original));_history.End();[self applyAppearance:a];[self historyChanged];}
- (void)reset{
    if(![self edited])return;NSString *message=self.slot==NSNotFound?@"The Mii goes back to the face you started from.":@"The Mii goes back to how it was when you opened it.";
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=@"Reset All Changes?";alert.informativeText=message;[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Reset Changes"];KPPlay(KPSound::Dialog);if([alert runModal]==NSAlertSecondButtonReturn){KPPlay(KPSound::PagePrevious);[self resetConfirmed];}else KPPlay(KPSound::Close);
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Reset All Changes?" message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction*action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Reset Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){KPPlay(KPSound::PagePrevious);[self resetConfirmed];}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)exportMii{
    if(![self commitNames])return;
    NSError *error=nil;NSData *data=KartPadExportMii(self.draft,&error);if(!data){KPPlay(KPSound::Reject);[self tell:@"Mii Couldn’t Be Exported" message:error.localizedDescription];return;}
    NSString *file=KPMiiFileName(KPMiiName(self.draft,2));
#if TARGET_OS_OSX
    NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=file;panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"mii" conformingToType:UTTypeData]?:UTTypeData];panel.message=@"Saves a standard 74-byte .mii file.";if([panel runModal]==NSModalResponseOK){if([data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])KPPlay(KPSound::Saved);else{KPPlay(KPSound::Reject);[self tell:@"Mii Couldn’t Be Exported" message:error.localizedDescription];}}
#else
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file]];if(![data writeToURL:url options:NSDataWritingAtomic error:&error]){KPPlay(KPSound::Reject);[self tell:@"Mii Couldn’t Be Exported" message:error.localizedDescription];return;}
    UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:@[url] applicationActivities:nil];share.popoverPresentationController.sourceView=self.canvas;share.popoverPresentationController.sourceRect=CGRectMake(self.canvas.bounds.size.width-52,7,40,28);share.completionWithItemsHandler=^(UIActivityType type,BOOL complete,NSArray *items,NSError *e){if(complete)KPPlay(KPSound::Saved);[NSFileManager.defaultManager removeItemAtPath:directory error:nil];};[self presentViewController:share animated:YES completion:nil];
#endif
}
- (void)toggleSound{KPMiiSounds *sounds=[KPMiiSounds shared];sounds.enabled=!sounds.enabled;if(sounds.enabled)KPPlay(KPSound::Confirm);}
- (void)toggleAnimation{BOOL on=!KPMiiPreviewAnimation();KPPlay(on?KPSound::Confirm:KPSound::Same);[NSUserDefaults.standardUserDefaults setBool:on forKey:KPMiiPreviewAnimationKey];self.preview.animated=on;}
// A new Mii can go back to the create screen to pick another way to start (asking first if edited).
- (void)startOver{
    void(^restart)(void)=^{
        KPPlay(KPSound::PagePrevious);
#if !TARGET_OS_OSX
        [self.view endEditing:YES];
#endif
        self->_history=kartpad::mii::DraftHistory{};self.draft=self.blank.mutableCopy;self.original=self.blank;self.creating=YES;self.pickingLookAlike=NO;self.validationMessage=nil;
        [self makeLookAlikes];[self rebuild];
    };
    if(![self edited]){restart();return;}
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=@"Start Over?";alert.informativeText=@"Your changes to this Mii will be lost.";[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Start Over"];KPPlay(KPSound::Dialog);if([alert runModal]==NSAlertSecondButtonReturn)restart();else KPPlay(KPSound::Close);
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Start Over?" message:@"Your changes to this Mii will be lost." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction*action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Start Over" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){restart();}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)showMore{
#if TARGET_OS_OSX
    NSMenu *menu=[NSMenu new];menu.autoenablesItems=NO;NSMutableArray *titles=[NSMutableArray arrayWithObjects:@"Export…",@"Reset Changes…",nil];if(self.blank)[titles addObject:@"Start Over…"];
    for(NSString *title in titles){NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:title action:[title hasPrefix:@"Export"]?@selector(exportMii):[title hasPrefix:@"Reset"]?@selector(reset):@selector(startOver) keyEquivalent:@""];item.target=self;item.enabled=![title hasPrefix:@"Reset"]||[self edited];[menu addItem:item];}
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *animate=[[NSMenuItem alloc]initWithTitle:@"Animate Preview" action:@selector(toggleAnimation) keyEquivalent:@""];animate.target=self;animate.state=KPMiiPreviewAnimation()?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:animate];
    // Short screens have no room for the Sound effects switch, so it lives here.
    if(self.canvas->_shortHeader){NSMenuItem *sound=[[NSMenuItem alloc]initWithTitle:@"Sound Effects" action:@selector(toggleSound) keyEquivalent:@""];sound.target=self;sound.state=[KPMiiSounds shared].enabled?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:sound];}
    [menu popUpMenuPositioningItem:nil atLocation:CGPointMake(self.canvas.bounds.size.width-100,38) inView:self.canvas];
#else
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];[menu addAction:[UIAlertAction actionWithTitle:@"Export…" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self exportMii];}]];UIAlertAction *reset=[UIAlertAction actionWithTitle:@"Reset Changes…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){[self reset];}];reset.enabled=[self edited];[menu addAction:reset];if(self.blank)[menu addAction:[UIAlertAction actionWithTitle:@"Start Over…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){[self startOver];}]];[menu addAction:[UIAlertAction actionWithTitle:KPMiiPreviewAnimation()?@"Stop Preview Animation":@"Animate Preview" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self toggleAnimation];}]];if(self.canvas->_shortHeader)[menu addAction:[UIAlertAction actionWithTitle:[KPMiiSounds shared].enabled?@"Turn Off Sound Effects":@"Turn On Sound Effects" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self toggleSound];}]];[menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];menu.popoverPresentationController.sourceView=self.canvas;menu.popoverPresentationController.sourceRect=CGRectMake(self.canvas.bounds.size.width-52,7,40,28);[self presentViewController:menu animated:YES completion:nil];
#endif
}
- (NSString*)saveQuestion{NSString *name=KPMiiName(self.draft,2);return name.length?[NSString stringWithFormat:@"Save Changes to “%@”?",name]:@"Save Changes to This Mii?";}
#if TARGET_OS_OSX
- (BOOL)windowShouldClose:(NSWindow*)window{
    if(self.allowClose)return YES;
    if(![self dirty]){KPPlay(KPSound::Close);return YES;}
    NSAlert *alert=[NSAlert new];alert.messageText=[self saveQuestion];[alert addButtonWithTitle:@"Save"];[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Discard Changes"];KPPlay(KPSound::Dialog);NSInteger answer=[alert runModal];if(answer==NSAlertFirstButtonReturn){[self save];return self.allowClose;}KPPlay(answer==NSAlertThirdButtonReturn?KPSound::PagePrevious:KPSound::Close);return answer==NSAlertThirdButtonReturn;
}
- (void)windowWillClose:(NSNotification*)note{[[KPMiiSounds shared] suspendSoon];}
- (void)quit{[self.window performClose:nil];}
// A duplicate is a new Mii that skips the Male/Female screen and opens on Profile for renaming.
- (instancetype)initWithData:(NSData*)data slot:(NSUInteger)slot duplicate:(BOOL)duplicate{
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,960,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){self.original=data;self.draft=data.mutableCopy;self.slot=slot;self.creating=slot==NSNotFound&&!duplicate;self.duplicating=duplicate;self.category=duplicate?0:2;self.feature=7;window.title=duplicate?@"Duplicate Mii":slot==NSNotFound?@"Create Mii":@"Edit Mii";window.contentMinSize=NSMakeSize(800,600);window.delegate=self;self.canvas=[[KPMiiCanvas alloc]initWithFrame:NSMakeRect(0,0,960,720)];self.canvas.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=self.canvas;[self setup];[window center];}return self;
}
#else
- (void)quit{
    [self.view endEditing:YES];if(self.allowClose||![self dirty]){if(!self.allowClose)KPPlay(KPSound::Close);[self dismissViewControllerAnimated:YES completion:nil];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:[self saveQuestion] message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self save];}]];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction*action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Discard Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){KPPlay(KPSound::PagePrevious);[self dismissViewControllerAnimated:YES completion:nil];}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
}
- (void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=[UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection *traits){return KPColor(traits.userInterfaceStyle==UIUserInterfaceStyleDark?KPDarkPalette.background:KPLightPalette.background);}];self.canvas=[KPMiiCanvas new];self.canvas.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.canvas];[NSLayoutConstraint activateConstraints:@[[self.canvas.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.canvas.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[self.canvas.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],[self.canvas.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];[self setup];self.modalInPresentation=YES;[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillChangeFrameNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];}
- (void)keyboard:(NSNotification*)note{CGRect keyboard=[self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];CGFloat overlap=std::max(CGFloat(0),CGRectGetMaxY(self.canvas.frame)-keyboard.origin.y);for(UIView *view in self.canvas.subviews)if([view isKindOfClass:UIScrollView.class]){UIScrollView *scroll=(UIScrollView*)view;scroll.contentInset=UIEdgeInsetsMake(0,0,overlap,0);for(UITextField *field in self.nameFields)if(field.isFirstResponder)[scroll scrollRectToVisible:CGRectInset(field.frame,0,-10) animated:NO];}}
- (void)viewDidDisappear:(BOOL)animated{[super viewDidDisappear:animated];[[KPMiiSounds shared] suspendSoon];}
- (void)contentSizeChanged:(NSNotification*)note{for(KPMiiWiiButton *button in self.canvas.buttons)button.look=NSUIntegerMax;[self.canvas redraw];}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];}
#endif
- (void)soundsChanged:(NSNotification*)note{[self.canvas redraw];}
- (void)setup{[[KPMiiSounds shared] prepare:KPMiiSoundArchivePath()];KPPlay(KPSound::Open);[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(soundsChanged:) name:KPMiiSoundsChangedNotification object:nil];_ticket=std::make_shared<std::atomic<uint64_t>>(0);self.canvas.editor=self;self.thumbnails=[NSMutableDictionary dictionary];if(self.creating){self.blank=self.draft.copy;[self shuffle];}self.preview=[[KPMiiMetalPreview alloc]initWithFrame:CGRectZero];self.preview.fullBody=self.category<=1;self.preview.animated=KPMiiPreviewAnimation();[self.canvas addSubview:self.preview];[self rebuild];[self refreshPreview];}
@end
#if TARGET_OS_OSX
static KPMiiEditor *KPMiiActiveEditor;
// Inside the game window (KartPad's Miis screen is there): the editor takes a borderless window laid
// exactly over the game's content, which moves with it and follows its size; the canvas lays out at
// the screens' 1280×720 design size and draws scaled to fit, like KartPad's other screens. Closing
// it gives the keyboard back to the game window.
@interface KPMiiEmbeddedWindow:NSWindow
// Following the game window's size; removed on close.
@property(nonatomic,strong) NSMutableArray *observers;
@end
@implementation KPMiiEmbeddedWindow
- (BOOL)canBecomeKeyWindow{return YES;}
- (BOOL)canBecomeMainWindow{return YES;}
- (void)performClose:(id)sender{
    id<NSWindowDelegate> delegate=self.delegate;
    if([delegate respondsToSelector:@selector(windowShouldClose:)]&&![delegate windowShouldClose:self])return;
    [self close];
}
- (void)close{
    for(id observer in self.observers)[NSNotificationCenter.defaultCenter removeObserver:observer];
    [self.observers removeAllObjects];
    NSWindow *game=self.parentWindow;[game removeChildWindow:self];[super close];
    [game makeKeyAndOrderFront:nil];
}
@end
@interface KPMiiScaledHost:NSView
@property(nonatomic,weak) NSView *canvas;
@end
@implementation KPMiiScaledHost
- (BOOL)isFlipped{return YES;}
- (void)layout{
    [super layout];NSView *canvas=self.canvas;if(!canvas)return;
    const CGFloat w=self.bounds.size.width,h=self.bounds.size.height,scale=std::clamp(std::min(w/1280,h/720),CGFloat(.5),CGFloat(3));
    canvas.frame=self.bounds;[canvas setBoundsSize:NSMakeSize(w/scale,h/scale)];canvas.needsLayout=YES;
}
@end
static void KPMiiFollowGameWindow(NSWindow *host,NSWindow *game){
    [host setFrame:[game convertRectToScreen:game.contentView.frame] display:YES];
}
static void KPMiiEmbedEditor(KPMiiEditor *editor,NSWindow *game){
    if([editor.window isKindOfClass:KPMiiEmbeddedWindow.class]){[editor.window makeKeyAndOrderFront:nil];return;}
    NSWindow *old=editor.window;NSView *canvas=editor.canvas;
    // Open in a window of its own already (from the Miis panel): it moves in here.
    [old orderOut:nil];
    KPMiiEmbeddedWindow *host=[[KPMiiEmbeddedWindow alloc]initWithContentRect:[game convertRectToScreen:game.contentView.frame] styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    host.releasedWhenClosed=NO;host.hasShadow=NO;host.title=old.title;
    host.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorCanJoinAllSpaces;
    KPMiiScaledHost *container=[[KPMiiScaledHost alloc]initWithFrame:NSMakeRect(0,0,host.frame.size.width,host.frame.size.height)];
    container.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;old.contentView=nil;
    canvas.autoresizingMask=NSViewNotSizable;[container addSubview:canvas];container.canvas=canvas;host.contentView=container;
    old.delegate=nil;host.delegate=editor;editor.window=host;
    [game addChildWindow:host ordered:NSWindowAbove];
    host.observers=[NSMutableArray array];__weak KPMiiEmbeddedWindow *weakHost=host;__weak NSWindow *weakGame=game;
    for(NSNotificationName name in @[NSWindowDidResizeNotification,NSWindowDidEndLiveResizeNotification])
        [host.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:game queue:nil usingBlock:^(NSNotification*note){
            KPMiiEmbeddedWindow *live=weakHost;NSWindow *parent=weakGame;if(live.visible&&parent)KPMiiFollowGameWindow(live,parent);}]];
    [host makeKeyAndOrderFront:nil];
}
// Open above the parent (the Miis window), which sits above the game window.
static void KPMiiShowEditor(id parent){
    // The game window: no window controller, not a panel.
    if([parent isKindOfClass:NSWindow.class]&&![parent isKindOfClass:NSPanel.class]&&[(NSWindow*)parent windowController]==nil&&KPMiiActiveEditor){
        KPMiiEmbedEditor(KPMiiActiveEditor,(NSWindow*)parent);return;
    }
    NSWindow *window=KPMiiActiveEditor.window;
    if([parent isKindOfClass:NSWindow.class])window.level=std::max(window.level,((NSWindow*)parent).level);
    window.collectionBehavior|=NSWindowCollectionBehaviorFullScreenAuxiliary;
    [NSApp activateIgnoringOtherApps:YES];[KPMiiActiveEditor showWindow:nil];
}
#endif
// data is the draft to open: nil reads the slot (or starts a new Mii); a duplicate passes its copy.
static void KPMiiPresentEditor(id parent,NSUInteger slot,NSData *data,BOOL duplicate){
    [[KPMiiSounds shared] prepare:KPMiiSoundArchivePath()];
    NSError *error=nil;if(!KartPadCanQueueMiiChanges()){KPPlay(KPSound::Reject);
#if TARGET_OS_OSX
        NSAlert *alert=[NSAlert new];alert.messageText=KPMiiRestartFirstTitle();alert.informativeText=KPMiiRestartFirstMessage();[alert runModal];
#else
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:KPMiiRestartFirstTitle() message:KPMiiRestartFirstMessage() preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[(UIViewController*)parent presentViewController:alert animated:YES completion:nil];
#endif
        return;
    }
#if TARGET_OS_OSX
    // One editor at a time. Asking for the Mii it already shows brings it forward; another Mii
    // closes it first, with the usual question about unsaved changes (Keep Editing stays put).
    if(KPMiiEditor *open=KPMiiActiveEditor;open.window.visible){
        BOOL same=!data&&!open.duplicating&&open.slot==slot;KPMiiShowEditor(parent);
        if(same)return;
        [open.window performClose:nil];if(open.window.visible)return;
    }
#endif
    if(!data)data=slot==NSNotFound?KartPadNewMii(&error):KartPadReadMii(slot,&error);
    if(!data){KPPlay(KPSound::Reject);
#if TARGET_OS_OSX
        NSAlert *alert=[NSAlert new];alert.messageText=@"Mii Couldn’t Be Opened";alert.informativeText=error.localizedDescription?:@"This Mii couldn’t be read.";[alert runModal];
#else
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Mii Couldn’t Be Opened" message:error.localizedDescription?:@"This Mii couldn’t be read." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[(UIViewController*)parent presentViewController:alert animated:YES completion:nil];
#endif
        return;
    }
#if TARGET_OS_OSX
    KPMiiActiveEditor=[[KPMiiEditor alloc]initWithData:data slot:slot duplicate:duplicate];KPMiiShowEditor(parent);
#else
    KPMiiEditor *editor=[KPMiiEditor new];editor.original=data;editor.draft=data.mutableCopy;editor.slot=slot;editor.category=duplicate?0:2;editor.feature=7;editor.creating=slot==NSNotFound&&!duplicate;editor.duplicating=duplicate;editor.modalPresentationStyle=UIModalPresentationFullScreen;
    // Follow the launcher's light/dark choice, which it sets as an override on its own controller.
    editor.overrideUserInterfaceStyle=[(UIViewController*)parent traitCollection].userInterfaceStyle;[(UIViewController*)parent presentViewController:editor animated:YES completion:nil];
#endif
}
void KartPadPresentMiiEditor(id parent,NSUInteger slot){KPMiiPresentEditor(parent,slot,nil,NO);}
#if TARGET_OS_OSX
void KartPadUIPrepareSounds(void){[[KPMiiSounds shared] prepare:KPMiiSoundArchivePath()];}
void KartPadUIPlaySound(NSInteger sound){if(sound>=0&&sound<NSInteger(KPSound::Count))KPPlay(KPSound(sound));}
BOOL KartPadUISoundsEnabled(void){return [KPMiiSounds shared].enabled;}
void KartPadUISetSoundsEnabled(BOOL enabled){[KPMiiSounds shared].enabled=enabled;}
id KartPadMiiPortrait(NSData *mii,void(^ready)(void)){
    if(KPMiiImage *image=[KPMiiPortraits() objectForKey:mii])return image;
    KPMiiRequestPortrait(mii,ready);return nil;
}
#endif
