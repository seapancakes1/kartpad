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
        if(left<=right){CGFloat pad=12;CGRect rect=CGRectIntersection(CGRectMake(0,0,image.width,image.height),CGRectMake(left-pad,top-pad,right-left+1+2*pad,bottom-top+1+2*pad));CGImageRef crop=CGImageCreateWithImageInRect(cg,rect);CGImageRelease(cg);cg=crop;}
    }
#if TARGET_OS_OSX
    NSImage *result=[[NSImage alloc]initWithCGImage:cg size:NSMakeSize(CGImageGetWidth(cg),CGImageGetHeight(cg))];
#else
    UIImage *result=[UIImage imageWithCGImage:cg];
#endif
    CGImageRelease(cg);return result;
}
static dispatch_queue_t KPMiiWorkQueue(){static dispatch_queue_t q;static dispatch_once_t once;dispatch_once(&once,^{q=dispatch_queue_create("dev.kartpad.mii-preview",DISPATCH_QUEUE_SERIAL);});return q;}
// Only touched on the serial worker; platform images and GPU state are installed on main.
static std::shared_ptr<kartpad::mii::Resources> KPMiiLoadResources(){
    static std::shared_ptr<kartpad::mii::Resources> resource;static NSString *digest;
    NSData *data=[NSData dataWithContentsOfFile:KPMiiResourcePath()];
    if(!data)throw std::runtime_error("Preview resources unavailable. Reimport your game-data folder.");
    NSString *key=KPMiiDigest(data);if(resource&&[key isEqual:digest])return resource;
    auto next=std::make_shared<kartpad::mii::Resources>(Bytes(data));
    NSString *folder=[SupportRoot() stringByAppendingPathComponent:@"Caches/MiiPreview"];
    NSString *file=[folder stringByAppendingPathComponent:@"catalog-v6.plist"];
    NSDictionary *disk=[NSDictionary dictionaryWithContentsOfFile:file];BOOL loaded=NO;
    if([disk[@"digest"] isEqual:key]&&[disk[@"catalog"] isKindOfClass:NSData.class]&&[disk[@"catalog"] length]<64*1024*1024){try{next->DecodeCache(Bytes(disk[@"catalog"]));loaded=YES;}catch(...){}}
    if(!loaded){auto decoded=next->EncodeCache();[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];[@{@"digest":key,@"catalog":[NSData dataWithBytes:decoded.data() length:decoded.size()]}writeToFile:file atomically:YES];}
    resource=next;digest=key;return resource;
}
static std::shared_ptr<kartpad::mii::BodyResources> KPMiiLoadBody(){
    static std::shared_ptr<kartpad::mii::BodyResources> body;static NSString *digest;
    NSString *path=[[[KPMiiResourcePath() stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Scene/Model/MiiBody.szs"];
    NSData *data=[NSData dataWithContentsOfFile:path];if(!data)return nullptr;
    NSString *key=KPMiiDigest(data);if(body&&[key isEqual:digest])return body;
    auto next=std::make_shared<kartpad::mii::BodyResources>(Bytes(data));body=next;digest=key;return body;
}
static KPMiiImage *KPMiiFeatureImage(const kartpad::mii::Resources&r,unsigned field,unsigned value){
    using namespace kartpad::mii;
    if(field==14)return KPMiiImageFromPixels(Portrait::ColorMask(r.Texture(1,value),{0,0,0},Eyes[0]));
    if(field==20){Image image=r.Texture(2,value);for(size_t i=0;i<image.rgba.size();i+=4)for(int c=0;c<3;c++)image.rgba[i+c]=Hair[1][c];return KPMiiImageFromPixels(image);}
    if(field==29)return KPMiiImageFromPixels(Portrait::ColorMask(r.Texture(11,value),Lip0[0],Lip1[0]));
    if((field==33||field==37||field==38)&&value==0)return nil;
    if((field==33||field==37)&&value)return KPMiiImageFromPixels(Portrait::AccessoryThumbnail(r,field,value),YES);
    auto a=Appearance::Decode(CreateDefaultMii({0,0,0,0,0,0}));a.Set(field,value);
    if(field==7||field==9){a.Set(11,30);a.Set(12,1);}
    return KPMiiImageFromPixels(Portrait::Render(r,a),YES);
}
static void KPFill(CGContextRef c,CGRect rect,unsigned hex,CGFloat radius=0){
    CGContextSetRGBFillColor(c,((hex>>16)&255)/255.,((hex>>8)&255)/255.,(hex&255)/255.,1);
    CGPathRef path=CGPathCreateWithRoundedRect(rect,radius,radius,nullptr);CGContextAddPath(c,path);CGContextFillPath(c);CGPathRelease(path);
}
static void KPStroke(CGContextRef c,CGRect rect,unsigned hex,CGFloat width=1,CGFloat radius=0){
    CGContextSetRGBStrokeColor(c,((hex>>16)&255)/255.,((hex>>8)&255)/255.,(hex&255)/255.,1);CGContextSetLineWidth(c,width);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(rect,width/2,width/2),radius,radius,nullptr);CGContextAddPath(c,path);CGContextStrokePath(c);CGPathRelease(path);
}
static void KPText(NSString*text,CGRect rect,CGFloat size,unsigned hex=0x435754,BOOL bold=NO,NSTextAlignment align=NSTextAlignmentCenter){
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];style.alignment=align;style.lineBreakMode=NSLineBreakByWordWrapping;
    KPMiiColor *color=[KPMiiColor colorWithRed:((hex>>16)&255)/255. green:((hex>>8)&255)/255. blue:(hex&255)/255. alpha:1];
    KPMiiFont *font=[KPMiiFont systemFontOfSize:size weight:bold?NSFontWeightSemibold:NSFontWeightRegular];
#if !TARGET_OS_OSX
    font=[UIFontMetrics.defaultMetrics scaledFontForFont:font maximumPointSize:std::max(size,std::min(size*1.3,rect.size.height*.75))];
#endif
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
static void KPBevel(CGContextRef c,CGRect r,BOOL selected,BOOL enabled=YES,BOOL pressed=NO,BOOL category=NO){
    if(!enabled)CGContextSetAlpha(c,.4);
    KPFill(c,CGRectOffset(r,0,2),0xb4c5c2,8);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(r,1,1),7,7,nullptr);CGContextSaveGState(c);CGContextAddPath(c,path);CGContextClip(c);
    CGFloat colors[]={.99,.995,.99,1,.80,.87,.85,1};if(selected||pressed){CGFloat s[]={.75,.94,.91,1,.43,.72,.68,1};std::copy(s,s+8,colors);}
    if(category){CGFloat steel[]={.72,.79,.78,1,.57,.68,.67,1};std::copy(steel,steel+8,colors);if(selected||pressed){CGFloat teal[]={.15,.75,.64,1,.04,.58,.49,1};std::copy(teal,teal+8,colors);}}
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,nullptr,2);CGContextDrawLinearGradient(c,gradient,CGPointMake(r.origin.x,r.origin.y),CGPointMake(r.origin.x,CGRectGetMaxY(r)),0);CGGradientRelease(gradient);CGColorSpaceRelease(space);CGContextRestoreGState(c);
    KPStroke(c,r,selected?0x428a82:0x8fa6a2,selected?2.5:1.25,8);KPStroke(c,CGRectInset(r,3,3),0xf8fffc,1,5);CGContextSetAlpha(c,1);
}
static void KPLine(CGContextRef c,CGFloat x,CGFloat y,CGFloat x2,CGFloat y2){CGContextMoveToPoint(c,x,y);CGContextAddLineToPoint(c,x2,y2);CGContextStrokePath(c);}
// Wii toolbar silhouettes: white artwork over the silver/teal category tabs.
static void KPIcon(CGContextRef c,unsigned category,CGRect rect){
    CGContextSaveGState(c);CGContextTranslateCTM(c,rect.origin.x,rect.origin.y);CGContextScaleCTM(c,rect.size.width/40,rect.size.height/40);
    CGContextSetRGBFillColor(c,1,1,1,1);CGContextSetRGBStrokeColor(c,1,1,1,1);CGContextSetLineWidth(c,2.5);CGContextSetLineCap(c,kCGLineCapRound);CGContextSetLineJoin(c,kCGLineJoinRound);
    CGColorRef shadow=CGColorCreateGenericRGB(.26,.42,.39,.32);CGContextSetShadowWithColor(c,CGSizeMake(0,.6),1.2,shadow);CGColorRelease(shadow);
    auto fill=[&](){CGContextClosePath(c);CGContextFillPath(c);};
    if(category==0){
        // Bubble and face use cutouts, preserving the tab color beneath them.
        CGPathRef bubble=CGPathCreateWithRoundedRect(CGRectMake(3,2,34,13),4,4,nullptr);CGContextAddPath(c,bubble);CGPathRelease(bubble);
        for(int x:{10,18,26})CGContextAddEllipseInRect(c,CGRectMake(x,6,3,3));CGContextEOFillPath(c);
        CGContextMoveToPoint(c,17,15);CGContextAddLineToPoint(c,20,19);CGContextAddLineToPoint(c,22,15);fill();
        CGContextAddEllipseInRect(c,CGRectMake(10,20,20,17));for(int x:{15,23})CGContextAddEllipseInRect(c,CGRectMake(x,25,2.7,2.7));CGContextAddEllipseInRect(c,CGRectMake(15,31,10,2.5));CGContextEOFillPath(c);
    }else if(category==1){
        CGContextFillEllipseInRect(c,CGRectMake(13,3,14,14));
        CGContextMoveToPoint(c,17,15);CGContextAddQuadCurveToPoint(c,20,13,23,15);CGContextAddLineToPoint(c,24,29);CGContextAddLineToPoint(c,22.5,37);CGContextAddLineToPoint(c,20.5,37);CGContextAddLineToPoint(c,20,28);CGContextAddLineToPoint(c,19.5,37);CGContextAddLineToPoint(c,17.5,37);CGContextAddLineToPoint(c,16,29);fill();
    }else if(category==2){
        CGContextStrokeEllipseInRect(c,CGRectMake(9,5,22,30));
        CGContextFillEllipseInRect(c,CGRectMake(14,16,3,3));CGContextFillEllipseInRect(c,CGRectMake(23,16,3,3));
        CGContextSetLineWidth(c,1.8);KPLine(c,20,20,18,23);CGContextMoveToPoint(c,16,27);CGContextAddQuadCurveToPoint(c,20,31,24,27);CGContextStrokePath(c);
    }else if(category==3){
        CGContextAddEllipseInRect(c,CGRectMake(7,4,26,32));
        CGContextMoveToPoint(c,12,23);CGContextAddLineToPoint(c,22,12);CGContextAddQuadCurveToPoint(c,24,18,28,21);CGContextAddLineToPoint(c,27,29);CGContextAddQuadCurveToPoint(c,20,38,12,29);CGContextClosePath(c);CGContextEOFillPath(c);
    }else if(category==4){
        CGContextMoveToPoint(c,3,17);CGContextAddQuadCurveToPoint(c,9,14,18,23);CGContextAddQuadCurveToPoint(c,9,23,3,19);fill();
        CGContextMoveToPoint(c,37,17);CGContextAddQuadCurveToPoint(c,31,14,22,23);CGContextAddQuadCurveToPoint(c,31,23,37,19);fill();
    }else if(category==5){
        for(int x:{2,22}){CGContextAddEllipseInRect(c,CGRectMake(x,15,16,11));CGContextAddEllipseInRect(c,CGRectMake(x+6,16,4,9));CGContextEOFillPath(c);}
    }else if(category==6){
        CGContextSetLineWidth(c,4.5);CGContextMoveToPoint(c,24,7);CGContextAddLineToPoint(c,17,25);CGContextAddQuadCurveToPoint(c,13,34,24,33);CGContextAddLineToPoint(c,28,30);CGContextStrokePath(c);
    }else if(category==7){
        CGContextMoveToPoint(c,5,20);CGContextAddQuadCurveToPoint(c,9,9,15,15);CGContextAddQuadCurveToPoint(c,20,6,25,15);CGContextAddQuadCurveToPoint(c,31,9,35,20);fill();
        CGContextMoveToPoint(c,5,24);CGContextAddLineToPoint(c,35,24);CGContextAddQuadCurveToPoint(c,33,34,20,34);CGContextAddQuadCurveToPoint(c,7,34,5,24);fill();
    }else if(category==8){
        CGContextMoveToPoint(c,20,16);CGContextAddCurveToPoint(c,12,9,10,23,3,21);CGContextAddCurveToPoint(c,6,30,16,29,20,22);CGContextAddCurveToPoint(c,24,29,34,30,37,21);CGContextAddCurveToPoint(c,30,23,28,9,20,16);fill();
    }else if(category==9){
        CGContextSetLineWidth(c,2.8);CGContextStrokeEllipseInRect(c,CGRectMake(2,10,16,17));CGContextStrokeEllipseInRect(c,CGRectMake(22,10,16,17));CGContextMoveToPoint(c,18,17);CGContextAddQuadCurveToPoint(c,20,13,22,17);CGContextStrokePath(c);
        CGContextFillEllipseInRect(c,CGRectMake(14,30,12,4));
    }
    CGContextRestoreGState(c);
}
static void KPArrow(CGContextRef c,CGPoint from,CGPoint to,CGFloat width=3.7){
    CGFloat angle=atan2(to.y-from.y,to.x-from.x),length=6;
    CGContextSetLineWidth(c,width);CGContextSetLineCap(c,kCGLineCapRound);KPLine(c,from.x,from.y,to.x,to.y);
    CGContextMoveToPoint(c,to.x,to.y);CGContextAddLineToPoint(c,to.x-length*cos(angle-.65),to.y-length*sin(angle-.65));CGContextAddLineToPoint(c,to.x-length*cos(angle+.65),to.y-length*sin(angle+.65));CGContextClosePath(c);CGContextFillPath(c);
}
static void KPControlIcon(CGContextRef c,CGRect rect,int kind,int direction){
    CGContextSaveGState(c);CGContextTranslateCTM(c,rect.origin.x,rect.origin.y);CGContextScaleCTM(c,rect.size.width/40,rect.size.height/40);
    CGContextSetRGBFillColor(c,.26,.43,.39,1);CGContextSetRGBStrokeColor(c,.26,.43,.39,1);CGContextSetLineJoin(c,kCGLineJoinRound);CGContextSetLineCap(c,kCGLineCapRound);
    if(kind==0){
        CGContextFillEllipseInRect(c,CGRectMake(7,16,8,8));
        KPArrow(c,direction<0?CGPoint{27,31}:CGPoint{27,9},direction<0?CGPoint{27,9}:CGPoint{27,31},4.2);
    }else if(kind==1){
        CGFloat radius=direction<0?3.4:6;CGContextFillEllipseInRect(c,CGRectMake(20-radius,20-radius,radius*2,radius*2));
        for(int x:{-1,1})for(int y:{-1,1}){CGPoint inner{CGFloat(20+x*(direction<0?7:9)),CGFloat(20+y*(direction<0?7:9))},outer{CGFloat(20+x*15),CGFloat(20+y*15)};KPArrow(c,direction<0?outer:inner,direction<0?inner:outer,3.2);}
    }else if(kind==2){
        if(direction<0){CGContextTranslateCTM(c,40,0);CGContextScaleCTM(c,-1,1);}
        CGContextFillEllipseInRect(c,CGRectMake(16,19,8,8));CGContextSetLineWidth(c,4.2);CGContextMoveToPoint(c,7,25);CGContextAddCurveToPoint(c,9,5,31,5,33,25);CGContextStrokePath(c);KPArrow(c,{32,18},{33,27},4.2);
    }else if(kind==3){
        if(direction<0){CGContextFillEllipseInRect(c,CGRectMake(16,16,8,8));KPArrow(c,{4,20},{13,20},3.8);KPArrow(c,{36,20},{27,20},3.8);}
        else {CGContextFillEllipseInRect(c,CGRectMake(2,16,8,8));CGContextFillEllipseInRect(c,CGRectMake(30,16,8,8));KPArrow(c,{20,20},{13,20},3.8);KPArrow(c,{20,20},{27,20},3.8);}
    }else if(kind==4){ // Undo/redo additions use a clear, solid return arrow.
        if(direction>0){CGContextTranslateCTM(c,40,0);CGContextScaleCTM(c,-1,1);}
        CGContextSetLineWidth(c,3.8);CGContextMoveToPoint(c,29,29);CGContextAddLineToPoint(c,29,20);CGContextAddQuadCurveToPoint(c,29,11,20,11);CGContextAddLineToPoint(c,10,11);CGContextStrokePath(c);KPArrow(c,{19,11},{9,11},3.8);
    }else if(kind==5){for(int x:{9,18,27})CGContextFillEllipseInRect(c,CGRectMake(x,18,4.8,4.8));}
    else if(kind==6){if(direction<0){CGContextTranslateCTM(c,40,0);CGContextScaleCTM(c,-1,1);}CGContextMoveToPoint(c,14,9);CGContextAddLineToPoint(c,29,20);CGContextAddLineToPoint(c,14,31);CGContextClosePath(c);CGContextFillPath(c);}
    CGContextRestoreGState(c);
}

