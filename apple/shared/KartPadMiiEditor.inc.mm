#import "KartPadMiiEditor.h"
#import <CommonCrypto/CommonDigest.h>
#include "kartpad/mii/editor.h"
#include <memory>
#include <atomic>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
using KPMiiImage=NSImage;
using KPMiiFont=NSFont;
using KPMiiColor=NSColor;
#else
#import <UIKit/UIKit.h>
using KPMiiImage=UIImage;
using KPMiiFont=UIFont;
using KPMiiColor=UIColor;
#define NSFontWeightSemibold UIFontWeightSemibold
#define NSFontWeightRegular UIFontWeightRegular
#endif
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
    auto a=Appearance::Decode(CreateDefaultMii({0,0,0,0,0,0}));a.Set(field,value);
    a.Set(8,current.Get(8));a.Set(12,current.Get(12));a.Set(39,current.Get(39));
    if(field==9)a.Set(11,30);
    return KPMiiImageFromPixels(Portrait::Render(r,a),YES);
}
// Colours that feed the tiles; part of the thumbnail cache key so a colour change re-renders them.
static NSString *KPMiiTileColors(const kartpad::mii::Appearance&a){return [NSString stringWithFormat:@"%u.%u.%u.%u.%u.%u.%u",a.Get(8),a.Get(12),a.Get(17),a.Get(22),a.Get(30),a.Get(34),a.Get(39)];}
// Mii Channel palette: silver gloss on pinstriped white, Wii-blue selection. Dark keeps the blue on graphite.
struct KPPalette{unsigned background,stripe,panel,panelStroke,well,buttonTop,buttonBottom,buttonStroke,tabTop,tabBottom,selectedTop,selectedBottom,accentTop,accentBottom,accentStroke,text,secondaryText,icon,switchOff;CGFloat gloss,shadow;unsigned ledge,accentLedge;};
static const KPPalette KPLightPalette{0xf2f4f5,0xe8ecee,0xfbfcfc,0xc9d1d6,0xe6ecef,0xffffff,0xdfe5e8,0xb3bdc3,0xfafbfc,0xd3dade,0xebf8fe,0xbde8fa,0x5ccbf3,0x1b9ad5,0x1784bc,0x3a4348,0x6a747a,0x5a646a,0xc3cbd0,.9,.20,0xb0bbc1,0x14709f};
static const KPPalette KPDarkPalette{0x15181b,0x191d20,0x22272b,0x363d43,0x191d21,0x3c4349,0x2a3035,0x4c555c,0x3f464c,0x2b3136,0x1f4b5f,0x163748,0x4cc6f2,0x168ac4,0x63d0f5,0xe6ebee,0x9aa5ab,0xc3cbd0,0x4a535a,.13,.55,0x0c0e10,0x0d5880};
static const KPPalette *KPP=&KPLightPalette;
static void KPUsePalette(id view){
#if TARGET_OS_OSX
    BOOL dark=[[[(NSView*)view effectiveAppearance] bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
#else
    BOOL dark=[(UIView*)view traitCollection].userInterfaceStyle==UIUserInterfaceStyleDark;
#endif
    KPP=dark?&KPDarkPalette:&KPLightPalette;
}
static KPMiiColor *KPColor(unsigned hex,CGFloat alpha=1){return [KPMiiColor colorWithRed:((hex>>16)&255)/255. green:((hex>>8)&255)/255. blue:(hex&255)/255. alpha:alpha];}
static void KPSetInk(CGContextRef c,unsigned hex,CGFloat alpha=1){CGFloat r=((hex>>16)&255)/255.,g=((hex>>8)&255)/255.,b=(hex&255)/255.;CGContextSetRGBFillColor(c,r,g,b,alpha);CGContextSetRGBStrokeColor(c,r,g,b,alpha);}
static void KPFill(CGContextRef c,CGRect rect,unsigned hex,CGFloat radius=0,CGFloat alpha=1){
    KPSetInk(c,hex,alpha);
    CGPathRef path=CGPathCreateWithRoundedRect(rect,radius,radius,nullptr);CGContextAddPath(c,path);CGContextFillPath(c);CGPathRelease(path);
}
static void KPStroke(CGContextRef c,CGRect rect,unsigned hex,CGFloat width=1,CGFloat radius=0,CGFloat alpha=1){
    KPSetInk(c,hex,alpha);CGContextSetLineWidth(c,width);radius=std::max(CGFloat(0),radius-width/2);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(rect,width/2,width/2),radius,radius,nullptr);CGContextAddPath(c,path);CGContextStrokePath(c);CGPathRelease(path);
}
static void KPText(NSString*text,CGRect rect,CGFloat size,unsigned hex,BOOL bold=NO,NSTextAlignment align=NSTextAlignmentCenter){
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];style.alignment=align;style.lineBreakMode=rect.size.height>size*2.6?NSLineBreakByWordWrapping:NSLineBreakByTruncatingTail;
    KPMiiFont *font=[KPMiiFont systemFontOfSize:size weight:bold?NSFontWeightSemibold:NSFontWeightRegular];
#if !TARGET_OS_OSX
    font=[UIFontMetrics.defaultMetrics scaledFontForFont:font maximumPointSize:std::max(size,std::min(size*1.3,rect.size.height*.75))];
#endif
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:KPColor(hex),NSParagraphStyleAttributeName:style}];
}
// One line of text centred vertically in a button face.
static void KPCenteredText(NSString*text,CGRect r,CGFloat size,unsigned hex,BOOL bold=NO,NSTextAlignment align=NSTextAlignmentCenter){KPText(text,CGRectMake(r.origin.x,CGRectGetMidY(r)-size*.66,r.size.width,size*1.5),size,hex,bold,align);}
static void KPGradientFill(CGContextRef c,CGRect r,CGFloat radius,unsigned top,unsigned bottom){
    CGPathRef path=CGPathCreateWithRoundedRect(r,radius,radius,nullptr);CGContextSaveGState(c);CGContextAddPath(c,path);CGContextClip(c);CGPathRelease(path);
    CGFloat colors[]={((top>>16)&255)/255.,((top>>8)&255)/255.,(top&255)/255.,1,((bottom>>16)&255)/255.,((bottom>>8)&255)/255.,(bottom&255)/255.,1};
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,nullptr,2);
    CGContextDrawLinearGradient(c,gradient,CGPointMake(0,r.origin.y),CGPointMake(0,CGRectGetMaxY(r)),0);CGGradientRelease(gradient);CGColorSpaceRelease(space);CGContextRestoreGState(c);
}
// Art tiles hold feature artwork; they stay light in dark mode so black eyes and dark hair remain visible.
enum class KPStyle{Plain,Primary,Tab,Tile,Art,Round,Card};
// Wii channel face: a rounded rectangle on a solid ledge, a soft vertical gradient and a double rim.
// Pressing drops the face onto its ledge.
// Hovering (Mac pointer, iPad trackpad) lights the rim in Wii blue, like the Wii pointer highlight.
static void KPButtonFace(CGContextRef c,CGRect r,KPStyle style,BOOL selected,BOOL enabled,BOOL pressed,BOOL hovered=NO){
    const KPPalette *theme=KPP;if(style==KPStyle::Art){KPP=&KPLightPalette;style=KPStyle::Tile;}
    CGFloat ledge=3,radius=style==KPStyle::Card?14:style==KPStyle::Round?10:style==KPStyle::Tile?10:8;
    CGRect body=CGRectMake(r.origin.x,r.origin.y,r.size.width,r.size.height-ledge);
    BOOL accent=style==KPStyle::Primary||(selected&&style==KPStyle::Tab),highlight=selected&&!accent;
    CGContextSaveGState(c);if(!enabled)CGContextSetAlpha(c,.42);
    KPFill(c,CGRectOffset(body,0,ledge),accent?KPP->accentLedge:highlight?KPP->accentStroke:KPP->ledge,radius);
    if(pressed)body=CGRectOffset(body,0,ledge-1);
    unsigned top=accent?KPP->accentTop:highlight?KPP->selectedTop:style==KPStyle::Tab?KPP->tabTop:KPP->buttonTop;
    unsigned bottom=accent?KPP->accentBottom:highlight?KPP->selectedBottom:style==KPStyle::Tab?KPP->tabBottom:KPP->buttonBottom;
    if(pressed)std::swap(top,bottom);
    KPGradientFill(c,body,radius,top,bottom);
    BOOL lit=hovered&&enabled&&!pressed&&!highlight;
    KPStroke(c,body,accent||highlight?KPP->accentStroke:lit?KPP->accentTop:KPP->buttonStroke,highlight||lit?2.5:1.25,radius);
    if(!pressed)KPStroke(c,CGRectInset(body,highlight?4:3,highlight?4:3),0xffffff,1,radius-3,KPP->gloss*(accent?.45:1));
    CGContextRestoreGState(c);KPP=theme;
}
// On/off indicator in the same rounded-rectangle language as the buttons.
static void KPSwitch(CGContextRef c,CGRect track,BOOL on){
    KPFill(c,track,on?KPP->accentBottom:KPP->switchOff,7);KPStroke(c,track,on?KPP->accentLedge:KPP->buttonStroke,1,7);
    CGFloat d=track.size.height-6;CGRect knob=CGRectMake(on?CGRectGetMaxX(track)-d-3:track.origin.x+3,track.origin.y+3,d,d);
    KPFill(c,CGRectOffset(knob,0,1.5),0x000000,5,.22);KPGradientFill(c,knob,5,0xffffff,0xe3e8eb);KPStroke(c,knob,KPP->buttonStroke,1,5);
}
static void KPLine(CGContextRef c,CGFloat x,CGFloat y,CGFloat x2,CGFloat y2){CGContextMoveToPoint(c,x,y);CGContextAddLineToPoint(c,x2,y2);CGContextStrokePath(c);}
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
    case 11:{ // Male body for the create screen and slider ends: the same Mii silhouette without the gauge.
        CGContextFillEllipseInRect(c,CGRectMake(13.5,2,13,13));
        CGContextMoveToPoint(c,15,17);CGContextAddLineToPoint(c,25,17);CGContextAddQuadCurveToPoint(c,28.5,17,29,20.5);CGContextAddLineToPoint(c,30.5,29);CGContextAddLineToPoint(c,26,29);CGContextAddLineToPoint(c,25.5,38);CGContextAddLineToPoint(c,21.2,38);CGContextAddLineToPoint(c,20,30.5);CGContextAddLineToPoint(c,18.8,38);CGContextAddLineToPoint(c,14.5,38);CGContextAddLineToPoint(c,14,29);CGContextAddLineToPoint(c,9.5,29);CGContextAddLineToPoint(c,11,20.5);CGContextAddQuadCurveToPoint(c,11.5,17,15,17);CGContextClosePath(c);CGContextFillPath(c);break;}
    case 2: // Face: a jaw outline with simple features.
        CGContextMoveToPoint(c,20,4);CGContextAddCurveToPoint(c,29,4,34,10,34,18);CGContextAddCurveToPoint(c,34,27,27,36,20,36);CGContextAddCurveToPoint(c,13,36,6,27,6,18);CGContextAddCurveToPoint(c,6,10,11,4,20,4);CGContextClosePath(c);CGContextStrokePath(c);
        CGContextFillEllipseInRect(c,CGRectMake(13,16,3.6,3.6));CGContextFillEllipseInRect(c,CGRectMake(23.4,16,3.6,3.6));
        CGContextSetLineWidth(c,2.4);CGContextMoveToPoint(c,15,26);CGContextAddQuadCurveToPoint(c,20,30,25,26);CGContextStrokePath(c);break;
    case 3: // Hair: a filled cap with a fringe over the face outline.
        CGContextMoveToPoint(c,5,21);CGContextAddCurveToPoint(c,4,9,12,3,20,3);CGContextAddCurveToPoint(c,28,3,36,9,35,21);CGContextAddLineToPoint(c,31,15);CGContextAddLineToPoint(c,27,18);CGContextAddLineToPoint(c,24,12);CGContextAddLineToPoint(c,19,17);CGContextAddLineToPoint(c,14,12);CGContextAddLineToPoint(c,10,17);CGContextClosePath(c);CGContextFillPath(c);
        CGContextMoveToPoint(c,7.5,22);CGContextAddCurveToPoint(c,8,31,14,37,20,37);CGContextAddCurveToPoint(c,26,37,32,31,32.5,22);CGContextStrokePath(c);break;
    case 4: // Eyebrows.
        CGContextSetLineWidth(c,4.6);CGContextMoveToPoint(c,4,24);CGContextAddQuadCurveToPoint(c,10,13,18,19);CGContextStrokePath(c);CGContextMoveToPoint(c,36,24);CGContextAddQuadCurveToPoint(c,30,13,22,19);CGContextStrokePath(c);break;
    case 5: // Eyes: almonds with pupils.
        CGContextSetLineWidth(c,2.4);for(CGFloat x:{2.,22.}){CGContextMoveToPoint(c,x,20);CGContextAddQuadCurveToPoint(c,x+8,9,x+16,20);CGContextAddQuadCurveToPoint(c,x+8,31,x,20);CGContextClosePath(c);CGContextStrokePath(c);CGContextFillEllipseInRect(c,CGRectMake(x+4.5,16.5,7,7));}break;
    case 6: // Nose: side profile with a nostril.
        CGContextSetLineWidth(c,3.2);CGContextMoveToPoint(c,15,5);CGContextAddCurveToPoint(c,18,14,26,19,29.5,25.5);CGContextAddCurveToPoint(c,31,29,28.5,31.5,25,31);CGContextAddCurveToPoint(c,23,34,18.5,34,15.5,31.5);CGContextStrokePath(c);
        CGContextSetLineWidth(c,2.4);CGContextMoveToPoint(c,19,28);CGContextAddQuadCurveToPoint(c,21.5,25.5,24,28);CGContextStrokePath(c);break;
    case 7: // Mouth: parted lips.
        CGContextMoveToPoint(c,4,20);CGContextAddCurveToPoint(c,9,12,14,11,20,15);CGContextAddCurveToPoint(c,26,11,31,12,36,20);CGContextClosePath(c);CGContextFillPath(c);
        CGContextMoveToPoint(c,4,22.5);CGContextAddLineToPoint(c,36,22.5);CGContextAddCurveToPoint(c,32,31,27,33,20,33);CGContextAddCurveToPoint(c,13,33,8,31,4,22.5);CGContextClosePath(c);CGContextFillPath(c);break;
    case 8: // Facial hair: a curled mustache.
        CGContextMoveToPoint(c,20,17);CGContextAddCurveToPoint(c,15,10,8,12,7,18);CGContextAddCurveToPoint(c,6,21,3,21,2,19);CGContextAddCurveToPoint(c,2,26,10,29,16,25.5);CGContextAddQuadCurveToPoint(c,19,23.5,20,22);
        CGContextAddQuadCurveToPoint(c,21,23.5,24,25.5);CGContextAddCurveToPoint(c,30,29,38,26,38,19);CGContextAddCurveToPoint(c,37,21,34,21,33,18);CGContextAddCurveToPoint(c,32,12,25,10,20,17);CGContextClosePath(c);CGContextFillPath(c);break;
    case 10:{ // Female body for the create screen: a dress instead of a torso.
        CGContextFillEllipseInRect(c,CGRectMake(15,2,10,10));
        CGContextMoveToPoint(c,16,13.5);CGContextAddLineToPoint(c,24,13.5);CGContextAddQuadCurveToPoint(c,26,14,26.5,17);CGContextAddLineToPoint(c,29,29);CGContextAddLineToPoint(c,11,29);CGContextAddLineToPoint(c,13.5,17);CGContextAddQuadCurveToPoint(c,14,14,16,13.5);CGContextClosePath(c);CGContextFillPath(c);
        CGContextSetLineWidth(c,3.4);KPLine(c,13,16,9,25);KPLine(c,27,16,31,25);
        CGContextSetLineWidth(c,3.8);KPLine(c,17.5,29,17.2,37);KPLine(c,22.5,29,22.8,37);break;}
    case 9: // Glasses: lenses, bridge and arms.
        for(CGFloat x:{2.5,22.5}){CGPathRef lens=CGPathCreateWithRoundedRect(CGRectMake(x,13,15,13),5.5,5.5,nullptr);CGContextAddPath(c,lens);CGContextStrokePath(c);CGPathRelease(lens);}
        CGContextMoveToPoint(c,17.5,18);CGContextAddQuadCurveToPoint(c,20,15,22.5,18);CGContextStrokePath(c);KPLine(c,2.5,16,1.5,12.5);KPLine(c,37.5,16,38.5,12.5);break;
    }
    CGContextRestoreGState(c);
}
static void KPArrowHead(CGContextRef c,CGPoint tip,CGFloat angle,CGFloat length=8){
    CGContextMoveToPoint(c,tip.x,tip.y);CGContextAddLineToPoint(c,tip.x-length*cos(angle-.6),tip.y-length*sin(angle-.6));CGContextAddLineToPoint(c,tip.x-length*cos(angle+.6),tip.y-length*sin(angle+.6));CGContextClosePath(c);CGContextFillPath(c);
}
static void KPArrow(CGContextRef c,CGPoint from,CGPoint to,CGFloat width=3.4){
    CGFloat angle=atan2(to.y-from.y,to.x-from.x);CGContextSetLineWidth(c,width);KPLine(c,from.x,from.y,to.x-4*cos(angle),to.y-4*sin(angle));KPArrowHead(c,to,angle);
}
// Clockwise arc (y-down) from start to end with a head at the end.
static void KPArcArrow(CGContextRef c,CGPoint center,CGFloat radius,CGFloat start,CGFloat end,CGFloat width=3.4){
    CGContextSetLineWidth(c,width);CGContextAddArc(c,center.x,center.y,radius,start,end,0);CGContextStrokePath(c);
    CGFloat tip=end+.32;KPArrowHead(c,CGPointMake(center.x+radius*cos(tip),center.y+radius*sin(tip)),tip+M_PI_2,9);
}
enum class KPGlyph{Move,Across,Size,Rotate,Spacing,Undo,More,Chevron,Turn,Front,None,Check};
static void KPControlIcon(CGContextRef c,CGRect rect,KPGlyph kind,int direction,unsigned ink){
    CGContextSaveGState(c);CGContextTranslateCTM(c,rect.origin.x,rect.origin.y);CGContextScaleCTM(c,rect.size.width/40,rect.size.height/40);
    KPSetInk(c,ink);CGContextSetLineJoin(c,kCGLineJoinRound);CGContextSetLineCap(c,kCGLineCapRound);
    auto mirror=[&](BOOL flip){if(flip){CGContextTranslateCTM(c,40,0);CGContextScaleCTM(c,-1,1);}};
    switch(kind){
    case KPGlyph::Move: // −1 moves up.
        CGContextFillEllipseInRect(c,CGRectMake(6,16,8,8));KPArrow(c,CGPointMake(26,direction<0?33:7),CGPointMake(26,direction<0?7:33));break;
    case KPGlyph::Across:
        CGContextFillEllipseInRect(c,CGRectMake(16,5,8,8));KPArrow(c,CGPointMake(direction<0?34:6,28),CGPointMake(direction<0?6:34,28));break;
    case KPGlyph::Size:{ // Corner arrows pointing in (smaller) or out (larger).
        CGFloat dot=direction<0?3.5:5.5;CGContextFillEllipseInRect(c,CGRectMake(20-dot,20-dot,dot*2,dot*2));
        for(int x:{-1,1})for(int y:{-1,1}){CGPoint inner{20+x*8.5,20+y*8.5},outer{20+x*18.,20+y*18.};KPArrow(c,direction<0?outer:inner,direction<0?inner:outer,3);}break;}
    case KPGlyph::Rotate: // Mii Channel tilt: a dot with a curved arrow over it (−1, clockwise) or under it (+1, counter-clockwise).
        if(direction>0){CGContextTranslateCTM(c,0,40);CGContextScaleCTM(c,1,-1);}
        CGContextFillEllipseInRect(c,CGRectMake(15,21.5,10,10));KPArcArrow(c,CGPointMake(20,26.5),14.5,M_PI*.93,M_PI*1.8,4.2);break;
    case KPGlyph::Spacing:
        if(direction<0){CGContextFillEllipseInRect(c,CGRectMake(16,16,8,8));KPArrow(c,{2,20},{13,20});KPArrow(c,{38,20},{27,20});}
        else{CGContextFillEllipseInRect(c,CGRectMake(2,16,8,8));CGContextFillEllipseInRect(c,CGRectMake(30,16,8,8));KPArrow(c,{17,20},{11,20});KPArrow(c,{23,20},{29,20});}break;
    case KPGlyph::Undo: // Redo is the mirror image.
        mirror(direction>0);CGContextSetLineWidth(c,3.6);CGContextMoveToPoint(c,31,31);CGContextAddCurveToPoint(c,32,19,25,14,15,14);CGContextStrokePath(c);KPArrowHead(c,CGPointMake(6,14),M_PI,11);break;
    case KPGlyph::More:for(CGFloat x:{8.,17.,26.})CGContextFillEllipseInRect(c,CGRectMake(x,17,6,6));break;
    case KPGlyph::Chevron:mirror(direction<0);CGContextSetLineWidth(c,4.4);CGContextMoveToPoint(c,15,8);CGContextAddLineToPoint(c,27,20);CGContextAddLineToPoint(c,15,32);CGContextStrokePath(c);break;
    case KPGlyph::Turn: // A three-quarter turn around the Mii.
        mirror(direction<0);CGContextFillEllipseInRect(c,CGRectMake(15.5,16.5,9,9));KPArcArrow(c,CGPointMake(20,21),13,M_PI*.62,M_PI*2.02);break;
    case KPGlyph::Front:
        CGContextSetLineWidth(c,2.8);CGContextStrokeEllipseInRect(c,CGRectMake(10,7,20,25));CGContextFillEllipseInRect(c,CGRectMake(14.5,16,3.4,3.4));CGContextFillEllipseInRect(c,CGRectMake(22.1,16,3.4,3.4));KPLine(c,16.5,25,23.5,25);break;
    case KPGlyph::None:CGContextSetLineWidth(c,3);CGContextStrokeEllipseInRect(c,CGRectMake(8,8,24,24));KPLine(c,12.5,27.5,27.5,12.5);break;
    case KPGlyph::Check:CGContextSetLineWidth(c,4.5);CGContextMoveToPoint(c,9,21);CGContextAddLineToPoint(c,17,29);CGContextAddLineToPoint(c,31,12);CGContextStrokePath(c);break;
    }
    CGContextRestoreGState(c);
}

