// Automated checks of the screens in the iOS Simulator (never in a device build): with
// KARTPAD_QA_DIR set (simctl launch passes SIMCTL_CHILD_KARTPAD_QA_DIR), KartPad reads commands.txt
// there four times a second, one command a line, each run once in order, and logs to log.txt.
//   home                     the three-dot button (opens HOME, or closes the screens)
//   screen settings|controllers|ghosts|miis|connect   opens that screen
//   tap LABEL                presses the control with that accessibility label on the top screen
//   hit X Y                  logs what a touch at X,Y (points in the game window) would land on
//   focus LABEL              moves the focus there;  pad up|down|left|right|a|b|x|y|l|r|start
//   close / back             closes every screen / goes back one
//   state                    logs the top screen, the focus, the hold and the game's frame count
//   controls                 logs every control on the top screen with its frame
//   roster                   logs each controller and the player it plays as
//   shot NAME                writes NAME.png of the window (the game's own picture may be missing)
//   presented / dismiss      logs / closes the UIKit sheet over the screens
//   drop N                   player N's controller drops out (the reconnect card)
//   restart                  asks to restart (iOS: close and reopen)
// Included by KartPadScreensGlue.inc.mm.

#if TARGET_OS_SIMULATOR
extern "C" int g_gxFrameCount;

static NSString *KPQADirectory;
static NSUInteger KPQADone;

