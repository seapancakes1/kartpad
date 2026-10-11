// Getting Retro Rewind for the player: the exact pack this KartPad plays (the archive and update
// pinned in its release header, size and SHA-256 checked before anything is unpacked), unpacked
// with macOS's own ditto, checked as the game checks it, and installed in KartPad's data folder
// (RetroRewind/RetroRewind6, its saves beside it). It keeps going while the game plays; a toast
// says when it's ready. Builds whose Retro Rewind is kept up to date by the local auto-updater
// leave it to that and don't offer the download. Dual builds only; included by KartPadMacShell.mm.

#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)

typedef NS_ENUM(NSInteger, KPRetroStage) {
  KPRetroIdle, KPRetroDownloading, KPRetroVerifying, KPRetroInstalling, KPRetroReady, KPRetroFailed
};

struct KPRetroArchive {
  NSString *__strong url, *__strong sha256;
  uint64_t bytes;
};

@interface KPRetroDownload : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic) KPRetroStage stage;
@property(nonatomic) double progress;  // of the current stage
@property(nonatomic) int64_t done, total;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) CFTimeInterval stageStarted;
+ (instancetype)shared;
- (BOOL)available;
- (void)start;
- (void)cancel;
- (NSString *)summary;
// Automated checks: a small archive in place of the pack (it fails at the final check, by design).
- (void)startWith:(KPRetroArchive)archive;
@end

static NSString *KPBytesText(int64_t bytes) {
  return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *KPRetroFolder() {
  return [ApplicationSupportURL().path stringByAppendingPathComponent:@"RetroRewind"];
}

@implementation KPRetroDownload {
  NSURLSession *_session;
  NSURLSessionDownloadTask *_task;
  std::vector<KPRetroArchive> _archives;
  size_t _current;
  NSMutableArray<NSString *> *_files;
  BOOL _cancelled;
  // Each run (and each cancel) moves this on; work from an older run stops where it notices.
  std::atomic<uint64_t> _generation;
}

+ (instancetype)shared {
  static KPRetroDownload *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [KPRetroDownload new]; });
  return shared;
}

- (BOOL)available {
  return strlen(KARTPAD_RR_ARCHIVE_URL) > 0 && KPLocalUpdateSettings() == nil;
}

- (BOOL)busy { return self.stage == KPRetroDownloading || self.stage == KPRetroVerifying || self.stage == KPRetroInstalling; }

- (void)setStage:(KPRetroStage)stage {
  _stage = stage;
  self.stageStarted = CACurrentMediaTime();
  self.progress = 0;
}

- (NSString *)summary {
  switch (self.stage) {
    case KPRetroIdle: return @"Not downloaded";
    case KPRetroDownloading: return [NSString stringWithFormat:@"Downloading %d%%", (int)std::lround(self.progress * 100)];
    case KPRetroVerifying: return @"Checking the download";
    case KPRetroInstalling: return @"Installing";
    case KPRetroReady: return @"Ready";
    case KPRetroFailed: return @"Didn't finish";
  }
  return @"";
}

- (void)start {
  std::vector<KPRetroArchive> archives{{@KARTPAD_RR_ARCHIVE_URL, @KARTPAD_RR_ARCHIVE_SHA256, KARTPAD_RR_ARCHIVE_BYTES}};
  if (strlen(KARTPAD_RR_UPDATE_URL)) archives.push_back({@KARTPAD_RR_UPDATE_URL, @KARTPAD_RR_UPDATE_SHA256, KARTPAD_RR_UPDATE_BYTES});
  [self begin:archives];
}

- (void)startWith:(KPRetroArchive)archive { [self begin:{archive}]; }

