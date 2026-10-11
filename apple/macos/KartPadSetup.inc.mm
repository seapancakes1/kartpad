// First-run setup (and finding the game again if its files went missing), in KartPad's own style and
// workable with just a controller: welcome, find Mario Kart Wii (KartPad looks in the usual places
// itself, or the player picks the folder), Retro Rewind if it's around, then a "ready" card that
// starts the game. It runs before the game starts, in a KartPad window of its own; controllers are
// read through a short SDL session that is shut down again before the game starts, so the game finds
// them fresh. Included by KartPadMacShell.mm with the screens; KartPadMacShellPrepareGameData runs it.

static void KPStartQA();  // KartPadQA.inc.mm

typedef NS_ENUM(NSInteger, KPSetupStep) { KPSetupWelcome, KPSetupFind, KPSetupSearching, KPSetupFound, KPSetupRetro, KPSetupReady };

@interface KPSetupCandidate : NSObject
@property(nonatomic, copy) NSString *path, *problem;
@property(nonatomic) BOOL retro;
@end
@implementation KPSetupCandidate
@end

// "~/Downloads/KartPad game data", the way Finder people say it.
static NSString *KPFriendlyPath(NSString *path) {
  NSString *home = NSHomeDirectory();
  if ([path hasPrefix:home]) path = [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
  if ([path hasPrefix:@"/Volumes/"]) path = [path substringFromIndex:9];
  return [path stringByReplacingOccurrencesOfString:@"/" withString:@" › "];
}

// Where people keep things: Downloads, Desktop, Documents, home, and connected drives.
static NSArray<NSString *> *KPSetupSearchRoots() {
  NSString *home = NSHomeDirectory();
  NSMutableArray *roots = [NSMutableArray arrayWithArray:@[
    [home stringByAppendingPathComponent:@"Downloads"], [home stringByAppendingPathComponent:@"Desktop"],
    [home stringByAppendingPathComponent:@"Documents"], home]];
  for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/Volumes" error:nil]) {
    NSString *volume = [@"/Volumes" stringByAppendingPathComponent:name];
    if ([volume.stringByResolvingSymlinksInPath isEqualToString:@"/"] || [name hasPrefix:@"com.apple."]) continue;
    [roots addObject:volume];
  }
  return roots;
}

// Walks the usual places for extracted Mario Kart Wii folders (files/ and sys/fst.bin, or a DATA or
// GameData folder holding them) and Retro Rewind folders, checking each it finds. Bounded, so a big
// drive can't keep the player waiting: a few levels deep, hidden folders and packages skipped.
static void KPSetupSearch(void (^progress)(NSString *place), void (^found)(KPSetupCandidate *candidate), void (^done)(void)) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory();
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *root in KPSetupSearchRoots()) {
      const BOOL isHome = [root isEqualToString:home];
      dispatch_async(dispatch_get_main_queue(), ^{ progress(KPFriendlyPath(root)); });
      NSDirectoryEnumerator<NSURL *> *walk = [files enumeratorAtURL:[NSURL fileURLWithPath:root]
          includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                             options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                        errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return YES; }];
      NSUInteger visited = 0;
      const CFTimeInterval started = CACurrentMediaTime();
      for (NSURL *url in walk) {
        if (++visited > 40000 || CACurrentMediaTime() - started > 12) break;
        NSNumber *directory = nil, *link = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!directory.boolValue || link.boolValue) continue;
        const NSUInteger depth = walk.level;
        // Home itself only a little way down (the folders under it are searched on their own).
        if ((isHome && (depth > 2 || [@[@"Downloads", @"Desktop", @"Documents", @"Library", @"Applications", @"Pictures", @"Music", @"Movies"]
                                         containsObject:url.lastPathComponent])) || depth > 5) {
          [walk skipDescendants];
          continue;
        }
        NSString *path = url.path;
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
        if ([url.lastPathComponent isEqualToString:@KARTPAD_RR_ROOT]) {
          [walk skipDescendants];
          if ([seen containsObject:path]) continue;
          [seen addObject:path];
          NSError *error = nil;
          NSString *problem = ValidateRetroRewindRoot(path, &error);
          KPSetupCandidate *candidate = [KPSetupCandidate new];
          candidate.path = path;
          candidate.retro = YES;
          candidate.problem = problem ?: error.localizedDescription;
          dispatch_async(dispatch_get_main_queue(), ^{ found(candidate); });
          continue;
        }
