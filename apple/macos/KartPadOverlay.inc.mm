// KartPad's own screens over the game: HOME, Controllers, Settings and the rest. They live inside
// the game window, above SDL's Metal view, so they follow it into full screen and onto a TV. Each is
// laid out on one 1280×720 design canvas that scales with the window, like a console's menus: the
// canvas is centred, and backgrounds and bars run on to the window's edges. While one is open the
// game holds still (KartPadOverlayPauseWanted) and gets no input; a controller, the keyboard or the
// mouse drives the screen. Controllers reach it through the Mii windows' reader
// (KartPadMacMiis.inc.mm), which hands each press here while a screen is up.
// Included by KartPadMacShell.mm after KartPadMacMiis.inc.mm.

#include "KartPadStyle.h"
#include "kartpad/mii/editor_sounds.h"
#import <QuartzCore/QuartzCore.h>
#include <vector>

using KPUISound = kartpad::mii::EditorSound;
static void KPUIPlay(KPUISound sound) { KartPadUIPlaySound(static_cast<NSInteger>(sound)); }

static constexpr CGFloat KPUIDesignWidth = 1280, KPUIDesignHeight = 720;
static BOOL KPUIReduceMotion() { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }
// The controller is in use, so the pointer gets out of the way; moving the mouse brings it back.
static void KPPadHideCursor() { [NSCursor setHiddenUntilMouseMoves:YES]; }

#pragma mark Views

// A view drawn in design points: it scales its drawing by `scale` (window points per design point),
// so text and artwork stay sharp at any window size. Decoration ignores the mouse.
@interface KPUIView : NSView
@property(nonatomic) CGFloat scale;
@property(nonatomic, copy) void (^paint)(CGContextRef c, CGSize size);
- (CGSize)designSize;
- (void)drawDesign:(CGContextRef)c size:(CGSize)size;
@end

@implementation KPUIView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _scale = 1;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
#if !TARGET_OS_OSX
    // UIKit draws a view opaque black behind its drawing unless told otherwise.
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
#endif
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)setScale:(CGFloat)scale {
  if (scale == _scale) return;
  _scale = scale;
  self.needsDisplay = YES;
}
- (CGSize)designSize { return CGSizeMake(self.bounds.size.width / self.scale, self.bounds.size.height / self.scale); }
- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)rect {
  (void)rect;
  CGContextRef c = NSGraphicsContext.currentContext.CGContext;
  KPUsePalette(self);
  CGContextSaveGState(c);
  CGContextScaleCTM(c, self.scale, self.scale);
  [self drawDesign:c size:self.designSize];
  CGContextRestoreGState(c);
}
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  if (self.paint) self.paint(c, size);
}
@end

struct KPUIState {
  BOOL focused, pressed, enabled;
};

@class KPScreen;

// A Wii-style control: a face its block paints, the focus ring, a springy pop when it takes the focus,
// and its own mouse tracking. (NSButton's tracking loop would stall the game, which shares this thread.)
@interface KPUIButton : KPUIView
// r is the face, in the button's design points; the margin around it holds the focus glow.
@property(nonatomic, copy) void (^face)(CGContextRef c, CGRect r, KPUIState state);
@property(nonatomic, copy) void (^activate)(void);
// Left and right change the control in place (a slider, a choice) rather than moving the focus.
@property(nonatomic, copy) BOOL (^adjust)(int direction);
// A slider's track under the pointer: called with the press (began) and each drag after it, in design
// points with the face rect. YES on the press takes the drag; NO leaves the press a click.
@property(nonatomic, copy) BOOL (^slide)(CGPoint point, CGRect face, BOOL began);
@property(nonatomic) BOOL enabled, focused, pressed;
// The last press that fired the action was a click (not A from a pad or the keyboard).
@property(nonatomic, readonly) BOOL clicked;
@property(nonatomic) KPUISound sound;
@property(nonatomic) CGFloat margin, radius, focusScale;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, weak) KPScreen *screen;
// Something the screen keeps with the control (a slot number, a device).
@property(nonatomic, strong) id tagObject;
@property(nonatomic) NSInteger tag2;
- (CGRect)faceRect;
- (void)springTo:(CGFloat)scale;
@end

@interface KPScreen : KPUIView
// The 1280×720 design area, in this screen's design points (the screen covers the whole window).
@property(nonatomic, readonly) CGRect safe;
@property(nonatomic, weak) KPUIButton *focus;
// Pinstriped Mii Channel panel behind everything (the game hidden); otherwise the game shows dimmed.
@property(nonatomic) BOOL solid;
// The game holds still while this screen is open.
@property(nonatomic) BOOL pausesGame;
// The screen hosts a view with its own controller handling (the Mii browser): presses go there.
@property(nonatomic) BOOL forwardsPads;
@property(nonatomic, copy) NSString *title;
- (void)build;
- (void)layoutDesign;
- (void)place:(NSView *)view at:(CGRect)design;
- (KPUIButton *)button:(CGRect)design face:(void (^)(CGContextRef, CGRect, KPUIState))face action:(void (^)(void))action;
- (NSArray<KPUIButton *> *)focusables;
- (KPUIButton *)initialFocus;
// A press the screen handles itself; NO leaves it to the navigator (moving, A, B).
- (BOOL)handle:(KartPadMiiPadButton)button;
// A key the screen wants as itself (a key being chosen for a button), before it is navigation.
- (BOOL)takesKey:(NSEvent *)event;
- (void)back;
- (void)willAppear;
- (void)didAppear;
- (void)willDisappear;
- (void)tick;
- (void)relayout;
// Where this screen's toasts may go first (top-left corners, in design points), before the overlay's
// usual places. A place is used only while no control lies under it.
- (NSArray<NSValue *> *)toastSpots;
@end

#pragma mark Overlay controller

@interface KPOverlayHost : NSView
@end

@interface KPToastView : KPUIView
@property(nonatomic, copy) NSString *heading, *detail;
@property(nonatomic) unsigned stripe;
@property(nonatomic, copy) void (^icon)(CGContextRef c, CGRect r);
@property(nonatomic, strong) NSImage *image;
// A controller's toast: its player (-1 while it has none) and a drawing of the controller.
@property(nonatomic) int player;
@property(nonatomic, copy) void (^art)(CGContextRef c, CGRect r);
// The screen that was showing when it came (nil over the game, or for a controller's): it goes when
// that screen does.
@property(nonatomic, weak) KPScreen *owner;
@property(nonatomic) BOOL owned, started, leaving;
@property(nonatomic) NSTimeInterval seconds;
// Counts restarts of its time, so an earlier timer doesn't take it away.
@property(nonatomic) NSUInteger showing;
@end

@interface KPOverlayController : NSObject
@property(nonatomic, strong) KPOverlayHost *host;
@property(nonatomic, strong) KPUIView *scrim;
@property(nonatomic, strong) NSMutableArray<KPScreen *> *stack;
@property(nonatomic, strong) NSMutableArray<KPToastView *> *toasts;
@property(nonatomic, strong) id keyMonitor;
@property(nonatomic, strong) NSTimer *ticker;
@property(nonatomic, weak) NSResponder *previousResponder;
// Return, Space or Enter went down on this control; its release presses it.
@property(nonatomic, weak) KPUIButton *keyPressed, *padPressed;
// Escape or Delete went down on a screen (it goes back when it comes up, so it isn't still held,
// and the key that opened HOME from the game doesn't close it again).
@property(nonatomic) int backKey;
@property(nonatomic) CGFloat scale;
@property(nonatomic) CGSize stage;
// The latest press came from the keyboard (not a controller).
@property(nonatomic) BOOL keyboardInput;
// Setup, before there's a game window: the screens go in this window instead.
@property(nonatomic, weak) NSWindow *hostWindow;
// Where the pointer rested when a screen opened or the controller or keyboard last moved the focus:
// hovering takes the focus again only once the mouse moves away from there.
@property(nonatomic) NSPoint pointerAnchor;
@property(nonatomic) BOOL pointerAnchored;
// The last move by direction: from where, to where, which way, and the column (or row) a run of moves
// keeps to, so pressing back the other way returns and up-down runs don't drift sideways.
@property(nonatomic, weak) KPUIButton *movedFrom, *movedTo;
@property(nonatomic) int movedDx, movedDy;
@property(nonatomic) CGFloat movedColumn;
+ (instancetype)shared;
- (void)anchorPointer;
- (void)pointerUsed;
- (BOOL)pointerMoved;
- (BOOL)active;
- (KPScreen *)top;
- (void)present:(KPScreen *)screen;
- (void)pop;
- (void)replaceTop:(KPScreen *)screen;
- (void)closeAll;
- (void)focus:(KPUIButton *)button sound:(BOOL)sound;
- (void)padPress:(KartPadMiiPadButton)button down:(BOOL)down;
- (void)toast:(NSString *)heading detail:(NSString *)detail stripe:(unsigned)stripe
         icon:(void (^)(CGContextRef c, CGRect r))icon image:(NSImage *)image;
