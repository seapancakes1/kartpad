// Local builds opt in by bundling their rebuild settings and Python helper. They sit in the signed
// bundle, which an update replaces rather than edits, so they are read once per launch.
static NSDictionary *KPLocalUpdateSettings() {
  static NSDictionary *settings;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSData *data = [NSData dataWithContentsOfURL:
        [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"LocalUpdater/settings.json"]];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    settings = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
  });
  return settings;
}

static NSString *KPLocalUpdateStatePath(NSString *name) {
  NSString *state = KPLocalUpdateSettings()[@"state"];
  return [state isKindOfClass:NSString.class] ? [state stringByAppendingPathComponent:name] : nil;
}

static NSDictionary *KPLocalUpdateRead(NSString *name) {
  NSString *path = KPLocalUpdateStatePath(name);
  NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
  id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

static BOOL KPLocalUpdateStateExists(NSString *name) {
  NSString *path = KPLocalUpdateStatePath(name);
  return path != nil && [NSFileManager.defaultManager fileExistsAtPath:path];
}

// The app the updater looks after: the settings' "app", else the one it installed or first saw.
static NSString *KPLocalUpdateInstalledPath() {
  NSString *path = KPLocalUpdateSettings()[@"app"];
  if (![path isKindOfClass:NSString.class]) path = KPLocalUpdateRead(@"installed.json")[@"app"];
  return [path isKindOfClass:NSString.class] && path.length ? path : nil;
}

static NSString *SHA256ForFile(NSString *path, NSError **error);  // KartPadMacShell.mm

// The installed app moved or renamed (as the helper's moved()): the same build, with no app left
// where it was recorded. Not a copy in the Trash, one macOS runs from a temporary place, or a
// backup in the state folder; settings that name the app keep it where they say.
static BOOL KPLocalUpdateIsMovedInstall(NSDictionary *settings, NSDictionary *record, NSString *bundle,
                                        NSString *executable) {
  NSString *recorded = record[@"app"], *digest = record[@"runtimeSha256"], *state = settings[@"state"];
  if (settings[@"app"] != nil || ![recorded isKindOfClass:NSString.class] || ![digest isKindOfClass:NSString.class] ||
      [NSFileManager.defaultManager fileExistsAtPath:[recorded stringByAppendingPathComponent:@"Contents/MacOS/KartPad"]])
    return NO;
  NSString *real = bundle.stringByResolvingSymlinksInPath;
  for (NSString *part in real.pathComponents)
    if ([@[@".Trash", @".Trashes", @"AppTranslocation"] containsObject:part]) return NO;
  if ([state isKindOfClass:NSString.class] &&
      [real hasPrefix:[state.stringByResolvingSymlinksInPath stringByAppendingString:@"/"]]) return NO;
  return [SHA256ForFile(executable, nil) isEqualToString:digest];
}

// A backup or another copy of KartPad leaves updates alone (as the helper's other_copy does); the
// installed app still updates after a move, and its next check records the new place.
static BOOL KPLocalUpdateIsInstalledCopy() {
  NSString *installed = KPLocalUpdateInstalledPath();
  if (installed == nil || [installed.stringByResolvingSymlinksInPath
      isEqualToString:NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath]) return YES;
  static BOOL moved;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    moved = KPLocalUpdateIsMovedInstall(KPLocalUpdateSettings(), KPLocalUpdateRead(@"installed.json"),
                                        NSBundle.mainBundle.bundlePath, NSBundle.mainBundle.executablePath);
  });
  return moved;
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
static NSString *kpUpdateVersion;  // of the status on screen
static NSDate *kpUpdateLastCheck;
static BOOL kpUpdateDismissed;
// Checks the player asked for show every result; automatic ones only show news.
static BOOL kpUpdateInteractive;
static BOOL kpUpdateLaunchFailure;
static void KPCheckLocalUpdates(BOOL interactive, NSArray<NSString *> *options);
static NSTask *KPLocalUpdateTask(NSString *action, NSArray<NSString *> *options);

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
  // The notice is as tall as its detail: one line or two.
  CGFloat detail = MIN(44, MAX(16, ceil([kpUpdateLabel.cell cellSizeForBounds:NSMakeRect(0, 0, width - 72, 1000)].height)));
  CGFloat height = 96 + detail;
  [kpUpdatePanel setFrame:NSMakeRect(NSMaxX(area) - width - 16, NSMaxY(area) - 16 - height, width, height) display:YES];
  kpUpdateHeading.frame = NSMakeRect(50, height - 35, width - 88, 20);
  kpUpdateLabel.frame = NSMakeRect(50, height - 38 - detail, width - 72, detail);
  kpUpdateProgress.frame = kpUpdateIcon.frame = NSMakeRect(18, height - 36, 20, 20);
  kpUpdateFootnote.frame = NSMakeRect(18, 16, width - 150, 20);
  kpDownloadProgress.frame = NSMakeRect(18, 44, width - 36, 4);
  kpUpdateAction.frame = NSMakeRect(width - 122, 12, 104, 28);
  NSButton *close = [kpUpdatePanel.contentView viewWithTag:42];
  close.frame = NSMakeRect(width - 32, height - 33, 20, 20);
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
  kpUpdateFootnote.stringValue = @"";
  kpUpdateProgress.hidden = !working;
  kpUpdateIcon.hidden = working;
  kpDownloadProgress.hidden = YES;
  kpUpdateAction.hidden = YES;
  if (working) [kpUpdateProgress startAnimation:nil];
  else [kpUpdateProgress stopAnimation:nil];
  KPPositionUpdateNotice();
}