- (void)begin:(std::vector<KPRetroArchive>)archives {
  if (self.busy) return;
  _archives = archives;
  _current = 0;
  _files = [NSMutableArray array];
  _cancelled = NO;
  ++_generation;
  self.problem = nil;
  // Room for the downloads, the unpacked pack and a little over.
  uint64_t needed = 256ull << 20;
  for (const KPRetroArchive &archive : archives) needed += archive.bytes;
  needed += KARTPAD_RR_MAXIMUM_EXPANDED_BYTES + KARTPAD_RR_UPDATE_MAXIMUM_EXPANDED_BYTES;
  NSNumber *free = nil;
  [[NSURL fileURLWithPath:ApplicationSupportURL().path] getResourceValue:&free
                                                                  forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
  if (free && free.unsignedLongLongValue < needed) {
    [self fail:[NSString stringWithFormat:@"It needs %@ free while it installs; this Mac has %@. Free some space and try again.",
                KPBytesText((int64_t)needed), KPBytesText(free.longLongValue)]];
    return;
  }
  AppendSessionLine(@"retroDownload=started");
  [self downloadNext];
}

- (void)downloadNext {
  if (_current >= _archives.size()) {
    [self install];
    return;
  }
  self.stage = KPRetroDownloading;
  self.total = (int64_t)_archives[_current].bytes;
  self.done = 0;
  if (_session == nil) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.timeoutIntervalForResource = 6 * 3600;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
  }
  _task = [_session downloadTaskWithURL:[NSURL URLWithString:_archives[_current].url]];
  [_task resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
    totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
  (void)session;
  (void)written;
  if (task != _task) return;
  self.done = total;
  if (expected > 0) self.total = expected;
  self.progress = self.total > 0 ? (double)total / self.total : 0;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
  (void)session;
  if (task != _task || _cancelled) return;
  NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
  if ([response isKindOfClass:NSHTTPURLResponse.class] && response.statusCode != 200) {
    [self fail:[NSString stringWithFormat:@"The download server answered %ld.", (long)response.statusCode]];
    return;
  }
  NSString *folder = [KPRetroFolder() stringByAppendingPathComponent:@"Downloads"];
  [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *file = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"archive-%zu.zip", _current]];
  [NSFileManager.defaultManager removeItemAtPath:file error:nil];
  NSError *error = nil;
  if (![NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:file] error:&error]) {
    [self fail:@"KartPad couldn't keep the download. Check its data folder can be written."];
    return;
  }
  [_files addObject:file];
  [self verify:file archive:_archives[_current]];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  (void)session;
  if (task != _task) return;
  if (error && !_cancelled) [self fail:@"The download stopped. Check the internet connection and try again."];
}

// Size and SHA-256, read in chunks off the main thread.
- (void)verify:(NSString *)file archive:(KPRetroArchive)archive {
  self.stage = KPRetroVerifying;
  const uint64_t generation = _generation;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:file];
    const uint64_t size = [[NSFileManager.defaultManager attributesOfItemAtPath:file error:nil] fileSize];
    BOOL good = handle != nil && size == archive.bytes;
    if (good) {
      CC_SHA256_CTX context;
      CC_SHA256_Init(&context);
      uint64_t read = 0;
      for (;;) {
        @autoreleasepool {
          NSData *chunk = [handle readDataOfLength:8 << 20];
          if (chunk.length == 0) break;
          CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
          read += chunk.length;
          const double fraction = (double)read / size;
          dispatch_async(dispatch_get_main_queue(), ^{ self.progress = fraction; });
        }
      }
      unsigned char digest[CC_SHA256_DIGEST_LENGTH];
      CC_SHA256_Final(digest, &context);
      NSMutableString *hex = [NSMutableString string];
      for (unsigned char byte : digest) [hex appendFormat:@"%02x", byte];
      good = [hex isEqualToString:archive.sha256];
    }
    [handle closeFile];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self->_generation) {
        [NSFileManager.defaultManager removeItemAtPath:file error:nil];
        return;
      }
      if (!good) {
        [NSFileManager.defaultManager removeItemAtPath:file error:nil];
        [self fail:@"The download was damaged. Try again."];
        return;
      }
      ++self->_current;
      [self downloadNext];
    });
  });
}

