// Miis inside the game window: the shared Miis screen (KartPadMiiBrowser.inc.mm), hosted as one of
// KartPad's screens and scaled with the window like the others. It keeps its own controller handling
// (KartPadMiiGamepad.inc.mm), which follows it into the game window; B (Done) comes back to HOME.
// Included by KartPadMacShell.mm after the overlay.

@interface KPMiisScreen : KPScreen
@property(nonatomic, strong) NSViewController<KartPadMiiBrowser> *browser;
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
  [self addSubview:self.browser.view];
}
// The browser lays itself out in points; giving it scaled bounds makes it lay out at the design
// size and draw at the window's.
- (void)layoutDesign {
  NSView *view = self.browser.view;
  view.frame = self.bounds;
  const CGFloat scale = std::max<CGFloat>(self.scale, 0.5);
  [view setBoundsSize:NSMakeSize(self.bounds.size.width / scale, self.bounds.size.height / scale)];
  view.needsLayout = YES;
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
  // An editor that closed (saved) leaves changes to show.
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