- (void)toast:(NSString *)heading detail:(NSString *)detail stripe:(unsigned)stripe
         icon:(void (^)(CGContextRef c, CGRect r))icon image:(NSImage *)image seconds:(NSTimeInterval)seconds;
- (void)toastController:(NSString *)heading detail:(NSString *)detail player:(int)player image:(NSImage *)image
                   icon:(void (^)(CGContextRef c, CGRect r))icon art:(void (^)(CGContextRef c, CGRect r))art;
// Takes away the toasts raised on screen (and any whose screen has gone).
- (void)dismissToastsFrom:(KPScreen *)screen;
- (void)layoutToasts:(BOOL)animated;
- (void)relayout;
@end
static KPOverlayController *KPOverlay() { return [KPOverlayController shared]; }
// The keys go to KartPad's screen while the game window has them, unless a name is being typed.
static bool KPOverlayWantsKeys() {
  NSWindow *key = NSApp.keyWindow;
  if (key == nil || key != KPOverlay().host.window) return false;
  return ![key.firstResponder isKindOfClass:NSTextView.class];
}

#pragma mark KPUIButton

// The level (0 to 1, in hundredths) a point on a slider's track picks. The press must land on the
// track, give or take a knob's width; the drag after it can go anywhere.
static bool KPSliderLevel(CGRect track, CGPoint point, BOOL began, float *level) {
  if (began && (point.x < track.origin.x - 12 || point.x > CGRectGetMaxX(track) + 12)) return false;
  *level = std::round(std::clamp<CGFloat>((point.x - track.origin.x) / track.size.width, 0, 1) * 100) / 100;
  return true;
}

// A slider (HOME's volume, Settings' levels): the track on its ledge, filled in Wii blue up to the
// level, and the knob at the end of the fill. Dimmed (muted), the fill is grey.
static void KPDrawSlider(CGContextRef c, CGRect track, CGFloat level, BOOL dimmed = NO) {
  KPFill(c, CGRectOffset(track, 0, -1), KPP->ledge, 6);
  KPFill(c, track, KPP->well, 6);
  KPStroke(c, track, KPP->buttonStroke, 1, 6);
  const CGFloat fill = track.size.width * level;
  const CGRect filled = CGRectMake(track.origin.x + 1, track.origin.y + 1, fill - 2, track.size.height - 2);
  if (fill > 2 && dimmed) KPFill(c, filled, KPP->secondaryText, 5, 0.45);
  else if (fill > 2) KPGradientFill(c, filled, 5, KPP->accentTop, KPP->accentBottom);
  const CGRect knob = CGRectMake(track.origin.x + fill - 11, CGRectGetMidY(track) - 11, 22, 22);
  KPFill(c, CGRectOffset(knob, 0, 1.5), 0x000000, 11, 0.22);
  KPGradientFill(c, knob, 11, 0xffffff, 0xe3e8eb);
  KPStroke(c, knob, KPP->buttonStroke, 1, 11);
}

// A row of dots in the player colours that bounce in turn, Wii-loading style (the restart curtain,
// setup looking for the game). origin is the first dot's resting corner; phase runs from 0 to 1.
static void KPDrawLoadingDots(CGContextRef c, CGPoint origin, CGFloat phase) {
  for (int dot = 0; dot < 5; ++dot) {
    const CGFloat lift = std::max(0.0, sin(phase * 2 * M_PI - dot * 0.7)) * 14;
    KPSetInk(c, KPPlayerColors[dot % 4]);
    CGContextFillEllipseInRect(c, CGRectMake(origin.x + dot * 34, origin.y - lift, 22, 22));
  }
}

// A slider dragged with the pointer saves its level once the drag rests a moment, or is let go,
// rather than at every step: each save rewrites Config.toml. The screen shows the level as it goes
// meanwhile, and its sounds play as they did. Anything else that saves the same setting saves the
// waiting level first (KPSaveSlide), so it can't land after.
static void (^KPSlideSave)(void);
static NSUInteger KPSlideSaves;
static void KPSaveSlide() {
  void (^save)(void) = KPSlideSave;
  KPSlideSave = nil;
  if (save) save();
}
static void KPSaveSlideSoon(void (^save)(void)) {
  KPSlideSave = [save copy];
  const NSUInteger saves = ++KPSlideSaves;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (saves == KPSlideSaves) KPSaveSlide();
  });
}

@implementation KPUIButton {
  NSTrackingArea *_tracking;
  BOOL _inside, _sliding;
  CGFloat _wheel;       // trackpad travel not yet spent on an adjust step
  CGFloat _faceRadius;  // the corner radius the face last drew with (0 before it has drawn)
}
#if !TARGET_OS_OSX
@synthesize focused = _focused;  // UIView has a read-only focused of its own (isFocused)
#endif
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _enabled = YES;
    _margin = 8;
    _radius = 14;
    _focusScale = 1.04;
    _sound = KPUISound::Press;
  }
  return self;
}
- (NSView *)hitTest:(NSPoint)point {
  if (self.hidden || !self.enabled) return nil;
  NSPoint local = [self convertPoint:point fromView:self.superview];
  return NSPointInRect(local, self.bounds) ? self : nil;
}
- (CGRect)faceRect {
  CGSize size = self.designSize;
  return CGRectMake(self.margin, self.margin, size.width - 2 * self.margin, size.height - 2 * self.margin);
}
- (void)setEnabled:(BOOL)enabled {
  if (enabled == _enabled) return;
  _enabled = enabled;
  self.needsDisplay = YES;
}
- (void)setPressed:(BOOL)pressed {
  if (pressed == _pressed) return;
  _pressed = pressed;
  self.needsDisplay = YES;
  [self springTo:pressed ? 0.97 : (self.focused ? self.focusScale : 1)];
}
- (void)setFocused:(BOOL)focused {
  if (focused == _focused) return;
  _focused = focused;
  self.needsDisplay = YES;
  [self springTo:focused ? self.focusScale : 1];
  if (focused) NSAccessibilityPostNotification(self, NSAccessibilityFocusedUIElementChangedNotification);
}
// Scales about the centre with a spring; Reduce Motion skips the motion (the ring still shows focus).
- (void)springTo:(CGFloat)k {
  CALayer *layer = self.layer;
  if (layer == nil) return;
  const CGSize size = layer.bounds.size;
  const CGPoint anchor = layer.anchorPoint;
  const CGFloat cx = size.width * (0.5 - anchor.x), cy = size.height * (0.5 - anchor.y);
  const CATransform3D target = KPUIReduceMotion() || k == 1 ? CATransform3DIdentity :
      CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), CATransform3DMakeScale(k, k, 1)),
                          CATransform3DMakeTranslation(cx, cy, 0));
  const CATransform3D from = layer.presentationLayer ? layer.presentationLayer.transform : layer.transform;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.transform = target;
  if (!KPUIReduceMotion()) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"transform"];
    spring.fromValue = [NSValue valueWithCATransform3D:from];
    spring.toValue = [NSValue valueWithCATransform3D:target];
    spring.damping = 15;
    spring.stiffness = 320;
    spring.mass = 1;
    spring.duration = spring.settlingDuration;
    [layer addAnimation:spring forKey:@"pop"];
  }
  [CATransaction commit];
}
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  (void)size;
  const CGRect face = self.faceRect;
  const KPUIState state{self.focused, self.pressed, self.enabled};
  // The ring's corners follow the face's: those of the button face it draws, or for a face drawn
  // another way (an empty player's dashed outline), the button's radius.
  const CGFloat radius = _faceRadius > 0 ? _faceRadius : self.radius;
  if (self.focused && self.enabled) {
    // Wii-blue glow around the face, as the Wii pointer lights what it rests on.
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeZero, 10, KPColor(KPP->accentTop, 0.85).CGColor);
    // It reaches a point under the face, so no seam shows between it and the face's lit rim.
    KPStroke(c, CGRectInset(face, -3.5, -3.5), KPP->accentTop, 4.5, radius + 3.5);
    CGContextRestoreGState(c);
  }
  KPFaceRadiusDrawn = -1;
  if (self.face) self.face(c, face, state);
  const CGFloat drawn = KPFaceRadiusDrawn >= 0 ? KPFaceRadiusDrawn : self.radius;
  KPFaceRadiusDrawn = -1;
  if (drawn != radius) {
    _faceRadius = drawn;
    // Drawn focused before the face had told its radius: once more with the ring's corners right.
    if (self.focused) dispatch_async(dispatch_get_main_queue(), ^{ self.needsDisplay = YES; });
  }
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
      options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
  [self addTrackingArea:_tracking];
}
// The pointer is the Wii pointer: what it rests on takes the focus, once it has really moved. A
// pointer left resting where a screen opens (or the controller moved the focus) doesn't take it back.
- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  if (self.enabled && self.screen == KPOverlay().top && [KPOverlay() pointerMoved]) [KPOverlay() focus:self sound:YES];
}
- (void)mouseMoved:(NSEvent *)event {
  (void)event;
  if (self.enabled && !self.focused && self.screen == KPOverlay().top && [KPOverlay() pointerMoved])
    [KPOverlay() focus:self sound:NO];
}
- (void)mouseDown:(NSEvent *)event {
  (void)event;
  if (!self.enabled) return;
  [KPOverlay() pointerUsed];
  if (self.screen == KPOverlay().top) [KPOverlay() focus:self sound:NO];
  if (self.slide && self.slide([self designPoint:event], self.faceRect, YES)) {
    _sliding = YES;
    return;
  }
  _inside = YES;
  self.pressed = YES;
}
// Where the pointer is in design points, undoing the focus pop (a scale about the centre) the face is drawn with.
- (CGPoint)designPoint:(NSEvent *)event {
  const NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  const CGFloat k = self.layer && self.layer.transform.m11 > 0 ? self.layer.transform.m11 : 1;
  const CGFloat cx = NSMidX(self.bounds), cy = NSMidY(self.bounds);
  return CGPointMake((cx + (local.x - cx) / k) / self.scale, (cy + (local.y - cy) / k) / self.scale);
}
- (void)mouseDragged:(NSEvent *)event {
  if (_sliding) {
    if (self.slide) self.slide([self designPoint:event], self.faceRect, NO);
    return;
  }
  _inside = NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
  self.pressed = _inside;
}
- (void)mouseUp:(NSEvent *)event {
  (void)event;
  if (_sliding) {
    _sliding = NO;
    KPSaveSlide();
    return;
  }
  const BOOL fire = self.pressed && _inside;
  self.pressed = NO;
  if (fire) [self fire:YES];
}
// A wheel's notch adjusts a step; a trackpad, a step for every 32 points it moves, and not while it coasts.
- (void)scrollWheel:(NSEvent *)event {
  const CGFloat dy = event.scrollingDeltaY;
  if (!self.adjust || fabs(dy) <= fabs(event.scrollingDeltaX)) {
    [super scrollWheel:event];
    return;
  }
  if (!event.hasPreciseScrollingDeltas) {
    _wheel = 0;
    self.adjust(dy > 0 ? 1 : -1);
    return;
  }
  if (event.phase == NSEventPhaseBegan || event.momentumPhase != NSEventPhaseNone) _wheel = 0;
  if (event.momentumPhase != NSEventPhaseNone) return;
  if (_wheel * dy < 0) _wheel = 0;  // turning back starts a fresh step
  _wheel += dy;
  const CGFloat step = 32;
  if (fabs(_wheel) < step) return;
  const int direction = _wheel > 0 ? 1 : -1;
  _wheel -= direction * step;
  self.adjust(direction);
}
- (void)fire { [self fire:NO]; }
- (void)fire:(BOOL)clicked {
  if (!self.enabled || !self.activate) return;
  _clicked = clicked;
  if (self.sound != KPUISound::Count) KPUIPlay(self.sound);
  void (^activate)(void) = self.activate;
  // Let this press finish before the action opens or closes a screen.
  dispatch_async(dispatch_get_main_queue(), activate);
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return self.label; }
- (BOOL)accessibilityPerformPress { [self fire]; return YES; }
- (BOOL)isAccessibilityEnabled { return self.enabled; }
@end