enum class KPAction{Category,Select,Adjust,Page,Mode,Toggle,Rotate,Front,Quit,Save,Discard,Birthday,Undo,Redo,More,Gender,Start,Slider};
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
- (void)drawRect:(NSRect)rect{[self.canvas drawItem:self.index context:NSGraphicsContext.currentContext.CGContext pressed:self.highlighted];if(self.window.firstResponder==self)KPStroke(NSGraphicsContext.currentContext.CGContext,CGRectInset(self.bounds,3,3),0x297f92,2,7);}
- (void)mouseDown:(NSEvent*)event{self.canvas.editor->_history.Begin();[super mouseDown:event];self.canvas.editor->_history.End();}
#else
- (void)drawRect:(CGRect)rect{[self.canvas drawItem:self.index context:UIGraphicsGetCurrentContext() pressed:self.highlighted];}
- (void)down{
    BOOL continuous=self.index<self.canvas->_items.size()&&self.canvas->_items[self.index].action==KPAction::Adjust;
    if(!continuous)return;
    KPMiiEditor *editor=self.canvas.editor;editor->_history.Begin();[self activate];
    if(!self.window)return;
    __weak KPMiiWiiButton *weak=self;
    self.repeatTimer=[NSTimer scheduledTimerWithTimeInterval:.35 repeats:NO block:^(NSTimer*t){
        KPMiiWiiButton *button=weak;if(!button||!button.enabled)return;
        button.repeatTimer=[NSTimer scheduledTimerWithTimeInterval:.085 repeats:YES block:^(NSTimer*repeat){KPMiiWiiButton *button=weak;if(!button.enabled){[repeat invalidate];return;}[button activate];}];
    }];
}
- (void)tap{if(self.index>=self.canvas->_items.size()||self.canvas->_items[self.index].action==KPAction::Adjust)return;KPMiiEditor *editor=self.canvas.editor;editor->_history.Begin();[self activate];editor->_history.End();}
- (void)up{[self.repeatTimer invalidate];self.repeatTimer=nil;self.canvas.editor->_history.End();}
- (void)didMoveToWindow{if(!self.window)[self up];}
#endif
- (void)activate{if(self.index<self.canvas->_items.size()&&self.canvas->_items[self.index].enabled)[self.canvas.editor performItem:self.canvas->_items[self.index]];}
@end
#if TARGET_OS_OSX
@interface KPMiiWiiSlider : NSSlider
@property(nonatomic,weak) KPMiiEditor *editor;
@end
@implementation KPMiiWiiSlider
- (void)mouseDown:(NSEvent*)event{self.editor->_history.Begin();[super mouseDown:event];self.editor->_history.End();}
@end
#endif
static unsigned KPBirthdayDays(unsigned month){return kartpad::mii::BirthdayDays(month);}
static NSArray<NSString*> *KPBirthdayMonths(){return @[@"Not set",@"January",@"February",@"March",@"April",@"May",@"June",@"July",@"August",@"September",@"October",@"November",@"December"];}
static NSString *KPBirthdayLabel(const kartpad::mii::Appearance &a){return a.Get(1)&&a.Get(2)?[NSString stringWithFormat:@"%@ %u",KPBirthdayMonths()[a.Get(1)],a.Get(2)]:@"Not set";}
static id KPLabelView(NSString *text,CGRect frame,CGFloat size=16){
#if TARGET_OS_OSX
    NSTextField *label=[NSTextField wrappingLabelWithString:text];label.frame=frame;label.font=[NSFont systemFontOfSize:size];label.textColor=[NSColor colorWithRed:.27 green:.35 blue:.33 alpha:1];
#else
    UILabel *label=[[UILabel alloc]initWithFrame:frame];label.text=text;label.font=[UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:size] maximumPointSize:std::max(size,std::min(size*1.3,frame.size.height*.75))];label.adjustsFontForContentSizeCategory=YES;label.textColor=[UIColor colorWithRed:.27 green:.35 blue:.33 alpha:1];label.numberOfLines=0;