enum class KPAction{Category,Select,Adjust,Page,Mode,Toggle,Rotate,Front,Quit,Save,Discard,Birthday,Undo,Redo,More,Gender,Start,Slider,Sound};
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
@property(nonatomic) BOOL choosingGender,allowClose,previewLoaded;
@property(nonatomic) unsigned gender;
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
- (void)birthday;
- (void)showMore;
- (void)rebuild;
- (BOOL)commitNames;
- (void)setBody:(unsigned)field value:(unsigned)value;
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
@implementation KPMiiWiiButton
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)keyDown:(NSEvent*)event{
    NSString *key=event.charactersIgnoringModifiers;
    if([key isEqual:@" "]||[key isEqual:@"\r"]){self.canvas.editor->_history.Begin();[self activate];self.canvas.editor->_history.End();return;}
    if(event.keyCode>=123&&event.keyCode<=126){const auto&here=self.canvas->_items[self.index];BOOL horizontal=event.keyCode==123||event.keyCode==124;int sign=(event.keyCode==123||event.keyCode==126)?-1:1;KPMiiWiiButton *best=nil;CGFloat score=1e9;for(KPMiiWiiButton *candidate in self.canvas.buttons){if(!candidate.enabled||candidate==self)continue;const auto&there=self.canvas->_items[candidate.index];CGFloat dx=CGRectGetMidX(there.rect)-CGRectGetMidX(here.rect),dy=CGRectGetMidY(there.rect)-CGRectGetMidY(here.rect),primary=horizontal?dx:dy,secondary=horizontal?dy:dx;if(primary*sign<=1)continue;CGFloat cost=std::abs(primary)+std::abs(secondary)*4;if(cost<score){score=cost;best=candidate;}}if(best){[self.window makeFirstResponder:best];[best scrollRectToVisible:best.bounds];}return;}
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
- (void)up{[self.repeatTimer invalidate];self.repeatTimer=nil;self.canvas.editor->_history.End();}
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
static id KPLabelView(NSString *text,CGRect frame,CGFloat size=16,BOOL bold=NO,BOOL secondary=NO){
    KPMiiColor *color=KPColor(secondary?KPP->secondaryText:KPP->text);auto weight=bold?NSFontWeightSemibold:NSFontWeightRegular;
#if TARGET_OS_OSX
    NSTextField *label=[NSTextField wrappingLabelWithString:text];label.frame=frame;label.font=[NSFont systemFontOfSize:size weight:weight];label.textColor=color;
#else
    UILabel *label=[[UILabel alloc]initWithFrame:frame];label.text=text;label.font=[UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:size weight:weight] maximumPointSize:std::max(size,std::min(size*1.3,frame.size.height*.75))];label.adjustsFontForContentSizeCategory=YES;label.textColor=color;label.numberOfLines=0;
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
    for(id hint in self.editor.nameHints){BOOL invalid=self.editor.validationMessage.length&&[hint tag]==self.editor.validationField;NSString *message=invalid?self.editor.validationMessage:@"Up to 10 characters";
#if TARGET_OS_OSX
        [hint setStringValue:message];[hint setTextColor:invalid?NSColor.systemRedColor:KPColor(KPP->secondaryText)];
#else
        [hint setText:message];[hint setTextColor:invalid?UIColor.systemRedColor:KPColor(KPP->secondaryText)];
#endif
    }
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));BOOL sound=[KPMiiSounds shared].enabled;
    for(KPMiiWiiButton *button in self.buttons){auto &item=_items[button.index];
        if(item.action==KPAction::Adjust){auto f=kartpad::mii::AppearanceFields[item.field];int value=int(a.Get(item.field))+item.value;item.enabled=value>=int(f.minimum)&&value<=int(f.maximum);}
        if(item.action==KPAction::Undo)item.enabled=self.editor->_history.CanUndo();
        if(item.action==KPAction::Redo)item.enabled=self.editor->_history.CanRedo();
        if(item.action==KPAction::Save)item.enabled=[self.editor dirty];
        button.enabled=item.enabled;
        NSString *value=item.action==KPAction::Toggle?(KPToggleOn(item,a)?@"On":@"Off"):item.action==KPAction::Sound?(sound?@"On":@"Off"):item.action==KPAction::Mode&&item.selected?@"Selected":nil;
#if TARGET_OS_OSX
        if(item.action==KPAction::Sound)[button setAccessibilityValue:@(sound)];else [button setAccessibilityValue:value];
#else
        BOOL selected=item.action==KPAction::Category||item.action==KPAction::Mode?item.selected:item.action==KPAction::Select?a.Get(item.field)==unsigned(item.value):item.action==KPAction::Sound?sound:item.action==KPAction::Toggle&&KPToggleOn(item,a);button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0)|(!item.enabled?UIAccessibilityTraitNotEnabled:0);button.accessibilityValue=value;
