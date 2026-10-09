// The Miis window: one place on Mac to create, edit, duplicate, import, export and remove Miis, and
// to rename, relink and delete licenses. The screen itself is shared with iPhone and iPad
// (KartPadMiiBrowser.inc.mm); this file keeps it above the game. The Player menu and Settings open
// it, and the Mii editor opens above it.

static NSWindow *KPGameWindow() {
  // The SDL game window has no window controller; the Mii editor has one.
  for (NSWindow *window in NSApp.windows) {
    if (![window isKindOfClass:NSPanel.class] && window.visible &&
        window.windowController == nil) {
      return window;
    }
  }
  return nil;
}

// Exclusive SDL windows sit above the menu-bar level. A normal panel would open
// behind the game even though the menu item or hotkey was received.
static NSInteger KPAuxiliaryWindowLevel() {
  NSWindow *game = KPGameWindow();
  return std::max<NSInteger>(NSFloatingWindowLevel, game != nil ? game.level + 1 : 0);
}

static void KPCenterOnGameScreen(NSWindow *window) {
  NSScreen *screen = KPGameWindow().screen ?: NSScreen.mainScreen;
  if (screen == nil) return;
  NSRect available = screen.visibleFrame;
  NSRect frame = window.frame;
  frame.origin = NSMakePoint(NSMidX(available) - frame.size.width / 2,
                             NSMidY(available) - frame.size.height / 2);
  [window setFrame:frame display:NO];
}

@interface KPMiisWindow : NSObject <NSWindowDelegate>
// The shell controller, which owns quitting.
@property(nonatomic, weak) id owner;
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSViewController<KartPadMiiBrowser> *browser;
- (void)show;
- (void)createMii:(id)sender;
- (void)editSlot:(NSUInteger)slot;
- (void)importMii:(id)sender;
@end

@implementation KPMiisWindow

- (void)build {
  self.browser = (NSViewController<KartPadMiiBrowser> *)KartPadMakeMiiBrowser();
  self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 820, 560)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  self.panel.title = @"Miis";
  self.panel.releasedWhenClosed = NO;
  self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.panel.hidesOnDeactivate = YES;
  self.panel.delegate = self;
  self.panel.contentViewController = self.browser;
  self.panel.contentMinSize = NSMakeSize(640, 460);
  [self.panel setContentSize:NSMakeSize(820, 560)];
  self.panel.initialFirstResponder = self.browser.view;
  __weak KPMiisWindow *weakSelf = self;
  self.browser.done = ^{ [weakSelf.panel performClose:nil]; };
  self.browser.quit = ^{ [NSApp sendAction:@selector(quitKartPad:) to:weakSelf.owner from:nil]; };
}

- (void)show {
  if (self.panel == nil) {
    [self build];
    KPCenterOnGameScreen(self.panel);
  }
  if (!self.panel.visible) [self.browser willShow];
  [self.browser reload];
  self.panel.level = KPAuxiliaryWindowLevel();
  [NSApp activateIgnoringOtherApps:YES];
  [self.panel makeKeyAndOrderFront:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  // The editor closes after saving; show the pending state when focus returns.
  [self.browser reload];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  [self.browser willClose];
}

- (void)createMii:(id)sender {
  (void)sender;
  [self.browser createMii];
}

- (void)editSlot:(NSUInteger)slot {
  [self.browser editSlot:slot];
}

- (void)importMii:(id)sender {
  (void)sender;
  [self.browser importMii];
}

@end