#endif
        NSString *game = ResolvedExtractedRoot(url);
        if (game == nil) continue;
        [walk skipDescendants];
        if ([seen containsObject:game]) continue;
        [seen addObject:game];
        NSError *error = nil;
        NSString *problem = ValidateExtractedRoot(game, &error);
        KPSetupCandidate *candidate = [KPSetupCandidate new];
        candidate.path = game;
        candidate.problem = problem ?: error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{ found(candidate); });
      }
    }
    dispatch_async(dispatch_get_main_queue(), done);
  });
}

@interface KPSetupScreen : KPScreen
@property(nonatomic) KPSetupStep step;
@property(nonatomic) BOOL recovering;  // the files were set up before and have gone missing
@property(nonatomic, strong) NSMutableArray<KPSetupCandidate *> *games, *retros;
@property(nonatomic, copy) NSString *place, *chosenGame, *chosenRetro, *message;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *actions;
@property(nonatomic, copy) void (^finish)(NSString *profile);
@property(nonatomic) CFTimeInterval started;
@end

@implementation KPSetupScreen

- (void)build {
  self.solid = YES;
  self.pausesGame = NO;
  self.games = [NSMutableArray array];
  self.retros = [NSMutableArray array];
  self.actions = [NSMutableArray array];
  self.started = CACurrentMediaTime();
  [self showStep:KPSetupWelcome];
}

// Each step is a heading, a line or two, an optional list of found folders and big buttons.
- (void)clearActions {
  for (KPUIButton *button in self.actions) [button removeFromSuperview];
  [self.actions removeAllObjects];
}
- (KPUIButton *)action:(NSString *)title detail:(NSString *)detail glyph:(KPUIGlyph)glyph primary:(BOOL)primary run:(void (^)(void))run {
  KPUIButton *button = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    if (detail.length) {
      KPButtonFace(c, r, primary ? KPStyle::Primary : KPStyle::Card, NO, state.enabled, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0;
      const unsigned ink = primary ? 0xffffff : KPP->text, sub = primary ? 0xeaf7fd : KPP->secondaryText;
      KPDrawGlyph(c, glyph, CGRectMake(r.origin.x + 24, CGRectGetMidY(r) - 22 + dy, 44, 44), primary ? 0xffffff : KPP->accentBottom);
      KPTextWeight(title, CGRectMake(r.origin.x + 86, r.origin.y + 17 + dy, r.size.width - 104, 30), 23, ink, NSFontWeightSemibold,
                   NSTextAlignmentLeft);
      KPTextWeight(detail, CGRectMake(r.origin.x + 86, r.origin.y + 48 + dy, r.size.width - 104, 24), 16, sub, NSFontWeightRegular,
                   NSTextAlignmentLeft);
    } else {
      KPDrawPill(c, r, state, primary ? KPStyle::Primary : KPStyle::Plain, glyph, title);
    }
  } action:run];
  button.label = title;
  button.sound = primary ? KPUISound::Confirm : KPUISound::Press;
  button.tag2 = (NSInteger)self.actions.count;
  [self.actions addObject:button];
  return button;
}