// A little side-to-side wobble about the centre: a card saying hello (a controller joined, was found
// or pressed). Nothing with Reduce Motion.
static void KPUIWobble(NSView *view) {
  CALayer *layer = view.layer;
  if (layer == nil || KPUIReduceMotion()) return;
  const CGSize size = layer.bounds.size;
  const CGFloat cx = size.width * (0.5 - layer.anchorPoint.x), cy = size.height * (0.5 - layer.anchorPoint.y);
  NSMutableArray *frames = [NSMutableArray array];
  for (NSNumber *angle in @[@0, @0.05, @-0.045, @0.03, @-0.015, @0]) {
    const CATransform3D turn = CATransform3DConcat(
        CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), CATransform3DMakeRotation(angle.doubleValue, 0, 0, 1)),
        CATransform3DMakeTranslation(cx, cy, 0));
    [frames addObject:[NSValue valueWithCATransform3D:CATransform3DConcat(turn, layer.transform)]];
  }
  CAKeyframeAnimation *wobble = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
  wobble.values = frames;
  wobble.duration = 0.55;
  wobble.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [layer addAnimation:wobble forKey:@"wobble"];
}

#pragma mark KPScreen

// A solid screen's panel and pinstripes. Every row of it is the same all the way across, so it's kept
// as one column of pixels, drawn again only for a new height, scale or look, and stretched across the
// window: a screen repaints its background whole whenever anything drawn on it changes.
static void KPDrawScreenBackdrop(NSView *view, CGContextRef c, CGSize size) {
  static CGImageRef column;
  static CGFloat columnHeight, columnPixels;
  static const KPPalette *columnPalette;
  const CGFloat pixels = std::round([view convertSizeToBacking:view.bounds.size].height);
  if (pixels < 1 || size.height <= 0) return;
  if (column == nullptr || columnHeight != size.height || columnPixels != pixels || columnPalette != KPP) {
    CGImageRelease(column);
    column = nullptr;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(nullptr, 1, (size_t)pixels, 8, 0, space,
                                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (bitmap == nullptr) return;
    // Top down in design points, as the screen draws.
    CGContextTranslateCTM(bitmap, 0, pixels);
    CGContextScaleCTM(bitmap, pixels / size.height, -pixels / size.height);
    const CGRect all = CGRectMake(0, 0, size.width, size.height);
    KPFill(bitmap, all, KPP->background);
    KPPinstripes(bitmap, all, KPP->stripe);
    column = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    columnHeight = size.height;
    columnPixels = pixels;
    columnPalette = KPP;
  }
  if (column == nullptr) return;
  CGContextSaveGState(c);
  CGContextSetInterpolationQuality(c, kCGInterpolationNone);
  CGContextTranslateCTM(c, 0, size.height);
  CGContextScaleCTM(c, 1, -1);
  CGContextDrawImage(c, CGRectMake(0, 0, size.width, size.height), column);
  CGContextRestoreGState(c);
}

@implementation KPScreen {
  BOOL _built;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _pausesGame = YES;
  }
  return self;
}
// Screens catch every click, so nothing reaches the game under them. The controls are asked directly:
// KPUIView's own hitTest turns the mouse away, which a screen must not inherit.
- (NSView *)hitTest:(NSPoint)point {
  if (self.hidden) return nil;
  const NSPoint local = [self convertPoint:point fromView:self.superview];
  if (!NSPointInRect(local, self.bounds)) return nil;
  for (NSView *child in self.subviews.reverseObjectEnumerator)
    if (NSView *hit = [child hitTest:local]) return hit;
  return self;
}
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; }
- (CGRect)safe {
  const CGSize size = self.designSize;
  return CGRectMake(std::round((size.width - KPUIDesignWidth) / 2), std::round((size.height - KPUIDesignHeight) / 2),
                    KPUIDesignWidth, KPUIDesignHeight);
}
- (void)build {}
- (void)layoutDesign {}
- (void)relayout {
  if (!_built) {
    _built = YES;
    [self build];
  }
  [self layoutDesign];
  self.needsDisplay = YES;
}
- (void)place:(NSView *)view at:(CGRect)design {
  CGFloat margin = [view isKindOfClass:KPUIButton.class] ? ((KPUIButton *)view).margin : 0;
  const CGRect r = CGRectInset(design, -margin, -margin);
  const CGFloat s = self.scale;
  view.frame = NSMakeRect(std::round(r.origin.x * s), std::round(r.origin.y * s), std::round(r.size.width * s),
                          std::round(r.size.height * s));
  if ([view isKindOfClass:KPUIView.class]) {
    KPUIView *ui = (KPUIView *)view;
    // Rounding the frame to whole points shifts its scale a hair; keep drawing exact to the frame.
    ui.scale = r.size.width > 0 ? view.frame.size.width / r.size.width : s;
  }
  if (view.superview != self) [self addSubview:view];
}
- (KPUIButton *)button:(CGRect)design face:(void (^)(CGContextRef, CGRect, KPUIState))face action:(void (^)(void))action {
  KPUIButton *button = [[KPUIButton alloc] initWithFrame:NSZeroRect];
  button.face = face;
  button.activate = action;
  button.screen = self;
  [self place:button at:design];
  return button;
}
- (NSArray<KPUIButton *> *)focusables {
  NSMutableArray *found = [NSMutableArray array];
  __block void (^walk)(NSView *) = nil;
  __block __weak void (^weakWalk)(NSView *) = nil;
  weakWalk = walk = ^(NSView *view) {
    for (NSView *child in view.subviews) {
      if (child.hidden) continue;
      if ([child isKindOfClass:KPUIButton.class] && ((KPUIButton *)child).enabled && ((KPUIButton *)child).activate)
        [found addObject:child];
      else if ([child isKindOfClass:KPUIButton.class] && ((KPUIButton *)child).enabled && ((KPUIButton *)child).adjust)
        [found addObject:child];
      weakWalk(child);
    }
  };
  walk(self);
  return found;
}
- (KPUIButton *)initialFocus { return self.focusables.firstObject; }
- (BOOL)handle:(KartPadMiiPadButton)button { (void)button; return NO; }
- (BOOL)takesKey:(NSEvent *)event { (void)event; return NO; }
- (void)back { [KPOverlay() pop]; }
- (void)willAppear {}
- (void)didAppear {}
- (void)willDisappear {}
- (void)tick {}
- (NSArray<NSValue *> *)toastSpots { return @[]; }
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  if (!self.solid) return;
  KPDrawScreenBackdrop(self, c, size);
}
@end

