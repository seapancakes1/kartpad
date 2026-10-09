// Local builds opt in by bundling their rebuild settings and Python helper.
static NSDictionary *KPLocalUpdateSettings() {
  NSURL *url = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"LocalUpdater/settings.json"];
  NSData *data = [NSData dataWithContentsOfURL:url];
  if (data == nil) return nil;
  id settings = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [settings isKindOfClass:NSDictionary.class] ? settings : nil;
}

static NSPanel *kpUpdatePanel;
static NSTextField *kpUpdateHeading;
static NSTextField *kpUpdateLabel;
static NSTextField *kpUpdateFootnote;
static NSProgressIndicator *kpUpdateProgress;
static NSProgressIndicator *kpDownloadProgress;
static NSImageView *kpUpdateIcon;
static NSButton *kpUpdateAction;
static NSTimer *kpUpdateTimer;
static NSTimer *kpUpdateDismissTimer;
static NSWindow *kpUpdateParent;
static id kpUpdateResizeObserver;
static NSString *kpUpdatePhase;
static BOOL kpUpdateDismissed;
static void KPCheckLocalUpdates();
static NSTask *KPLocalUpdateTask(NSString *action);

@interface KPLocalUpdateActions : NSObject
- (void)dismiss:(id)sender;
- (void)performAction:(id)sender;
@end
static KPLocalUpdateActions *KPUpdateActions() {
  static KPLocalUpdateActions *actions;
  if (actions == nil) actions = [KPLocalUpdateActions new];
  return actions;
}

static void KPPositionUpdateNotice() {
  if (kpUpdatePanel == nil || kpUpdateDismissed) return;
  NSWindow *parent = NSApp.mainWindow;
  if (parent == nil || [parent isKindOfClass:NSPanel.class]) {
    for (NSWindow *window in NSApp.windows) {
      if (![window isKindOfClass:NSPanel.class] && window.visible) { parent = window; break; }
    }
  }
  if (parent != kpUpdateParent) {
    if (kpUpdateResizeObserver != nil) [NSNotificationCenter.defaultCenter removeObserver:kpUpdateResizeObserver];
    [kpUpdateParent removeChildWindow:kpUpdatePanel];
    kpUpdateParent = parent;
    if (parent != nil) {
      [parent addChildWindow:kpUpdatePanel ordered:NSWindowAbove];
      kpUpdateResizeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification
          object:parent queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { KPPositionUpdateNotice(); }];
    }
  }
  NSRect area = parent ? [parent convertRectToScreen:parent.contentLayoutRect] : NSScreen.mainScreen.visibleFrame;
  CGFloat width = MIN(440, MAX(300, area.size.width - 32));
  [kpUpdatePanel setFrame:NSMakeRect(NSMaxX(area) - width - 16, NSMaxY(area) - 156, width, 140) display:YES];
  kpUpdateHeading.frame = NSMakeRect(50, 105, width - 88, 20);
  kpUpdateLabel.frame = NSMakeRect(50, 58, width - 72, 44);
  kpUpdateFootnote.frame = NSMakeRect(18, 16, width - 150, 20);
  kpDownloadProgress.frame = NSMakeRect(18, 44, width - 36, 4);
  kpUpdateAction.frame = NSMakeRect(width - 122, 12, 104, 28);
  NSButton *close = [kpUpdatePanel.contentView viewWithTag:42];
  close.frame = NSMakeRect(width - 32, 107, 20, 20);
}

static void KPShowUpdateNotice() {
  if (kpUpdateDismissed) return;
  KPPositionUpdateNotice();
  [kpUpdatePanel orderFront:nil];
}