// Unpacked into a staging folder next to the final one, checked, then moved into place.
- (void)install {
  self.stage = KPRetroInstalling;
  NSArray<NSString *> *archives = _files.copy;
  const uint64_t generation = _generation;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *base = KPRetroFolder();
    NSString *staging = [base stringByAppendingPathComponent:[@"Staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [files createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *problem = nil;
    for (NSUInteger i = 0; i < archives.count && !problem; ++i) {
      NSTask *ditto = [NSTask new];
      ditto.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
      ditto.arguments = @[@"-x", @"-k", archives[i], staging];
      ditto.standardOutput = NSFileHandle.fileHandleWithNullDevice;
      ditto.standardError = NSFileHandle.fileHandleWithNullDevice;
      NSError *error = nil;
      if (![ditto launchAndReturnError:&error]) problem = @"macOS couldn't unpack the download.";
      else {
        [ditto waitUntilExit];
        if (ditto.terminationStatus != 0) problem = @"The download couldn't be unpacked. Try again.";
      }
      const double fraction = (double)(i + 1) / archives.count;
      dispatch_async(dispatch_get_main_queue(), ^{ self.progress = fraction * 0.9; });
    }
    // The pack's folder, at the top or one level in.
    NSString *found = nil;
    for (NSString *candidate in @[[staging stringByAppendingPathComponent:@KARTPAD_RR_ROOT]]) {
      BOOL directory = NO;
      if ([files fileExistsAtPath:candidate isDirectory:&directory] && directory) found = candidate;
    }
    if (!found && !problem)
      for (NSString *name in [files contentsOfDirectoryAtPath:staging error:nil]) {
        NSString *candidate = [[staging stringByAppendingPathComponent:name] stringByAppendingPathComponent:@KARTPAD_RR_ROOT];
        BOOL directory = NO;
        if ([files fileExistsAtPath:candidate isDirectory:&directory] && directory) found = candidate;
      }
    if (!found && !problem) problem = [NSString stringWithFormat:@"The download had no %@ folder.", @KARTPAD_RR_ROOT];
    if (!problem) {
      NSError *error = nil;
      NSString *validation = ValidateRetroRewindRoot(found, &error);
      if (validation || error) problem = validation ?: @"The unpacked pack didn't pass KartPad's check.";
    }
    NSString *destination = [base stringByAppendingPathComponent:@KARTPAD_RR_ROOT];
    const BOOL cancelled = generation != self->_generation;
    if (!problem && !cancelled) {
      NSString *previous = [base stringByAppendingPathComponent:[@"Previous-" stringByAppendingString:NSUUID.UUID.UUIDString]];
      if ([files fileExistsAtPath:destination]) [files moveItemAtPath:destination toPath:previous error:nil];
      NSError *error = nil;
      if (![files moveItemAtPath:found toPath:destination error:&error]) {
        if ([files fileExistsAtPath:previous]) [files moveItemAtPath:previous toPath:destination error:nil];
        problem = @"KartPad couldn't put Retro Rewind in place.";
      } else {
        [files removeItemAtPath:previous error:nil];
      }
    }
    [files removeItemAtPath:staging error:nil];
    for (NSString *archive in archives) [files removeItemAtPath:archive error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (cancelled || generation != self->_generation) return;
      if (problem) {
        [self fail:problem];
        return;
      }
      [self installed:destination];
    });
  });
}