static void KPQALog(NSString *line) {
  NSString *path = [KPQADirectory stringByAppendingPathComponent:@"log.txt"];
  NSString *stamped = [NSString stringWithFormat:@"%.3f %@\n", NSProcessInfo.processInfo.systemUptime, line];
  NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
  if (file == nil) {
    [stamped writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  [file seekToEndOfFile];
  [file writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
  [file closeFile];
}

static void KPQACollect(UIView *view, NSMutableArray<KPUIButton *> *found) {
  for (UIView *child in view.subviews) {
    if (child.hidden) continue;
    if ([child isKindOfClass:KPUIButton.class]) [found addObject:(KPUIButton *)child];
    KPQACollect(child, found);
  }
}
static KPUIButton *KPQAButton(NSString *label) {
  NSMutableArray<KPUIButton *> *found = [NSMutableArray array];
  if (KPScreen *top = KPOverlay().top) KPQACollect(top, found);
  for (KPUIButton *button in found)
    if ([button.label isEqualToString:label]) return button;
  for (KPUIButton *button in found)
    if ([button.label.lowercaseString hasPrefix:label.lowercaseString]) return button;
  return nil;
}

static void KPQARun(NSString *line) {
  NSArray<NSString *> *words = [line componentsSeparatedByString:@" "];
  NSString *command = words.firstObject;
  NSString *rest = words.count > 1 ? [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "] : @"";
  KPOverlayController *overlay = KPOverlay();
  if ([command isEqualToString:@"home"]) {
    UIButton *menu = KartPadFindMenuButton(KPGameWindow().rootViewController.view);
    if (menu) [menu sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    else KartPadScreensToggleHome();
    KPQALog([NSString stringWithFormat:@"home: %@", menu ? @"menu button" : @"no menu button"]);
  } else if ([command isEqualToString:@"screen"]) {
    KPScreen *screen = [rest isEqualToString:@"settings"] ? KPMakeSettingsScreen()
                     : [rest isEqualToString:@"controllers"] ? (KPScreen *)KPMakeControllersScreen(-1)
                     : [rest isEqualToString:@"ghosts"] ? KPMakeGhostsScreen()
                     : [rest isEqualToString:@"miis"] ? KPMakeMiisScreen()
                     : [rest isEqualToString:@"connect"] ? KPMakeConnectScreen() : nil;
    if (screen) [overlay present:screen];
    KPQALog([NSString stringWithFormat:@"screen %@: %@", rest, screen ? @"opened" : @"unknown"]);
  } else if ([command isEqualToString:@"tap"]) {
    KPUIButton *button = KPQAButton(rest);
    KPScreensTouchUsed();
    if (button) [button fire:YES];
    KPQALog([NSString stringWithFormat:@"tap %@: %@", rest, button ? @"pressed" : @"not found"]);
  } else if ([command isEqualToString:@"hit"]) {
    UIWindow *window = KPGameWindow();
    const CGPoint point = CGPointMake(words.count > 1 ? words[1].doubleValue : 0, words.count > 2 ? words[2].doubleValue : 0);
    UIView *hit = [window hitTest:point withEvent:nil];
    NSString *what = [hit isKindOfClass:KPUIButton.class] ? [NSString stringWithFormat:@"button \"%@\"", ((KPUIButton *)hit).label]
                                                         : NSStringFromClass(hit.class);
    KPQALog([NSString stringWithFormat:@"hit %.0f,%.0f: %@", point.x, point.y, what ?: @"nothing"]);
  } else if ([command isEqualToString:@"focus"]) {
    KPUIButton *button = KPQAButton(rest);
    if (button) [overlay focus:button sound:NO];
    KPQALog([NSString stringWithFormat:@"focus %@: %@", rest, button ? @"done" : @"not found"]);
  } else if ([command isEqualToString:@"pad"]) {
    NSDictionary<NSString *, NSNumber *> *buttons = @{
      @"up": @(KartPadMiiPadUp), @"down": @(KartPadMiiPadDown), @"left": @(KartPadMiiPadLeft), @"right": @(KartPadMiiPadRight),
      @"a": @(KartPadMiiPadConfirm), @"b": @(KartPadMiiPadBack), @"x": @(KartPadMiiPadUndo), @"y": @(KartPadMiiPadRedo),
      @"l": @(KartPadMiiPadPreviousTab), @"r": @(KartPadMiiPadNextTab), @"start": @(KartPadMiiPadStart)};
    NSNumber *button = buttons[rest];
    if (button) {
      KPScreensPadUsed();
      KPOverlayPadPress((KartPadMiiPadButton)button.integerValue, YES);
      KPOverlayPadPress((KartPadMiiPadButton)button.integerValue, NO);
    }
    KPQALog([NSString stringWithFormat:@"pad %@: %@ (focus %@)", rest, button ? @"pressed" : @"unknown",
                                       KPOverlay().top.focus.label ?: @"none"]);
  } else if ([command isEqualToString:@"close"]) {
    [overlay closeAll];
    KPQALog(@"close");
  } else if ([command isEqualToString:@"back"]) {
    [overlay.top back];
    KPQALog(@"back");
  } else if ([command isEqualToString:@"state"]) {
    KPQALog([NSString stringWithFormat:@"state: top=%@ title=%@ focus=%@ screens=%lu hold=%d frame=%d touching=%d scale=%.3f",
                                       NSStringFromClass(overlay.top.class) ?: @"none", overlay.top.title ?: @"",
                                       overlay.top.focus.label ?: @"none", (unsigned long)overlay.stack.count,
                                       KartPadScreensHoldGame(), g_gxFrameCount, KPScreensTouching, overlay.scale]);
  } else if ([command isEqualToString:@"controls"]) {
    NSMutableArray<KPUIButton *> *found = [NSMutableArray array];
    if (KPScreen *top = overlay.top) KPQACollect(top, found);
    for (KPUIButton *button in found) {
      const CGRect r = [button convertRect:button.bounds toView:nil];
      KPQALog([NSString stringWithFormat:@"control \"%@\" at %.0f,%.0f %.0fx%.0f%@", button.label ?: @"", r.origin.x,
                                         KPGameWindow().bounds.size.height - CGRectGetMaxY(r), r.size.width, r.size.height,
                                         button.enabled ? @"" : @" (disabled)"]);
    }
  } else if ([command isEqualToString:@"roster"]) {
    [KPControllerRoster.shared refresh];
    for (KPPadDevice *device in KPControllerRoster.shared.devices)
      KPQALog([NSString stringWithFormat:@"roster: %@ (%@) player=%d", device.name, device.identifier, device.slot + 1]);
  } else if ([command isEqualToString:@"shot"]) {
    UIWindow *window = KPGameWindow();
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
      (void)context;
      [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];
    NSString *path = [KPQADirectory stringByAppendingPathComponent:[rest stringByAppendingPathExtension:@"png"]];
    [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
    KPQALog([NSString stringWithFormat:@"shot %@", rest]);
  } else if ([command isEqualToString:@"presented"]) {
    UIViewController *shown = KPGameWindow().rootViewController.presentedViewController;
    NSString *title = [shown isKindOfClass:UIAlertController.class] ? ((UIAlertController *)shown).title : shown.title;
    KPQALog([NSString stringWithFormat:@"presented: %@ %@", shown ? NSStringFromClass(shown.class) : @"none", title ?: @""]);
  } else if ([command isEqualToString:@"dismiss"]) {
    [KPGameWindow().rootViewController dismissViewControllerAnimated:NO completion:nil];
    KPQALog(@"dismiss");
  } else if ([command isEqualToString:@"drop"]) {
    const int slot = std::clamp(rest.intValue - 1, 0, 3);
    KPControllerDroppedAs(slot, @"Gamepad", nil, KPFamilyGeneric, nil);
    KPQALog([NSString stringWithFormat:@"drop %d", slot + 1]);
  } else if ([command isEqualToString:@"restart"]) {
    KPRestartWithCurtain(@"Restart KartPad", @"");
    KPQALog(@"restart");
  } else if (command.length) {
    KPQALog([NSString stringWithFormat:@"unknown command: %@", line]);
  }
}

static void KPQAStart() {
  NSString *directory = NSProcessInfo.processInfo.environment[@"KARTPAD_QA_DIR"];
  if (directory.length == 0 || KPQADirectory) return;
  if (!directory.isAbsolutePath)
    directory = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:directory];
  [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  KPQADirectory = directory;
  KPQALog(@"qa: listening");
  NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
    (void)t;
    NSString *text = [NSString stringWithContentsOfFile:[KPQADirectory stringByAppendingPathComponent:@"commands.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    // Only finished lines (a newline after them) run, one a tick, so screens can open between.
    if (lines.count == 0) return;
    const NSUInteger complete = lines.count - 1;
    if (KPQADone < complete) {
      NSString *line = [lines[KPQADone++] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      @autoreleasepool { KPQARun(line); }
    }
  }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
#else
static void KPQAStart() {}
#endif