static void KPUpdateNotice(NSString *title, NSString *detail, BOOL working) {
  [NSApplication sharedApplication];
  [kpUpdateDismissTimer invalidate]; kpUpdateDismissTimer = nil;
  if (kpUpdatePanel == nil) {
    kpUpdatePanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 140)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    kpUpdatePanel.releasedWhenClosed = NO;
    kpUpdatePanel.hidesOnDeactivate = YES;
    kpUpdatePanel.hasShadow = YES;
    kpUpdatePanel.opaque = NO;
    kpUpdatePanel.backgroundColor = NSColor.clearColor;
    kpUpdatePanel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSVisualEffectView *surface = [[NSVisualEffectView alloc] initWithFrame:kpUpdatePanel.contentView.bounds];
    surface.material = NSVisualEffectMaterialPopover;
    surface.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    surface.state = NSVisualEffectStateActive;
    surface.wantsLayer = YES;
    surface.layer.cornerRadius = 14;
    surface.layer.masksToBounds = YES;
    kpUpdatePanel.contentView = surface;
    kpUpdateHeading = [NSTextField labelWithString:@""];
    kpUpdateHeading.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    kpUpdateLabel = [NSTextField wrappingLabelWithString:@""];
    kpUpdateLabel.font = [NSFont systemFontOfSize:12];
    kpUpdateLabel.textColor = NSColor.labelColor;
    kpUpdateFootnote = [NSTextField labelWithString:@""];
    kpUpdateFootnote.font = [NSFont systemFontOfSize:11];
    kpUpdateFootnote.textColor = [NSColor.labelColor colorWithAlphaComponent:0.78];
    kpUpdateProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(18, 104, 20, 20)];
    kpUpdateProgress.style = NSProgressIndicatorStyleSpinning;
    kpUpdateProgress.displayedWhenStopped = NO;
    kpUpdateIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(18, 104, 20, 20)];
    kpDownloadProgress = [NSProgressIndicator new];
    kpDownloadProgress.style = NSProgressIndicatorStyleBar;
    kpDownloadProgress.indeterminate = NO;
    kpDownloadProgress.minValue = 0; kpDownloadProgress.maxValue = 1;
    kpDownloadProgress.hidden = YES;
    kpUpdateAction = [NSButton buttonWithTitle:@"" target:KPUpdateActions() action:@selector(performAction:)];
    kpUpdateAction.bezelStyle = NSBezelStyleRounded;
    NSButton *close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Dismiss update notice"]
        target:KPUpdateActions() action:@selector(dismiss:)];
    close.bordered = NO; close.tag = 42;
    for (NSView *view in @[kpUpdateHeading, kpUpdateLabel, kpUpdateFootnote, kpUpdateProgress, kpUpdateIcon, kpDownloadProgress, kpUpdateAction, close])
      [surface addSubview:view];
  }
  kpUpdatePanel.title = title;
  kpUpdateHeading.stringValue = title;
  kpUpdateLabel.stringValue = detail;
  kpUpdateFootnote.stringValue = @"You can keep playing";
  kpUpdateProgress.hidden = !working;
  kpUpdateIcon.hidden = working;
  kpDownloadProgress.hidden = YES;
  kpUpdateAction.hidden = YES;
  if (working) [kpUpdateProgress startAnimation:nil];
  else [kpUpdateProgress stopAnimation:nil];
  KPPositionUpdateNotice();
}

static void KPFinishUpdateNotice(NSString *title, NSString *detail) {
  KPUpdateNotice(title, detail, NO);
  kpUpdateIcon.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:@"Update ready"];
  kpUpdateIcon.contentTintColor = NSColor.systemGreenColor;
  kpUpdateFootnote.stringValue = @"Installs on next launch";
  kpUpdateAction.title = @"Restart game";
  kpUpdateAction.hidden = NO;
  kpUpdateDismissTimer = [NSTimer timerWithTimeInterval:5.0 repeats:NO block:^(NSTimer *timer) {
    [kpUpdatePanel orderOut:nil];
    if (kpUpdateDismissTimer == timer) kpUpdateDismissTimer = nil;
  }];
  [NSRunLoop.mainRunLoop addTimer:kpUpdateDismissTimer forMode:NSRunLoopCommonModes];
}

