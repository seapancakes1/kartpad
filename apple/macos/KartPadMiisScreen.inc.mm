// Miis inside the game window: the shared Miis screen (KartPadMiiBrowser.inc.mm), hosted as one of
// KartPad's screens and scaled with the window like the others. It keeps its own controller handling
// (KartPadMiiGamepad.inc.mm), which follows it into the game window; B (Done) comes back to HOME.
// The browser lays itself out as the other screens do (header, pills); the button hints along the
// bottom come from here, since they follow the controller in hand (KartPadHints.inc.mm).
// Included by KartPadMacShell.mm after the overlay.

// KartPadMiiBrowser.inc.mm (another file): lay out on the screens' 1280×720 design canvas.
@protocol KPMiiBrowserHosting
- (void)setHosted:(BOOL)hosted;
@end

@interface KPMiisScreen : KPScreen
@property(nonatomic, strong) NSViewController<KartPadMiiBrowser> *browser;
@property(nonatomic, strong) KPUIView *hints;
@end

@implementation KPMiisScreen
- (void)build {
  self.solid = YES;
  self.forwardsPads = YES;
  self.title = @"Miis";
  self.browser = (NSViewController<KartPadMiiBrowser> *)KartPadMakeMiiBrowser();
  __weak KPMiisScreen *weakSelf = self;
  self.browser.done = ^{
    if (KPOverlay().top == weakSelf) [KPOverlay() pop];
  };
  self.browser.restart = ^{ KPRestartWithCurtain(@"Applying your Mii changes", @""); };
  if ([self.browser respondsToSelector:@selector(setHosted:)]) [(id<KPMiiBrowserHosting>)self.browser setHosted:YES];
  [self addSubview:self.browser.view];
  // Above the browser; it takes no clicks (KPUIView).
  self.hints = [[KPUIView alloc] initWithFrame:NSZeroRect];
  self.hints.paint = ^(CGContextRef c, CGSize size) {
    KPDrawHints(c, CGRectMake(0, 0, size.width, size.height), {{KartPadMiiPadConfirm, @"Select"}, {KartPadMiiPadBack, @"Back"}}, 16,
                NSTextAlignmentRight);
  };
}
// The browser lays itself out in points; giving it scaled bounds makes it lay out at the design
// size and draw at the window's.
- (void)layoutDesign {
  NSView *view = self.browser.view;
  view.frame = self.bounds;
  const CGFloat scale = std::max<CGFloat>(self.scale, 0.5);
  [view setBoundsSize:NSMakeSize(self.bounds.size.width / scale, self.bounds.size.height / scale)];
  view.needsLayout = YES;
  const CGRect s = self.safe;
  [self place:self.hints at:CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26)];
}
- (NSArray<KPUIButton *> *)focusables { return @[]; }
- (KPUIButton *)initialFocus { return nil; }
- (void)willAppear {
  [self.browser willShow];
  [self.browser reload];
  [self.window makeFirstResponder:self.browser.view];
  KartPadMiiPadShowFocus();
}
- (void)willDisappear { [self.browser willClose]; }
- (void)tick {
  // An editor that closed (saved) leaves changes to show, and the game can write its saves. A
  // reload that finds nothing changed costs well under a millisecond: the manager keeps the
  // replayed queue until a file changes, and the screen redraws only when something did.
  static NSTimeInterval last;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - last < 1) return;
  last = now;
  if (self.window.isKeyWindow) [self.browser reload];
}
// The browser takes the keyboard itself; Escape comes back here.
- (BOOL)takesKey:(NSEvent *)event {
  if (event.keyCode == kVK_Escape) {
    if (event.type == NSEventTypeKeyDown && !event.isARepeat) [self back];
    return YES;
  }
  return NO;
}
- (BOOL)passesKeys { return YES; }
- (void)back { [KPOverlay() pop]; }
@end

static KPScreen *KPMakeMiisScreen() { return [[KPMiisScreen alloc] initWithFrame:NSZeroRect]; }