- (void)showStep:(KPSetupStep)step {
  self.step = step;
  [self clearActions];
  __weak KPSetupScreen *weakSelf = self;
  switch (step) {
    case KPSetupWelcome: {
      [self action:@"Start" detail:nil glyph:KPUIGlyph::Play primary:YES run:^{ [weakSelf showStep:KPSetupFind]; }];
      [self action:@"Quit" detail:nil glyph:KPUIGlyph::Power primary:NO run:^{ [weakSelf quit]; }];
      break;
    }
    case KPSetupFind: {
      [self action:@"Look for my game" detail:@"In Downloads, Desktop, Documents and connected drives" glyph:KPUIGlyph::Search primary:YES
               run:^{ [weakSelf search]; }];
      [self action:@"I'll choose the folder" detail:@"In a Finder window. Needs a mouse." glyph:KPUIGlyph::Window primary:NO
               run:^{ [weakSelf chooseFolder]; }];
      [self action:@"Back" detail:nil glyph:KPUIGlyph::Back primary:NO run:^{ [weakSelf showStep:KPSetupWelcome]; }];
      break;
    }
    case KPSetupSearching:
      break;
    case KPSetupFound: {
      NSInteger shown = 0;
      for (KPSetupCandidate *candidate in self.games) {
        if (candidate.problem || shown >= 3) continue;
        ++shown;
        NSString *path = candidate.path;
        [self action:@"Use this one" detail:KPFriendlyPath(path) glyph:KPUIGlyph::Check primary:shown == 1 run:^{
          [weakSelf useGame:path];
        }];
      }
      [self action:@"Choose the folder myself" detail:nil glyph:KPUIGlyph::Window primary:shown == 0 run:^{ [weakSelf chooseFolder]; }];
      [self action:@"Look again" detail:nil glyph:KPUIGlyph::Restart primary:NO run:^{ [weakSelf search]; }];
      break;
    }
    case KPSetupRetro: {
      NSInteger shown = 0;
      for (KPSetupCandidate *candidate in self.retros) {
        if (candidate.problem || shown >= 2) continue;
        ++shown;
        NSString *path = candidate.path;
        [self action:@"Use this Retro Rewind" detail:KPFriendlyPath(path) glyph:KPUIGlyph::Check primary:shown == 1 run:^{
          [weakSelf useRetro:path];
        }];
      }
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
      if (shown == 0 && KPRetroDownload.shared.available)
        [self action:@"Download Retro Rewind" detail:@"About 2 GB. Play while it downloads." glyph:KPUIGlyph::Plus primary:YES run:^{
          [KPRetroDownload.shared start];
          KPUIPlay(KPUISound::Saved);
          [weakSelf showStep:KPSetupReady];
        }];
#endif
      [self action:@"Choose its folder" detail:nil glyph:KPUIGlyph::Window primary:NO run:^{ [weakSelf chooseRetro]; }];
      [self action:shown ? @"Not now" : @"Skip for now" detail:nil glyph:KPUIGlyph::Chevron
           primary:shown == 0 && ![self.actions.firstObject.label hasPrefix:@"Download"] run:^{
        [weakSelf showStep:KPSetupReady];
      }];
      break;
    }
    case KPSetupReady: {
      [self action:@"Start Mario Kart Wii" detail:nil glyph:KPUIGlyph::Play primary:YES run:^{ [weakSelf start:kKartPadBaseProfile]; }];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
      if (KPRetroRewindReady())
        [self action:@"Start Retro Rewind" detail:nil glyph:KPUIGlyph::Play primary:NO run:^{ [weakSelf start:kKartPadRetroProfile]; }];
#endif
      break;
    }
  }
  [self layoutDesign];
  // The focus starts on the step's main (blue) choice.
  KPUIButton *first = self.actions.firstObject;
  for (KPUIButton *button in self.actions)
    if (button.sound == KPUISound::Confirm) {
      first = button;
      break;
    }
  [KPOverlay() focus:first sound:NO];
  self.needsDisplay = YES;
}

