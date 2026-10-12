// What KartPadAppKitShim.h declares. Included once, by KartPadScreens.mm, before the renaming
// header (KartPadAppKitShimNames.h), so the UIKit methods here keep their own names.

@implementation NSValue (KPAppKitShim)
+ (NSValue *)valueWithPoint:(NSPoint)point { return [NSValue valueWithCGPoint:point]; }
+ (NSValue *)valueWithRect:(NSRect)rect { return [NSValue valueWithCGRect:rect]; }
+ (NSValue *)valueWithSize:(NSSize)size { return [NSValue valueWithCGSize:size]; }
- (NSPoint)pointValue { return self.CGPointValue; }
- (NSRect)rectValue { return self.CGRectValue; }
- (NSSize)sizeValue { return self.CGSizeValue; }
@end

@implementation KPShimEvent
+ (NSPoint)mouseLocation { return CGPointZero; }
+ (id)addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(KPShimEvent * (^)(KPShimEvent *event))handler {
  (void)mask;
  (void)handler;
  return [NSObject new];
}
+ (void)removeMonitor:(id)monitor { (void)monitor; }
- (NSEventType)type { return NSEventTypeKeyDown; }
- (NSEventModifierFlags)modifierFlags { return 0; }
- (unsigned short)keyCode { return 0xffff; }
- (BOOL)isARepeat { return NO; }
- (NSPoint)locationInWindow { return CGPointZero; }
- (UIWindow *)window { return nil; }
- (CGFloat)scrollingDeltaX { return 0; }
- (CGFloat)scrollingDeltaY { return 0; }
- (BOOL)hasPreciseScrollingDeltas { return NO; }
- (NSEventPhase)phase { return NSEventPhaseNone; }
- (NSEventPhase)momentumPhase { return NSEventPhaseNone; }
- (NSString *)characters { return @""; }
- (NSString *)charactersIgnoringModifiers { return @""; }
@end

@implementation KPShimTrackingArea
- (instancetype)initWithRect:(NSRect)rect options:(NSTrackingAreaOptions)options owner:(id)owner userInfo:(NSDictionary *)userInfo {
  (void)rect;
  (void)options;
  (void)owner;
  (void)userInfo;
  return [super init];
}
@end

@implementation KPShimCursor
+ (void)setHiddenUntilMouseMoves:(BOOL)hidden { (void)hidden; }
+ (void)hide {}
+ (void)unhide {}
@end

@implementation KPShimWorkspace
+ (instancetype)sharedWorkspace {
  static KPShimWorkspace *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [KPShimWorkspace new]; });
  return shared;
}
- (BOOL)accessibilityDisplayShouldReduceMotion { return UIAccessibilityIsReduceMotionEnabled(); }
- (BOOL)openURL:(NSURL *)url {
  [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
  return YES;
}
@end

@implementation KPShimApplication
- (BOOL)active { return UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }
- (void)activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
- (NSArray<UIWindow *> *)windows {
  NSMutableArray *all = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class]) [all addObjectsFromArray:((UIWindowScene *)scene).windows];
  return all;
}
- (UIWindow *)keyWindow {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows)
      if (window.isKeyWindow) return window;
  }
  return nil;
}
@end
KPShimApplication *KPShimSharedApplication(void) {
  static KPShimApplication *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [KPShimApplication new]; });
  return shared;
}

@implementation KPShimGraphicsContext
+ (KPShimGraphicsContext *)currentContext {
  static KPShimGraphicsContext *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [KPShimGraphicsContext new]; });
  return shared;
}
+ (void)setCurrentContext:(KPShimGraphicsContext *)context { (void)context; }
- (CGContextRef)CGContext { return UIGraphicsGetCurrentContext(); }
@end

#pragma mark Animation

static NSMutableArray<KPShimAnimationContext *> *KPShimAnimationStack() {
  static NSMutableArray *stack;
  if (stack == nil) stack = [NSMutableArray array];
  return stack;
}