- (void)installed:(NSString *)root {
  // Retro Rewind keeps its saves beside its folder; bring the old ones along.
  NSString *old = ConfiguredRetroRewindRoot();
  NSString *oldSaves = [old.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"riivolution"];
  NSString *newSaves = [root.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"riivolution"];
  NSFileManager *files = NSFileManager.defaultManager;
  if (old.length && ![oldSaves isEqualToString:newSaves] && [files fileExistsAtPath:oldSaves] && ![files fileExistsAtPath:newSaves])
    [files copyItemAtPath:oldSaves toPath:newSaves error:nil];
  if (!WriteRetroRewindRoot(root)) {
    [self fail:@"Retro Rewind is installed, but KartPad couldn't save where. Check its settings file can be written."];
    return;
  }
  self.stage = KPRetroReady;
  AppendSessionLine(@"retroDownload=ready");
  if ([RunningRuntimeProfile() isEqualToString:kKartPadRetroProfile]) [Controller() setRestartNeeded:YES for:@"retro-data"];
  KPUIPlay(KPUISound::Saved);
  [KPOverlay() toast:@"Retro Rewind is ready" detail:@"Switch to it from HOME." stripe:0 icon:^(CGContextRef c, CGRect r) {
    KPDrawGlyph(c, KPUIGlyph::Check, r, 0x22843f);
  } image:nil seconds:6];
}

- (void)fail:(NSString *)problem {
  // Nothing half-done stays behind (a verified first archive is 2 GB).
  for (NSString *file in _files) [NSFileManager.defaultManager removeItemAtPath:file error:nil];
  [_files removeAllObjects];
  self.problem = problem;
  self.stage = KPRetroFailed;
  AppendSessionLine(@"retroDownload=failed");
  KPUIPlay(KPUISound::Reject);
  [KPOverlay() toast:@"Retro Rewind didn't finish" detail:problem stripe:0 icon:^(CGContextRef c, CGRect r) {
    KPDrawGlyph(c, KPUIGlyph::Close, r, 0xd0342c);
  } image:nil seconds:6];
}

- (void)cancel {
  _cancelled = YES;
  ++_generation;
  [_task cancel];
  _task = nil;
  // While unpacking, the install step tidies its own files once ditto lets go of them.
  if (self.stage != KPRetroInstalling)
    for (NSString *file in _files) [NSFileManager.defaultManager removeItemAtPath:file error:nil];
  self.stage = KPRetroIdle;
  AppendSessionLine(@"retroDownload=cancelled");
}
@end

// Its progress, on a card. Before it starts (or after it failed) Download leads, with Not Now beside
// it; while it runs, Keep Playing (it carries on) and Cancel.
@interface KPRetroDownloadScreen : KPScreen
@property(nonatomic, strong) KPUIButton *keep, *cancel, *retry;
@end