- (void)layoutDesign {
  const CGRect s = self.safe;
  NSArray<KPUIButton *> *big = [self.actions filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(KPUIButton *b, NSDictionary *x) {
    (void)x;
    return [b.label hasPrefix:@"Use this one"] || [b.label hasPrefix:@"Look for"] || [b.label hasPrefix:@"I'll"] || [b.label hasPrefix:@"Use this"] ||
           [b.label hasPrefix:@"Download"];
  }]];
  CGFloat y = s.origin.y + (self.step == KPSetupFound || self.step == KPSetupRetro ? 300 : 330);
  for (KPUIButton *button in big) {
    [self place:button at:CGRectMake(s.origin.x + 290, y, 700, 92)];
    y += 108;
  }
  // The small buttons in a row underneath.
  NSMutableArray<KPUIButton *> *small = [NSMutableArray array];
  for (KPUIButton *button in self.actions)
    if (![big containsObject:button]) [small addObject:button];
  const CGFloat width = small.count > 1 ? 300 : 340, gap = 24;
  const CGFloat total = small.count * width + (small.count ? (small.count - 1) * gap : 0);
  CGFloat x = s.origin.x + (1280 - total) / 2, row = std::max(y + 10, s.origin.y + (big.count ? 300 : 420));
  if (row > s.origin.y + 620) row = s.origin.y + 620;
  for (KPUIButton *button in small) {
    [self place:button at:CGRectMake(x, row, width, 72)];
    x += width + gap;
  }
}

- (KPUIButton *)initialFocus { return self.actions.firstObject; }
- (void)back {
  switch (self.step) {
    case KPSetupFind: [self showStep:KPSetupWelcome]; break;
    case KPSetupFound: [self showStep:KPSetupFind]; break;
    case KPSetupRetro: [self showStep:KPSetupReady]; break;
    default: KPUIPlay(KPUISound::Same); break;
  }
}
- (void)tick { if (self.step == KPSetupSearching) self.needsDisplay = YES; }

#pragma mark Actions

- (void)search {
  [self.games removeAllObjects];
  [self.retros removeAllObjects];
  self.place = nil;
  [self showStep:KPSetupSearching];
  __weak KPSetupScreen *weakSelf = self;
  KPSetupSearch(^(NSString *place) {
    weakSelf.place = place;
    weakSelf.needsDisplay = YES;
  }, ^(KPSetupCandidate *candidate) {
    [candidate.retro ? weakSelf.retros : weakSelf.games addObject:candidate];
    weakSelf.needsDisplay = YES;
  }, ^{
    KPSetupScreen *screen = weakSelf;
    BOOL any = NO;
    for (KPSetupCandidate *candidate in screen.games) any |= candidate.problem == nil;
    KPUIPlay(any ? KPUISound::Saved : KPUISound::Reject);
    [screen showStep:KPSetupFound];
  });
}

- (void)useGame:(NSString *)root {
  if (!WriteGameDataRoot(root)) {
    self.message = @"KartPad couldn't save that: its settings file can't be written.";
    KPUIPlay(KPUISound::Reject);
    self.needsDisplay = YES;
    return;
  }
  self.chosenGame = root;
  AppendSessionLine(@"setup=game-data-chosen");
  // Menu sounds come from the game, so they start now.
  KartPadUIPrepareSounds();
  KPUIPlay(KPUISound::Saved);
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  if (!KPRetroRewindReady()) {
    [self showStep:KPSetupRetro];
    return;
  }
#endif
  [self showStep:KPSetupReady];
}

- (void)chooseFolder {
  NSString *root = ChooseAndValidateGameData();
  if (root.length) [self useGame:root];
}

- (void)useRetro:(NSString *)root {
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  if (WriteRetroRewindRoot(root)) {
    self.chosenRetro = root;
    KPUIPlay(KPUISound::Saved);
  }
#else
  (void)root;
#endif
  [self showStep:KPSetupReady];
}