#endif
    return label;
}
@implementation KPMiiCanvas
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)layout{[super layout];if(!CGSizeEqualToSize(self.bounds.size,self.previousSize)){self.previousSize=self.bounds.size;[self rebuild];}}
- (void)keyDown:(NSEvent*)event{if([event.charactersIgnoringModifiers isEqual:@"\033"]){[self.editor quit];return;}if([event.charactersIgnoringModifiers isEqual:@"z"]&&(event.modifierFlags&NSEventModifierFlagCommand)){KPItem item{};item.action=(event.modifierFlags&NSEventModifierFlagShift)?KPAction::Redo:KPAction::Undo;[self.editor performItem:item];return;}[super keyDown:event];}
#else
- (void)layoutSubviews{[super layoutSubviews];if(!CGSizeEqualToSize(self.bounds.size,self.previousSize)){self.previousSize=self.bounds.size;[self rebuild];}}
#endif
- (void)redraw{
#if TARGET_OS_OSX
    self.needsDisplay=YES;
#else
    [self setNeedsDisplay];
#endif
    for(id hint in self.editor.nameHints){BOOL invalid=self.editor.validationMessage.length&&[hint tag]==self.editor.validationField;NSString *message=invalid?self.editor.validationMessage:@"Up to 10 characters";
#if TARGET_OS_OSX
        [hint setStringValue:message];[hint setTextColor:invalid?NSColor.systemRedColor:[NSColor colorWithRed:.39 green:.46 blue:.44 alpha:1]];
#else
        [hint setText:message];[hint setTextColor:invalid?UIColor.systemRedColor:[UIColor colorWithRed:.39 green:.46 blue:.44 alpha:1]];
#endif
    }
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));
    for(KPMiiWiiButton *button in self.buttons){auto &item=_items[button.index];
        if(item.action==KPAction::Adjust){auto f=kartpad::mii::AppearanceFields[item.field];int value=int(a.Get(item.field))+item.value;item.enabled=value>=int(f.minimum)&&value<=int(f.maximum);}
        if(item.action==KPAction::Undo)item.enabled=self.editor->_history.CanUndo();
        if(item.action==KPAction::Redo)item.enabled=self.editor->_history.CanRedo();
        if(item.action==KPAction::Save||item.action==KPAction::Discard)item.enabled=[self.editor dirty];
        button.enabled=item.enabled;
#if !TARGET_OS_OSX
        BOOL selected=item.action==KPAction::Category?item.selected:item.action==KPAction::Select?a.Get(item.field)==unsigned(item.value):NO;button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0)|(!item.enabled?UIAccessibilityTraitNotEnabled:0);
#endif
#if TARGET_OS_OSX
        button.needsDisplay=YES;
#else
        [button setNeedsDisplay];