#endif
        // Every state drawItem reads besides hover, press and focus, which repaint themselves.
        BOOL chosen=item.action==KPAction::Select?a.Get(item.field)==unsigned(item.value):item.selected;
        NSUInteger look=NSUInteger(item.enabled)|NSUInteger(chosen)<<1|NSUInteger(item.action==KPAction::Toggle&&KPToggleOn(item,a))<<2|NSUInteger(item.action==KPAction::Sound&&sound)<<3|(item.action==KPAction::Birthday?NSUInteger(a.Get(1))<<4|NSUInteger(a.Get(2))<<8:0);
        id art=item.action==KPAction::Select&&item.field&&!KPColorField(item.field)?self.editor.thumbnails[[NSString stringWithFormat:@"%u:%d",item.field,item.value]]:nil;
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
    CGFloat margin=compact?12:24,top=compact?154:114;
    // Footer actions sit on the bottom edge; compact layouts keep a status line above them.
    _footerY=h-44-(compact?10:16);CGFloat contentBottom=_footerY-(compact?28:16);
    CGFloat previewWidth=compact?w-2*margin:(w-3*margin)*.34;
    _previewRect=compact?CGRectMake(margin,top,previewWidth,std::min(CGFloat(216),std::max(CGFloat(150),(contentBottom-top)*.38))):CGRectMake(margin,top,previewWidth,std::max(CGFloat(120),contentBottom-top));
    CGFloat panelX=compact?margin:CGRectGetMaxX(_previewRect)+margin,panelY=compact?CGRectGetMaxY(_previewRect)+10:top;
    _panelRect=CGRectMake(panelX,panelY,w-margin-panelX,std::max(CGFloat(140),contentBottom-panelY));
    // The card header holds the name and turn controls; the Metal view fills the rest on a matching background.
    BOOL tight=compact||h<500;CGFloat header=tight?42:50,turn=tight?32:38;
    _nameRect=CGRectMake(_previewRect.origin.x+16,_previewRect.origin.y+2,_previewRect.size.width-32-3*turn-20,header);
    self.editor.preview.frame=CGRectMake(_previewRect.origin.x+8,_previewRect.origin.y+header,_previewRect.size.width-16,_previewRect.size.height-header-8);
    self.editor.preview.clearColor=MTLClearColorMake(((KPP->well>>16)&255)/255.,((KPP->well>>8)&255)/255.,(KPP->well&255)/255.,1);
    self.editor.preview.hidden=self.editor.choosingGender;
    auto add=[&](KPAction action,CGRect rect,NSString *label,unsigned field=0,int value=0,BOOL selected=NO){_items.push_back({action,rect,field,value,label,YES,selected});};
    id form=nil;CGFloat x=_panelRect.origin.x+12,y=_panelRect.origin.y+12,pw=_panelRect.size.width-24;
    if(self.editor.choosingGender){
        CGFloat bw=std::min(CGFloat(220),(w-60)/2);CGFloat center=h*.36;
        add(KPAction::Gender,CGRectMake(w/2-bw-8,center,bw,164),@"Male",0,0,self.editor.gender==0);
        add(KPAction::Gender,CGRectMake(w/2+8,center,bw,164),@"Female",0,1,self.editor.gender==1);
        add(KPAction::Start,CGRectMake(w/2-120,center+196,240,52),@"Start from scratch");
        add(KPAction::Quit,CGRectMake(margin,_footerY,120,44),@"Cancel");
        add(KPAction::Sound,CGRectMake(w-margin-96,6,96,40),@"Sound effects");
    }else{
        CGFloat gap=compact?5:8;int cols=compact?5:10;CGFloat tw=(w-2*margin-gap*(cols-1))/cols;
        for(unsigned i=0;i<10;i++)add(KPAction::Category,CGRectMake(margin+(i%cols)*(tw+gap),54+(i/cols)*48,tw,46),[NSString stringWithUTF8String:kartpad::mii::EditorCategories[i]],i,0,self.editor.category==i);
        CGFloat tx=CGRectGetMaxX(_previewRect)-8-turn,ty=_previewRect.origin.y+(header-turn)/2+2;
        add(KPAction::Rotate,CGRectMake(tx-2*(turn+6),ty,turn,turn),@"Turn left",0,-1);
        add(KPAction::Front,CGRectMake(tx-turn-6,ty,turn,turn),@"Face front");
        add(KPAction::Rotate,CGRectMake(tx,ty,turn,turn),@"Turn right",0,1);
        CGFloat saveW=compact?150:164,cancelW=compact?110:120;
        add(KPAction::Save,CGRectMake(w-margin-saveW,_footerY,saveW,44),@"Save & Quit");
        add(KPAction::Discard,CGRectMake(w-margin-saveW-10-cancelW,_footerY,cancelW,44),@"Cancel");
        add(KPAction::Sound,CGRectMake(w-margin-136-12-96,6,96,40),@"Sound effects");
        add(KPAction::Undo,CGRectMake(w-margin-136,6,40,40),@"Undo");add(KPAction::Redo,CGRectMake(w-margin-88,6,40,40),@"Redo");add(KPAction::More,CGRectMake(w-margin-40,6,40,40),@"More");
        auto appearance=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));
        CGRect frame=CGRectInset(_panelRect,12,12);