#pragma mark Host and toasts

@implementation KPOverlayHost
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
// Over the game the host is invisible to the mouse unless a screen is open.
- (NSView *)hitTest:(NSPoint)point {
  if (!KPOverlay().active) return nil;
  NSView *hit = [super hitTest:point];
  return hit ?: self;
}
- (void)setFrameSize:(NSSize)size {
  const BOOL changed = !NSEqualSizes(size, self.frame.size);
  [super setFrameSize:size];
  if (changed) [KPOverlay() relayout];
}
// Keys are handled by the controller's monitor; swallow the rest so the window doesn't beep.
- (void)keyDown:(NSEvent *)event { (void)event; }
@end

static void KPDrawMiiWell(CGContextRef c, CGRect well, NSImage *portrait, unsigned color, BOOL empty);  // KartPadHomeScreen.inc.mm
static void KPDrawPlayerBadge(CGContextRef c, CGRect r, int slot, BOOL dim);

@implementation KPToastView
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  const CGRect card = CGRectMake(6, 4, size.width - 12, size.height - 12);
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 4), 14, [NSColor colorWithWhite:0 alpha:0.28].CGColor);
  KPFill(c, card, KPP->panel, 18);
  CGContextRestoreGState(c);
  if (self.art) {
    [self drawController:c card:card];
    return;
  }
  KPStroke(c, card, KPP->panelStroke, 1, 18);
  // The player's colour runs down the leading edge.
  if (self.stripe) {
    CGContextSaveGState(c);
    CGPathRef clip = CGPathCreateWithRoundedRect(card, 18, 18, nullptr);
    CGContextAddPath(c, clip);
    CGContextClip(c);
    CGPathRelease(clip);
    KPFill(c, CGRectMake(card.origin.x, card.origin.y, 8, card.size.height), self.stripe);
    CGContextRestoreGState(c);
  }
  const CGRect art = CGRectMake(card.origin.x + 22, card.origin.y + (card.size.height - 52) / 2, 52, 52);
  if (self.image) {
    KPFill(c, art, KPLightPalette.well, 14);
    CGContextSaveGState(c);
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    [self.image drawInRect:CGRectInset(art, 3, 3) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                  fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    NSGraphicsContext.currentContext = previous;
    CGContextRestoreGState(c);
  } else if (self.icon) {
    KPFill(c, art, KPP->well, 14);
    self.icon(c, CGRectInset(art, 9, 9));
  }
  const CGFloat x = art.origin.x + art.size.width + 16, w = CGRectGetMaxX(card) - x - 18;
  if (self.detail.length) {
    KPTextWeight(self.heading, CGRectMake(x, card.origin.y + 17, w, 26), 19, KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
    KPTextWeight(self.detail, CGRectMake(x, card.origin.y + 44, w, 22), 15, KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
  } else {
    KPTextWeight(self.heading, CGRectMake(x, CGRectGetMidY(card) - 13, w, 26), 19, KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
  }
}
// The player's colour fills the leading end, with their number on it (or their Mii, badged); a
// controller still without a player gets a grey end and its icon. The controller itself sits at the
// trailing end, its lights in the player's colour.
- (void)drawController:(CGContextRef)c card:(CGRect)card {
  const int player = self.player;
  const CGRect band = CGRectMake(card.origin.x, card.origin.y, 84, card.size.height);
  CGContextSaveGState(c);
  CGPathRef clip = CGPathCreateWithRoundedRect(card, 18, 18, nullptr);
  CGContextAddPath(c, clip);
  CGContextClip(c);
  CGPathRelease(clip);
  if (player >= 0) {
    KPGradientFill(c, band, 0, KPPlayerColors[player], KPPlayerDarkColors[player]);
    KPFill(c, CGRectMake(band.origin.x, band.origin.y, band.size.width, 1.5), 0xffffff, 0, 0.35);
  } else {
    KPFill(c, band, KPP->well);
  }
  CGContextRestoreGState(c);
  KPStroke(c, card, KPP->panelStroke, 1, 18);
  if (player >= 0 && self.image) {
    const CGRect well = CGRectMake(CGRectGetMidX(band) - 29, CGRectGetMidY(band) - 29, 52, 52);
    KPFill(c, CGRectOffset(well, 0, 2), 0x000000, 52 * 0.22, 0.18);
    KPDrawMiiWell(c, well, self.image, KPPlayerColors[player], NO);
    // On the well's corner, ringed in white, as on the HOME player cards.
    const CGRect badge = CGRectMake(CGRectGetMaxX(well) - 13, CGRectGetMaxY(well) - 13, 24, 24);
    KPSetInk(c, 0xffffff);
    CGContextFillEllipseInRect(c, CGRectInset(badge, -2.5, -2.5));
    KPDrawPlayerBadge(c, badge, player, NO);
  } else if (player >= 0) {
    KPCentredLabel(c, [NSString stringWithFormat:@"%d", player + 1], band, 50, KPPlayerInk[player], NSFontWeightHeavy);
  } else if (self.icon) {
    self.icon(c, CGRectMake(CGRectGetMidX(band) - 18, CGRectGetMidY(band) - 18, 36, 36));
  }
  const CGRect art = CGRectMake(CGRectGetMaxX(card) - 18 - 88, card.origin.y + 10, 88, card.size.height - 20);
  self.art(c, art);
  const CGFloat x = CGRectGetMaxX(band) + 18, w = art.origin.x - 12 - x;
  KPTextWeight(self.heading, CGRectMake(x, card.origin.y + 14, w, 30), 23, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  KPTextWeight(self.detail, CGRectMake(x, card.origin.y + 46, w, 22), 15, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
}
@end

#pragma mark Navigation

// The control the pressed direction leads to, as TV menus choose it (dy positive downwards). Only what
// lies that way counts (clearly: a neighbour a few points out of line isn't "above"), and left and
// right stay on their row. One in line (overlapping sideways) beats one off to the side, unless,
// going up or down, the one to the side lies wholly nearer; otherwise the nearest wins, distance
// ahead weighing more than sideways offset. `across` is the sideways position measured from (the column a run of
// moves up or down started in), CGFLOAT_MAX for the middle of `from` (not NAN: the build assumes
// fast math, which takes every number to be one).
static KPUIButton *KPUINearest(NSArray<KPUIButton *> *candidates, KPUIButton *from, int dx, int dy,
                               CGFloat across = CGFLOAT_MAX) {
  struct Span { CGFloat lo, hi; };
  struct Option { KPUIButton *view; bool beam, ahead; CGFloat gap, far, score; };
  auto frame = [](NSView *view) { return [view convertRect:((KPUIButton *)view).bounds toView:nil]; };
  // Window coordinates run upwards.
  auto along = [&](NSRect r) -> Span {
    return dx > 0 ? Span{NSMinX(r), NSMaxX(r)} : dx < 0 ? Span{-NSMaxX(r), -NSMinX(r)}
         : dy > 0 ? Span{-NSMaxY(r), -NSMinY(r)} : Span{NSMinY(r), NSMaxY(r)};
  };
  auto aside = [&](NSRect r) -> Span { return dx ? Span{NSMinY(r), NSMaxY(r)} : Span{NSMinX(r), NSMaxX(r)}; };
  const NSRect here = frame(from);
  const Span a = along(here), p = aside(here);
  const CGFloat middle = across == CGFLOAT_MAX ? (p.lo + p.hi) / 2 : across;
  auto beamBeats = [&](const Option &x, const Option &y) {
    if (y.beam || !x.beam) return false;
    if (!y.ahead || dx != 0) return true;
    return x.gap < y.far;
  };
  bool found = false;
  Option best{};
  for (KPUIButton *view in candidates) {
    if (view == from) continue;
    const NSRect there = frame(view);
    const Span b = along(there), q = aside(there);
    const CGFloat slack = 0.2 * std::min(a.hi - a.lo, b.hi - b.lo);
    if (!((a.lo + slack < b.lo || a.hi <= b.lo) && a.hi + slack < b.hi)) continue;
    const bool beam = std::min(p.hi, q.hi) - std::max(p.lo, q.lo) > 0;
    if (dx != 0 && !beam) continue;
    const CGFloat gap = std::max(CGFloat(0), b.lo - a.hi), offset = (q.lo + q.hi) / 2 - middle;
    const Option option{view, beam, b.lo >= a.hi, gap, std::max(CGFloat(1), b.hi - a.hi), 13 * gap * gap + offset * offset};
    if (!found || beamBeats(option, best) || (!beamBeats(best, option) && option.score < best.score)) {
      best = option;
      found = true;
    }
  }
  return found ? best.view : nil;
}

@implementation KPOverlayController

+ (instancetype)shared {
  static KPOverlayController *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [KPOverlayController new]; });
  return shared;
}

- (instancetype)init {
  if ((self = [super init])) {
    _stack = [NSMutableArray array];
    _toasts = [NSMutableArray array];
    _scale = 1;
    _backKey = -1;
    _host = [[KPOverlayHost alloc] initWithFrame:NSZeroRect];
    _host.wantsLayer = YES;
    _host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _host.hidden = YES;
    _scrim = [[KPUIView alloc] initWithFrame:NSZeroRect];
    _scrim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrim.paint = ^(CGContextRef c, CGSize size) {
      KPFill(c, CGRectMake(0, 0, size.width, size.height), 0x000000, 0, KPP == &KPDarkPalette ? 0.62 : 0.46);
    };
    [_host addSubview:_scrim];
    _scrim.alphaValue = 0;
  }
  return self;
}

- (BOOL)active { return self.stack.count > 0; }
- (KPScreen *)top { return self.stack.lastObject; }

- (void)anchorPointer {
  self.pointerAnchor = NSEvent.mouseLocation;
  self.pointerAnchored = YES;
}
- (void)pointerUsed { self.pointerAnchored = NO; }
- (BOOL)pointerMoved {
  if (!self.pointerAnchored) return YES;
  const NSPoint now = NSEvent.mouseLocation, then = self.pointerAnchor;
  if (std::hypot(now.x - then.x, now.y - then.y) < 4) return NO;
  self.pointerAnchored = NO;
  return YES;
}

// Into the game window, above SDL's Metal view (which SDL can re-create), once that window exists.
- (BOOL)attach {
  NSWindow *game = self.hostWindow ?: KPGameWindow();
  NSView *content = game.contentView;
  if (content == nil) return NO;
  if (self.host.superview != content) {
    [self.host removeFromSuperview];
    self.host.frame = content.bounds;
    [content addSubview:self.host positioned:NSWindowAbove relativeTo:nil];
    [self relayout];
  } else if (content.subviews.lastObject != self.host) {
    [content addSubview:self.host positioned:NSWindowAbove relativeTo:nil];
  }
  return YES;
}

- (void)relayout {
  const NSSize size = self.host.bounds.size;
  if (size.width < 1 || size.height < 1) return;
  self.scale = std::min(size.width / KPUIDesignWidth, size.height / KPUIDesignHeight);
  self.stage = CGSizeMake(size.width / self.scale, size.height / self.scale);
  self.scrim.frame = self.host.bounds;
  self.scrim.scale = self.scale;
  for (KPScreen *screen in self.stack) {
    screen.frame = self.host.bounds;
    screen.scale = self.scale;
    [screen relayout];
  }
  [self layoutToasts:NO];
}

- (void)showHost {
  self.host.hidden = NO;
  if (self.active) {
    NSWindow *game = self.host.window;
    // The keyboard comes to the screens: arrows, Return and Escape go to the focus, not the game. A
    // hosted screen (the Mii browser) puts its own view first instead.
    if (!self.top.forwardsPads && game.firstResponder != self.host) [game makeFirstResponder:self.host];
    if (!KPUIBackgroundAutomation() && !game.isKeyWindow && NSApp.active) [game makeKeyAndOrderFront:nil];
    [self installKeyMonitor];
    [self startTicker];
  }
}

- (void)present:(KPScreen *)screen {
  if (![self attach]) return;
  const BOOL opening = !self.active;
  if (opening) self.previousResponder = self.host.window.firstResponder;
  KartPadUIPrepareSounds();
  [self.top willDisappear];
  self.top.hidden = YES;
  screen.frame = self.host.bounds;
  screen.scale = self.scale;
  [self.stack addObject:screen];
  [self anchorPointer];
  self.movedTo = nil;
  [self.host addSubview:screen positioned:NSWindowAbove relativeTo:self.scrim];
  [screen relayout];
  [screen willAppear];
  [self showHost];
  [self dismissStaleToasts];
  [self layoutToasts:NO];
  KPUIButton *focus = screen.focus.enabled && !screen.focus.hidden ? screen.focus : [screen initialFocus];
  screen.focus = nil;
  [self focus:focus sound:NO];
  if (opening) {
    KPUIPlay(KPUISound::Open);
    [self fadeScrim:!screen.solid];
    AppendSessionLine(@"overlay=opened");
  }
  [self animateIn:screen];
  [screen didAppear];
}

- (void)fadeScrim:(BOOL)visible {
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = KPUIReduceMotion() ? 0.12 : 0.2;
    self.scrim.animator.alphaValue = visible ? 1 : 0;
  }];
}

- (void)animateIn:(KPScreen *)screen {
  screen.alphaValue = 0;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = KPUIReduceMotion() ? 0.12 : 0.18;
    screen.animator.alphaValue = 1;
  }];
}