#endif
    }
}
- (void)rebuild{
    if(!self.editor.draft)return;
    for(id view in self.subviews.copy)if(view!=self.editor.preview)[view removeFromSuperview];
    self.buttons=[NSMutableArray array];self.editor.nameFields=[NSMutableArray array];self.editor.nameHints=[NSMutableArray array];_items.clear();
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;BOOL compact=w<680,shortLayout=!compact&&h<500;
    CGFloat margin=compact?12:24,top=compact?154:114;
    CGFloat previewWidth=compact?w-2*margin:(w-3*margin)*.34;
    _previewRect=compact?CGRectMake(margin,top,previewWidth,170):CGRectMake(margin,top,previewWidth,std::max(CGFloat(70),std::min(h-top-(shortLayout?84:126),previewWidth*1.9)));
    CGFloat panelX=compact?margin:CGRectGetMaxX(_previewRect)+margin;
    CGFloat panelY=compact?CGRectGetMaxY(_previewRect)+60:top;
    CGFloat panelHeight=std::max(CGFloat(140),h-panelY-94);
    if(!compact&&!shortLayout)panelHeight=std::min(panelHeight,std::max(CGFloat(540),previewWidth*1.9));
    _panelRect=CGRectMake(panelX,panelY,w-margin-panelX,panelHeight);
    self.editor.preview.frame=CGRectMake(_previewRect.origin.x+4,_previewRect.origin.y+30,_previewRect.size.width-8,_previewRect.size.height-34);
    [self addSubview:KPLabelView(KPMiiName(self.editor.draft,2),CGRectMake(_previewRect.origin.x+8,_previewRect.origin.y+6,_previewRect.size.width-16,24),17)];self.editor.preview.hidden=self.editor.choosingGender;
    auto add=[&](KPAction action,CGRect rect,NSString *label,unsigned field=0,int value=0,BOOL selected=NO){_items.push_back({action,rect,field,value,label,YES,selected});};
    if(self.editor.choosingGender){
        CGFloat bw=std::min(CGFloat(220),(w-60)/2);CGFloat center=h*.38;
        add(KPAction::Gender,CGRectMake(w/2-bw-8,center,bw,150),@"Male",0,0,self.editor.gender==0);
        add(KPAction::Gender,CGRectMake(w/2+8,center,bw,150),@"Female",0,1,self.editor.gender==1);
        add(KPAction::Start,CGRectMake(w/2-120,center+184,240,52),@"Start from scratch");
        add(KPAction::Quit,CGRectMake(20,h-70,110,44),@"Quit");
    }else{
        CGFloat gap=compact?5:7;int cols=compact?5:10;CGFloat tw=(w-2*margin-gap*(cols-1))/cols;
        for(unsigned i=0;i<10;i++)add(KPAction::Category,CGRectMake(margin+(i%cols)*(tw+gap),54+(i/cols)*48,tw,44),[NSString stringWithUTF8String:kartpad::mii::EditorCategories[i]],i,0,self.editor.category==i);
        CGFloat rx=shortLayout?CGRectGetMaxX(_previewRect)-144:CGRectGetMidX(_previewRect)-72,ry=CGRectGetMaxY(_previewRect)+8;
        add(KPAction::Rotate,CGRectMake(rx,ry,44,44),@"Rotate left",0,-1);
        add(KPAction::Front,CGRectMake(rx+50,ry,44,44),@"Front");
        add(KPAction::Rotate,CGRectMake(rx+100,ry,44,44),@"Rotate right",0,1);
        CGFloat quitY=(compact||shortLayout)?ry:ry+52;
        add(KPAction::Quit,CGRectMake(margin,quitY,(compact||shortLayout)?70:previewWidth,(compact||shortLayout)?44:40),@"Quit");
        CGFloat footerY=std::min(h-76,CGRectGetMaxY(_panelRect)+18);
        add(KPAction::Save,CGRectMake(w-margin-224,footerY,108,44),@"Save & Quit");
        add(KPAction::Discard,CGRectMake(w-margin-108,footerY,108,44),@"Discard");
        add(KPAction::Undo,CGRectMake(w-156,5,44,44),@"Undo");add(KPAction::Redo,CGRectMake(w-106,5,44,44),@"Redo");add(KPAction::More,CGRectMake(w-56,5,44,44),@"More");
        CGFloat x=_panelRect.origin.x+12,y=_panelRect.origin.y+12,pw=_panelRect.size.width-24;
        auto appearance=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));
        id form=nil;
        if(self.editor.category<=1){
            CGRect frame=CGRectInset(_panelRect,12,12);
#if TARGET_OS_OSX
            NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:frame];scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;
            KPMiiCanvas *document=[[KPMiiCanvas alloc]initWithFrame:CGRectMake(0,0,frame.size.width,self.editor.category==0?566:250)];scroll.documentView=document;[self addSubview:scroll];form=document;
#else
            UIScrollView *scroll=[[UIScrollView alloc]initWithFrame:frame];scroll.contentSize=CGSizeMake(frame.size.width,self.editor.category==0?566:250);scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self addSubview:scroll];form=scroll;
#endif
            if(self.editor.category==0){
                for(unsigned n=0;n<2;n++){
                    [form addSubview:KPLabelView(n?@"Creator":@"Nickname",CGRectMake(4,n*92,100,25),15)];
#if TARGET_OS_OSX
                    NSTextField *field=[NSTextField textFieldWithString:KPMiiName(self.editor.draft,n?54:2)];field.font=[NSFont systemFontOfSize:18];field.delegate=self.editor;field.frame=CGRectMake(4,n*92+26,pw-8,34);field.bezelStyle=NSTextFieldRoundedBezel;
#else
                    UITextField *field=[[UITextField alloc]initWithFrame:CGRectMake(4,n*92+26,pw-8,36)];field.text=KPMiiName(self.editor.draft,n?54:2);field.font=[UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:18] maximumPointSize:24];field.adjustsFontForContentSizeCategory=YES;field.borderStyle=UITextBorderStyleRoundedRect;field.autocorrectionType=UITextAutocorrectionTypeNo;field.delegate=self.editor;[field addTarget:self.editor action:@selector(nameChanged:) forControlEvents:UIControlEventEditingChanged];
#endif
                    #if TARGET_OS_OSX
                    field.toolTip=@"Names fit 10 UTF-16 units. Emoji and some symbols use more than one unit.";
#else
                    field.accessibilityHint=@"Up to 10 letters. Emoji and some symbols use more of the available space.";
#endif
                    field.tag=n?54:2;[form addSubview:field];[self.editor.nameFields addObject:field];
                    id hint=KPLabelView(@"Up to 10 characters",CGRectMake(4,n*92+64,pw-8,24),12);[hint setTag:field.tag];[form addSubview:hint];[self.editor.nameHints addObject:hint];
                }
                [form addSubview:KPLabelView(@"Gender",CGRectMake(4,194,pw,24),15)];
                add(KPAction::Select,CGRectMake(x,y+220,(pw-8)/2,44),@"Male",0,0);
                add(KPAction::Select,CGRectMake(x+(pw+8)/2,y+220,(pw-8)/2,44),@"Female",0,1);
                [form addSubview:KPLabelView(@"Birthday",CGRectMake(4,280,pw,24),15)];
#if TARGET_OS_OSX
                NSPopUpButton *month=[[NSPopUpButton alloc]initWithFrame:CGRectMake(4,306,(pw-16)*.65,36) pullsDown:NO];
                [month addItemsWithTitles:@[@"Not set",@"January",@"February",@"March",@"April",@"May",@"June",@"July",@"August",@"September",@"October",@"November",@"December"]];
                [month selectItemAtIndex:appearance.Get(1)];month.tag=1;month.target=self.editor;month.action=@selector(birthdayChanged:);[month setAccessibilityLabel:@"Birthday month"];[form addSubview:month];
                NSPopUpButton *day=[[NSPopUpButton alloc]initWithFrame:CGRectMake(12+(pw-16)*.65,306,(pw-16)*.35,36) pullsDown:NO];
                if(!appearance.Get(1))[day addItemWithTitle:@"Day"];
                else for(unsigned d=1;d<=KPBirthdayDays(appearance.Get(1));d++)[day addItemWithTitle:[NSString stringWithFormat:@"%u",d]];
                [day selectItemAtIndex:appearance.Get(2)?std::min(appearance.Get(2),KPBirthdayDays(appearance.Get(1)))-1:0];day.enabled=appearance.Get(1)>0;day.tag=2;day.target=self.editor;day.action=@selector(birthdayChanged:);[day setAccessibilityLabel:@"Birthday day"];[form addSubview:day];