@implementation KPShimAnimationContext {
@public
  NSTimeInterval _longest;  // the longest animation the group started
}
- (instancetype)init {
  if ((self = [super init])) _duration = 0.25;
  return self;
}
+ (KPShimAnimationContext *)currentContext { return KPShimAnimationStack().lastObject; }
+ (void)runAnimationGroup:(void (^)(KPShimAnimationContext *context))changes {
  [self runAnimationGroup:changes completionHandler:nil];
}
+ (void)runAnimationGroup:(void (^)(KPShimAnimationContext *context))changes completionHandler:(void (^)(void))completion {
  KPShimAnimationContext *context = [KPShimAnimationContext new];
  [KPShimAnimationStack() addObject:context];
  if (changes) changes(context);
  [KPShimAnimationStack() removeObject:context];
  if (completion == nil) return;
  const NSTimeInterval wait = context->_longest;
  if (wait <= 0) {
    dispatch_async(dispatch_get_main_queue(), completion);
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), completion);
}
@end

// A view's animator: each property set through it animates over the current group's duration.
@interface KPShimAnimator : NSProxy
@property(nonatomic, strong) UIView *view;
@end
@implementation KPShimAnimator
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.view methodSignatureForSelector:selector]; }
- (BOOL)respondsToSelector:(SEL)selector { return [self.view respondsToSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation {
  UIView *view = self.view;
  [invocation retainArguments];
  KPShimAnimationContext *context = KPShimAnimationContext.currentContext;
  const NSTimeInterval duration = context ? context.duration : 0.25;
  if (duration <= 0 || UIAccessibilityIsReduceMotionEnabled() && duration < 0.05) {
    [invocation invokeWithTarget:view];
    return;
  }
  if (context) context->_longest = std::max(context->_longest, duration);
  id<UITimingCurveProvider> timing = nil;
  if (CAMediaTimingFunction *function = context.timingFunction) {
    float p1[2], p2[2];
    [function getControlPointAtIndex:1 values:p1];
    [function getControlPointAtIndex:2 values:p2];
    timing = [[UICubicTimingParameters alloc] initWithControlPoint1:CGPointMake(p1[0], p1[1])
                                                     controlPoint2:CGPointMake(p2[0], p2[1])];
  } else {
    timing = [[UICubicTimingParameters alloc] initWithAnimationCurve:UIViewAnimationCurveEaseInOut];
  }
  UIViewPropertyAnimator *run = [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:timing];
  [run addAnimations:^{ [invocation invokeWithTarget:view]; }];
  [run startAnimation];
}
@end

#pragma mark UIKit additions

@implementation UIView (KPAppKitShim)
- (BOOL)kp_needsDisplay { return NO; }
- (void)setKp_needsDisplay:(BOOL)needs {
  if (needs) [self setNeedsDisplay];
}
- (CGFloat)kp_alphaValue { return self.alpha; }
- (void)setKp_alphaValue:(CGFloat)alpha { self.alpha = alpha; }
- (BOOL)kp_wantsLayer { return YES; }
- (void)setKp_wantsLayer:(BOOL)wants { (void)wants; }
- (NSViewLayerContentsRedrawPolicy)kp_layerContentsRedrawPolicy { return 0; }
- (void)setKp_layerContentsRedrawPolicy:(NSViewLayerContentsRedrawPolicy)policy { (void)policy; }
- (instancetype)kp_animator {
  KPShimAnimator *animator = [KPShimAnimator alloc];
  animator.view = self;
  return (id)animator;
}
- (BOOL)kp_isFlipped { return YES; }
- (BOOL)kp_acceptsFirstResponder { return NO; }
- (void)kp_mouseDown:(NSEvent *)event { (void)event; }
- (void)kp_mouseUp:(NSEvent *)event { (void)event; }
- (void)kp_mouseDragged:(NSEvent *)event { (void)event; }
- (void)kp_mouseMoved:(NSEvent *)event { (void)event; }
- (void)kp_mouseEntered:(NSEvent *)event { (void)event; }
- (void)kp_mouseExited:(NSEvent *)event { (void)event; }
- (void)kp_rightMouseDown:(NSEvent *)event { (void)event; }
- (void)kp_scrollWheel:(NSEvent *)event { (void)event; }
- (void)kp_keyDown:(NSEvent *)event { (void)event; }
- (void)kp_updateTrackingAreas {}
- (void)kp_addTrackingArea:(NSTrackingArea *)area { (void)area; }
- (void)kp_removeTrackingArea:(NSTrackingArea *)area { (void)area; }
- (void)kp_viewDidChangeEffectiveAppearance {}
- (void)kp_viewDidMoveToWindow {}
- (UIView *)hitTest:(NSPoint)point {
  return [self hitTest:[self convertPoint:point fromView:self.superview] withEvent:nil];
}
- (NSRect)kp_convertRect:(NSRect)rect toView:(UIView *)view {
  if (view) return [self convertRect:rect toView:view];
  const CGRect r = [self convertRect:rect toView:nil];
  UIWindow *window = self.window;
  if (window == nil) return r;
  return CGRectMake(r.origin.x, window.bounds.size.height - CGRectGetMaxY(r), r.size.width, r.size.height);
}
- (NSRect)kp_convertRect:(NSRect)rect fromView:(UIView *)view {
  if (view) return [self convertRect:rect fromView:view];
  UIWindow *window = self.window;
  const CGRect r = window ? CGRectMake(rect.origin.x, window.bounds.size.height - CGRectGetMaxY(rect), rect.size.width,
                                       rect.size.height)
                          : rect;
  return [self convertRect:r fromView:nil];
}
- (void)kp_setFrameOrigin:(NSPoint)origin {
  CGRect frame = self.frame;
  frame.origin = origin;
  self.frame = frame;
}
- (void)kp_setFrameSize:(NSSize)size {
  CGRect frame = self.frame;
  frame.size = size;
  self.frame = frame;
}
- (NSSize)kp_convertSizeToBacking:(NSSize)size {
  const CGFloat k = self.window ? self.window.screen.scale : UIScreen.mainScreen.scale;
  return CGSizeMake(size.width * k, size.height * k);
}
- (void)addSubview:(UIView *)view positioned:(NSWindowOrderingMode)place relativeTo:(UIView *)other {
  if (other == nil || other.superview != self) {
    if (place == NSWindowBelow) [self insertSubview:view atIndex:0];
    else [self addSubview:view];
    if (place != NSWindowBelow) [self bringSubviewToFront:view];
    return;
  }
  if (place == NSWindowBelow) [self insertSubview:view belowSubview:other];
  else [self insertSubview:view aboveSubview:other];
}
- (BOOL)kp_accessibilityPerformPress { return NO; }
- (BOOL)kp_isAccessibilityEnabled { return YES; }
- (NSAccessibilityRole)kp_accessibilityRole { return nil; }
@end

@implementation UIWindow (KPAppKitShim)
- (BOOL)kp_visible { return !self.hidden; }
- (UIResponder *)firstResponder { return nil; }
- (BOOL)makeFirstResponder:(UIResponder *)responder {
  (void)responder;
  return NO;
}
- (void)makeKeyAndOrderFront:(id)sender { (void)sender; }
- (UIView *)contentView { return self.rootViewController.view; }
@end

@implementation UIImage (KPAppKitShim)
- (void)drawInRect:(NSRect)rect fromRect:(NSRect)from operation:(CGBlendMode)operation fraction:(CGFloat)fraction
    respectFlipped:(BOOL)flipped hints:(NSDictionary *)hints {
  (void)from;
  (void)flipped;
  (void)hints;
  [self drawInRect:rect blendMode:operation alpha:fraction];
}
- (void)drawInRect:(NSRect)rect fromRect:(NSRect)from operation:(CGBlendMode)operation fraction:(CGFloat)fraction {
  (void)from;
  [self drawInRect:rect blendMode:operation alpha:fraction];
}
@end

@implementation NSString (KPAppKitShim)
- (CGRect)boundingRectWithSize:(CGSize)size options:(NSStringDrawingOptions)options
                    attributes:(NSDictionary<NSAttributedStringKey, id> *)attributes {
  return [self boundingRectWithSize:size options:options attributes:attributes context:nil];
}
@end

@implementation NSAttributedString (KPAppKitShim)
- (CGRect)boundingRectWithSize:(CGSize)size options:(NSStringDrawingOptions)options {
  return [self boundingRectWithSize:size options:options context:nil];
}
@end
