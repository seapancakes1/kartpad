// Progress sync on iPhone and iPad (apple/shared/KartPadSync.h): the choice at launch, Settings →
// Game → Sync progress, and sending when KartPad goes to the background. Included by
// KartPadRuntimeOverlayHost.mm after the overlay host's implementation.

#import "KartPadSync.h"

static NSString *KPSyncThisDevice() { return [@"This " stringByAppendingString:KartPadSyncThisDeviceName()]; }

// Asked at launch over the launch window, before the game opens its files.
static KartPadSyncChoice KPSyncAskAtLaunch(UIViewController *presenter, KartPadSyncProgress *mine,
                                           KartPadSyncProgress *other) {
  __block BOOL answered = NO;
  __block KartPadSyncChoice choice = KartPadSyncChoiceLater;
  void (^answer)(KartPadSyncChoice) = ^(KartPadSyncChoice picked) {
    choice = picked;
    // As for other launch alerts, wait for it to finish dismissing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   ^{ answered = YES; });
  };
  NSString *device = KartPadSyncThisDeviceName();
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose Progress"
      message:[NSString stringWithFormat:@"Progress changed on this %@ and on %@.\n\n%@: %@\n%@: %@", device,
                  other.deviceName, KPSyncThisDevice(), KartPadSyncDescribe(mine), other.deviceName,
                  KartPadSyncDescribe(other)]
      preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Keep This %@’s", device]
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; answer(KartPadSyncChoiceKeepThisDevice); }]];
  [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Use %@’s", other.deviceName]
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; answer(KartPadSyncChoiceUseOther); }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Decide Later" style:UIAlertActionStyleCancel
      handler:^(UIAlertAction *a) { (void)a; answer(KartPadSyncChoiceLater); }]];
  dispatch_async(dispatch_get_main_queue(), ^{ [presenter presentViewController:alert animated:YES completion:nil]; });
  while (!answered) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  return choice;
}

// Once per process: the first launch of the game in it.
static void KPSyncAtLaunch(UIViewController *presenter) {
  static BOOL done = NO;
  if (done) return;
  done = YES;
  KartPadSyncAtLaunch(8, ^KartPadSyncChoice(KartPadSyncProgress *mine, KartPadSyncProgress *other) {
    return KPSyncAskAtLaunch(presenter, mine, other);
  });
  KartPadSyncStartWatching();
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                                                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
    (void)note;
    if (!KartPadSyncEnabled()) return;
    UIApplication *application = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^finish)(void) = ^{
      if (task == UIBackgroundTaskInvalid) return;
      [application endBackgroundTask:task];
      task = UIBackgroundTaskInvalid;
    };
    task = [application beginBackgroundTaskWithName:@"Sync progress" expirationHandler:finish];
    KartPadSyncSendSoon(finish);
  }];
}

@interface KPSyncFolderPicker : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^picked)(NSURL *folder);
@end
@implementation KPSyncFolderPicker
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  (void)controller;
  if (urls.firstObject && self.picked) self.picked(urls.firstObject);
  self.picked = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  (void)controller;
  self.picked = nil;
}
@end

@interface KartPadRuntimeOverlayHost (SyncPrivate)
- (void)presentOverlayAlert:(UIAlertController *)alert;
- (void)showIntegrationAlert:(NSString *)title message:(NSString *)message;
@end

@implementation KartPadRuntimeOverlayHost (Sync)

static NSString *const KPSyncRestartHint = @"Fully close KartPad from the app switcher and reopen it.";

- (void)showSyncResult:(NSString *)title {
  NSString *status = KartPadSyncStatus();
  [self showIntegrationAlert:title message:KartPadSyncNeedsRestart()
      ? [NSString stringWithFormat:@"%@. %@", status, KPSyncRestartHint] : status];
}

- (void)chooseSyncFolder {
  static KPSyncFolderPicker *delegate;
  delegate = [KPSyncFolderPicker new];
  __weak KartPadRuntimeOverlayHost *weakSelf = self;
  delegate.picked = ^(NSURL *folder) {
    NSError *error = nil;
    if (!KartPadSyncChooseFolder(folder, &error)) {
      [weakSelf showIntegrationAlert:@"Sync Couldn’t Be Turned On" message:error.localizedDescription ?: @""];
      return;
    }
    KartPadSyncSendSoon(^{ [weakSelf showSyncResult:@"Sync On"]; });
  };
  UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
  picker.delegate = delegate;
  picker.allowsMultipleSelection = NO;
  UIViewController *presenter = [self screensPresenter];
  dispatch_async(dispatch_get_main_queue(), ^{ [presenter presentViewController:picker animated:YES completion:nil]; });
}

- (void)useSyncedProgress {
  __weak KartPadRuntimeOverlayHost *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSArray<KartPadSyncProgress *> *others = KartPadSyncOtherDevices(8);
    dispatch_async(dispatch_get_main_queue(), ^{
      KartPadRuntimeOverlayHost *host = weakSelf;
      if (host == nil) return;
      if (others.count == 0) {
        [host showIntegrationAlert:@"No Other Progress" message:@"No other device has synced to this folder yet."];
        return;
      }
      NSMutableArray *lines = [NSMutableArray array];
      for (KartPadSyncProgress *other in others)
        [lines addObject:[NSString stringWithFormat:@"%@: %@", other.deviceName, KartPadSyncDescribe(other)]];
      UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Use Progress From"
          message:[[lines componentsJoinedByString:@"\n"] stringByAppendingFormat:
                      @"\n\nIt replaces this %@’s progress at the next launch.", KartPadSyncThisDeviceName()]
          preferredStyle:UIAlertControllerStyleActionSheet];
      for (KartPadSyncProgress *other in others) {
        [sheet addAction:[UIAlertAction actionWithTitle:other.deviceName style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
          (void)a;
          NSError *error = nil;
          if (!KartPadSyncUseProgressAtNextLaunch(other.deviceID, &error)) {
            [weakSelf showIntegrationAlert:@"Progress Unavailable" message:error.localizedDescription ?: @""];
            return;
          }
          [weakSelf showIntegrationAlert:[NSString stringWithFormat:@"%@’s Progress Loads Next Launch", other.deviceName]
                                 message:KPSyncRestartHint];
        }]];
      }
      [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
      [host presentOverlayAlert:sheet];
    });
  });
}

- (void)screensProgressSync {
  if (!KartPadSyncEnabled()) return [self chooseSyncFolder];
  __weak KartPadRuntimeOverlayHost *weakSelf = self;
  UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Sync Progress"
      message:[NSString stringWithFormat:@"%@ · %@", KartPadSyncFolderName() ?: @"", KartPadSyncStatus()]
      preferredStyle:UIAlertControllerStyleActionSheet];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Sync Now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
    (void)a;
    KartPadSyncSendSoon(^{ [weakSelf showSyncResult:@"Sync Progress"]; });
  }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Use Progress From…" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { (void)a; [weakSelf useSyncedProgress]; }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Change Folder…" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { (void)a; [weakSelf chooseSyncFolder]; }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Turn Off" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { (void)a; KartPadSyncTurnOff(); }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  [self presentOverlayAlert:sheet];
}

@end