static void KPRenderUpdateStatus(NSDictionary *status) {
  NSString *phase = status[@"phase"];
  BOOL changed = ![kpUpdatePhase isEqualToString:phase];
  kpUpdatePhase = phase;
  NSString *version = [status[@"version"] isKindOfClass:NSString.class] ? status[@"version"] : @"";
  if ([phase isEqualToString:@"building"]) {
    NSString *step = status[@"step"];
    NSString *title = @"Preparing update";
    NSString *detail = [NSString stringWithFormat:@"Retro Rewind %@ is being prepared. This can take a few minutes.", version];
    if ([step isEqualToString:@"downloading"]) {
      title = @"Downloading update";
      detail = [NSString stringWithFormat:@"Getting Retro Rewind %@ in the background.", version];
    } else if ([step isEqualToString:@"extracting"]) detail = @"Organizing the new game files. Your current version stays available.";
    else if ([step isEqualToString:@"verifying"]) { title = @"Finishing update"; detail = @"Checking the new app and game files before installation."; }
    KPUpdateNotice(title, detail, YES);
    double total = [status[@"totalBytes"] doubleValue], downloaded = [status[@"downloadedBytes"] doubleValue];
    if ([step isEqualToString:@"downloading"] && total > 0) {
      kpDownloadProgress.hidden = NO;
      kpDownloadProgress.doubleValue = MIN(1, MAX(0, downloaded / total));
      kpUpdateFootnote.stringValue = [NSString stringWithFormat:@"%@ of %@",
          [NSByteCountFormatter stringFromByteCount:(long long)downloaded countStyle:NSByteCountFormatterCountStyleFile],
          [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile]];
      NSInteger count = [status[@"patchCount"] integerValue];
      if (count > 1) kpUpdateFootnote.stringValue = [NSString stringWithFormat:@"File %ld of %ld · %@",
          (long)[status[@"patchIndex"] integerValue], (long)count, kpUpdateFootnote.stringValue];
    }
  } else if ([phase isEqualToString:@"ready"] && changed) {
    KPFinishUpdateNotice(@"Ready when you are", [NSString stringWithFormat:@"Retro Rewind %@ is ready. Restart KartPad whenever you’ve finished playing.", version]);
  } else if ([phase isEqualToString:@"error"] && changed) {
    NSString *kind = status[@"errorKind"];
    NSString *title = @"Update couldn’t be prepared";
    NSString *detail = @"The new app couldn’t be prepared for this Mac. Your current version is ready to play.";
    if ([kind isEqualToString:@"network"]) {
      title = @"Couldn’t reach the update server";
      detail = @"Check your internet connection and try again. Your current game is still available.";
    } else if ([kind isEqualToString:@"storage"]) {
      title = @"More space needed";
      detail = @"Free at least 8 GB of disk space, then try again. Your current version is unchanged.";
    } else if ([kind isEqualToString:@"verification"]) {
      title = @"Update wasn’t installed";
      detail = @"The new files didn’t pass validation. Your current version is unchanged.";
    }
    KPUpdateNotice(title, detail, NO);
    kpUpdateIcon.image = [NSImage imageWithSystemSymbolName:@"exclamationmark.circle" accessibilityDescription:@"Update failed"];
    kpUpdateIcon.contentTintColor = NSColor.systemOrangeColor;
    kpUpdateFootnote.stringValue = @"We’ll retry next launch";
    kpUpdateAction.title = @"Try again"; kpUpdateAction.hidden = NO;
  }
  KPShowUpdateNotice();
}

static NSTask *KPLocalUpdateTask(NSString *action) {
  NSDictionary *settings = KPLocalUpdateSettings();
  NSString *python = settings[@"python"];
  if (![python isKindOfClass:NSString.class] || ![python hasPrefix:@"/"]) return nil;
  NSURL *resources = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"LocalUpdater"];
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:python];
  task.arguments = @[[resources URLByAppendingPathComponent:@"updater.py"].path,
      action, @"--settings", [resources URLByAppendingPathComponent:@"settings.json"].path,
      @"--app", NSBundle.mainBundle.bundlePath, @"--version", @KARTPAD_RR_VERSION,
      @"--pid", [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier]];
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  return task;
}

static BOOL KPActivateLocalUpdate() {
  NSDictionary *settings = KPLocalUpdateSettings();
  NSString *state = settings[@"state"];
  if (![state isKindOfClass:NSString.class]) return NO;
  NSFileManager *files = NSFileManager.defaultManager;
  if (![files fileExistsAtPath:[state stringByAppendingPathComponent:@"pending.json"]] &&
      ![files fileExistsAtPath:[state stringByAppendingPathComponent:@"activation.json"]]) return NO;
  NSTask *task = KPLocalUpdateTask(@"activate");
  NSError *error = nil;
  if (task == nil || ![task launchAndReturnError:&error]) return NO;
  kpUpdateDismissed = NO;
  KPUpdateNotice(@"Installing update", @"KartPad will reopen with the updated app and game files.", YES);
  kpUpdateFootnote.stringValue = @"Just a moment…";
  KPShowUpdateNotice();
  while (task.running) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  [kpUpdatePanel orderOut:nil];
  return task.terminationStatus == 10;
}

