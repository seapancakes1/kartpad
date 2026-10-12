// The AppKit words the Mac shell's screens are written in (apple/macos/KartPad*Screen.inc.mm and the
// overlay kit), said in UIKit, so the same files build for iPhone and iPad (KartPadScreens.mm).
// Geometry and colours map one to one. Window coordinates keep AppKit's sense (y up) wherever
// a screen converts to the window, so its direction maths reads the same. Animations run as
// UIView animations. Mouse, keyboard-monitor and pointer calls exist but do nothing: on iOS,
// touches and controllers reach the screens through KartPadScreensTouch.inc.mm and the pad
// reader instead. Include it after every system header; KartPadAppKitShimNames.h then renames
// the AppKit methods that could meet UIKit's own.
#pragma once
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#error "KartPadAppKitShim.h is for iPhone and iPad builds only"
#endif
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark Geometry

typedef CGRect NSRect;
typedef CGPoint NSPoint;
typedef CGSize NSSize;
#define NSZeroRect CGRectZero
#define NSZeroPoint CGPointZero
#define NSZeroSize CGSizeZero
static inline NSRect NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return CGRectMake(x, y, w, h); }
static inline NSPoint NSMakePoint(CGFloat x, CGFloat y) { return CGPointMake(x, y); }
static inline NSSize NSMakeSize(CGFloat w, CGFloat h) { return CGSizeMake(w, h); }
static inline CGFloat NSMinX(NSRect r) { return CGRectGetMinX(r); }
static inline CGFloat NSMaxX(NSRect r) { return CGRectGetMaxX(r); }
static inline CGFloat NSMidX(NSRect r) { return CGRectGetMidX(r); }
static inline CGFloat NSMinY(NSRect r) { return CGRectGetMinY(r); }
static inline CGFloat NSMaxY(NSRect r) { return CGRectGetMaxY(r); }
static inline CGFloat NSMidY(NSRect r) { return CGRectGetMidY(r); }
static inline CGFloat NSWidth(NSRect r) { return r.size.width; }
static inline CGFloat NSHeight(NSRect r) { return r.size.height; }
static inline BOOL NSPointInRect(NSPoint p, NSRect r) { return CGRectContainsPoint(r, p); }
static inline BOOL NSEqualSizes(NSSize a, NSSize b) { return CGSizeEqualToSize(a, b); }
static inline BOOL NSEqualRects(NSRect a, NSRect b) { return CGRectEqualToRect(a, b); }
static inline BOOL NSIsEmptyRect(NSRect r) { return CGRectIsEmpty(r); }
static inline NSRect NSInsetRect(NSRect r, CGFloat dx, CGFloat dy) { return CGRectInset(r, dx, dy); }
static inline NSRect NSOffsetRect(NSRect r, CGFloat dx, CGFloat dy) { return CGRectOffset(r, dx, dy); }
static inline BOOL NSIntersectsRect(NSRect a, NSRect b) { return CGRectIntersectsRect(a, b); }
static inline NSRect NSIntersectionRect(NSRect a, NSRect b) { return CGRectIntersection(a, b); }
static inline NSRect NSUnionRect(NSRect a, NSRect b) { return CGRectUnion(a, b); }

@interface NSValue (KPAppKitShim)
+ (NSValue *)valueWithPoint:(NSPoint)point;
+ (NSValue *)valueWithRect:(NSRect)rect;
+ (NSValue *)valueWithSize:(NSSize)size;
@property(nonatomic, readonly) NSPoint pointValue;
@property(nonatomic, readonly) NSRect rectValue;
@property(nonatomic, readonly) NSSize sizeValue;
@end

#pragma mark Classes

@compatibility_alias NSView UIView;
@compatibility_alias NSImage UIImage;
@compatibility_alias NSColor UIColor;
@compatibility_alias NSFont UIFont;
@compatibility_alias NSResponder UIResponder;
@compatibility_alias NSWindow UIWindow;
@compatibility_alias NSImageView UIImageView;
@compatibility_alias NSTextView UITextView;