#else
                add(KPAction::Birthday,CGRectMake(x,y+306,pw,44),KPBirthdayLabel(appearance));
#endif
                add(KPAction::Toggle,CGRectMake(x,y+366,pw/2-4,44),@"Favorite",4);
                add(KPAction::Toggle,CGRectMake(x+pw/2+4,y+366,pw/2-4,44),@"Mingle",10);
                [form addSubview:KPLabelView(@"Favorite color",CGRectMake(4,426,pw,24),15)];
                CGFloat sw=std::min(CGFloat(44),(pw-5*7)/6);for(unsigned i=0;i<12;i++)add(KPAction::Select,CGRectMake(x+(i%6)*(sw+7),y+456+(i/6)*50,sw,44),@"Favorite color",3,i);
            }else{
                for(unsigned n=0;n<2;n++){
                    [form addSubview:KPLabelView(n?@"Weight":@"Height",CGRectMake(4,n*110+14,pw-8,28),22)];
#if TARGET_OS_OSX
                    KPMiiWiiSlider *slider=[KPMiiWiiSlider sliderWithValue:appearance.Get(n?6:5) minValue:0 maxValue:127 target:self.editor action:@selector(sliderChanged:)];slider.frame=CGRectMake(4,n*110+52,pw-8,38);slider.continuous=YES;slider.editor=self.editor;
#else
                    UISlider *slider=[[UISlider alloc]initWithFrame:CGRectMake(4,n*110+52,pw-8,38)];slider.minimumValue=0;slider.maximumValue=127;slider.value=appearance.Get(n?6:5);slider.minimumTrackTintColor=[UIColor colorWithRed:.35 green:.68 blue:.63 alpha:1];[slider addTarget:self.editor action:@selector(sliderBegin:) forControlEvents:UIControlEventTouchDown];[slider addTarget:self.editor action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[slider addTarget:self.editor action:@selector(sliderEnd:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
#endif
                    slider.tag=n?6:5;
#if TARGET_OS_OSX
                    [slider setAccessibilityLabel:n?@"Weight":@"Height"];
#else
                    slider.accessibilityLabel=n?@"Weight":@"Height";
#endif
                    [form addSubview:slider];
                }
            }
        }else{
#if TARGET_OS_OSX
            NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:CGRectInset(_panelRect,12,12)];scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;
            KPMiiCanvas *document=[[KPMiiCanvas alloc]initWithFrame:CGRectMake(0,0,pw,600)];scroll.documentView=document;[self addSubview:scroll];form=document;
#else
            UIScrollView *scroll=[[UIScrollView alloc]initWithFrame:CGRectInset(_panelRect,12,12)];scroll.showsVerticalScrollIndicator=YES;[self addSubview:scroll];form=scroll;
#endif
            auto ids=kartpad::mii::FeatureIds(self.editor.feature);unsigned pages=unsigned((ids.size()+11)/12);self.editor.page=std::min(self.editor.page,std::max(1u,pages)-1);
            CGFloat side=compact?138:std::min(CGFloat(150),pw*.36),gap2=compact?7:12;
            CGFloat gridW=pw-side-gap2,gridH=_panelRect.size.height-80;
            CGFloat tileW=(gridW-2*7)/3,tileH=std::min(tileW,(gridH-3*7)/4);
            tileH=std::max(CGFloat(44),tileH);
            add(KPAction::Page,CGRectMake(x,y,44,44),@"Previous page",0,-1);_items.back().enabled=self.editor.page>0;
            add(KPAction::Page,CGRectMake(x+gridW-44,y,44,44),@"Next page",0,1);_items.back().enabled=self.editor.page+1<pages;
            for(unsigned i=0;i<12&&self.editor.page*12+i<ids.size();i++){unsigned value=ids[self.editor.page*12+i];add(KPAction::Select,CGRectMake(x+(i%3)*(tileW+7),y+52+(i/3)*(tileH+7),tileW,tileH),@"Feature",self.editor.feature,value);}
            CGFloat sx=x+gridW+gap2,sy=y;
            unsigned colorField=self.editor.category==2?8:self.editor.category==3?12:self.editor.category==4?22:self.editor.category==5?17:self.editor.category==7?30:self.editor.category==8?39:self.editor.category==9?34:99;
            if(colorField!=99){unsigned count=kartpad::mii::AppearanceFields[colorField].maximum+1;CGFloat sw=(side-8)/3;for(unsigned i=0;i<count;i++)add(KPAction::Select,CGRectMake(sx+(i%3)*(sw+4),sy+(i/3)*48,sw,44),@"Color",colorField,i);sy+=((count+2)/3)*48+12;}
            if(self.editor.category==2){add(KPAction::Mode,CGRectMake(sx,sy,side,44),self.editor.feature==7?@"Details":@"Face shape",self.editor.feature==7?9:7);sy+=52;}
            if(self.editor.category==3){add(KPAction::Toggle,CGRectMake(sx,sy,side,44),@"Flip hair",13);sy+=52;}
            if(self.editor.category==8){add(KPAction::Mode,CGRectMake(sx,sy,side,44),self.editor.feature==37?@"Beard":@"Mustache",self.editor.feature==37?38:37);sy+=52;add(KPAction::Toggle,CGRectMake(sx,sy,side,44),@"Mole",42);sy+=52;}
            std::vector<std::pair<unsigned,NSString*>> adjustments;
            switch(self.editor.category){
            case 4:adjustments={{24,@"Move"},{23,@"Size"},{21,@"Rotate"},{25,@"Spacing"}};break;
            case 5:adjustments={{16,@"Move"},{18,@"Size"},{15,@"Rotate"},{19,@"Spacing"}};break;
            case 6:adjustments={{28,@"Move"},{27,@"Size"}};break;
            case 7:adjustments={{32,@"Move"},{31,@"Size"}};break;
            case 8:adjustments=appearance.Get(42)?std::vector<std::pair<unsigned,NSString*>>{{44,@"Mole move"},{43,@"Mole size"},{45,@"Mole across"}}:std::vector<std::pair<unsigned,NSString*>>{{41,@"Move"},{40,@"Size"}};break;
            case 9:adjustments={{36,@"Move"},{35,@"Size"}};break;
            }
            CGFloat ah=64;
            for(auto adjustment:adjustments){unsigned f=adjustment.first;NSString *label=adjustment.second;
                CGRect labelFrame=CGRectMake(sx,sy,side,18);
                labelFrame.origin.x-=x;labelFrame.origin.y-=y;
                [(form?:self) addSubview:KPLabelView(label,labelFrame,12)];
                add(KPAction::Adjust,CGRectMake(sx,sy+18,(side-5)/2,44),[label stringByAppendingString:@" −"],f,-1);add(KPAction::Adjust,CGRectMake(sx+(side+5)/2,sy+18,(side-5)/2,44),[label stringByAppendingString:@" +"],f,1);sy+=ah;}
#if TARGET_OS_OSX
            [(NSView*)form setFrameSize:NSMakeSize(pw,std::max(CGFloat(52+4*(tileH+7)),sy-y+4))];
#else
            ((UIScrollView*)form).contentSize=CGSizeMake(pw,std::max(CGFloat(52+4*(tileH+7)),sy-y+4));
#endif
            [form addSubview:KPLabelView([NSString stringWithFormat:@"%u / %u",self.editor.page+1,pages],CGRectMake(46,10,gridW-92,24),14)];
        }
        for(NSUInteger i=0;i<_items.size();i++){
            auto &item=_items[i];KPMiiWiiButton *button=[[KPMiiWiiButton alloc]initWithFrame:item.rect];button.canvas=self;button.index=i;
#if TARGET_OS_OSX
            button.bordered=NO;button.title=@"";button.target=button;button.action=@selector(activate);button.continuous=item.action==KPAction::Adjust;[button setPeriodicDelay:.35 interval:.085];[button setAccessibilityLabel:item.action==KPAction::Select?[NSString stringWithFormat:@"%@, choice %d",item.label,item.value+1]:item.label];[button setAccessibilityRole:NSAccessibilityButtonRole];
#else
            [button addTarget:button action:@selector(down) forControlEvents:UIControlEventTouchDown];[button addTarget:button action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];[button addTarget:button action:@selector(up) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel|UIControlEventTouchDragExit];button.accessibilityLabel=item.action==KPAction::Select?[NSString stringWithFormat:@"%@, choice %d",item.label,item.value+1]:item.label;button.accessibilityTraits=UIAccessibilityTraitButton;
#endif
            if(form&&item.action!=KPAction::Save&&item.action!=KPAction::Discard&&item.rect.origin.x>=x&&item.rect.origin.y>=y){CGRect frame=item.rect;frame.origin.x-=x;frame.origin.y-=y;button.frame=frame;[form addSubview:button];}else [self addSubview:button];[self.buttons addObject:button];
        }
    }
    if(self.editor.choosingGender){for(NSUInteger i=0;i<_items.size();i++){auto &item=_items[i];KPMiiWiiButton *b=[[KPMiiWiiButton alloc]initWithFrame:item.rect];b.canvas=self;b.index=i;
#if TARGET_OS_OSX
        b.bordered=NO;b.title=@"";b.target=b;b.action=@selector(activate);[b setAccessibilityLabel:item.label];
#else
        b.accessibilityLabel=item.label;[b addTarget:b action:@selector(down) forControlEvents:UIControlEventTouchDown];[b addTarget:b action:@selector(up) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchCancel];
#endif
        [self addSubview:b];[self.buttons addObject:b];}}
    [self redraw];
}
- (void)drawRect:(CGRect)rect{
#if TARGET_OS_OSX
    CGContextRef c=NSGraphicsContext.currentContext.CGContext;
#else
    CGContextRef c=UIGraphicsGetCurrentContext();
#endif
    KPFill(c,self.bounds,0xe8eeec);CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    // Quiet Wii scanlines and rounded chrome, rather than contemporary app cards.
    CGContextSetRGBStrokeColor(c,.89,.92,.91,.35);CGContextSetLineWidth(c,.5);for(CGFloat y=40;y<h;y+=3)KPLine(c,0,y,w,y);
    if(!self.editor)return;
    if(self.editor.choosingGender){KPText(@"Create a Mii",CGRectMake(20,h*.18,w-40,40),30,0x4b625c,YES);KPText(@"Choose Male or Female",CGRectMake(20,h*.18+46,w-40,30),18);return;}
    KPText([NSString stringWithUTF8String:kartpad::mii::EditorCategories[self.editor.category]],CGRectMake(24,9,w-190,26),18,0x526d66,YES,NSTextAlignmentLeft);
    KPFill(c,_panelRect,0xf3f7f4,12);KPStroke(c,_panelRect,0xa8bab5,1.5,12);

        NSString *message=self.editor.validationMessage.length?self.editor.validationMessage:self.editor.previewMessage;
    if(message.length)KPText(message,CGRectMake(w<680?90:_panelRect.origin.x,h-30,w-(w<680?102:_panelRect.origin.x)-12,28),w<680?10:12,self.editor.validationMessage.length?0x9a3e34:0x637771);
}
- (void)drawItem:(NSUInteger)i context:(CGContextRef)c pressed:(BOOL)pressed{
    if(i>=_items.size())return;const auto &item=_items[i];auto a=kartpad::mii::Appearance::Decode(Bytes(self.editor.draft));CGRect r=CGRectMake(1,1,item.rect.size.width-2,item.rect.size.height-4);BOOL selected=item.selected||(item.action==KPAction::Save&&item.enabled);
    if(item.action==KPAction::Select)selected=a.Get(item.field)==unsigned(item.value);
    if(item.action==KPAction::Toggle)selected=a.Get(item.field)!=0;if(item.field==10&&item.action==KPAction::Toggle)selected=!a.Get(10);
    KPBevel(c,r,selected,item.enabled,pressed,item.action==KPAction::Category||item.action==KPAction::Gender);
    if(item.action==KPAction::Category){KPIcon(c,item.field,CGRectMake(CGRectGetMidX(r)-18,4,36,36));return;}
    if(item.action==KPAction::Gender){KPIcon(c,1,CGRectMake(CGRectGetMidX(r)-28,18,56,68));KPText(item.label,CGRectMake(4,100,r.size.width-8,30),22);return;}
    if(item.action==KPAction::Select){
        if(item.field==0){KPText(item.label,CGRectMake(4,11,r.size.width-8,24),16,0x435f55,selected);return;}
        if(item.field==3||item.field==8||item.field==12||item.field==17||item.field==22||item.field==30||item.field==34||item.field==39){
            using namespace kartpad::mii;Color color=item.field==3?Shirt[item.value]:item.field==8?Skin[item.value]:item.field==17?Eyes[item.value]:item.field==30?Lip0[item.value]:item.field==34?Glasses[item.value]:Hair[item.value];unsigned hex=(color[0]<<16)|(color[1]<<8)|color[2];KPFill(c,CGRectInset(r,5,5),hex,4);if(selected)KPStroke(c,CGRectInset(r,7,7),item.value==0?0xffffff:0x263f37,2,3);return;
        }
        KPMiiImage *image=self.editor.thumbnails[[NSString stringWithFormat:@"%u:%d",item.field,item.value]];
        if(image){CGSize size=image.size;CGRect destination=CGRectInset(r,8,8);CGFloat scale=std::min(destination.size.width/size.width,destination.size.height/size.height);destination=CGRectMake(CGRectGetMidX(r)-size.width*scale/2,CGRectGetMidY(r)-size.height*scale/2,size.width*scale,size.height*scale);
#if TARGET_OS_OSX
            [image drawInRect:destination fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
#else
            [image drawInRect:destination];
#endif
        }else if((item.field==33||item.field==37||item.field==38)&&item.value==0)KPText(@"None",CGRectMake(2,r.size.height/2-10,r.size.width-4,24),14);else KPIcon(c,self.editor.category,CGRectInset(r,8,8));return;
    }
    NSString *text=item.label;
    CGRect glyph=CGRectMake(CGRectGetMidX(r)-17,CGRectGetMidY(r)-17,34,34);
    if(item.action==KPAction::Page||item.action==KPAction::Rotate){KPControlIcon(c,glyph,6,item.value);return;}
    if(item.action==KPAction::Undo||item.action==KPAction::Redo){KPControlIcon(c,glyph,4,item.action==KPAction::Undo?-1:1);return;}
    if(item.action==KPAction::More){KPControlIcon(c,glyph,5,0);return;}
    if(item.action==KPAction::Adjust){
        BOOL move=item.field==16||item.field==24||item.field==28||item.field==32||item.field==36||item.field==41||item.field==44;
        BOOL spacing=item.field==19||item.field==25||item.field==45,rotation=item.field==15||item.field==21;
        KPControlIcon(c,glyph,move?0:spacing?3:rotation?2:1,item.value);return;
    }
    if(item.action==KPAction::Birthday)text=KPBirthdayLabel(a);
    if(item.action==KPAction::Toggle){text=[NSString stringWithFormat:@"%@  %@",item.label,selected?@"✓":@"—"];}
    KPText(text,CGRectMake(3,r.size.height/2-9,r.size.width-6,24),item.action==KPAction::Quit?18:13,0x435f55,item.action==KPAction::Quit);
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
    self.preview.fullBody=category<=1;[self rebuild];[self refreshPreview];
}
- (void)refreshPreview{
    auto appearance=kartpad::mii::Appearance::Decode(Bytes(self.draft));uint64_t revision=_revision.Next();_ticket->store(revision);auto ticket=_ticket;
    unsigned field=self.feature,page=self.page;BOOL needsTiles=self.category>=2;
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
            NSString *previewStatus=body?nil:@"Body assets missing. Reimport game data. Head preview available.";
            static std::weak_ptr<kartpad::mii::Resources> previous;static NSMutableDictionary *cache;
            if(previous.lock().get()!=resource.get()){cache=[NSMutableDictionary dictionary];previous=resource;}
            NSMutableDictionary *images=[NSMutableDictionary dictionary];
            if(needsTiles){auto ids=kartpad::mii::FeatureIds(field);for(size_t i=page*12;i<std::min(ids.size(),size_t(page*12+12));i++){NSString *key=[NSString stringWithFormat:@"%u:%u",field,ids[i]];if(ticket->load()!=revision)return;
                if(!cache[key]){auto thumbnail=KPMiiFeatureImage(*resource,field,ids[i]);if(thumbnail)cache[key]=thumbnail;}if(cache[key])images[key]=cache[key];}}
            dispatch_async(dispatch_get_main_queue(),^{KPMiiEditor *editor=weak;if(!editor||!editor->_revision.Accept(revision))return;[editor.preview installScene:scene];[editor.thumbnails removeAllObjects];[editor.thumbnails addEntriesFromDictionary:images];editor.previewLoaded=YES;editor.previewMessage=editor.preview.device?previewStatus:@"Metal preview unavailable. Editing and export are available.";[editor.canvas redraw];});
        }catch(const std::exception&error){NSString *message=[NSString stringWithUTF8String:error.what()];dispatch_async(dispatch_get_main_queue(),^{KPMiiEditor *editor=weak;if(!editor||!editor->_revision.Accept(revision))return;[editor.preview installScene:nullptr];editor.previewLoaded=YES;editor.previewMessage=message;[editor.canvas redraw];});}
    }});
}
- (void)performItem:(const KPItem&)item{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));
    switch(item.action){
    case KPAction::Category:[self categoryChangedTo:item.field];return;
    case KPAction::Page:self.page+=item.value;[self rebuild];[self refreshPreview];return;
    case KPAction::Mode:self.feature=item.field;self.page=kartpad::mii::FeaturePage(item.field,a.Get(item.field));[self rebuild];[self refreshPreview];return;
    case KPAction::Gender:self.gender=item.value;[self rebuild];return;
    case KPAction::Start:{a.Set(0,self.gender);if(self.gender){a.Set(11,12);a.Set(14,4);a.Set(20,0);}self.draft=[NSMutableData dataWithBytes:a.bytes.data() length:74];self.original=self.draft.copy;self.choosingGender=NO;[self categoryChangedTo:2];return;}
    case KPAction::Select:a.Set(item.field,item.value);[self applyAppearance:a];return;
    case KPAction::Adjust:{int value=int(a.Get(item.field))+item.value;auto f=kartpad::mii::AppearanceFields[item.field];if(value>=int(f.minimum)&&value<=int(f.maximum)){a.Set(item.field,value);[self applyAppearance:a];}return;}
    case KPAction::Toggle:a.Set(item.field,!a.Get(item.field));[self applyAppearance:a];if(item.field==42)[self rebuild];return;
    case KPAction::Rotate:self.preview.yaw+=item.value*.35f;return;
    case KPAction::Front:self.preview.yaw=0;return;
    case KPAction::Undo:if(![self commitNames])return;a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.draft=[NSMutableData dataWithBytes:_history.Undo(a).bytes.data() length:74];[self historyChanged];return;
    case KPAction::Redo:if(![self commitNames])return;a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.draft=[NSMutableData dataWithBytes:_history.Redo(a).bytes.data() length:74];[self historyChanged];return;
    case KPAction::Quit:[self quit];return;
    case KPAction::Save:[self save];return;
    case KPAction::Discard:[self discard];return;
    case KPAction::Birthday:[self birthday];return;
    case KPAction::More:[self showMore];return;
    default:return;
    }
}
- (void)historyChanged{auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));self.page=kartpad::mii::FeaturePage(self.feature,a.Get(self.feature));[self rebuild];[self refreshPreview];}
#if TARGET_OS_OSX
- (void)sliderChanged:(NSSlider*)slider{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));a.Set(slider.tag,unsigned(slider.integerValue));[self applyAppearance:a];
}
#else
- (void)sliderBegin:(id)sender{_history.Begin();}
- (void)sliderEnd:(id)sender{_history.End();}
- (void)sliderChanged:(UISlider*)slider{auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));a.Set(slider.tag,unsigned(lroundf(slider.value)));[self applyAppearance:a];}
#endif
- (BOOL)commitNames{
    for(id field in self.nameFields){
#if TARGET_OS_OSX
        NSString *text=[field stringValue];if([(NSTextView*)[field currentEditor] hasMarkedText]){self.validationField=[field tag];self.validationMessage=@"Finish entering this name first.";[self.canvas redraw];return NO;}
#else
        NSString *text=[field text]?:@"";if([field markedTextRange]){self.validationField=[field tag];self.validationMessage=@"Finish entering this name first.";[self.canvas redraw];return NO;}
#endif
        NSMutableData *data=self.draft.mutableCopy;
        if((![text length]&&[field tag]==2)||!KPMiiSetName(data,text,[field tag])){
            self.validationField=[field tag];self.validationMessage=![text length]?@"Enter a nickname.":@"This name is too long. Please shorten it.";[self.canvas redraw];return NO;
        }
        if(![data isEqual:self.draft]){auto a=kartpad::mii::Appearance::Decode(Bytes(data));[self applyAppearance:a];}
    }self.validationMessage=nil;return YES;
}
#if TARGET_OS_OSX
- (void)controlTextDidBeginEditing:(NSNotification*)note{_history.Begin();}
- (void)controlTextDidEndEditing:(NSNotification*)note{[self commitNames];_history.End();}
- (void)controlTextDidChange:(NSNotification*)note{
    NSTextField *field=note.object;NSTextView *editor=(NSTextView*)field.currentEditor;if(editor.hasMarkedText)return;
    NSMutableData *data=self.draft.mutableCopy;
    if(KPMiiSetName(data,field.stringValue,field.tag)){[self applyAppearance:kartpad::mii::Appearance::Decode(Bytes(data))];}else{self.validationField=field.tag;self.validationMessage=@"This name is too long. Please shorten it.";[self.canvas redraw];}
}
#else
- (void)textFieldDidBeginEditing:(UITextField*)field{_history.Begin();}
- (void)textFieldDidEndEditing:(UITextField*)field{[self commitNames];_history.End();}
- (BOOL)textFieldShouldReturn:(UITextField*)field{if([self commitNames]){[field resignFirstResponder];return YES;}return NO;}
- (void)nameChanged:(UITextField*)field{if(field.markedTextRange)return;NSMutableData *data=self.draft.mutableCopy;if(KPMiiSetName(data,field.text?:@"",field.tag))[self applyAppearance:kartpad::mii::Appearance::Decode(Bytes(data))];else{self.validationField=field.tag;self.validationMessage=@"This name is too long. Please shorten it.";[self.canvas redraw];}}
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
    [self applyAppearance:a];[self rebuild];
}
- (void)birthday{}
#else
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView*)picker{return 2;}
- (NSInteger)pickerView:(UIPickerView*)picker numberOfRowsInComponent:(NSInteger)component{return component?std::max(1u,KPBirthdayDays(self.birthdayMonth)):13;}
- (NSString*)pickerView:(UIPickerView*)picker titleForRow:(NSInteger)row forComponent:(NSInteger)component{return component?(self.birthdayMonth?[NSString stringWithFormat:@"%ld",long(row+1)]:@"—"):KPBirthdayMonths()[row];}
- (void)pickerView:(UIPickerView*)picker didSelectRow:(NSInteger)row inComponent:(NSInteger)component{if(!component){self.birthdayMonth=unsigned(row);NSInteger day=[picker selectedRowInComponent:1];[picker reloadComponent:1];[picker selectRow:std::min(day,NSInteger(std::max(1u,KPBirthdayDays(unsigned(row)))-1)) inComponent:1 animated:NO];}}
- (void)birthdayDone:(id)sender{
    auto a=kartpad::mii::Appearance::Decode(Bytes(self.draft));unsigned month=unsigned([self.birthdayPicker selectedRowInComponent:0]);a.Set(1,month);a.Set(2,month?unsigned([self.birthdayPicker selectedRowInComponent:1]+1):0);
    [self applyAppearance:a];[self dismissViewControllerAnimated:YES completion:^{self.birthdayPicker=nil;}];
}
- (void)birthdayCancel:(id)sender{[self dismissViewControllerAnimated:YES completion:^{self.birthdayPicker=nil;}];}
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
    [self presentViewController:sheet animated:YES completion:nil];
}
#endif
- (void)discard{
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=@"Discard your changes?";alert.informativeText=self.slot==NSNotFound?@"This new Mii won’t be saved.":@"This Mii will stay as it was before you opened the editor.";[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Discard Changes"];if([alert runModal]==NSAlertSecondButtonReturn){self.allowClose=YES;[self close];}
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Discard your changes?" message:self.slot==NSNotFound?@"This new Mii won’t be saved.":@"This Mii will stay as it was before you opened the editor." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"Discard Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){self.allowClose=YES;[self dismissViewControllerAnimated:YES completion:nil];}]];[self presentViewController:alert animated:YES completion:nil];
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
    NSError *error=nil;if(!KartPadStageMiiEditor(self.slot,self.slot==NSNotFound?nil:self.original,self.draft,&error)){[self alert:error.localizedDescription?:@"Could not save this Mii."];return;}
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
    NSAlert *alert=[NSAlert new];alert.messageText=@"Reset all Mii changes?";[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Reset Changes"];if([alert runModal]==NSAlertSecondButtonReturn)[self resetConfirmed];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Reset all Mii changes?" message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"Reset Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){[self resetConfirmed];}]];[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)exportMii{
    if(![self commitNames])return;
    NSError *error=nil;NSData *data=KartPadExportMii(self.draft,&error);if(!data){[self alert:error.localizedDescription];return;}
#if TARGET_OS_OSX
    NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=@"My Mii.mii";if([panel runModal]==NSModalResponseOK&&![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])[self alert:error.localizedDescription];
#else
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"My Mii.mii"]];if(![data writeToURL:url options:NSDataWritingAtomic error:&error]){[self alert:error.localizedDescription];return;}
    UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:@[url] applicationActivities:nil];share.popoverPresentationController.sourceView=self.canvas;share.popoverPresentationController.sourceRect=CGRectMake(self.canvas.bounds.size.width-52,7,40,28);share.completionWithItemsHandler=^(UIActivityType type,BOOL complete,NSArray *items,NSError *e){[NSFileManager.defaultManager removeItemAtPath:directory error:nil];};[self presentViewController:share animated:YES completion:nil];