static void KPCheckLocalUpdates() {
  NSTask *task = KPLocalUpdateTask(@"check");
  if (task == nil) return;
  NSDate *started = NSDate.date;
  NSError *error = nil;
  if (![task launchAndReturnError:&error]) {
    NSLog(@"[KartPad] local update check unavailable: %@", error.localizedDescription); return;
  }
  kpUpdateDismissed = NO; kpUpdatePhase = nil;
  KPUpdateNotice(@"Checking for updates", @"Automatic updates are on. We’ll let you know if there’s something new.", YES);
  KPShowUpdateNotice();
  [kpUpdateTimer invalidate];
  NSString *state = KPLocalUpdateSettings()[@"state"];
  if (![state isKindOfClass:NSString.class]) return;
  kpUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
    NSData *data = [NSData dataWithContentsOfFile:[state stringByAppendingPathComponent:@"status.json"]];
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *status = [result isKindOfClass:NSDictionary.class] ? result : nil;
    NSString *phase = status[@"phase"];
    BOOL fresh = [status[@"checkedAt"] isKindOfClass:NSNumber.class] &&
        [status[@"checkedAt"] doubleValue] >= started.timeIntervalSince1970;
    if ([phase isEqualToString:@"building"] || [phase isEqualToString:@"ready"] || (fresh && [phase isEqualToString:@"error"])) {
      KPRenderUpdateStatus(status);
      if (![phase isEqualToString:@"building"]) [timer invalidate];
    } else if (fresh && [phase isEqualToString:@"current"]) {
      [kpUpdatePanel orderOut:nil]; [timer invalidate];
    } else if (!task.running && [started timeIntervalSinceNow] < -5) {
      [kpUpdatePanel orderOut:nil]; [timer invalidate];
    }
  }];
}

@implementation KPLocalUpdateActions
- (void)dismiss:(id)sender {
  (void)sender; kpUpdateDismissed = YES;
  [kpUpdateDismissTimer invalidate]; kpUpdateDismissTimer = nil;
  [kpUpdatePanel orderOut:nil];
}
- (void)performAction:(id)sender {
  (void)sender;
  if ([kpUpdatePhase isEqualToString:@"error"]) { KPCheckLocalUpdates(); return; }
  if (![kpUpdatePhase isEqualToString:@"ready"]) return;
  [kpUpdateDismissTimer invalidate]; kpUpdateDismissTimer = nil;
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Restart to install the update?";
  alert.informativeText = @"Finish your race before restarting. KartPad will close, install the update, and reopen.";
  [alert addButtonWithTitle:@"Restart"];
  [alert addButtonWithTitle:@"Keep playing"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSTask *task = KPLocalUpdateTask(@"relaunch");
  NSError *error = nil;
  if (task == nil || ![task launchAndReturnError:&error]) return;
  NSMenuItem *quit = nil;
  for (NSMenuItem *menu in NSApp.mainMenu.itemArray) {
    for (NSMenuItem *item in menu.submenu.itemArray) {
      if (item.action == NSSelectorFromString(@"quitKartPad:")) { quit = item; break; }
    }
  }
  if (quit) [NSApp sendAction:quit.action to:quit.target from:self];
  else [NSApp terminate:self];
}
@end

static void KPShowLocalUpdateStatus() {
  NSDictionary *settings = KPLocalUpdateSettings();
  NSString *state = settings[@"state"];
  NSData *data = [state isKindOfClass:NSString.class] ? [NSData dataWithContentsOfFile:[state stringByAppendingPathComponent:@"status.json"]] : nil;
  id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSDictionary *status = [result isKindOfClass:NSDictionary.class] ? result : nil;
  NSString *phase = status[@"phase"];
  kpUpdateDismissed = NO; kpUpdatePhase = nil;
  if ([phase isEqualToString:@"ready"] || [phase isEqualToString:@"building"] || [phase isEqualToString:@"error"]) {
    KPRenderUpdateStatus(status);
  } else KPCheckLocalUpdates();
}