@implementation KPRetroDownloadScreen
- (void)build {
  self.solid = YES;
  __weak KPRetroDownloadScreen *weakSelf = self;
  self.keep = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPRetroDownload *download = KPRetroDownload.shared;
    const BOOL waiting = !download.busy && download.stage != KPRetroReady;
    KPDrawPill(c, r, state, waiting ? KPStyle::Plain : KPStyle::Primary,
               download.busy ? KPUIGlyph::Play : waiting ? KPUIGlyph::Close : KPUIGlyph::Check,
               download.stage == KPRetroReady ? @"Done" : download.busy ? @"Keep Playing" : @"Not Now");
  } action:^{ [KPOverlay() pop]; }];
  self.cancel = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Close, @"Cancel Download");
  } action:^{
    [KPRetroDownload.shared cancel];
    [weakSelf layoutDesign];
  }];
  self.retry = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    const BOOL first = KPRetroDownload.shared.stage == KPRetroIdle;
    KPDrawPill(c, r, state, KPStyle::Primary, first ? KPUIGlyph::Play : KPUIGlyph::Restart, first ? @"Download" : @"Try Again");
  } action:^{
    [KPRetroDownload.shared start];
    [weakSelf layoutDesign];
  }];
}
- (void)layoutDesign {
  const CGRect s = self.safe;
  KPRetroDownload *download = KPRetroDownload.shared;
  const BOOL waiting = !download.busy && download.stage != KPRetroReady;
  const BOOL changed = self.retry.hidden == waiting;
  self.cancel.hidden = !download.busy;
  self.retry.hidden = !waiting;
  // The main choice on the left: Download (or Try Again) while waiting, otherwise Keep Playing.
  const CGRect left = CGRectMake(s.origin.x + 330, s.origin.y + 520, 290, 70), right = CGRectOffset(left, 330, 0);
  [self place:self.retry at:left];
  [self place:self.keep at:waiting ? right : left];
  [self place:self.cancel at:right];
  if (changed && self.focus.hidden) [KPOverlay() focus:[self initialFocus] sound:NO];
}
- (KPUIButton *)initialFocus { return self.retry.hidden ? self.keep : self.retry; }
- (void)tick {
  [self layoutDesign];
  self.needsDisplay = YES;
}
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPRetroDownload *download = KPRetroDownload.shared;
  KPTextWeight(@"Retro Rewind", CGRectMake(s.origin.x + 56, s.origin.y + 26, 600, 50), 36, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  KPTextWeight([NSString stringWithFormat:@"Version %@ · 200+ extra tracks", @KARTPAD_RR_VERSION],
               CGRectMake(s.origin.x + 58, s.origin.y + 78, 760, 26), 18, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  const CGRect card = CGRectMake(s.origin.x + 240, s.origin.y + 170, 800, 300);
  KPCard(c, card, 26);
  NSString *title = @"", *detail = @"";
  switch (download.stage) {
    case KPRetroIdle: title = @"Get Retro Rewind"; detail = @"About 2 GB. You can play while it downloads."; break;
    case KPRetroDownloading:
      title = @"Downloading…";
      detail = download.done > 0 ? [NSString stringWithFormat:@"%@ of %@", KPBytesText(download.done), KPBytesText(download.total)]
                                 : @"Starting…";
      break;
    case KPRetroVerifying: title = @"Checking the download…"; detail = @""; break;
    case KPRetroInstalling: title = @"Installing…"; detail = @"Unpacking the files."; break;
    case KPRetroReady: title = @"Retro Rewind is ready"; detail = @"Switch to it from HOME."; break;
    case KPRetroFailed: title = @"It didn't finish"; detail = download.problem ?: @"Try again."; break;
  }
  KPTextWeight(title, CGRectMake(card.origin.x + 40, card.origin.y + 44, card.size.width - 80, 44), 32, KPP->text, NSFontWeightBold);
  KPTextWeight(detail, CGRectMake(card.origin.x + 40, card.origin.y + 96, card.size.width - 80, 60), 19, KPP->secondaryText,
               NSFontWeightMedium);
  if (download.busy) {
    const CGRect track = CGRectMake(card.origin.x + 60, card.origin.y + 190, card.size.width - 120, 20);
    KPFill(c, track, KPP->well, 10);
    KPStroke(c, track, KPP->buttonStroke, 1, 10);
    const CGFloat fill = track.size.width * std::clamp(download.progress, 0.0, 1.0);
    if (fill > 4) KPGradientFill(c, CGRectMake(track.origin.x + 1, track.origin.y + 1, fill - 2, track.size.height - 2), 9,
                                 KPP->accentTop, KPP->accentBottom);
    KPTextWeight([NSString stringWithFormat:@"%d%%", (int)std::lround(download.progress * 100)],
                 CGRectMake(card.origin.x + 40, card.origin.y + 222, card.size.width - 80, 30), 19, KPP->text, NSFontWeightSemibold);
  }
}
@end

static BOOL KPRetroDownloadOffered() { return KPRetroDownload.shared.available; }

static void KPShowRetroDownload(BOOL start) {
  if (start) [KPRetroDownload.shared start];
  [KPOverlay() present:[[KPRetroDownloadScreen alloc] initWithFrame:NSZeroRect]];
}

#endif