typedef NS_ENUM(NSInteger, NSWindowOrderingMode) { NSWindowBelow = -1, NSWindowOut = 0, NSWindowAbove = 1 };
#define NSViewWidthSizable UIViewAutoresizingFlexibleWidth
#define NSViewHeightSizable UIViewAutoresizingFlexibleHeight
#define NSViewLayerContentsRedrawOnSetNeedsDisplay 0
typedef NSInteger NSViewLayerContentsRedrawPolicy;
typedef NSString *NSAccessibilityRole;
typedef NSString *NSAccessibilityNotificationName;
#define NSAccessibilityButtonRole @"AXButton"
#define NSAccessibilityFocusedUIElementChangedNotification @"AXFocusedUIElementChanged"
static inline void NSAccessibilityPostNotification(id element, NSAccessibilityNotificationName name) {
  (void)name;
  UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, element);
}
#define NSCompositingOperationSourceOver kCGBlendModeNormal
#define NSImageHintInterpolation @"NSImageHintInterpolation"
#define NSImageInterpolationHigh 3
typedef NSInteger NSModalResponse;
#define NSModalResponseOK 1
#define NSModalResponseCancel 0

#pragma mark Events (never sent on iOS)

typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
  NSEventModifierFlagShift = 1 << 17,
  NSEventModifierFlagControl = 1 << 18,
  NSEventModifierFlagOption = 1 << 19,
  NSEventModifierFlagCommand = 1 << 20,
  NSEventModifierFlagDeviceIndependentFlagsMask = 0xffff0000UL,
};
typedef NS_ENUM(NSUInteger, NSEventType) { NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11 };
typedef NS_OPTIONS(unsigned long long, NSEventMask) { NSEventMaskKeyDown = 1ULL << 10, NSEventMaskKeyUp = 1ULL << 11 };
typedef NS_OPTIONS(NSUInteger, NSEventPhase) { NSEventPhaseNone = 0, NSEventPhaseBegan = 1 };
enum {
  kVK_Return = 0x24, kVK_Tab = 0x30, kVK_Space = 0x31, kVK_Delete = 0x33, kVK_Escape = 0x35,
  kVK_ANSI_KeypadEnter = 0x4C, kVK_LeftArrow = 0x7B, kVK_RightArrow = 0x7C, kVK_DownArrow = 0x7D, kVK_UpArrow = 0x7E,
};

@interface KPShimEvent : NSObject
+ (NSPoint)mouseLocation;
+ (id)addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(KPShimEvent * (^)(KPShimEvent *event))handler;
+ (void)removeMonitor:(id)monitor;
@property(nonatomic, readonly) NSEventType type;
@property(nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property(nonatomic, readonly) unsigned short keyCode;
@property(nonatomic, readonly) BOOL isARepeat;
@property(nonatomic, readonly) NSPoint locationInWindow;
@property(nonatomic, readonly) UIWindow *window;
@property(nonatomic, readonly) CGFloat scrollingDeltaX, scrollingDeltaY;
@property(nonatomic, readonly) BOOL hasPreciseScrollingDeltas;
@property(nonatomic, readonly) NSEventPhase phase, momentumPhase;
@property(nonatomic, readonly, copy) NSString *characters, *charactersIgnoringModifiers;
@end
@compatibility_alias NSEvent KPShimEvent;

typedef NS_OPTIONS(NSUInteger, NSTrackingAreaOptions) {
  NSTrackingMouseEnteredAndExited = 1, NSTrackingMouseMoved = 2, NSTrackingActiveAlways = 0x80,
  NSTrackingInVisibleRect = 0x200,
};
@interface KPShimTrackingArea : NSObject
- (instancetype)initWithRect:(NSRect)rect options:(NSTrackingAreaOptions)options owner:(id)owner userInfo:(NSDictionary *)userInfo;
@end
@compatibility_alias NSTrackingArea KPShimTrackingArea;

@interface KPShimCursor : NSObject
+ (void)setHiddenUntilMouseMoves:(BOOL)hidden;
+ (void)hide;
+ (void)unhide;
@end
@compatibility_alias NSCursor KPShimCursor;

// Reduce Motion is the one thing the screens ask of the workspace.
@interface KPShimWorkspace : NSObject
+ (instancetype)sharedWorkspace;
@property(nonatomic, readonly) BOOL accessibilityDisplayShouldReduceMotion;
- (BOOL)openURL:(NSURL *)url;
@end
@compatibility_alias NSWorkspace KPShimWorkspace;

@interface KPShimApplication : NSObject
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) UIWindow *keyWindow;
@property(nonatomic, readonly) NSArray<UIWindow *> *windows;
- (void)activateIgnoringOtherApps:(BOOL)flag;
@end
KPShimApplication *KPShimSharedApplication(void);
#define NSApp KPShimSharedApplication()