#if TARGET_OS_OSX
        NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:frame];scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;scroll.automaticallyAdjustsContentInsets=NO;
        KPMiiCanvas *document=[[KPMiiCanvas alloc]initWithFrame:CGRectMake(0,0,frame.size.width,frame.size.height)];scroll.documentView=document;[self addSubview:scroll];form=document;
#else
        UIScrollView *scroll=[[UIScrollView alloc]initWithFrame:frame];scroll.showsVerticalScrollIndicator=YES;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self addSubview:scroll];form=scroll;
#endif
        CGFloat contentHeight=0;
        if(self.editor.category==0){
            // Two columns when the panel is wide enough; otherwise one stacked column.
            BOOL two=pw>=420;CGFloat cw=two?(pw-16)/2:pw,fy=0;
            for(unsigned n=0;n<2;n++){
                CGFloat fx=two?n*(cw+16):0,ry=two?0:n*94;
                [form addSubview:KPLabelView(n?@"Creator":@"Nickname",CGRectMake(fx+2,ry,cw,22),14,YES,YES)];
#if TARGET_OS_OSX
                NSTextField *field=[NSTextField textFieldWithString:KPMiiName(self.editor.draft,n?54:2)];field.font=[NSFont systemFontOfSize:18];field.delegate=self.editor;field.frame=CGRectMake(fx,ry+26,cw,34);field.bezelStyle=NSTextFieldRoundedBezel;
#else
                UITextField *field=[[UITextField alloc]initWithFrame:CGRectMake(fx,ry+26,cw,36)];field.text=KPMiiName(self.editor.draft,n?54:2);field.font=[UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:18] maximumPointSize:24];field.adjustsFontForContentSizeCategory=YES;field.borderStyle=UITextBorderStyleRoundedRect;field.autocorrectionType=UITextAutocorrectionTypeNo;field.delegate=self.editor;[field addTarget:self.editor action:@selector(nameChanged:) forControlEvents:UIControlEventEditingChanged];
#endif
#if TARGET_OS_OSX
                field.toolTip=@"Names fit 10 UTF-16 units. Emoji and some symbols use more than one unit.";
#else
                field.accessibilityHint=@"Up to 10 letters. Emoji and some symbols use more of the available space.";
#endif
                field.tag=n?54:2;[form addSubview:field];[self.editor.nameFields addObject:field];
                id hint=KPLabelView(@"Up to 10 characters",CGRectMake(fx+2,ry+64,cw,20),12,NO,YES);[hint setTag:field.tag];[form addSubview:hint];[self.editor.nameHints addObject:hint];
            }
            fy=two?100:188;
            [form addSubview:KPLabelView(@"Gender",CGRectMake(2,fy,cw,22),14,YES,YES)];
            add(KPAction::Select,CGRectMake(x,y+fy+26,(cw-8)/2,44),@"Male",0,0);
            add(KPAction::Select,CGRectMake(x+(cw+8)/2,y+fy+26,(cw-8)/2,44),@"Female",0,1);
            CGFloat bx=two?cw+16:0,by=two?fy:fy+86;
            [form addSubview:KPLabelView(@"Birthday",CGRectMake(bx+2,by,cw,22),14,YES,YES)];