static void KPUpdateNoticeIcon(NSString *symbol, NSColor *tint, NSString *description) {
  kpUpdateIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:description];
  kpUpdateIcon.contentTintColor = tint;
}

static void KPHideUpdateNoticeAfter(NSTimeInterval seconds) {
  kpUpdateDismissTimer = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
    [kpUpdatePanel orderOut:nil];
    if (kpUpdateDismissTimer == timer) kpUpdateDismissTimer = nil;
  }];
  [NSRunLoop.mainRunLoop addTimer:kpUpdateDismissTimer forMode:NSRunLoopCommonModes];
}

static void KPFinishUpdateNotice(NSString *title, NSString *detail) {
  KPUpdateNotice(title, detail, NO);
  KPUpdateNoticeIcon(@"checkmark.circle.fill", NSColor.systemGreenColor, @"Update ready");
  kpUpdateFootnote.stringValue = @"Installs on next launch";
  kpUpdateAction.title = @"Restart";
  kpUpdateAction.hidden = NO;
  KPHideUpdateNoticeAfter(5.0);
}

// The helper records its process ID while it works, so a status left by a
// helper that was interrupted doesn't keep a progress notice on screen.
static BOOL KPLocalUpdateHelperRunning(NSDictionary *status) {
  pid_t pid = [status[@"pid"] isKindOfClass:NSNumber.class] ? [status[@"pid"] intValue] : 0;
  return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

static void KPRenderUpdateStatus(NSDictionary *status) {
  NSString *phase = status[@"phase"], *previous = kpUpdatePhase;
  BOOL changed = ![previous isEqualToString:phase];
  kpUpdatePhase = phase;
  NSString *version = [status[@"version"] isKindOfClass:NSString.class] ? status[@"version"] : @"";
  kpUpdateVersion = version;
  if ([phase isEqualToString:@"building"]) {
    NSString *step = status[@"step"];
    NSString *title = @"Preparing update";
    NSString *detail = [NSString stringWithFormat:@"Retro Rewind %@ is being prepared.", version];
    if ([step isEqualToString:@"downloading"]) {
      title = @"Downloading update";
      detail = [NSString stringWithFormat:@"Getting Retro Rewind %@ in the background.", version];
    } else if ([step isEqualToString:@"extracting"]) detail = [NSString stringWithFormat:@"Unpacking Retro Rewind %@.", version];
    else if ([step isEqualToString:@"compiling"]) {
      NSString *stage = status[@"buildStage"];
      title = [NSString stringWithFormat:@"Building Retro Rewind %@", version];
      if ([stage isEqualToString:@"preparing"]) detail = @"Reading the game files.";
      else if ([stage isEqualToString:@"translating"]) detail = @"Translating the game code.";
      else if ([stage isEqualToString:@"compiling"]) detail = @"Compiling the game code.";
      else if ([stage isEqualToString:@"packaging"]) detail = @"Packaging KartPad.";
    } else if ([step isEqualToString:@"verifying"]) { title = @"Finishing update"; detail = @"Checking the files."; }
    KPUpdateNotice(title, detail, YES);
    // The rebuild reports how far it has got; downloads report their bytes below.
    NSNumber *progress = [status[@"progress"] isKindOfClass:NSNumber.class] ? status[@"progress"] : nil;
    if (progress != nil && ![step isEqualToString:@"downloading"]) {
      double done = MIN(1, MAX(0, progress.doubleValue));
      kpDownloadProgress.hidden = NO;
      kpDownloadProgress.doubleValue = done;
      kpUpdateFootnote.stringValue = [NSNumberFormatter localizedStringFromNumber:@(floor(done * 100) / 100)
                                                                     numberStyle:NSNumberFormatterPercentStyle];
    }
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
    KPFinishUpdateNotice(@"Update ready", [NSString stringWithFormat:@"Restart KartPad to install Retro Rewind %@.", version]);
  } else if ([phase isEqualToString:@"error"] && changed) {
    NSString *kind = status[@"errorKind"];
    NSString *message = [status[@"message"] isKindOfClass:NSString.class] ? status[@"message"] : @"";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Automatic checks stay quiet offline and show each distinct failure once.
    if (!kpUpdateInteractive && ([kind isEqualToString:@"network"] ||
        [message isEqualToString:[defaults stringForKey:@"KartPadLocalUpdateLastError"]])) return;
    [defaults setObject:message forKey:@"KartPadLocalUpdateLastError"];
    NSString *title = @"Update couldn’t be prepared";
    NSString *detail = version.length ? [NSString stringWithFormat:@"Retro Rewind %@ couldn’t be added to KartPad.", version]
                                      : @"Retro Rewind couldn’t be added to KartPad.";
    NSString *footnote = @"Paused until you try again";
    if ([kind isEqualToString:@"network"]) {
      title = @"Couldn’t reach the update server";
      detail = @"Check your internet connection and try again.";
      footnote = @"Checks again later";
    } else if ([kind isEqualToString:@"storage"]) {
      title = @"More space needed";
      detail = @"Free at least 8 GB of disk space, then try again.";
      footnote = @"Tries again next launch";
    } else if ([kind isEqualToString:@"verification"]) {
      title = @"Update wasn’t installed";
      detail = @"The new files didn’t pass validation.";
    } else if ([kind isEqualToString:@"checkout"]) {
      detail = [NSString stringWithFormat:@"Retro Rewind %@ needs a newer KartPad checkout.", version];
      footnote = @"Tries again after the checkout updates";
    }
    KPUpdateNotice(title, detail, NO);
    KPUpdateNoticeIcon(@"exclamationmark.circle", NSColor.systemOrangeColor, @"Update failed");
    kpUpdateFootnote.stringValue = footnote;
    kpUpdateAction.title = @"Try Again"; kpUpdateAction.hidden = NO;
  } else if ([phase isEqualToString:@"current"]) {
    // The review was withdrawn or the feed went back: a notice shown from the last launch goes.
    if (!kpUpdateInteractive && [previous isEqualToString:@"unverified"]) [kpUpdatePanel orderOut:nil];
    if (!kpUpdateInteractive) return;
    KPUpdateNotice(@"You’re up to date", [NSString stringWithFormat:@"Retro Rewind %@ is the latest version.", version], NO);
    KPUpdateNoticeIcon(@"checkmark.circle.fill", NSColor.systemGreenColor, @"Up to date");
    KPHideUpdateNoticeAfter(4.0);
  } else if ([phase isEqualToString:@"unverified"] && changed) {
    // A version KartPad's maintainers haven't reviewed, or whose files differ from the review.
    // Shown at every launch until it's installed, so a dismissed notice comes back.
    BOOL mismatch = [status[@"reason"] isEqualToString:@"mismatch"];
    KPUpdateNotice([NSString stringWithFormat:mismatch ? @"Retro Rewind %@ wasn’t installed" : @"Retro Rewind %@ is available", version],
        mismatch ? @"Its files differ from the ones KartPad tested." : @"Installs automatically once KartPad has tested it.", NO);
    KPUpdateNoticeIcon(@"exclamationmark.shield", NSColor.systemOrangeColor, @"Update not tested");
    kpUpdateAction.title = @"Install Anyway"; kpUpdateAction.hidden = NO;
  } else if ([phase isEqualToString:@"declined"]) {
    KPUpdateNotice([NSString stringWithFormat:@"Retro Rewind %@ is skipped", version],
        @"Automatic updates skip versions you went back from.", NO);
    KPUpdateNoticeIcon(@"arrow.uturn.backward.circle", NSColor.secondaryLabelColor, @"Version skipped");
    kpUpdateFootnote.stringValue = @"Your current version stays installed";
    kpUpdateAction.title = @"Install Anyway"; kpUpdateAction.hidden = NO;
  } else if ([phase isEqualToString:@"rolledBack"]) {
    NSString *from = [status[@"from"] isKindOfClass:NSString.class] ? status[@"from"] : @"";
    NSString *detail = [status[@"reason"] isEqualToString:@"unstable"]
        ? [NSString stringWithFormat:@"Retro Rewind %@ didn’t start properly.", from]
        : [NSString stringWithFormat:@"Retro Rewind %@ was removed. Automatic updates will skip it.", from];
    KPUpdateNotice([NSString stringWithFormat:@"Back on Retro Rewind %@", version], detail, NO);
    KPUpdateNoticeIcon(@"arrow.uturn.backward.circle.fill", NSColor.systemBlueColor, @"Previous version restored");
    kpUpdateFootnote.stringValue = @"Install it later from Game › Retro Rewind Updates…";
    KPHideUpdateNoticeAfter(10.0);
  } else return;
  KPShowUpdateNotice();
}

static NSTask *KPLocalUpdateTask(NSString *action, NSArray<NSString *> *options) {
  NSDictionary *settings = KPLocalUpdateSettings();
  NSString *python = settings[@"python"];
  if (![python isKindOfClass:NSString.class] || ![python hasPrefix:@"/"]) return nil;
  NSURL *resources = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"LocalUpdater"];
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:python];
  // Isolated from the user's Python setup, and never writing bytecode into the signed bundle.
  NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"-I", @"-B",
      [resources URLByAppendingPathComponent:@"updater.py"].path, action, nil];
  [arguments addObjectsFromArray:options];
  [arguments addObjectsFromArray:@[@"--settings", [resources URLByAppendingPathComponent:@"settings.json"].path,
      @"--app", NSBundle.mainBundle.bundlePath, @"--version", @KARTPAD_RR_VERSION,
      @"--pid", [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier]]];
  task.arguments = arguments;
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  return task;
}