- (void)removeScreen:(KPScreen *)screen {
  [screen willDisappear];
  [self.stack removeObject:screen];
  [screen removeFromSuperview];
}

- (void)pop {
  KPScreen *leaving = self.top;
  if (leaving == nil) return;
  if (self.stack.count == 1) {
    [self closeAll];
    return;
  }
  [self removeScreen:leaving];
  KPUIPlay(KPUISound::Close);
  [self anchorPointer];
  self.movedTo = nil;
  KPScreen *back = self.top;
  back.hidden = NO;
  [back relayout];
  [back willAppear];
  [self showHost];
  [self dismissStaleToasts];
  [self layoutToasts:NO];
  [self fadeScrim:!back.solid];
  [self focus:back.focus.enabled && !back.focus.hidden ? back.focus : [back initialFocus] sound:NO];
  [self animateIn:back];
  [back didAppear];
}

- (void)replaceTop:(KPScreen *)screen {
  KPScreen *leaving = self.top;
  if (leaving) [self removeScreen:leaving];
  [self present:screen];
}

// Back to the game: every screen closes, the keyboard returns to the game and the game carries on
// once the buttons that closed it are let go.
- (void)closeAll {
  if (!self.active) return;
  NSArray<KPScreen *> *closing = self.stack.copy;
  for (KPScreen *screen in closing.reverseObjectEnumerator) [screen willDisappear];
  [self.stack removeAllObjects];
  KPUIPlay(KPUISound::Close);
  AppendSessionLine(@"overlay=closed");
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = KPUIReduceMotion() ? 0.1 : 0.16;
    for (KPScreen *screen in closing) screen.animator.alphaValue = 0;
    self.scrim.animator.alphaValue = 0;
  } completionHandler:^{
    for (KPScreen *screen in closing) [screen removeFromSuperview];
    if (!self.active && self.toasts.count == 0) self.host.hidden = YES;
  }];
  NSWindow *game = self.host.window;
  if (game.firstResponder == self.host) {
    NSResponder *previous = self.previousResponder;
    [game makeFirstResponder:previous.nextResponder || [previous isKindOfClass:NSView.class] ? previous : game.contentView];
  }
  [self removeKeyMonitor];
  [self.ticker invalidate];
  self.ticker = nil;
  [self dismissStaleToasts];
  [self layoutToasts:YES];
}