- (void)chooseRetro {
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  NSString *root = ChooseAndValidateRetroRewindData();
  if (root.length) [self useRetro:root];
#endif
}

- (void)start:(NSString *)profile {
  KPUIPlay(KPUISound::NewMii);
  if (self.finish) self.finish(profile);
}

- (void)quit {
  if (self.finish) self.finish(nil);
}

#pragma mark Drawing

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  // KartPad's own mark, then the step.
  NSImage *icon = NSApp.applicationIconImage;
  const CGFloat iconSize = self.step == KPSetupWelcome ? 150 : 84;
  const CGRect iconRect = CGRectMake(CGRectGetMidX(s) - iconSize / 2, s.origin.y + (self.step == KPSetupWelcome ? 70 : 40), iconSize, iconSize);
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 6), 16, [NSColor colorWithWhite:0 alpha:0.25].CGColor);
  KPFill(c, iconRect, 0x101826, iconSize * 0.22);
  CGContextRestoreGState(c);
  CGContextSaveGState(c);
  CGPathRef rounded = CGPathCreateWithRoundedRect(iconRect, iconSize * 0.22, iconSize * 0.22, nullptr);
  CGContextAddPath(c, rounded);
  CGContextClip(c);
  CGPathRelease(rounded);
  [icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES
             hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
  CGContextRestoreGState(c);
  NSString *heading = @"", *line = @"";
  switch (self.step) {
    case KPSetupWelcome:
      heading = self.recovering ? @"Let's find your game again" : @"Welcome to KartPad";
      line = self.recovering ? @"KartPad can't find your Mario Kart Wii files where they used to be."
                             : @"Let's get Mario Kart Wii ready. It takes about a minute.";
      break;
    case KPSetupFind:
      heading = @"Where's your Mario Kart Wii?";
      line = @"KartPad plays your own copy: the extracted DATA folder (PadMint names it \"KartPad game data\"). "
             @"If your Mac asks whether KartPad can look in your folders, choose Allow.";
      break;
    case KPSetupSearching:
      heading = @"Looking for your game…";
      line = self.place.length ? [NSString stringWithFormat:@"Looking in %@", self.place] : @"Getting started";
      break;
    case KPSetupFound: {
      NSInteger good = 0;
      for (KPSetupCandidate *candidate in self.games) good += candidate.problem == nil;
      heading = good ? @"Found it!" : @"KartPad couldn't find it";
      KPSetupCandidate *bad = nil;
      for (KPSetupCandidate *candidate in self.games)
        if (candidate.problem) bad = candidate;
      line = good ? @""
           : bad ? [NSString stringWithFormat:@"A copy in %@ won't work: %@", KPFriendlyPath(bad.path), bad.problem]
                 : @"Choose the folder yourself, or plug in the drive it's on and look again.";
      break;
    }
    case KPSetupRetro:
      heading = @"Retro Rewind too?";
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
      line = self.retros.count ? @"It's on this Mac: 200+ extra tracks."
                               : @"200+ extra tracks. You can also add it later in HOME › Settings › Game.";
#endif
      break;
    case KPSetupReady:
      heading = @"You're ready to race!";
      line = @"Press HOME (or esc) any time for Controllers, Miis and Settings.";
      break;
  }
  const CGFloat top = iconRect.origin.y + iconSize + 22;
  KPTextWeight(heading, CGRectMake(s.origin.x + 100, top, 1080, 56), 42, KPP->text, NSFontWeightBold);
  KPTextWeight(line, CGRectMake(s.origin.x + 200, top + 62, 880, 84), 21, KPP->secondaryText, NSFontWeightMedium);
  if (self.step == KPSetupSearching) {
    const CGFloat phase = fmod((CACurrentMediaTime() - self.started) / 1.2, 1);
    for (int dot = 0; dot < 5; ++dot) {
      const CGFloat lift = std::max(0.0, sin(phase * 2 * M_PI - dot * 0.7)) * 14;
      KPSetInk(c, KPPlayerColors[dot % 4]);
      CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMidX(s) - 80 + dot * 34, s.origin.y + 420 - lift, 22, 22));
    }
  }
  if (self.message.length)
    KPTextWeight(self.message, CGRectMake(s.origin.x + 200, s.origin.y + 650, 880, 30), 17, KPP->danger, NSFontWeightSemibold);
  KPDrawHints(c, CGRectMake(s.origin.x + 52, s.origin.y + 680, 1176, 24), {{KartPadMiiPadConfirm, @"Choose"}, {KartPadMiiPadBack, @"Back"}},
              15, NSTextAlignmentRight);
}
@end