// Runs before game files open: installs a finished update, or counts a launch of a
// newly installed app and returns to the previous version if it keeps failing. An app the
// updater didn't install (the first launch with it, or a package built by hand) becomes its
// starting point, and the game is pointed at that version's files.
static void KPCurtainDone();  // KartPadCurtain.inc.mm

static BOOL KPActivateLocalUpdate() {
  if (KPLocalUpdateSettings() == nil || !KPLocalUpdateIsInstalledCopy()) return NO;
  BOOL installing = KPLocalUpdateStateExists(@"pending.json") || KPLocalUpdateStateExists(@"activation.json");
  BOOL unknown = ![KPLocalUpdateRead(@"installed.json")[@"version"] isEqual:@KARTPAD_RR_VERSION];
  if (!installing && !unknown && !KPLocalUpdateStateExists(@"trial.json")) return NO;
  // A restart's curtain mustn't hide the install notice (or stay up while this process hands over).
  if (installing) KPCurtainDone();
  NSTask *task = KPLocalUpdateTask(@"activate", @[]);
  NSError *error = nil;
  if (task == nil || ![task launchAndReturnError:&error]) return NO;
  if (installing) {
    kpUpdateDismissed = NO;
    KPUpdateNotice(@"Installing update", @"", YES);
    kpUpdateFootnote.stringValue = @"";
    KPShowUpdateNotice();
  }
  while (task.running) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  [kpUpdatePanel orderOut:nil];
  if (task.terminationStatus == 1) kpUpdateLaunchFailure = YES;
  return task.terminationStatus == 10;
}