- (void)focus:(KPUIButton *)button sound:(BOOL)sound {
  KPScreen *screen = self.top;
  if (button == screen.focus) return;
  screen.focus.focused = NO;
  screen.focus.pressed = NO;
  screen.focus = button;
  button.focused = YES;
  if (sound && button) KPUIPlay(KPUISound::Hover);
}

- (void)move:(int)dx dy:(int)dy {
  KPScreen *screen = self.top;
  NSArray<KPUIButton *> *controls = [screen focusables];
  KPUIButton *focus = screen.focus;
  if (focus == nil || ![controls containsObject:focus]) {
    [self focus:[screen initialFocus] sound:YES];
    return;
  }
  if (dx && focus.adjust && focus.adjust(dx)) return;
  // Straight back the way it came returns to where it was. A run of moves up or down keeps to the
  // column it started in (sideways, to its row), so passing a wide control doesn't change columns.
  const BOOL continuing = focus == self.movedTo;
  KPUIButton *next = nil;
  if (continuing && dx == -self.movedDx && dy == -self.movedDy && [controls containsObject:self.movedFrom]) next = self.movedFrom;
  const NSRect here = [focus convertRect:focus.bounds toView:nil];
  const CGFloat column = continuing && (dx != 0) == (self.movedDx != 0) ? self.movedColumn : dx ? NSMidY(here) : NSMidX(here);
  if (next == nil) next = KPUINearest(controls, focus, dx, dy, column);
  if (next == nil) return;
  self.movedFrom = focus;
  self.movedTo = next;
  self.movedDx = dx;
  self.movedDy = dy;
  self.movedColumn = column;
  [self focus:next sound:YES];
}

- (void)padPress:(KartPadMiiPadButton)button down:(BOOL)down {
  KPScreen *screen = self.top;
  if (screen == nil) return;
  KPPadHideCursor();
  [self anchorPointer];
  if (!down) {
    // A acts on release, on what it went down on.
    if (button != KartPadMiiPadConfirm) return;
    KPUIButton *pressed = self.padPressed;
    self.padPressed = nil;
    if (pressed == nil) return;
    pressed.pressed = NO;
    if (pressed == screen.focus) [pressed fire];
    return;
  }
  if ([screen handle:button]) return;
  switch (button) {
    case KartPadMiiPadUp: [self move:0 dy:-1]; break;
    case KartPadMiiPadDown: [self move:0 dy:1]; break;
    case KartPadMiiPadLeft: [self move:-1 dy:0]; break;
    case KartPadMiiPadRight: [self move:1 dy:0]; break;
    case KartPadMiiPadConfirm:
      if (screen.focus.enabled && screen.focus.activate) {
        screen.focus.pressed = YES;
        self.padPressed = screen.focus;
      } else if (screen.focus == nil) {
        [self focus:[screen initialFocus] sound:YES];
      }
      break;
    case KartPadMiiPadBack: [screen back]; break;
    case KartPadMiiPadStart: [self closeAll]; break;
    default: break;
  }
}

#pragma mark Keyboard

// While a screen is up, the keyboard drives it: arrows move, Return / Space / Enter press, Escape and
// Delete go back, Tab and Shift-Tab change page. Command shortcuts still reach the menus.
- (BOOL)handleKey:(NSEvent *)event {
  const NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;
  if (event.window != self.host.window) return NO;
  self.keyboardInput = YES;
  [self anchorPointer];
  if ([self.top takesKey:event]) return YES;
  // A hosted screen with its own keyboard handling (the Mii browser) gets the keys as they are.
  if (self.top.forwardsPads) return NO;
  const unsigned short key = event.keyCode;
  const BOOL down = event.type == NSEventTypeKeyDown;
  KartPadMiiPadButton button = KartPadMiiPadButtonCount;
  switch (key) {
    case kVK_UpArrow: button = KartPadMiiPadUp; break;
    case kVK_DownArrow: button = KartPadMiiPadDown; break;
    case kVK_LeftArrow: button = KartPadMiiPadLeft; break;
    case kVK_RightArrow: button = KartPadMiiPadRight; break;
    case kVK_Return: case kVK_ANSI_KeypadEnter: case kVK_Space: button = KartPadMiiPadConfirm; break;
    case kVK_Escape: case kVK_Delete: button = KartPadMiiPadBack; break;
    case kVK_Tab: button = (modifiers & NSEventModifierFlagShift) ? KartPadMiiPadPreviousTab : KartPadMiiPadNextTab; break;
    default: break;
  }
  if (button == KartPadMiiPadButtonCount) return YES;  // other keys do nothing here (and don't beep)
  if (!down) {
    if (button == KartPadMiiPadConfirm) {
      KPUIButton *pressed = self.keyPressed;
      self.keyPressed = nil;
      pressed.pressed = NO;
      if (pressed && pressed == self.top.focus) [pressed fire];
    } else if (button == KartPadMiiPadBack && self.backKey == key) {
      self.backKey = -1;
      [self padPress:KartPadMiiPadBack down:YES];
    }
    return YES;
  }
  if (button == KartPadMiiPadConfirm) {
    if (event.isARepeat) return YES;
    KPScreen *screen = self.top;
    if ([screen handle:button]) return YES;
    if (screen.focus.enabled && screen.focus.activate) {
      screen.focus.pressed = YES;
      self.keyPressed = screen.focus;
    }
    return YES;
  }
  if (button == KartPadMiiPadBack) {
    if (!event.isARepeat) self.backKey = key;
    return YES;
  }
  [self padPress:button down:YES];
  return YES;
}

- (void)installKeyMonitor {
  if (self.keyMonitor) return;
  __weak KPOverlayController *weakSelf = self;
  self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp
      handler:^NSEvent *(NSEvent *event) {
        KPOverlayController *overlay = weakSelf;
        if (overlay == nil || !overlay.active || !KPOverlayWantsKeys()) return event;
        return [overlay handleKey:event] ? nil : event;
      }];
}

- (void)removeKeyMonitor {
  if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
  self.keyMonitor = nil;
}

#pragma mark Ticks and toasts

- (void)startTicker {
  if (self.ticker) return;
  __weak KPOverlayController *weakSelf = self;
  self.ticker = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
    @autoreleasepool { [weakSelf.top tick]; }
  }];
  [NSRunLoop.mainRunLoop addTimer:self.ticker forMode:NSRunLoopCommonModes];
}