#endif
}
- (void)showMore{
#if TARGET_OS_OSX
    NSMenu *menu=[NSMenu new];for(NSString *title in @[@"Export…",@"Reset Changes…"]){NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:title action:[title hasPrefix:@"Export"]?@selector(exportMii):@selector(reset) keyEquivalent:@""];item.target=self;[menu addItem:item];}[menu popUpMenuPositioningItem:nil atLocation:CGPointMake(self.canvas.bounds.size.width-100,38) inView:self.canvas];
#else
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];[menu addAction:[UIAlertAction actionWithTitle:@"Export…" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self exportMii];}]];[menu addAction:[UIAlertAction actionWithTitle:@"Reset Changes…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){[self reset];}]];[menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];menu.popoverPresentationController.sourceView=self.canvas;menu.popoverPresentationController.sourceRect=CGRectMake(self.canvas.bounds.size.width-52,7,40,28);[self presentViewController:menu animated:YES completion:nil];
#endif
}
#if TARGET_OS_OSX
- (BOOL)windowShouldClose:(NSWindow*)window{
    if(self.allowClose||![self dirty])return YES;
    NSAlert *alert=[NSAlert new];alert.messageText=@"Save this Mii before quitting?";[alert addButtonWithTitle:@"Save & Quit"];[alert addButtonWithTitle:@"Keep Editing"];[alert addButtonWithTitle:@"Discard Changes"];NSInteger answer=[alert runModal];if(answer==NSAlertFirstButtonReturn){[self save];return self.allowClose;}return answer==NSAlertThirdButtonReturn;
}
- (void)quit{[self.window performClose:nil];}
- (instancetype)initWithData:(NSData*)data slot:(NSUInteger)slot{
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,960,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){self.original=data;self.draft=data.mutableCopy;self.slot=slot;self.choosingGender=slot==NSNotFound;self.category=2;self.feature=7;window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];window.title=slot==NSNotFound?@"Create Mii":@"Edit Mii";window.contentMinSize=NSMakeSize(800,600);window.delegate=self;self.canvas=[[KPMiiCanvas alloc]initWithFrame:NSMakeRect(0,0,960,720)];self.canvas.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=self.canvas;[self setup];[window center];}return self;
}
#else
- (void)quit{
    [self.view endEditing:YES];if(self.allowClose||![self dirty]){[self dismissViewControllerAnimated:YES completion:nil];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Save this Mii before quitting?" message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Save & Quit" style:UIAlertActionStyleDefault handler:^(UIAlertAction*action){[self save];}]];[alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"Discard Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*action){[self dismissViewControllerAnimated:YES completion:nil];}]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)viewDidLoad{[super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;self.view.backgroundColor=[UIColor colorWithRed:.91 green:.94 blue:.93 alpha:1];self.canvas=[KPMiiCanvas new];self.canvas.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.canvas];[NSLayoutConstraint activateConstraints:@[[self.canvas.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.canvas.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[self.canvas.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],[self.canvas.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];[self setup];self.modalInPresentation=YES;[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillChangeFrameNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];}
- (void)keyboard:(NSNotification*)note{CGRect keyboard=[self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];CGFloat overlap=std::max(CGFloat(0),CGRectGetMaxY(self.canvas.frame)-keyboard.origin.y);for(UIView *view in self.canvas.subviews)if([view isKindOfClass:UIScrollView.class]){UIScrollView *scroll=(UIScrollView*)view;scroll.contentInset=UIEdgeInsetsMake(0,0,overlap,0);for(UITextField *field in self.nameFields)if(field.isFirstResponder)[scroll scrollRectToVisible:CGRectInset(field.frame,0,-10) animated:NO];}}
- (void)contentSizeChanged:(NSNotification*)note{[self.canvas redraw];}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];}
#endif
- (void)setup{_ticket=std::make_shared<std::atomic<uint64_t>>(0);self.canvas.editor=self;self.thumbnails=[NSMutableDictionary dictionary];self.preview=[[KPMiiMetalPreview alloc]initWithFrame:CGRectZero];self.preview.fullBody=self.category<=1;[self.canvas addSubview:self.preview];[self rebuild];[self refreshPreview];}
@end
#if TARGET_OS_OSX
static KPMiiEditor *KPMiiActiveEditor;
#endif
void KartPadPresentMiiEditor(id parent,NSUInteger slot){
    NSError *error=nil;if(KartPadHasPendingMiiChanges()){
#if TARGET_OS_OSX
        NSAlert *alert=[NSAlert new];alert.messageText=@"Restart KartPad to apply pending changes first.";[alert runModal];
#else
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Restart KartPad" message:@"Fully close and reopen KartPad to apply pending changes first." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[(UIViewController*)parent presentViewController:alert animated:YES completion:nil];
#endif
        return;
    }
#if TARGET_OS_OSX
    if(KPMiiActiveEditor.window.visible){[KPMiiActiveEditor showWindow:nil];return;}
#endif
    NSData *data=slot==NSNotFound?KartPadNewMii(&error):KartPadReadMii(slot,&error);
    if(!data){
#if TARGET_OS_OSX
        NSAlert *alert=[NSAlert new];alert.messageText=error.localizedDescription?:@"Could not read this Mii.";[alert runModal];
#else
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not open Mii" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[(UIViewController*)parent presentViewController:alert animated:YES completion:nil];
#endif
        return;
    }
#if TARGET_OS_OSX
    KPMiiActiveEditor=[[KPMiiEditor alloc]initWithData:data slot:slot];[KPMiiActiveEditor showWindow:nil];
#else
    KPMiiEditor *editor=[KPMiiEditor new];editor.original=data;editor.draft=data.mutableCopy;editor.slot=slot;editor.category=2;editor.feature=7;editor.choosingGender=slot==NSNotFound;editor.modalPresentationStyle=UIModalPresentationFullScreen;[(UIViewController*)parent presentViewController:editor animated:YES completion:nil];
#endif
}
