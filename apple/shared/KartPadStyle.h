// KartPad's Wii-style drawing kit, shared by the Mii screens and the Mac shell's screens (HOME,
// Controllers, Settings, setup): the Mii Channel palette, silver button faces on a ledge, pinstripes,
// cards, switches, glyphs and SF Pro Rounded type. Everything is Core Graphics, so it draws the same
// on Mac and iPhone/iPad. Each file that includes it gets its own copy; KPUsePalette picks light or
// dark for the view about to draw, on the main thread.
#pragma once
#import <TargetConditionals.h>
#include <algorithm>
#include <cmath>
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
#if !TARGET_OS_OSX
#define NSFontWeightMedium UIFontWeightMedium
#define NSFontWeightBold UIFontWeightBold
#define NSFontWeightHeavy UIFontWeightHeavy
#endif

// The system font in its rounded design (SF Pro Rounded), the closest built-in match to the Wii's
// friendly type. Falls back to the plain system font where the rounded design is missing.
// Kept per size and weight (main thread), since every text draw asks.
static KPMiiFont *KPStyleFont(CGFloat size,CGFloat weight){
    static NSMutableDictionary<NSString*,KPMiiFont*> *fonts;if(!fonts)fonts=[NSMutableDictionary dictionary];
    NSString *key=[NSString stringWithFormat:@"%.2f/%.3f",size,weight];
    if(KPMiiFont *font=fonts[key])return font;
    KPMiiFont *base=[KPMiiFont systemFontOfSize:size weight:weight],*font=base;
#if TARGET_OS_OSX
    if(NSFontDescriptor *rounded=[base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded])font=[NSFont fontWithDescriptor:rounded size:size]?:base;
#else
    if(UIFontDescriptor *rounded=[base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded])font=[UIFont fontWithDescriptor:rounded size:size];
#endif
    if(fonts.count>256)[fonts removeAllObjects];
    fonts[key]=font;return font;
}
// Mii Channel palette: silver gloss on pinstriped white, Wii-blue selection. Dark keeps the blue on graphite.
// Caution (amber, a tint behind a "restart to apply") and danger (red, a choice that loses something)
// are lighter in dark so they still read on graphite.
struct KPPalette{unsigned background,stripe,panel,panelStroke,well,buttonTop,buttonBottom,buttonStroke,tabTop,tabBottom,selectedTop,selectedBottom,accentTop,accentBottom,accentStroke,text,secondaryText,icon,switchOff;CGFloat gloss,shadow;unsigned ledge,accentLedge,caution,cautionInk,danger;};
static const KPPalette KPLightPalette{0xf2f4f5,0xe8ecee,0xfbfcfc,0xc9d1d6,0xe6ecef,0xffffff,0xdfe5e8,0xb3bdc3,0xfafbfc,0xd3dade,0xebf8fe,0xbde8fa,0x5ccbf3,0x1b9ad5,0x1784bc,0x3a4348,0x6a747a,0x5a646a,0xc3cbd0,.9,.20,0xb0bbc1,0x14709f,0xf0a030,0xc6731a,0xd0342c};
static const KPPalette KPDarkPalette{0x15181b,0x191d20,0x22272b,0x363d43,0x191d21,0x3c4349,0x2a3035,0x4c555c,0x3f464c,0x2b3136,0x1f4b5f,0x163748,0x4cc6f2,0x168ac4,0x63d0f5,0xe6ebee,0x9aa5ab,0xc3cbd0,0x4a535a,.13,.55,0x0c0e10,0x0d5880,0xf0a030,0xf2a64a,0xff6b5e};
static const KPPalette *KPP=&KPLightPalette;
static void KPUsePalette(id view){
#if TARGET_OS_OSX
    BOOL dark=[[[(NSView*)view effectiveAppearance] bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
#else
    BOOL dark=[(UIView*)view traitCollection].userInterfaceStyle==UIUserInterfaceStyleDark;
#endif
    KPP=dark?&KPDarkPalette:&KPLightPalette;
}
static void KPRefresh(id view){
#if TARGET_OS_OSX
    [(NSView*)view setNeedsDisplay:YES];
#else
    [(UIView*)view setNeedsDisplay];
#endif
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
    KPMiiFont *font=KPStyleFont(size,bold?NSFontWeightSemibold:NSFontWeightRegular);
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
// The corner radius of the first face drawn since this was set below zero. The Mac's focus ring reads
// it, so the ring's corners follow the face's whatever its style.
static CGFloat KPFaceRadiusDrawn=-1;
// Wii channel face: a rounded rectangle on a solid ledge, a soft vertical gradient and a double rim
// whose inner, white line fades out towards the bottom, where it would show against the grey.
// Pressing drops the face onto its ledge.
// Hovering (Mac pointer, iPad trackpad) lights the rim in Wii blue, like the Wii pointer highlight.
static void KPButtonFace(CGContextRef c,CGRect r,KPStyle style,BOOL selected,BOOL enabled,BOOL pressed,BOOL hovered=NO){
    const KPPalette *theme=KPP;if(style==KPStyle::Art){KPP=&KPLightPalette;style=KPStyle::Tile;}
    CGFloat ledge=3,radius=style==KPStyle::Card?14:style==KPStyle::Round?10:style==KPStyle::Tile?10:8;
    if(KPFaceRadiusDrawn<0)KPFaceRadiusDrawn=radius;
    CGRect body=CGRectMake(r.origin.x,r.origin.y,r.size.width,r.size.height-ledge);
    BOOL accent=style==KPStyle::Primary||(selected&&style==KPStyle::Tab),highlight=selected&&!accent;
    CGContextSaveGState(c);if(!enabled)CGContextSetAlpha(c,.42);
    KPFill(c,CGRectOffset(body,0,ledge),accent?KPP->accentLedge:highlight?KPP->accentStroke:KPP->ledge,radius);
    if(pressed)body=CGRectOffset(body,0,ledge-1);
    unsigned top=accent?KPP->accentTop:highlight?KPP->selectedTop:style==KPStyle::Tab?KPP->tabTop:KPP->buttonTop;
    unsigned bottom=accent?KPP->accentBottom:highlight?KPP->selectedBottom:style==KPStyle::Tab?KPP->tabBottom:KPP->buttonBottom;
    if(pressed)std::swap(top,bottom);
    KPGradientFill(c,body,radius,top,bottom);
    // The lit rim runs round the ledge too, so it is as thick at the bottom as on the other sides.
    BOOL lit=hovered&&enabled&&!pressed&&!highlight;
    KPStroke(c,lit?r:body,accent||highlight?KPP->accentStroke:lit?KPP->accentTop:KPP->buttonStroke,highlight||lit?2.5:1.25,radius);
    if(!pressed){
        const CGRect gloss=CGRectInset(body,highlight?4.5:3.5,highlight?4.5:3.5);const CGFloat round=std::max(CGFloat(0),radius-3.5);
        CGPathRef path=CGPathCreateWithRoundedRect(gloss,round,round,nullptr);
        CGContextSaveGState(c);CGContextAddPath(c,path);CGContextSetLineWidth(c,1);CGContextReplacePathWithStrokedPath(c);CGContextClip(c);CGPathRelease(path);
        const CGFloat alpha=KPP->gloss*(accent?.45:1),colors[]={1,1,1,alpha,1,1,1,alpha,1,1,1,0};const CGFloat stops[]={0,.45,.9};
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,stops,3);
        CGContextDrawLinearGradient(c,gradient,CGPointMake(0,gloss.origin.y),CGPointMake(0,CGRectGetMaxY(gloss)),0);
        CGGradientRelease(gradient);CGColorSpaceRelease(space);CGContextRestoreGState(c);
    }
    CGContextRestoreGState(c);KPP=theme;
}
// On/off indicator in the same rounded-rectangle language as the buttons.
static void KPSwitch(CGContextRef c,CGRect track,BOOL on){
    KPFill(c,track,on?KPP->accentBottom:KPP->switchOff,7);KPStroke(c,track,on?KPP->accentLedge:KPP->buttonStroke,1,7);
    CGFloat d=track.size.height-6;CGRect knob=CGRectMake(on?CGRectGetMaxX(track)-d-3:track.origin.x+3,track.origin.y+3,d,d);
    KPFill(c,CGRectOffset(knob,0,1.5),0x000000,5,.22);KPGradientFill(c,knob,5,0xffffff,0xe3e8eb);KPStroke(c,knob,KPP->buttonStroke,1,5);
}
static void KPLine(CGContextRef c,CGFloat x,CGFloat y,CGFloat x2,CGFloat y2){CGContextMoveToPoint(c,x,y);CGContextAddLineToPoint(c,x2,y2);CGContextStrokePath(c);}
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

// Pinstripes: a 1-point line every 4, the Mii Channel's background.
static void KPPinstripes(CGContextRef c,CGRect r,unsigned stripe){
    KPSetInk(c,stripe);CGContextSetLineWidth(c,1);
    for(CGFloat y=CGRectGetMinY(r)+1.5;y<CGRectGetMaxY(r);y+=4)KPLine(c,CGRectGetMinX(r),y,CGRectGetMaxX(r),y);
}
// A panel card: soft drop shadow, the panel fill and a hairline rim.
static void KPCard(CGContextRef c,CGRect r,CGFloat radius=18){
    KPFill(c,CGRectOffset(r,0,2),0x000000,radius,KPP->shadow*.6);KPFill(c,r,KPP->panel,radius);KPStroke(c,r,KPP->panelStroke,1,radius);
}
// Text in a chosen weight (KPText's bold is Semibold).
static void KPTextWeight(NSString*text,CGRect rect,CGFloat size,unsigned hex,CGFloat weight,NSTextAlignment align=NSTextAlignmentCenter){
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];style.alignment=align;style.lineBreakMode=rect.size.height>size*2.6?NSLineBreakByWordWrapping:NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:KPStyleFont(size,weight),NSForegroundColorAttributeName:KPColor(hex),NSParagraphStyleAttributeName:style}];
}
static CGSize KPTextSize(NSString*text,CGFloat size,CGFloat weight){return [text sizeWithAttributes:@{NSFontAttributeName:KPStyleFont(size,weight)}];}

// Player colors, as the game's Register Controllers screen colours its four slots (yellow, blue, red,
// green), so KartPad and the game agree. They tint player cards and badges and light controllers that
// have a color light (DualShock 4, DualSense). Ink is the text color on the fill.
static const unsigned KPPlayerColors[4]={0xf2b51e,0x2e7cf6,0xe5484d,0x30b85c};
static const unsigned KPPlayerDarkColors[4]={0xc48a0c,0x1d5bc4,0xb5303a,0x218a43};
static const unsigned KPPlayerInk[4]={0x3a2a00,0xffffff,0xffffff,0xffffff};
// The same colors for a controller's light, which looks washed out at the UI's values.
static const unsigned char KPPlayerLights[4][3]={{255,170,0},{0,70,255},{255,0,0},{0,255,40}};