#if TARGET_OS_OSX
            NSPopUpButton *month=[[NSPopUpButton alloc]initWithFrame:CGRectMake(bx,by+32,(cw-8)*.62,32) pullsDown:NO];
            [month addItemsWithTitles:KPBirthdayMonths()];
            [month selectItemAtIndex:appearance.Get(1)];month.tag=1;month.target=self.editor;month.action=@selector(birthdayChanged:);[month setAccessibilityLabel:@"Birthday month"];[form addSubview:month];
            NSPopUpButton *day=[[NSPopUpButton alloc]initWithFrame:CGRectMake(bx+(cw-8)*.62+8,by+32,(cw-8)*.38,32) pullsDown:NO];
            if(!appearance.Get(1))[day addItemWithTitle:@"Day"];
            else for(unsigned d=1;d<=KPBirthdayDays(appearance.Get(1));d++)[day addItemWithTitle:[NSString stringWithFormat:@"%u",d]];
            [day selectItemAtIndex:appearance.Get(2)?std::min(appearance.Get(2),KPBirthdayDays(appearance.Get(1)))-1:0];day.enabled=appearance.Get(1)>0;day.tag=2;day.target=self.editor;day.action=@selector(birthdayChanged:);[day setAccessibilityLabel:@"Birthday day"];[form addSubview:day];
#else
            add(KPAction::Birthday,CGRectMake(x+bx,y+by+26,cw,44),KPBirthdayLabel(appearance));
#endif
            fy=by+90;
            add(KPAction::Toggle,CGRectMake(x,y+fy,(pw-12)/2,46),@"Favorite",4);
            add(KPAction::Toggle,CGRectMake(x+(pw+12)/2,y+fy,(pw-12)/2,46),@"Mingle",10);
            fy+=62;
            [form addSubview:KPLabelView(@"Favorite color",CGRectMake(2,fy,pw,22),14,YES,YES)];
            unsigned perRow=pw>=12*40+11*6?12:6;CGFloat sw=std::min(CGFloat(50),(pw-(perRow-1)*6)/perRow);
            for(unsigned i=0;i<12;i++)add(KPAction::Select,CGRectMake(x+(i%perRow)*(sw+6),y+fy+28+(i/perRow)*52,sw,46),@"Favorite color",3,i);
            contentHeight=fy+28+(12/perRow)*52;
        }else if(self.editor.category==1){
            for(unsigned n=0;n<2;n++){
                CGFloat sy=n*124+8;
                [form addSubview:KPLabelView(n?@"Weight":@"Height",CGRectMake(4,sy,pw-8,26),18,YES)];
                KPMiiBodySlider *slider=[[KPMiiBodySlider alloc]initWithFrame:CGRectMake(0,sy+34,pw,64)];slider.editor=self.editor;slider.field=n?6:5;
#if TARGET_OS_OSX
                [slider setAccessibilityLabel:n?@"Weight":@"Height"];
#else
                slider.accessibilityLabel=n?@"Weight":@"Height";slider.backgroundColor=UIColor.clearColor;slider.opaque=NO;
#endif
                [form addSubview:slider];
            }
            // The game snaps height + weight to one of three body models; say which one the preview shows.
            id build=KPLabelView(KPBuildName(appearance),CGRectMake(4,2*124+12,pw-8,24),17,YES);[form addSubview:build];self.editor.buildLabel=build;
            id note=KPLabelView(@"Mario Kart Wii uses height and weight together to pick a small, medium or large Mii. This also sets its kart and bike size.",CGRectMake(4,2*124+40,pw-8,compact?66:44),13,NO,YES);[form addSubview:note];
            contentHeight=2*124+40+(compact?66:44);
        }else{
            auto ids=kartpad::mii::FeatureIds(self.editor.feature);unsigned pages=unsigned((ids.size()+11)/12);self.editor.page=std::min(self.editor.page,std::max(1u,pages)-1);
            CGFloat side=compact?138:std::min(CGFloat(164),pw*.36),gap2=compact?8:14;
            // The pager only appears when a feature has more than one page.
            CGFloat pager=pages>1?52:0,tileGap=compact?7:10;
            CGFloat gridW=pw-side-gap2,gridH=_panelRect.size.height-24-pager;
            CGFloat tileW=(gridW-2*tileGap)/3,tileH=std::max(CGFloat(44),std::min(tileW,(gridH-3*tileGap)/4));
            if(pages>1){
                add(KPAction::Page,CGRectMake(x,y,44,44),@"Previous page",0,-1);_items.back().enabled=self.editor.page>0;
                add(KPAction::Page,CGRectMake(x+gridW-44,y,44,44),@"Next page",0,1);_items.back().enabled=self.editor.page+1<pages;
                id label=KPLabelView([NSString stringWithFormat:gridW-104<110?@"%u / %u":@"Page %u of %u",self.editor.page+1,pages],CGRectMake(52,11,gridW-104,22),14,YES,YES);
#if TARGET_OS_OSX
                [label setAlignment:NSTextAlignmentCenter];
#else
                [label setTextAlignment:NSTextAlignmentCenter];
#endif
                [form addSubview:label];
            }
            for(unsigned i=0;i<12&&self.editor.page*12+i<ids.size();i++){unsigned value=ids[self.editor.page*12+i];add(KPAction::Select,CGRectMake(x+(i%3)*(tileW+tileGap),y+pager+(i/3)*(tileH+tileGap),tileW,tileH),@"Feature",self.editor.feature,value);}
            CGFloat sx=x+gridW+gap2,sy=y;
            unsigned colorField=self.editor.category==2?8:self.editor.category==3?12:self.editor.category==4?22:self.editor.category==5?17:self.editor.category==7?30:self.editor.category==8?39:self.editor.category==9?34:99;
            if(colorField!=99){unsigned count=kartpad::mii::AppearanceFields[colorField].maximum+1;CGFloat sw=(side-12)/3,shH=std::min(CGFloat(46),sw);for(unsigned i=0;i<count;i++)add(KPAction::Select,CGRectMake(sx+(i%3)*(sw+6),sy+(i/3)*(shH+6),sw,shH),@"Color",colorField,i);sy+=((count+2)/3)*(shH+6)+10;}
            // Two-part switches name both pages and highlight the one showing.
            auto modes=[&](unsigned first,NSString *firstLabel,unsigned second,NSString *secondLabel){CGFloat half=(side-4)/2;add(KPAction::Mode,CGRectMake(sx,sy,half,44),firstLabel,first,0,self.editor.feature==first);add(KPAction::Mode,CGRectMake(sx+half+4,sy,half,44),secondLabel,second,0,self.editor.feature==second);sy+=54;};
            if(self.editor.category==2)modes(7,@"Shape",9,@"Details");
            if(self.editor.category==3){add(KPAction::Toggle,CGRectMake(sx,sy,side,46),@"Flip hair",13);sy+=56;}
            if(self.editor.category==8){modes(37,@"Mustache",38,@"Beard");add(KPAction::Toggle,CGRectMake(sx,sy,side,46),@"Mole",42);sy+=56;}
            // Each adjustment names its section and spells out both directions for VoiceOver and tooltips.
            struct KPAdjustment{unsigned field;NSString *title,*less,*more;};
            NSString *up=@"Move up",*down=@"Move down",*smaller=@"Smaller",*larger=@"Larger";
            std::vector<KPAdjustment> adjustments;
            switch(self.editor.category){
            case 4:adjustments={{24,@"Position",up,down},{23,@"Size",smaller,larger},{21,@"Tilt",@"Tilt outer ends down",@"Tilt outer ends up"},{25,@"Spacing",@"Closer together",@"Farther apart"}};break;
            case 5:adjustments={{16,@"Position",up,down},{18,@"Size",smaller,larger},{15,@"Tilt",@"Tilt outer ends down",@"Tilt outer ends up"},{19,@"Spacing",@"Closer together",@"Farther apart"}};break;
            case 6:adjustments={{28,@"Position",up,down},{27,@"Size",smaller,larger}};break;
            case 7:adjustments={{32,@"Position",up,down},{31,@"Size",smaller,larger}};break;
            case 8:adjustments=appearance.Get(42)?std::vector<KPAdjustment>{{44,@"Mole position",up,down},{43,@"Mole size",smaller,larger},{45,@"Mole sideways",@"Move left",@"Move right"}}:std::vector<KPAdjustment>{{41,@"Position",up,down},{40,@"Size",smaller,larger}};break;
            case 9:adjustments={{36,@"Position",up,down},{35,@"Size",smaller,larger}};break;
            }
            for(const auto &adjustment:adjustments){
                [form addSubview:KPLabelView(adjustment.title,CGRectMake(sx-x+2,sy-y,side,18),12,YES,YES)];
                add(KPAction::Adjust,CGRectMake(sx,sy+20,(side-6)/2,44),adjustment.less,adjustment.field,-1);add(KPAction::Adjust,CGRectMake(sx+(side+6)/2,sy+20,(side-6)/2,44),adjustment.more,adjustment.field,1);sy+=72;}
            contentHeight=std::max(pager+4*(tileH+tileGap),sy-y+4);
        }
        contentHeight=std::max(contentHeight+4,frame.size.height);