// A new app has proved itself once it has run for a while or quit cleanly.
static void KPConfirmLocalUpdate() {
  if (!KPLocalUpdateIsInstalledCopy()) return;
  NSDictionary *trial = KPLocalUpdateRead(@"trial.json");
  if ([trial[@"version"] isEqual:@KARTPAD_RR_VERSION])
    [NSFileManager.defaultManager removeItemAtPath:KPLocalUpdateStatePath(@"trial.json") error:nil];
}

static void KPCheckLocalUpdates(BOOL interactive, NSArray<NSString *> *options) {
  NSTask *task = KPLocalUpdateTask(@"check", interactive ? [@[@"--force"] arrayByAddingObjectsFromArray:options] : options);
  if (task == nil) return;
  task.qualityOfService = NSQualityOfServiceUtility;
  NSDate *started = NSDate.date;
  NSError *error = nil;
  if (![task launchAndReturnError:&error]) {
    NSLog(@"[KartPad] local update check unavailable: %@", error.localizedDescription); return;
  }
  kpUpdateLastCheck = started;
  kpUpdateInteractive = interactive;
  if (interactive) {
    kpUpdateDismissed = NO;
    KPUpdateNotice(@"Checking for updates", @"", YES);
    kpUpdatePhase = @"checking";
    KPShowUpdateNotice();
  }
  [kpUpdateTimer invalidate];
  kpUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
    BOOL finished = !task.running;
    NSDictionary *status = KPLocalUpdateRead(@"status.json");
    NSString *phase = status[@"phase"];
    BOOL fresh = [status[@"checkedAt"] isKindOfClass:NSNumber.class] &&
        [status[@"checkedAt"] doubleValue] >= started.timeIntervalSince1970;
    if ([phase isEqualToString:@"building"] && KPLocalUpdateHelperRunning(status)) {
      KPRenderUpdateStatus(status);
    } else if (fresh && phase && [@[@"ready", @"error", @"current", @"declined", @"unverified"] containsObject:phase]) {
      KPRenderUpdateStatus(status); [timer invalidate];
    } else if (finished) {
      if ([kpUpdatePhase isEqualToString:@"checking"] || [kpUpdatePhase isEqualToString:@"building"])
        [kpUpdatePanel orderOut:nil];
      [timer invalidate];
    }
  }];
}

