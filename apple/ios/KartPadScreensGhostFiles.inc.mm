// Ghost files on iPhone and iPad (in place of the Mac's folder, open and save panels and window
// drops): Import picks a .rkg in Files, and a ghost goes out through the share sheet (Save to Files,
// AirDrop, another app). Included by apple/macos/KartPadGhostsScreen.inc.mm.

static void KPChooseGhostToImport() {
  KPScreensChooseFile(KPGhostTypes(), ^(NSURL *url) {
    if (url) KPImportGhostFile(url.path);
  });
}

// Files reach iOS through Import alone; nothing is dropped on the game.
static void KPGhostsTick() {}

static NSString *KPGhostFileName(NSDictionary *info) {
  NSString *time = [[info[@"time"] stringByReplacingOccurrencesOfString:@":" withString:@"'"] copy];
  NSString *name = info[@"name"] ? [NSString stringWithFormat:@" (%@)", info[@"name"]] : @"";
  NSString *file = [NSString stringWithFormat:@"%@ %@%@", info[@"course"], time, name];
  return [[file stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByAppendingPathExtension:@"rkg"];
}

static void KPExportGhost(NSData *data, NSDictionary *info) {
  NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Ghosts"];
  [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  NSURL *file = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:KPGhostFileName(info)]];
  NSError *error = nil;
  if (![data writeToURL:file options:NSDataWritingAtomic error:&error]) {
    KPGhostProblem(@"Couldn’t Save the Ghost", error.localizedDescription);
    return;
  }
  AppendSessionLine([NSString stringWithFormat:@"ghostExported=%@", file.lastPathComponent]);
  KPScreensShareFile(file);
}