#if TARGET_OS_OSX
        [(NSView*)form setFrameSize:NSMakeSize(frame.size.width,contentHeight)];
#else
        ((UIScrollView*)form).contentSize=CGSizeMake(frame.size.width,contentHeight);
#endif
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
    if(self.editor.choosingGender){KPText(@"Create a Mii",CGRectMake(20,h*.16,w-40,40),30,KPP->text,YES);KPText(@"Choose Male or Female, then start from scratch.",CGRectMake(20,h*.16+46,w-40,48),17,KPP->secondaryText);return;}
    KPText([NSString stringWithUTF8String:kartpad::mii::EditorCategories[self.editor.category]],CGRectMake(compact?12:24,13,w-200,28),21,KPP->text,YES,NSTextAlignmentLeft);
    for(CGRect card:{_previewRect,_panelRect}){KPFill(c,CGRectOffset(card,0,2),0x000000,18,KPP->shadow*.6);KPFill(c,card,KPP->panel,18);KPStroke(c,card,KPP->panelStroke,1,18);}
    CGRect well=CGRectInset(self.editor.preview.frame,-4,-4);KPFill(c,well,KPP->well,13);
    KPCenteredText(KPMiiName(self.editor.draft,2),_nameRect,_nameRect.size.height<46?16:18,KPP->text,YES,NSTextAlignmentLeft);
    NSString *message=self.editor.validationMessage.length?self.editor.validationMessage:self.editor.previewMessage;
    unsigned tone=self.editor.validationMessage.length?0xd64545:KPP->secondaryText;
    CGFloat margin=compact?12:24;
    if(message.length){if(compact)KPText(message,CGRectMake(margin,_footerY-24,w-2*margin,18),11,tone,NO,NSTextAlignmentLeft);else KPCenteredText(message,CGRectMake(margin,_footerY,w-2*margin-310,44),12,tone,NO,NSTextAlignmentLeft);}
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
    KPStyle style=action==KPAction::Category?KPStyle::Tab:action==KPAction::Save||action==KPAction::Start?KPStyle::Primary:action==KPAction::Gender?KPStyle::Card:action==KPAction::Select&&item.field!=0?(KPColorField(item.field)?KPStyle::Tile:KPStyle::Art):round?KPStyle::Round:KPStyle::Plain;
    KPButtonFace(c,r,style,selected,item.enabled,pressed,i==_hoverIndex);
    CGContextSaveGState(c);if(!item.enabled)CGContextSetAlpha(c,.42);if(pressed)CGContextTranslateCTM(c,0,2);
    unsigned ink=style==KPStyle::Primary||(style==KPStyle::Tab&&selected)?0xffffff:KPP->icon;
    CGFloat glyphSide=std::min(face.size.width,face.size.height)*(round?.6:.68);CGRect glyph=CGRectMake(CGRectGetMidX(face)-glyphSide/2,CGRectGetMidY(face)-glyphSide/2,glyphSide,glyphSide);
    switch(action){
    case KPAction::Category:{CGFloat side=std::min(CGFloat(32),face.size.height-10);KPIcon(c,item.field,CGRectMake(CGRectGetMidX(face)-side/2,CGRectGetMidY(face)-side/2,side,side),ink);break;}
    case KPAction::Gender:KPIcon(c,item.value?10:11,CGRectMake(CGRectGetMidX(face)-32,20,64,80),selected?KPP->accentStroke:KPP->icon);KPCenteredText(item.label,CGRectMake(4,112,face.size.width-8,30),22,KPP->text,YES);break;
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
    case KPAction::Birthday:KPCenteredText(KPBirthdayLabel(a),face,16,KPP->text);break;
    case KPAction::Mode:KPCenteredText(item.label,face,face.size.width<80?13:14,selected?KPP->accentStroke:KPP->text,YES);break;
    default:KPCenteredText(item.label,face,style==KPStyle::Primary?16:15,style==KPStyle::Primary?0xffffff:KPP->text,YES);break;
    }
    CGContextRestoreGState(c);
}
@end
@implementation KPMiiEditor
- (BOOL)dirty{
    if((!self.choosingGender&&self.slot==NSNotFound)||![self.draft isEqualToData:self.original])return YES;
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
- (void)applyAppearance:(const kartpad::mii::Appearance&)appearance{
    auto before=kartpad::mii::Appearance::Decode(Bytes(self.draft));_history.Record(before,appearance);
    self.draft=[NSMutableData dataWithBytes:appearance.bytes.data() length:appearance.bytes.size()];
    self.validationMessage=nil;[self.canvas redraw];[self refreshPreview];
}
- (void)categoryChangedTo:(unsigned)category{
    if(![self commitNames])return;
    self.category=category;self.feature=kartpad::mii::PrimaryFeatures[category];
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
    case KPAction::Mode:KPPlay(item.field==self.feature?KPSound::Same:KPSound::Tab);self.feature=item.field;self.page=kartpad::mii::FeaturePage(item.field,a.Get(item.field));[self rebuild];[self refreshPreview];return;
    case KPAction::Gender:KPPlay(self.gender==unsigned(item.value)?KPSound::Same:KPSound::Confirm);self.gender=item.value;[self rebuild];return;
    case KPAction::Start:{KPPlay(KPSound::NewMii);a.Set(0,self.gender);if(self.gender){a.Set(11,12);a.Set(14,4);a.Set(20,0);}self.draft=[NSMutableData dataWithBytes:a.bytes.data() length:74];self.original=self.draft.copy;self.choosingGender=NO;[self categoryChangedTo:2];return;}
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
    case KPAction::Sound:{KPMiiSounds *sounds=[KPMiiSounds shared];sounds.enabled=!sounds.enabled;if(sounds.enabled)KPPlay(KPSound::Confirm);[self.canvas redraw];return;}
    case KPAction::Undo:if(![self commitNames])return;if(!_history.CanUndo()){KPPlay(KPSound::Same);return;}KPPlay(KPSound::PagePrevious);a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.draft=[NSMutableData dataWithBytes:_history.Undo(a).bytes.data() length:74];[self historyChanged];return;
    case KPAction::Redo:if(![self commitNames])return;if(!_history.CanRedo()){KPPlay(KPSound::Same);return;}KPPlay(KPSound::PageNext);a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.draft=[NSMutableData dataWithBytes:_history.Redo(a).bytes.data() length:74];[self historyChanged];return;
    case KPAction::Quit:[self quit];return;
    case KPAction::Save:[self save];return;
    case KPAction::Discard:[self discard];return;
    case KPAction::Birthday:[self birthday];return;
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
        NSMutableData *data=self.draft.mutableCopy;
        if((![text length]&&[field tag]==2)||!KPMiiSetName(data,text,[field tag])){
            self.validationField=[field tag];self.validationMessage=![text length]?@"Enter a nickname.":@"This name is too long. Please shorten it.";[self.canvas redraw];KPPlay(KPSound::Reject);return NO;
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
    if(KPMiiSetName(data,field.stringValue,field.tag)){KPPlay(field.stringValue.length<before?KPSound::Erase:KPSound::Key);[self applyAppearance:kartpad::mii::Appearance::Decode(Bytes(data))];}else{KPPlay(KPSound::Reject);self.validationField=field.tag;self.validationMessage=@"This name is too long. Please shorten it.";[self.canvas redraw];}
}
#else
- (void)textFieldDidBeginEditing:(UITextField*)field{_history.Begin();}
- (void)textFieldDidEndEditing:(UITextField*)field{[self commitNames];_history.End();}
- (BOOL)textFieldShouldReturn:(UITextField*)field{if([self commitNames]){[field resignFirstResponder];return YES;}return NO;}
- (void)nameChanged:(UITextField*)field{if(field.markedTextRange)return;NSMutableData *data=self.draft.mutableCopy;NSUInteger before=KPMiiName(self.draft,field.tag).length;if(KPMiiSetName(data,field.text?:@"",field.tag)){KPPlay(field.text.length<before?KPSound::Erase:KPSound::Key);[self applyAppearance:kartpad::mii::Appearance::Decode(Bytes(data))];}else{KPPlay(KPSound::Reject);self.validationField=field.tag;self.validationMessage=@"This name is too long. Please shorten it.";[self.canvas redraw];}}
- (NSArray<UIKeyCommand*>*)keyCommands{return @[[UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand action:@selector(undoCommand:)],[UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift action:@selector(redoCommand:)],[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(quit)]];}
- (void)undoCommand:(id)sender{KPItem i{};i.action=KPAction::Undo;[self performItem:i];}
- (void)redoCommand:(id)sender{KPItem i{};i.action=KPAction::Redo;[self performItem:i];}
#endif
#if TARGET_OS_OSX
- (void)birthdayChanged:(NSPopUpButton*)sender{
    if(![self commitNames])return;
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));
    if(sender.tag==1){a.Set(1,sender.indexOfSelectedItem);a.Set(2,a.Get(1)?std::min(std::max(1u,a.Get(2)),KPBirthdayDays(a.Get(1))):0);}
    else a.Set(2,sender.indexOfSelectedItem+1);
    KPPlay(KPSound::Tab);[self applyAppearance:a];[self rebuild];
}
- (void)birthday{}
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
    NSAlert *alert=[NSAlert new];alert.messageText=@"Discard your changes?";alert.informativeText=self.slot==NSNotFound?@"This new Mii won’t be saved.":@"This Mii will stay as it was before you opened the editor.";[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Discard Changes"];KPPlay(KPSound::Dialog);if([alert runModal]==NSAlertSecondButtonReturn){KPPlay(KPSound::PagePrevious);self.allowClose=YES;[self close];}else KPPlay(KPSound::Close);
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Discard your changes?" message:self.slot==NSNotFound?@"This new Mii won’t be saved.":@"This Mii will stay as it was before you opened the editor." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Discard Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){KPPlay(KPSound::PagePrevious);self.allowClose=YES;[self dismissViewControllerAnimated:YES completion:nil];}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)alert:(NSString*)message{
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=@"Mii editor";alert.informativeText=message;[alert runModal];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Mii editor" message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)save{
    if(![self commitNames])return;
    NSError *error=nil;if(!KartPadStageMiiEditor(self.slot,self.slot==NSNotFound?nil:self.original,self.draft,&error)){KPPlay(KPSound::Reject);[self alert:error.localizedDescription?:@"Could not save this Mii."];return;}
    KPPlay(KPSound::Saved);
#if TARGET_OS_OSX
    [self alert:@"Mii saved for the next launch. Quit and reopen KartPad to apply it. Select new Miis in License Settings → Change Mii."];self.allowClose=YES;[self close];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Mii saved" message:@"Fully close and reopen KartPad to apply it. Select new Miis in License Settings → Change Mii." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){self.allowClose=YES;[self dismissViewControllerAnimated:YES completion:nil];}]];[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)resetConfirmed{auto a=kartpad::mii::Appearance::Decode(Bytes(self.original));_history.End();[self applyAppearance:a];[self historyChanged];}
- (void)reset{
    if(![self dirty])return;
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=@"Reset all Mii changes?";[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Reset Changes"];KPPlay(KPSound::Dialog);if([alert runModal]==NSAlertSecondButtonReturn){KPPlay(KPSound::PagePrevious);[self resetConfirmed];}else KPPlay(KPSound::Close);
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Reset all Mii changes?" message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction*action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Reset Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){KPPlay(KPSound::PagePrevious);[self resetConfirmed];}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)exportMii{
    if(![self commitNames])return;
    NSError *error=nil;NSData *data=KartPadExportMii(self.draft,&error);if(!data){KPPlay(KPSound::Reject);[self alert:error.localizedDescription];return;}
#if TARGET_OS_OSX
    NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=@"My Mii.mii";if([panel runModal]==NSModalResponseOK){if([data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])KPPlay(KPSound::Saved);else{KPPlay(KPSound::Reject);[self alert:error.localizedDescription];}}
#else
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"My Mii.mii"]];if(![data writeToURL:url options:NSDataWritingAtomic error:&error]){KPPlay(KPSound::Reject);[self alert:error.localizedDescription];return;}
    UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:@[url] applicationActivities:nil];share.popoverPresentationController.sourceView=self.canvas;share.popoverPresentationController.sourceRect=CGRectMake(self.canvas.bounds.size.width-52,7,40,28);share.completionWithItemsHandler=^(UIActivityType type,BOOL complete,NSArray *items,NSError *e){if(complete)KPPlay(KPSound::Saved);[NSFileManager.defaultManager removeItemAtPath:directory error:nil];};[self presentViewController:share animated:YES completion:nil];