// A rebuild runs at full speed except while a race runs in the active window: KartPad's process ID
// in the state folder's "racing" file says so (the helper's racing()). One left by a KartPad that
// has quit names a process that is gone.
static void KPLocalUpdateNoteRace(BOOL racing) {
  static BOOL noted;
  racing = racing && NSApp.active && KPLocalUpdateIsInstalledCopy();
  NSString *path = KPLocalUpdateStatePath(@"racing");
  if (racing == noted || path == nil) return;
  noted = racing;
  if (racing)
    [[NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  else [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

// Called once the shell is up: one-time notices from the last launch, then a quiet check.
static void KPStartLocalUpdates() {
  if (KPLocalUpdateSettings() == nil || !KPLocalUpdateIsInstalledCopy()) return;
  [NSFileManager.defaultManager removeItemAtPath:KPLocalUpdateStatePath(@"racing") error:nil];
  // A paused game in the background doesn't tick; leaving the window ends the slowdown at once.
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil
      queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { KPLocalUpdateNoteRace(NO); }];
  NSDictionary *status = KPLocalUpdateRead(@"status.json");
  BOOL failed = kpUpdateLaunchFailure;
  kpUpdateLaunchFailure = NO;
  // Give the game window a moment to appear so the notice attaches to it.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (kpUpdatePhase != nil && ![kpUpdatePhase isEqualToString:@"checking"]) return;
    kpUpdateDismissed = NO;
    if (failed) {
      kpUpdateInteractive = YES;
      KPRenderUpdateStatus(status);
      kpUpdateInteractive = NO;
    } else if ([KPLocalUpdateRead(@"status.json")[@"phase"] isEqualToString:@"unverified"]) {
      // Offline, or before the check finishes: the update waiting from last time.
      KPRenderUpdateStatus(KPLocalUpdateRead(@"status.json"));
    } else if ([status[@"phase"] isEqualToString:@"rolledBack"]) {
      NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
      double at = [status[@"checkedAt"] doubleValue];
      if (at > [defaults doubleForKey:@"KartPadLocalUpdateNoticeAt"]) {
        [defaults setDouble:at forKey:@"KartPadLocalUpdateNoticeAt"];
        KPRenderUpdateStatus(status);
      }
    }
  });
  KPCheckLocalUpdates(NO, @[]);
  // KartPad left open, or asleep with the Mac, checks again every few hours.
  [NSTimer scheduledTimerWithTimeInterval:30 * 60 repeats:YES block:^(NSTimer *timer) {
    if (!kpUpdateTimer.valid && kpUpdateLastCheck && -kpUpdateLastCheck.timeIntervalSinceNow >= 4 * 60 * 60)
      KPCheckLocalUpdates(NO, @[]);
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    KPConfirmLocalUpdate();
  });
}

// The helper waits for this process to exit, finishes the change, then reopens the app once.
static void KPFinishLocalUpdateAndQuit(NSString *then, id sender) {
  NSTask *task = KPLocalUpdateTask(@"finish", @[@"--then", then]);
  NSError *error = nil;
  if (task == nil || ![task launchAndReturnError:&error]) return;
  NSMenuItem *quit = nil;
  for (NSMenuItem *menu in NSApp.mainMenu.itemArray) {
    for (NSMenuItem *item in menu.submenu.itemArray) {
      if (item.action == NSSelectorFromString(@"quitKartPad:")) { quit = item; break; }
    }
  }
  if (quit) [NSApp sendAction:quit.action to:quit.target from:sender];
  else [NSApp terminate:sender];
}

@implementation KPLocalUpdateActions
- (void)dismiss:(id)sender {
  (void)sender; kpUpdateDismissed = YES;
  [kpUpdateDismissTimer invalidate]; kpUpdateDismissTimer = nil;
  [kpUpdatePanel orderOut:nil];
}
- (void)performAction:(id)sender {
  (void)sender;
  if ([kpUpdatePhase isEqualToString:@"error"]) { KPCheckLocalUpdates(YES, @[]); return; }
  if ([kpUpdatePhase isEqualToString:@"declined"]) { KPCheckLocalUpdates(YES, @[@"--allow-declined"]); return; }
  if ([kpUpdatePhase isEqualToString:@"unverified"]) {
    NSString *version = kpUpdateVersion;
    [kpUpdateDismissTimer invalidate]; kpUpdateDismissTimer = nil;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Install Retro Rewind %@?", version];
    alert.informativeText = @"KartPad hasn’t tested this version. It may not work.";
    [alert addButtonWithTitle:@"Install Anyway"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) KPCheckLocalUpdates(YES, @[@"--allow-unverified", version]);
    return;
  }
  if (![kpUpdatePhase isEqualToString:@"ready"]) return;
  [kpUpdateDismissTimer invalidate]; kpUpdateDismissTimer = nil;
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Restart to Install the Update?";
  alert.informativeText = @"Unsaved progress will be lost.";
  [alert addButtonWithTitle:@"Restart"];
  [alert addButtonWithTitle:@"Keep Playing"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  KPFinishLocalUpdateAndQuit(@"activate", self);
}
@end

static void KPShowLocalUpdateStatus() {
  NSDictionary *status = KPLocalUpdateRead(@"status.json");
  NSString *phase = status[@"phase"];
  kpUpdateDismissed = NO; kpUpdatePhase = nil; kpUpdateInteractive = YES;
  if (!KPLocalUpdateIsInstalledCopy()) {
    KPUpdateNotice(@"This copy doesn’t update", [NSString stringWithFormat:@"Retro Rewind updates go to %@.",
        KPLocalUpdateInstalledPath().stringByAbbreviatingWithTildeInPath], NO);
    KPUpdateNoticeIcon(@"info.circle", NSColor.secondaryLabelColor, @"Updates off");
    kpUpdateFootnote.stringValue = @"";
    KPShowUpdateNotice();
    KPHideUpdateNoticeAfter(8.0);
    return;
  }
  if ([phase isEqualToString:@"ready"] || [phase isEqualToString:@"error"] ||
      ([phase isEqualToString:@"building"] && KPLocalUpdateHelperRunning(status))) {
    KPRenderUpdateStatus(status);
  } else KPCheckLocalUpdates(YES, @[]);
}

// Menu title for returning to the version the last update replaced, or nil.
static NSString *KPLocalUpdateRevertTitle() {
  if (!KPLocalUpdateIsInstalledCopy()) return nil;
  NSDictionary *rollback = KPLocalUpdateRead(@"rollback.json");
  if (![rollback[@"version"] isKindOfClass:NSString.class]) return nil;
  return [NSString stringWithFormat:@"Go Back to Retro Rewind %@…", rollback[@"version"]];
}

static void KPRevertLocalUpdate(id sender) {
  if (!KPLocalUpdateIsInstalledCopy()) return;
  NSDictionary *rollback = KPLocalUpdateRead(@"rollback.json");
  if (![rollback[@"version"] isKindOfClass:NSString.class]) return;
  NSAlert *alert = [NSAlert new];
  if (KPLocalUpdateHelperRunning(KPLocalUpdateRead(@"status.json"))) {
    alert.messageText = @"An Update Is Being Prepared";
    alert.informativeText = @"Try again when it has finished.";
    [alert runModal];
    return;
  }
  alert.messageText = [NSString stringWithFormat:@"Go Back to Retro Rewind %@?", rollback[@"version"]];
  alert.informativeText = [NSString stringWithFormat:
      @"Unsaved progress will be lost. Automatic updates will skip Retro Rewind %@.",
      rollback[@"replaces"]];
  [alert addButtonWithTitle:@"Go Back"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  KPFinishLocalUpdateAndQuit(@"rollback", sender);
}
