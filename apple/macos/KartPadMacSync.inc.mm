// Progress sync on Mac (apple/shared/KartPadSync.h): Settings → Game → Sync progress, the choice at
// launch when progress changed here and on another device, and sending when KartPad quits or
// goes to the background. Included by KartPadMacShell.mm after the controller's Screens category.

#import "KartPadSync.h"

// Asked at launch, before the game window opens.
static KartPadSyncChoice KPAskSyncChoice(KartPadSyncProgress *mine, KartPadSyncProgress *other) {
  KPCurtainDone();
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Choose Progress";
  alert.informativeText = [NSString stringWithFormat:@"Progress changed on this Mac and on %@.\n\n%@: %@\n%@: %@",
      other.deviceName, @"This Mac", KartPadSyncDescribe(mine), other.deviceName, KartPadSyncDescribe(other)];
  [alert addButtonWithTitle:@"Keep This Mac’s"];
  [alert addButtonWithTitle:[NSString stringWithFormat:@"Use %@’s", other.deviceName]];
  [alert addButtonWithTitle:@"Decide Later"];
  [NSApp activateIgnoringOtherApps:YES];
  switch ([alert runModal]) {
    case NSAlertFirstButtonReturn: return KartPadSyncChoiceKeepThisDevice;
    case NSAlertSecondButtonReturn: return KartPadSyncChoiceUseOther;
    default: return KartPadSyncChoiceLater;
  }
}

static void KPSyncAtLaunch() {
  KartPadSyncAtLaunch(10, ^KartPadSyncChoice(KartPadSyncProgress *mine, KartPadSyncProgress *other) {
    return KPAskSyncChoice(mine, other);
  });
  KartPadSyncStartWatching();
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil
                                                   queue:nil usingBlock:^(NSNotification *note) {
    (void)note;
    KartPadSyncSendSoon(nil);
  }];
}

@implementation KartPadMacShellController (Sync)

- (BOOL)chooseSyncFolder {
  NSOpenPanel *panel = NSOpenPanel.openPanel;
  panel.canChooseDirectories = YES;
  panel.canChooseFiles = NO;
  panel.canCreateDirectories = YES;
  panel.prompt = @"Sync Here";
  panel.message = @"Choose the same folder on each device, such as one in iCloud Drive.";
  NSURL *iCloud = [NSFileManager.defaultManager.homeDirectoryForCurrentUser
      URLByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs" isDirectory:YES];
  if ([NSFileManager.defaultManager fileExistsAtPath:iCloud.path]) panel.directoryURL = iCloud;
  [NSApp activateIgnoringOtherApps:YES];
  if ([panel runModal] != NSModalResponseOK || panel.URL == nil) return NO;
  NSError *error = nil;
  if (!KartPadSyncChooseFolder(panel.URL, &error)) {
    [self showSimpleAlert:@"Sync Couldn’t Be Turned On" message:error.localizedDescription ?: @""];
    return NO;
  }
  KartPadSyncSendNow(15);
  return YES;
}

- (void)useSyncedProgress {
  NSArray<KartPadSyncProgress *> *others = KartPadSyncOtherDevices(10);
  if (others.count == 0) {
    [self showSimpleAlert:@"No Other Progress" message:@"No other device has synced to this folder yet."];
    return;
  }
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Use Progress From";
  NSMutableArray *lines = [NSMutableArray array];
  const NSUInteger shown = MIN(others.count, (NSUInteger)3);
  for (NSUInteger i = 0; i < shown; i++) {
    [lines addObject:[NSString stringWithFormat:@"%@: %@", others[i].deviceName, KartPadSyncDescribe(others[i])]];
    [alert addButtonWithTitle:others[i].deviceName];
  }
  alert.informativeText = [[lines componentsJoinedByString:@"\n"]
      stringByAppendingString:@"\n\nIt replaces this Mac’s progress at the next launch."];
  [alert addButtonWithTitle:@"Cancel"];
  const NSInteger index = [alert runModal] - NSAlertFirstButtonReturn;
  if (index < 0 || index >= (NSInteger)shown) return;
  NSError *error = nil;
  if (!KartPadSyncUseProgressAtNextLaunch(others[index].deviceID, &error)) {
    [self showSimpleAlert:@"Progress Unavailable" message:error.localizedDescription ?: @""];
    return;
  }
  NSAlert *restart = [NSAlert new];
  restart.messageText = [NSString stringWithFormat:@"Restart to Load %@’s Progress", others[index].deviceName];
  [restart addButtonWithTitle:@"Restart Now"];
  [restart addButtonWithTitle:@"Later"];
  if ([restart runModal] == NSAlertFirstButtonReturn) [self restartKartPad:nil];
}

- (void)showProgressSync:(id)sender {
  (void)sender;
  if (!KartPadSyncEnabled()) {
    if (![self chooseSyncFolder]) return;
  }
  for (;;) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Sync Progress";
    alert.informativeText = [NSString stringWithFormat:@"%@ · %@", KartPadSyncFolderName() ?: @"", KartPadSyncStatus()];
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Sync Now"];
    NSButton *use = [alert addButtonWithTitle:@"Use Progress From…"];
    NSButton *restart = KartPadSyncNeedsRestart() ? [alert addButtonWithTitle:@"Restart Now"] : nil;
    NSButton *change = [alert addButtonWithTitle:@"Change Folder…"];
    NSButton *off = [alert addButtonWithTitle:@"Turn Off"];
    [NSApp activateIgnoringOtherApps:YES];
    const NSModalResponse response = [alert runModal];
    const NSInteger index = response - NSAlertFirstButtonReturn;
    NSButton *pressed = index >= 0 && index < (NSInteger)alert.buttons.count ? alert.buttons[index] : nil;
    if (pressed == alert.buttons.firstObject || pressed == nil) return;
    if (pressed == use) return [self useSyncedProgress];
    if (pressed == restart) return [self restartKartPad:nil];
    if (pressed == change) {
      [self chooseSyncFolder];
      continue;
    }
    if (pressed == off) {
      KartPadSyncTurnOff();
      return;
    }
    KartPadSyncSendNow(15);  // Sync Now
  }
}

@end