// Toasts come in front of the game and any screen, and never take the focus or a click. They make one
// stack, oldest at its start: over the game, down from the top right; over a screen, at the first place
// with room for the whole stack where no control is: the screen's own places (toastSpots), the top
// centre, the bottom centre above the hints (stacking up), then down the right below the header. With
// room nowhere, the stack starts at the first free place and runs over the controls. A toast raised on
// a screen goes when that screen goes (or, for Settings, changes category).
static constexpr CGFloat KPToastWidth = 420, KPToastHeight = 92;
- (void)toast:(NSString *)heading detail:(NSString *)detail stripe:(unsigned)stripe
         icon:(void (^)(CGContextRef c, CGRect r))icon image:(NSImage *)image {
  [self toast:heading detail:detail stripe:stripe icon:icon image:image seconds:3.4];
}
- (void)toast:(NSString *)heading detail:(NSString *)detail stripe:(unsigned)stripe
         icon:(void (^)(CGContextRef c, CGRect r))icon image:(NSImage *)image seconds:(NSTimeInterval)seconds {
  KPToastView *toast = [[KPToastView alloc] initWithFrame:NSZeroRect];
  toast.heading = heading;
  toast.detail = detail;
  toast.stripe = stripe;
  toast.icon = icon;
  toast.image = image;
  toast.owner = self.top;
  toast.owned = self.top != nil;
  [self show:toast seconds:seconds];
}
- (void)toastController:(NSString *)heading detail:(NSString *)detail player:(int)player image:(NSImage *)image
                   icon:(void (^)(CGContextRef c, CGRect r))icon art:(void (^)(CGContextRef c, CGRect r))art {
  KPToastView *toast = [[KPToastView alloc] initWithFrame:NSZeroRect];
  toast.heading = heading;
  toast.detail = detail;
  toast.player = player;
  toast.icon = icon;
  toast.image = image;
  toast.art = art;
  [self show:toast seconds:3.4];
}
- (void)show:(KPToastView *)toast seconds:(NSTimeInterval)seconds {
  if (![self attach]) return;
  toast.seconds = seconds;
  // The same toast again (a row pressed over and over, a controller reconnecting) renews the one
  // already up rather than stacking a copy.
  for (KPToastView *shown in self.toasts) {
    if (shown.leaving || shown.player != toast.player || shown.owner != toast.owner || shown.owned != toast.owned ||
        ![shown.heading ?: @"" isEqualToString:toast.heading ?: @""] || ![shown.detail ?: @"" isEqualToString:toast.detail ?: @""])
      continue;
    shown.stripe = toast.stripe;
    shown.icon = toast.icon;
    shown.image = toast.image;
    shown.art = toast.art;
    shown.seconds = seconds;
    shown.needsDisplay = YES;
    if (shown.started) [self time:shown];
    return;
  }
  [self.toasts addObject:toast];
  while (self.toasts.count > 4) {
    [self.toasts.firstObject removeFromSuperview];
    [self.toasts removeObjectAtIndex:0];
  }
  self.host.hidden = NO;
  toast.hidden = YES;
  [self.host addSubview:toast positioned:NSWindowAbove relativeTo:nil];
  [self layoutToasts:YES];
}
// A toast's first showing: it slides in and its time starts.
- (void)start:(KPToastView *)toast {
  toast.started = YES;
  toast.hidden = NO;
  toast.alphaValue = 0;
  const CGFloat slide = KPUIReduceMotion() ? 0 : 40 * self.scale;
  NSRect end = toast.frame;
  [toast setFrameOrigin:NSMakePoint(end.origin.x + slide, end.origin.y)];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = 0.28;
    context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :1.3 :0.4 :1];
    toast.animator.alphaValue = 1;
    toast.animator.frame = end;
  }];
  [self time:toast];
}
// Starts (or restarts) a showing toast's time.
- (void)time:(KPToastView *)toast {
  const NSUInteger showing = ++toast.showing;
  __weak KPToastView *weakToast = toast;
  __weak KPOverlayController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(toast.seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (KPToastView *gone = weakToast; gone && gone.showing == showing) [weakSelf dismissToast:gone];
  });
}
- (void)dismissToast:(KPToastView *)toast {
  if (toast.leaving || ![self.toasts containsObject:toast]) return;
  toast.leaving = YES;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = toast.started ? 0.25 : 0;
    toast.animator.alphaValue = 0;
  } completionHandler:^{
    [toast removeFromSuperview];
    [self.toasts removeObject:toast];
    [self layoutToasts:YES];
    if (!self.active && self.toasts.count == 0) self.host.hidden = YES;
  }];
}
// Toasts raised on a screen that has gone, or isn't on top any more, or on screen itself.
- (void)dismissToastsFrom:(KPScreen *)screen {
  for (KPToastView *toast in self.toasts.copy)
    if (toast.owned && (toast.owner == nil || toast.owner == screen || toast.owner != self.top)) [self dismissToast:toast];
}
- (void)dismissStaleToasts { [self dismissToastsFrom:nil]; }

// The controls on a screen, in design points, for toasts to keep off.
static void KPCollectControls(NSView *view, NSView *screen, CGFloat scale, std::vector<CGRect> &out) {
  for (NSView *child in view.subviews) {
    if (child.hidden) continue;
    if ([child isKindOfClass:KPUIButton.class]) {
      // The face, without the margin its focus glow takes, and a little room round it.
      const NSRect r = [child convertRect:child.bounds toView:screen];
      const CGFloat margin = ((KPUIButton *)child).margin - 3;
      out.push_back(CGRectInset(CGRectMake(r.origin.x / scale, r.origin.y / scale, r.size.width / scale, r.size.height / scale),
                                margin, margin));
    }
    KPCollectControls(child, screen, scale, out);
  }
}

- (void)layoutToasts:(BOOL)animated {
  const CGFloat s = self.scale, width = KPToastWidth, height = KPToastHeight;
  KPScreen *screen = self.top;
  // Where a stack can start, and which way it grows (1 down, -1 up).
  std::vector<std::pair<CGPoint, int>> starts;
  std::vector<CGRect> controls;
  if (screen == nil) {
    starts.push_back({CGPointMake(self.stage.width - width - 18, 18), 1});
  } else {
    const CGRect safe = CGRectMake(std::round((self.stage.width - KPUIDesignWidth) / 2),
                                   std::round((self.stage.height - KPUIDesignHeight) / 2), KPUIDesignWidth, KPUIDesignHeight);
    for (NSValue *spot in screen.toastSpots)
      starts.push_back({spot.pointValue, spot.pointValue.y + height / 2 > CGRectGetMidY(safe) ? -1 : 1});
    const CGFloat mid = std::round(CGRectGetMidX(safe) - width / 2);
    starts.push_back({CGPointMake(mid, safe.origin.y + 6), 1});
    starts.push_back({CGPointMake(mid, safe.origin.y + 588), -1});
    starts.push_back({CGPointMake(CGRectGetMaxX(safe) - width - 18, safe.origin.y + 112), 1});
    KPCollectControls(screen, screen, s, controls);
  }
  // The card a toast draws, inside its frame (KPToastView), is what mustn't cover a control.
  auto card = [&](CGPoint p) { return CGRectMake(p.x + 6, p.y + 4, width - 12, height - 12); };
  auto place = [&](const std::pair<CGPoint, int> &start, size_t i) {
    return CGPointMake(start.first.x, start.first.y + start.second * (CGFloat)i * (height - 4));
  };
  auto fits = [&](const std::pair<CGPoint, int> &start, size_t count) {
    for (size_t i = 0; i < count; ++i) {
      const CGRect r = card(place(start, i));
      if (r.origin.y < 0 || CGRectGetMaxY(r) > self.stage.height) return false;
      for (const CGRect &control : controls)
        if (CGRectIntersectsRect(r, control)) return false;
    }
    return true;
  };
  NSMutableArray<KPToastView *> *stack = [NSMutableArray array];
  for (KPToastView *toast in self.toasts)
    if (!toast.leaving) [stack addObject:toast];
  if (stack.count == 0 || starts.empty()) return;
  const std::pair<CGPoint, int> *start = nullptr;
  for (const auto &candidate : starts)
    if (fits(candidate, stack.count)) {
      start = &candidate;
      break;
    }
  for (const auto &candidate : starts)
    if (!start && fits(candidate, 1)) start = &candidate;
  if (!start) start = &starts.front();
  for (NSUInteger i = 0; i < stack.count; ++i) {
    KPToastView *toast = stack[i];
    const CGPoint at = place(*start, i);
    const NSRect frame = NSMakeRect(std::round(at.x * s), std::round(at.y * s), std::round(width * s), std::round(height * s));
    toast.scale = s;
    if (!toast.started) {
      toast.frame = frame;
      [self start:toast];
    } else if (animated) {
      toast.animator.frame = frame;
    } else {
      toast.frame = frame;
    }
  }
}

@end

#pragma mark Dialogs

// A Wii-style question over whatever is showing: a card with a heading, a message and two or three
// big buttons. B picks the last (cancel) choice.
@interface KPDialogScreen : KPScreen
@property(nonatomic, copy) NSString *heading, *message;
@property(nonatomic, copy) NSArray<NSString *> *choices;
@property(nonatomic) NSInteger primary, destructive;
@property(nonatomic) BOOL warning;  // the message is a warning, drawn in red
@property(nonatomic, copy) void (^done)(NSInteger choice);
@end