#endif
}
- (void)toggleAnimation{BOOL on=!KPMiiPreviewAnimation();KPPlay(on?KPSound::Confirm:KPSound::Same);[NSUserDefaults.standardUserDefaults setBool:on forKey:KPMiiPreviewAnimationKey];self.preview.animated=on;}
- (void)showMore{
#if TARGET_OS_OSX
    NSMenu *menu=[NSMenu new];for(NSString *title in @[@"Export…",@"Reset Changes…"]){NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:title action:[title hasPrefix:@"Export"]?@selector(exportMii):@selector(reset) keyEquivalent:@""];item.target=self;[menu addItem:item];}
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *animate=[[NSMenuItem alloc]initWithTitle:@"Animate Preview" action:@selector(toggleAnimation) keyEquivalent:@""];animate.target=self;animate.state=KPMiiPreviewAnimation()?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:animate];[menu popUpMenuPositioningItem:nil atLocation:CGPointMake(self.canvas.bounds.size.width-100,38) inView:self.canvas];
#else
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];[menu addAction:[UIAlertAction actionWithTitle:@"Export…" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self exportMii];}]];[menu addAction:[UIAlertAction actionWithTitle:@"Reset Changes…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){[self reset];}]];[menu addAction:[UIAlertAction actionWithTitle:KPMiiPreviewAnimation()?@"Stop Preview Animation":@"Animate Preview" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self toggleAnimation];}]];[menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];menu.popoverPresentationController.sourceView=self.canvas;menu.popoverPresentationController.sourceRect=CGRectMake(self.canvas.bounds.size.width-52,7,40,28);[self presentViewController:menu animated:YES completion:nil];
#endif
}
#if TARGET_OS_OSX
- (BOOL)windowShouldClose:(NSWindow*)window{
    if(self.allowClose)return YES;
    if(![self dirty]){KPPlay(KPSound::Close);return YES;}
    NSAlert *alert=[NSAlert new];alert.messageText=@"Save this Mii before quitting?";[alert addButtonWithTitle:@"Save & Quit"];[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Discard Changes"];KPPlay(KPSound::Dialog);NSInteger answer=[alert runModal];if(answer==NSAlertFirstButtonReturn){[self save];return self.allowClose;}KPPlay(answer==NSAlertThirdButtonReturn?KPSound::PagePrevious:KPSound::Close);return answer==NSAlertThirdButtonReturn;
}
- (void)windowWillClose:(NSNotification*)note{[[KPMiiSounds shared] suspendSoon];}
- (void)quit{[self.window performClose:nil];}
- (instancetype)initWithData:(NSData*)data slot:(NSUInteger)slot{
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,960,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){self.original=data;self.draft=data.mutableCopy;self.slot=slot;self.choosingGender=slot==NSNotFound;self.category=2;self.feature=7;window.title=slot==NSNotFound?@"Create Mii":@"Edit Mii";window.contentMinSize=NSMakeSize(800,600);window.delegate=self;self.canvas=[[KPMiiCanvas alloc]initWithFrame:NSMakeRect(0,0,960,720)];self.canvas.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=self.canvas;[self setup];[window center];}return self;
}
#else
- (void)quit{
    [self.view endEditing:YES];if(self.allowClose||![self dirty]){if(!self.allowClose)KPPlay(KPSound::Close);[self dismissViewControllerAnimated:YES completion:nil];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Save this Mii before quitting?" message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Save & Quit" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self save];}]];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction*action){KPPlay(KPSound::Close);}]];[alert addAction:[UIAlertAction actionWithTitle:@"Discard Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){KPPlay(KPSound::PagePrevious);[self dismissViewControllerAnimated:YES completion:nil];}]];KPPlay(KPSound::Dialog);[self presentViewController:alert animated:YES completion:nil];
}
- (void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=[UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection *traits){return KPColor(traits.userInterfaceStyle==UIUserInterfaceStyleDark?KPDarkPalette.background:KPLightPalette.background);}];self.canvas=[KPMiiCanvas new];self.canvas.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.canvas];[NSLayoutConstraint activateConstraints:@[[self.canvas.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.canvas.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[self.canvas.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],[self.canvas.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];[self setup];self.modalInPresentation=YES;[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillChangeFrameNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];}
- (void)keyboard:(NSNotification*)note{CGRect keyboard=[self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];CGFloat overlap=std::max(CGFloat(0),CGRectGetMaxY(self.canvas.frame)-keyboard.origin.y);for(UIView *view in self.canvas.subviews)if([view isKindOfClass:UIScrollView.class]){UIScrollView *scroll=(UIScrollView*)view;scroll.contentInset=UIEdgeInsetsMake(0,0,overlap,0);for(UITextField *field in self.nameFields)if(field.isFirstResponder)[scroll scrollRectToVisible:CGRectInset(field.frame,0,-10) animated:NO];}}
- (void)viewDidDisappear:(BOOL)animated{[super viewDidDisappear:animated];[[KPMiiSounds shared] suspendSoon];}
- (void)contentSizeChanged:(NSNotification*)note{for(KPMiiWiiButton *button in self.canvas.buttons)button.look=NSUIntegerMax;[self.canvas redraw];}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];}
#endif
- (void)setup{[[KPMiiSounds shared] prepare:KPMiiSoundArchivePath()];KPPlay(KPSound::Open);_ticket=std::make_shared<std::atomic<uint64_t>>(0);self.canvas.editor=self;self.thumbnails=[NSMutableDictionary dictionary];self.preview=[[KPMiiMetalPreview alloc]initWithFrame:CGRectZero];self.preview.fullBody=self.category<=1;self.preview.animated=KPMiiPreviewAnimation();[self.canvas addSubview:self.preview];[self rebuild];[self refreshPreview];}
@end
#if TARGET_OS_OSX
static KPMiiEditor *KPMiiActiveEditor;
// Open above the parent (the Miis window), which sits above the game window.
static void KPMiiShowEditor(id parent){
    NSWindow *window=KPMiiActiveEditor.window;
    if([parent isKindOfClass:NSWindow.class])window.level=std::max(window.level,((NSWindow*)parent).level);
    window.collectionBehavior|=NSWindowCollectionBehaviorFullScreenAuxiliary;
    [NSApp activateIgnoringOtherApps:YES];[KPMiiActiveEditor showWindow:nil];
}
#endif
void KartPadPresentMiiEditor(id parent,NSUInteger slot){
    [[KPMiiSounds shared] prepare:KPMiiSoundArchivePath()];
    NSError *error=nil;if(KartPadHasPendingMiiChanges()){KPPlay(KPSound::Reject);
#if TARGET_OS_OSX
        NSAlert *alert=[NSAlert new];alert.messageText=@"Restart KartPad first";alert.informativeText=@"Saved Mii changes are waiting to be applied. Quit and reopen KartPad, then try again.";[alert runModal];
#else
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Restart KartPad" message:@"Fully close and reopen KartPad to apply pending changes first." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[(UIViewController*)parent presentViewController:alert animated:YES completion:nil];
#endif
        return;
    }
#if TARGET_OS_OSX
    if(KPMiiActiveEditor.window.visible){KPMiiShowEditor(parent);return;}
#endif
    NSData *data=slot==NSNotFound?KartPadNewMii(&error):KartPadReadMii(slot,&error);
    if(!data){KPPlay(KPSound::Reject);
#if TARGET_OS_OSX
        NSAlert *alert=[NSAlert new];alert.messageText=error.localizedDescription?:@"Could not read this Mii.";[alert runModal];
#else
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not open Mii" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[(UIViewController*)parent presentViewController:alert animated:YES completion:nil];
#endif
        return;
    }
#if TARGET_OS_OSX
    KPMiiActiveEditor=[[KPMiiEditor alloc]initWithData:data slot:slot];KPMiiShowEditor(parent);
#else
    KPMiiEditor *editor=[KPMiiEditor new];editor.original=data;editor.draft=data.mutableCopy;editor.slot=slot;editor.category=2;editor.feature=7;editor.choosingGender=slot==NSNotFound;editor.modalPresentationStyle=UIModalPresentationFullScreen;
    // Follow the launcher's light/dark choice, which it sets as an override on its own controller.
    editor.overrideUserInterfaceStyle=[(UIViewController*)parent traitCollection].userInterfaceStyle;[(UIViewController*)parent presentViewController:editor animated:YES completion:nil];
#endif
}