// Setup quits when its window is closed.
@interface KPSetupWindowWatcher : NSObject
@end
@implementation KPSetupWindowWatcher
+ (void)watch:(NSWindow *)window {
  [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:window queue:nil
                                              usingBlock:^(NSNotification *note) {
    (void)note;
    [NSApp stopModal];
  }];
}
@end

// The window setup lives in: KartPad's, titled, with a window controller so it's never taken for the
// game window.
static NSString *KPRunSetup(BOOL recovering) {
  NSApplication *app = NSApplication.sharedApplication;
  NSRect visible = NSScreen.mainScreen.visibleFrame;
  NSSize size = NSMakeSize(1280, 720);
  if (size.width > visible.size.width - 80 || size.height > visible.size.height - 80) size = NSMakeSize(960, 540);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
  NSWindowController *controller = [[NSWindowController alloc] initWithWindow:window];
  window.title = @"KartPad";
  window.contentMinSize = NSMakeSize(854, 480);
  window.releasedWhenClosed = NO;
  window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
  [window center];

  KPStartQA();
  // Controllers, for setup only.
  SDL_InitSubSystem(SDL_INIT_GAMEPAD);
  NSMutableArray<NSValue *> *opened = [NSMutableArray array];
  NSTimer *pads = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
    SDL_UpdateGamepads();
    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count);
    for (int i = 0; i < count; ++i)
      if (SDL_GetGamepadFromID(ids[i]) == nullptr)
        if (SDL_Gamepad *pad = SDL_OpenGamepad(ids[i])) [opened addObject:[NSValue valueWithPointer:pad]];
    SDL_free(ids);
    KPMiiPadTick();
  }];
  [NSRunLoop.mainRunLoop addTimer:pads forMode:NSRunLoopCommonModes];

  KPOverlayController *overlay = KPOverlay();
  overlay.hostWindow = window;
  KPSetupScreen *screen = [[KPSetupScreen alloc] initWithFrame:NSZeroRect];
  screen.recovering = recovering;
  __block NSString *result = nil;
  __block BOOL finished = NO;
  screen.finish = ^(NSString *profile) {
    result = profile;
    finished = YES;
    // A controller's press comes from a timer, not an event: stopModal only ends the modal loop
    // once an event arrives, so post one.
    [app stopModal];
    [app postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                      timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
  };
  [controller showWindow:nil];
  if (!KPUIBackgroundAutomation()) [app activateIgnoringOtherApps:YES];
  [overlay present:screen];
  KPCurtainDone();
  AppendSessionLine(recovering ? @"setup=recovery" : @"setup=first-run");
  // Runs until a step finishes it; closing the window quits, as setup's Quit does.
  [KPSetupWindowWatcher watch:window];
  [app runModalForWindow:window];
  (void)finished;
  [pads invalidate];
  [overlay closeAll];
  overlay.hostWindow = nil;
  [overlay.host removeFromSuperview];
  [window orderOut:nil];
  for (NSValue *pad in opened) SDL_CloseGamepad((SDL_Gamepad *)pad.pointerValue);
  SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
  (void)controller;
  AppendSessionLine(result ? @"setup=finished" : @"setup=quit");
  return result;
}