// Drawing happens inside UIKit's drawRect:, whose context is current.
@interface KPShimGraphicsContext : NSObject
@property(class, nonatomic, strong) KPShimGraphicsContext *currentContext;
@property(nonatomic, readonly) CGContextRef CGContext;
@end
@compatibility_alias NSGraphicsContext KPShimGraphicsContext;

// One animation group: properties set through a view's animator while it runs animate together.
@interface KPShimAnimationContext : NSObject
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic, strong) CAMediaTimingFunction *timingFunction;
@property(nonatomic) BOOL allowsImplicitAnimation;
+ (void)runAnimationGroup:(void (^)(KPShimAnimationContext *context))changes;
+ (void)runAnimationGroup:(void (^)(KPShimAnimationContext *context))changes completionHandler:(void (^)(void))completion;
+ (KPShimAnimationContext *)currentContext;
@end
@compatibility_alias NSAnimationContext KPShimAnimationContext;

#pragma mark UIKit additions in AppKit's words

@interface UIView (KPAppKitShim)
@property(nonatomic, setter=setKp_needsDisplay:) BOOL kp_needsDisplay;
@property(nonatomic) CGFloat kp_alphaValue;
@property(nonatomic) BOOL kp_wantsLayer;
@property(nonatomic) NSViewLayerContentsRedrawPolicy kp_layerContentsRedrawPolicy;
// The view itself, its property changes animated in the current animation group.
- (instancetype)kp_animator;
- (BOOL)kp_isFlipped;
- (BOOL)kp_acceptsFirstResponder;
- (void)kp_mouseDown:(NSEvent *)event;
- (void)kp_mouseUp:(NSEvent *)event;
- (void)kp_mouseDragged:(NSEvent *)event;
- (void)kp_mouseMoved:(NSEvent *)event;
- (void)kp_mouseEntered:(NSEvent *)event;
- (void)kp_mouseExited:(NSEvent *)event;
- (void)kp_rightMouseDown:(NSEvent *)event;
- (void)kp_scrollWheel:(NSEvent *)event;
- (void)kp_keyDown:(NSEvent *)event;
- (void)kp_updateTrackingAreas;
- (void)kp_addTrackingArea:(NSTrackingArea *)area;
- (void)kp_removeTrackingArea:(NSTrackingArea *)area;
- (void)kp_viewDidChangeEffectiveAppearance;
- (void)kp_viewDidMoveToWindow;
// AppKit's hit test: the point is in the superview's coordinates.
- (UIView *)hitTest:(NSPoint)point;
// To nil, a rect in window coordinates with y running up, as AppKit's are.
- (NSRect)kp_convertRect:(NSRect)rect toView:(UIView *)view;
- (NSRect)kp_convertRect:(NSRect)rect fromView:(UIView *)view;
- (void)kp_setFrameOrigin:(NSPoint)origin;
- (void)kp_setFrameSize:(NSSize)size;
- (NSSize)kp_convertSizeToBacking:(NSSize)size;
- (void)addSubview:(UIView *)view positioned:(NSWindowOrderingMode)place relativeTo:(UIView *)other;
- (BOOL)kp_accessibilityPerformPress;
- (BOOL)kp_isAccessibilityEnabled;
- (NSAccessibilityRole)kp_accessibilityRole;
@end

@interface UIWindow (KPAppKitShim)
@property(nonatomic, readonly) BOOL kp_visible;
@property(nonatomic, readonly) UIResponder *firstResponder;
- (BOOL)makeFirstResponder:(UIResponder *)responder;
- (void)makeKeyAndOrderFront:(id)sender;
@property(nonatomic, readonly) UIView *contentView;
@end

@interface UIImage (KPAppKitShim)
- (void)drawInRect:(NSRect)rect fromRect:(NSRect)from operation:(CGBlendMode)operation fraction:(CGFloat)fraction
    respectFlipped:(BOOL)flipped hints:(NSDictionary *)hints;
- (void)drawInRect:(NSRect)rect fromRect:(NSRect)from operation:(CGBlendMode)operation fraction:(CGFloat)fraction;
@end

@interface NSString (KPAppKitShim)
- (CGRect)boundingRectWithSize:(CGSize)size options:(NSStringDrawingOptions)options
                    attributes:(NSDictionary<NSAttributedStringKey, id> *)attributes;
@end

@interface NSAttributedString (KPAppKitShim)
- (CGRect)boundingRectWithSize:(CGSize)size options:(NSStringDrawingOptions)options;
@end