@implementation KPDialogScreen
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _primary = 0;
    _destructive = -1;
  }
  return self;
}
// As tall as the message needs, centred.
- (CGRect)card {
  const CGRect s = self.safe;
  const CGFloat text = std::ceil([self.message boundingRectWithSize:NSMakeSize(680, 400) options:NSStringDrawingUsesLineFragmentOrigin
                                                         attributes:@{NSFontAttributeName: KPStyleFont(21, NSFontWeightRegular)}].size.height);
  const CGFloat height = std::min<CGFloat>(560, 92 + text + 40 + 104);
  return CGRectMake(s.origin.x + 260, std::round(s.origin.y + (720 - height) / 2), 760, height);
}
- (void)build {
  for (NSInteger i = 0; i < (NSInteger)self.choices.count; ++i) {
    __weak KPDialogScreen *weakSelf = self;
    KPUIButton *button = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPDialogScreen *dialog = weakSelf;
      const BOOL primary = i == dialog.primary;
      KPButtonFace(c, r, primary ? KPStyle::Primary : KPStyle::Plain, NO, state.enabled, state.pressed, state.focused);
      const unsigned ink = primary ? 0xffffff : i == dialog.destructive ? KPP->danger : KPP->text;
      KPTextWeight(dialog.choices[i], CGRectMake(r.origin.x, CGRectGetMidY(r) - 16, r.size.width, 32), 23, ink,
                   NSFontWeightSemibold);
    } action:^{
      KPDialogScreen *dialog = weakSelf;
      void (^done)(NSInteger) = dialog.done;
      [KPOverlay() pop];
      if (done) done(i);
    }];
    button.tag2 = i;
    button.label = self.choices[i];
    button.sound = i == (NSInteger)self.choices.count - 1 ? KPUISound::Close : KPUISound::Confirm;
  }
}
- (void)layoutDesign {
  const CGRect card = self.card;
  const NSInteger count = self.choices.count;
  const CGFloat gap = 20, width = (card.size.width - 64 - gap * (count - 1)) / count;
  for (NSView *view in self.subviews) {
    if (![view isKindOfClass:KPUIButton.class]) continue;
    KPUIButton *button = (KPUIButton *)view;
    [self place:button at:CGRectMake(card.origin.x + 32 + button.tag2 * (width + gap), CGRectGetMaxY(card) - 104, width, 72)];
  }
}
- (KPUIButton *)initialFocus {
  for (KPUIButton *button in self.focusables)
    if (button.tag2 == self.primary) return button;
  return [super initialFocus];
}
- (void)willAppear { KPUIPlay(KPUISound::Dialog); }
- (void)back {
  void (^done)(NSInteger) = self.done;
  const NSInteger cancel = (NSInteger)self.choices.count - 1;
  [KPOverlay() pop];
  if (done) done(cancel);
}
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  KPFill(c, CGRectMake(0, 0, size.width, size.height), 0x000000, 0, 0.35);
  const CGRect card = self.card;
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 10), 30, [NSColor colorWithWhite:0 alpha:0.35].CGColor);
  KPFill(c, card, KPP->panel, 28);
  CGContextRestoreGState(c);
  KPStroke(c, card, KPP->panelStroke, 1.5, 28);
  KPTextWeight(self.heading, CGRectMake(card.origin.x + 40, card.origin.y + 30, card.size.width - 80, 44), 31, KPP->text,
               NSFontWeightBold, NSTextAlignmentLeft);
  KPTextWeight(self.message, CGRectMake(card.origin.x + 40, card.origin.y + 92, card.size.width - 80, card.size.height - 92 - 104), 21,
               self.warning ? KPP->danger : KPP->secondaryText, self.warning ? NSFontWeightMedium : NSFontWeightRegular,
               NSTextAlignmentLeft);
}
@end

// Asks over the current screen (or over the game, opening the overlay).
static void KPAskShowing(NSString *heading, NSString *message, BOOL warning, NSArray<NSString *> *choices,
                         NSInteger primary, NSInteger destructive, void (^done)(NSInteger choice)) {
  KPDialogScreen *dialog = [[KPDialogScreen alloc] initWithFrame:NSZeroRect];
  dialog.heading = heading;
  dialog.message = message;
  dialog.warning = warning;
  dialog.choices = choices;
  dialog.primary = primary;
  dialog.destructive = destructive;
  dialog.done = done;
  dialog.solid = NO;
  [KPOverlay() present:dialog];
}
static void KPAsk(NSString *heading, NSString *message, NSArray<NSString *> *choices, NSInteger primary,
                  NSInteger destructive, void (^done)(NSInteger choice)) {
  KPAskShowing(heading, message, NO, choices, primary, destructive, done);
}
// Like KPAsk, with the message in red: for a choice that loses something.
static void KPAskWarning(NSString *heading, NSString *warning, NSArray<NSString *> *choices, NSInteger primary,
                         NSInteger destructive, void (^done)(NSInteger choice)) {
  KPAskShowing(heading, warning, YES, choices, primary, destructive, done);
}

#pragma mark Menus

// A short Wii-style menu over the current screen: a card with a heading and a column of big
// choices, each with an icon. A picks, B closes it.
struct KPMenuItem {
  NSString *__strong title;
  NSString *__strong detail;
  int glyph;  // a KPUIGlyph, or -1
  BOOL enabled;
  void (^__strong run)(void);
};

@interface KPMenuScreen : KPScreen
@property(nonatomic, copy) NSString *heading, *message;
// The choice in effect, focused first and marked with chosenGlyph (KPUIGlyph::Check, as glyphs are
// declared after this file); -1 for none.
@property(nonatomic) NSInteger chosen;
@property(nonatomic) int chosenGlyph;
- (void)add:(NSString *)title detail:(NSString *)detail glyph:(int)glyph enabled:(BOOL)enabled run:(void (^)(void))run;
@end

static void KPDrawGlyphIndex(CGContextRef c, int glyph, CGRect rect, unsigned ink);  // KartPadUIGlyphs.inc.mm

@implementation KPMenuScreen {
  std::vector<KPMenuItem> _items;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) _chosen = _chosenGlyph = -1;
  return self;
}
- (void)add:(NSString *)title detail:(NSString *)detail glyph:(int)glyph enabled:(BOOL)enabled run:(void (^)(void))run {
  _items.push_back({title, detail, glyph, enabled, [run copy]});
}
- (CGRect)card {
  const CGRect s = self.safe;
  const CGFloat rowHeight = 76, height = 96 + (self.message.length ? 40 : 0) + rowHeight * _items.size() + 18;
  return CGRectMake(s.origin.x + 340, std::round(s.origin.y + (720 - height) / 2), 600, height);
}
- (void)build {
  __weak KPMenuScreen *weakSelf = self;
  for (size_t i = 0; i < _items.size(); ++i) {
    KPUIButton *button = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPMenuScreen *menu = weakSelf;
      if (menu == nil || i >= menu->_items.size()) return;
      const KPMenuItem &item = menu->_items[i];
      KPButtonFace(c, r, KPStyle::Plain, NO, state.enabled, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0, x = item.glyph >= 0 ? r.origin.x + 66 : r.origin.x + 24;
      if (item.glyph >= 0)
        KPDrawGlyphIndex(c, item.glyph, CGRectMake(r.origin.x + 20, CGRectGetMidY(r) - 17 + dy, 32, 32), KPP->accentBottom);
      if (item.detail.length) {
        KPTextWeight(item.title, CGRectMake(x, r.origin.y + 9 + dy, r.size.width - x + r.origin.x - 16, 28), 21, KPP->text,
                     NSFontWeightSemibold, NSTextAlignmentLeft);
        KPTextWeight(item.detail, CGRectMake(x, r.origin.y + 36 + dy, r.size.width - x + r.origin.x - 16, 22), 15,
                     KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
      } else {
        KPTextWeight(item.title, CGRectMake(x, CGRectGetMidY(r) - 15 + dy, r.size.width - x + r.origin.x - 16, 30), 21,
                     KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
      }
      if ((NSInteger)i == menu.chosen && menu.chosenGlyph >= 0)
        KPDrawGlyphIndex(c, menu.chosenGlyph, CGRectMake(CGRectGetMaxX(r) - 50, CGRectGetMidY(r) - 15 + dy, 30, 30),
                         KPP->accentBottom);
    } action:^{
      KPMenuScreen *menu = weakSelf;
      if (menu == nil || i >= menu->_items.size()) return;
      void (^run)(void) = menu->_items[i].run;
      [KPOverlay() pop];
      if (run) run();
    }];
    button.tag2 = (NSInteger)i;
    button.enabled = _items[i].enabled;
    button.label = _items[i].title;
    button.sound = KPUISound::Confirm;
  }
}
- (KPUIButton *)initialFocus {
  for (KPUIButton *button in self.focusables)
    if (button.tag2 == self.chosen && button.enabled) return button;
  return [super initialFocus];
}
- (void)layoutDesign {
  const CGRect card = self.card;
  const CGFloat top = card.origin.y + 96 + (self.message.length ? 40 : 0);
  for (NSView *view in self.subviews)
    if ([view isKindOfClass:KPUIButton.class]) {
      KPUIButton *button = (KPUIButton *)view;
      [self place:button at:CGRectMake(card.origin.x + 28, top + button.tag2 * 76, card.size.width - 56, 66)];
    }
}
- (void)willAppear { KPUIPlay(KPUISound::Dialog); }
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  KPFill(c, CGRectMake(0, 0, size.width, size.height), 0x000000, 0, 0.35);
  const CGRect card = self.card;
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 10), 30, [NSColor colorWithWhite:0 alpha:0.35].CGColor);
  KPFill(c, card, KPP->panel, 28);
  CGContextRestoreGState(c);
  KPStroke(c, card, KPP->panelStroke, 1.5, 28);
  KPTextWeight(self.heading, CGRectMake(card.origin.x + 34, card.origin.y + 28, card.size.width - 68, 44), 29, KPP->text,
               NSFontWeightBold, NSTextAlignmentLeft);
  if (self.message.length)
    KPTextWeight(self.message, CGRectMake(card.origin.x + 34, card.origin.y + 80, card.size.width - 68, 50), 18,
                 KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
}
@end
