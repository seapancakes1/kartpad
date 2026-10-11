// Time Trial ghosts, as Mario Kart Wii's own .rkg files. The Ghosts screen (Settings › Game, or
// Data › Time Trial Ghosts…) shows each license's saved ghosts with the course, the time and the
// racer's Mii; A saves one to Downloads. A ghost comes in by dropping its .rkg on the game window, or
// from Import: it becomes the license's downloaded ghost for that course (the one Time Trials offer
// to race against) at the next restart, with a backup, and personal bests stay as they are. Only the
// original game's courses: the import and export live in KartPadMiiManager.mm, shared with iPhone.
// Included by KartPadMacShell.mm after KartPadReconnect.inc.mm.

#include "kartpad/mii/appearance.h"

// What a ghost file says about itself: its course, its time and the racer's Mii (when it's a valid
// one, so a stranger's file never reaches the portrait renderer otherwise). nil for a file the game
// can't use, with why.
static NSDictionary *KPGhostInfo(NSData *data, NSError **error) {
  try {
    std::span<const uint8_t> bytes((const uint8_t *)data.bytes, data.length);
    const auto info = kartpad::ghost::Validate(bytes);
    const uint32_t race = kartpad::ghost::Read32(bytes, 4);
    const auto course = std::find(kartpad::ghost::CourseIds.begin(), kartpad::ghost::CourseIds.end(), info.course);
    kartpad::ghost::Require(course != kartpad::ghost::CourseIds.end(), "Only Original race courses are supported");
    const size_t slot = size_t(course - kartpad::ghost::CourseIds.begin());
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"slot"] = @(slot);
    result[@"course"] = @(kartpad::ghost::CourseNames[slot]);
    result[@"time"] = [NSString stringWithFormat:@"%u:%02u.%03u", race >> 25, (race >> 18) & 127, (race >> 8) & 1023];
    constexpr size_t miiAt = 0x3c;
    NSData *mii = [data subdataWithRange:NSMakeRange(miiAt, kartpad::mii::kMiiBlockSize)];
    try {
      if (kartpad::mii::Appearance::Decode(std::span<const uint8_t>((const uint8_t *)mii.bytes, mii.length)).Validate()) result[@"mii"] = mii;
    } catch (const std::exception &) {
    }
    // The Mii's name: up to ten UTF-16 characters.
    NSUInteger length = 0;
    while (length < 20 && (bytes[miiAt + 2 + length] || bytes[miiAt + 3 + length])) length += 2;
    NSString *name = length ? [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(miiAt + 2, length)]
                                                    encoding:NSUTF16BigEndianStringEncoding]
                            : nil;
    if (name.length) result[@"name"] = name;
    return result;
  } catch (const std::exception &e) {
    if (error) *error = [NSError errorWithDomain:KartPadMiiManagerErrorDomain code:60
                                        userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
    return nil;
  }
}

// The original game's licenses: slot and name.
static NSArray<NSDictionary *> *KPGhostLicenses() {
  NSMutableArray *licenses = [NSMutableArray array];
  for (NSDictionary *license in KartPadLicenseRecords(nil))
    if ([license[@"profileIdentifier"] isEqual:@"original"]) [licenses addObject:license];
  [licenses sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"slot"] compare:b[@"slot"]]; }];
  return licenses;
}
static NSString *KPLicenseTitle(NSDictionary *license) {
  NSString *name = [license[@"name"] isKindOfClass:NSString.class] && [license[@"name"] length] ? license[@"name"] : nil;
  const unsigned number = [license[@"slot"] unsignedIntValue] + 1;
  return name ? [NSString stringWithFormat:@"%u · %@", number, name] : [NSString stringWithFormat:@"License %u", number];
}

// .rkg isn't a type macOS knows; one made up from the extension lets the panels pick it.
static NSArray<UTType *> *KPGhostTypes() {
  UTType *ghost = [UTType typeWithFilenameExtension:@"rkg"];
  return ghost ? @[ghost] : @[UTTypeData];
}

static void KPGhostProblem(NSString *heading, NSString *message) {
  KPUIPlay(KPUISound::Reject);
  KPAsk(heading, message, @[@"OK"], 0, -1, nil);
}

#pragma mark Importing

// Stages the ghost on a license and offers the restart that applies it. A ghost already waiting is
// replaced (only one waits at a time).
static void KPStageGhost(NSData *data, NSDictionary *info, NSDictionary *license) {
  const NSUInteger slot = [license[@"slot"] unsignedIntegerValue];
  NSString *whose = [license[@"name"] isKindOfClass:NSString.class] && [license[@"name"] length]
                        ? [NSString stringWithFormat:@"%@'s", license[@"name"]]
                        : [NSString stringWithFormat:@"License %lu's", (unsigned long)slot + 1];
  NSString *heading = [NSString stringWithFormat:@"%@ · %@", info[@"course"], info[@"time"]];
  NSString *message = [NSString stringWithFormat:@"Replaces %@ downloaded ghost for this course. Applies after a restart.", whose];
  KPAsk(heading, message, @[@"Restart Now", @"Later", @"Cancel"], 0, -1, ^(NSInteger choice) {
    if (choice == 2) return;
    NSError *error = nil;
    if (KartPadHasPendingGhost() && !KartPadCancelPendingGhost(&error)) {
      KPGhostProblem(@"Couldn't Import the Ghost", error.localizedDescription);
      return;
    }
    if (!KartPadStageOriginalGhost(data, slot, &error)) {
      KPGhostProblem(@"Couldn't Import the Ghost", error.localizedDescription ?: @"The ghost doesn't fit this save.");
      return;
    }
    AppendSessionLine([NSString stringWithFormat:@"ghostStaged=%@; license=%lu", info[@"course"], (unsigned long)slot + 1]);
    for (KPScreen *screen in KPOverlay().stack) screen.needsDisplay = YES;
    if (choice == 0) {
      KPRestartWithCurtain(@"Restarting", @"");
      return;
    }
    KPUIPlay(KPUISound::Saved);
    [KPOverlay() toast:@"Ghost ready" detail:@"Restart to race it." stripe:0 icon:^(CGContextRef c, CGRect r) {
      KPDrawGlyph(c, KPUIGlyph::Ghost, r, KPP->accentBottom);
    } image:nil];
  });
}

static void KPImportGhost(NSData *data, NSString *fileName) {
  NSError *error = nil;
  NSDictionary *info = data.length <= kartpad::ghost::GhostBytes ? KPGhostInfo(data, &error) : nil;
  if (info == nil) {
    KPGhostProblem(@"Can't Use This Ghost",
                   [NSString stringWithFormat:@"%@: %@", fileName, error.localizedDescription ?: @"Not an RKG ghost"]);
    return;
  }
  // Mii and license changes waiting for a restart have to go first; a waiting ghost can be replaced.
  const BOOL onlyGhost = KartPadHasPendingGhost() && KartPadPendingMiiChangeCount() == 1;
  if (KartPadHasPendingMiiChanges() && !onlyGhost) {
    KPAsk(@"Restart First", @"Other changes are waiting for a restart.", @[@"Restart Now", @"Cancel"], 0, -1, ^(NSInteger choice) {
      if (choice == 0) KPRestartWithCurtain(@"Restarting", @"");
    });
    return;
  }
  NSArray<NSDictionary *> *licenses = KPGhostLicenses();
  if (licenses.count == 0) {
    KPGhostProblem(@"No License Yet", @"Make a license in Mario Kart Wii first.");
    return;
  }
  if (licenses.count == 1) {
    KPStageGhost(data, info, licenses.firstObject);
    return;
  }
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  menu.heading = @"Which license?";
  for (NSDictionary *license in licenses)
    [menu add:KPLicenseTitle(license) detail:nil glyph:-1 enabled:YES run:^{ KPStageGhost(data, info, license); }];
  [KPOverlay() present:menu];
}

static void KPImportGhostFile(NSString *path) {
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  NSData *data = attributes && attributes.fileSize <= kartpad::ghost::GhostBytes ? [NSData dataWithContentsOfFile:path] : nil;
  if (data == nil) {
    KPGhostProblem(@"Can't Use This Ghost", [NSString stringWithFormat:@"%@ isn't an RKG ghost.", path.lastPathComponent]);
    return;
  }
  AppendSessionLine([NSString stringWithFormat:@"ghostFile=%@", path.lastPathComponent]);
  KPImportGhost(data, path.lastPathComponent);
}

// Choosing a file: the newest ghosts in Downloads and on the Desktop, or any file (with the mouse).
static void KPChooseGhostToImport() {
  NSFileManager *files = NSFileManager.defaultManager;
  NSMutableArray<NSURL *> *found = [NSMutableArray array];
  for (NSSearchPathDirectory place : {NSDownloadsDirectory, NSDesktopDirectory}) {
    NSURL *folder = [files URLsForDirectory:place inDomains:NSUserDomainMask].firstObject;
    for (NSURL *url in [files contentsOfDirectoryAtURL:folder includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                               options:NSDirectoryEnumerationSkipsHiddenFiles error:nil])
      if ([url.pathExtension.lowercaseString isEqualToString:@"rkg"]) [found addObject:url];
  }
  [found sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
    NSDate *first = nil, *second = nil;
    [a getResourceValue:&first forKey:NSURLContentModificationDateKey error:nil];
    [b getResourceValue:&second forKey:NSURLContentModificationDateKey error:nil];
    return [second ?: NSDate.distantPast compare:first ?: NSDate.distantPast];
  }];
  KPMenuScreen *menu = [[KPMenuScreen alloc] initWithFrame:NSZeroRect];
  menu.heading = @"Import a Ghost";
  NSInteger listed = 0;
  for (NSURL *url in found) {
    if (listed == 5) break;
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSDictionary *info = data.length <= kartpad::ghost::GhostBytes ? KPGhostInfo(data, nil) : nil;
    if (info == nil) continue;
    ++listed;
    NSString *path = url.path;
    [menu add:[NSString stringWithFormat:@"%@ · %@", info[@"course"], info[@"time"]] detail:url.lastPathComponent
        glyph:(int)KPUIGlyph::Ghost enabled:YES run:^{ KPImportGhostFile(path); }];
  }
  if (listed == 0) menu.message = @"No ghosts in Downloads or on the Desktop.";
  [menu add:@"Choose a File…" detail:@"Needs a mouse" glyph:(int)KPUIGlyph::Search enabled:YES run:^{
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowedContentTypes = KPGhostTypes();
    panel.message = @"Choose a Mario Kart Wii ghost (.rkg)";
    [panel beginSheetModalForWindow:KPGameWindow() completionHandler:^(NSModalResponse response) {
      if (response == NSModalResponseOK && panel.URL) KPImportGhostFile(panel.URL.path);
    }];
  }];
  [KPOverlay() present:menu];
}

// Files dropped on the game window (SDL turns the drop into an event). They wait while the game starts.
static NSMutableArray<NSString *> *KPDroppedGhosts = [NSMutableArray array];
static void KPGhostFileArrived(NSString *path) {
  if (KartPadGameStarting() || KPGameWindow() == nil) {
    [KPDroppedGhosts addObject:path];
    return;
  }
  if (!KPUIBackgroundAutomation()) {
    [NSApp activateIgnoringOtherApps:YES];
    [KPGameWindow() makeKeyAndOrderFront:nil];
  }
  KPImportGhostFile(path);
}
static bool SDLCALL KPGhostDropWatch(void *userdata, SDL_Event *event) {
  (void)userdata;
  if (event->type != SDL_EVENT_DROP_FILE || event->drop.data == nullptr) return true;
  NSString *path = @(event->drop.data);
  if (![path.pathExtension.lowercaseString isEqualToString:@"rkg"]) return true;
  // The drop can arrive in the game loop's event pump, inside a guest fiber.
  dispatch_async(dispatch_get_main_queue(), ^{ KPGhostFileArrived(path); });
  return true;
}
// From the game loop: start watching for drops, and handle any that came while the game started.
static void KPGhostsTick() {
  static bool watching;
  if (!watching) {
    watching = SDL_AddEventWatch(KPGhostDropWatch, nullptr);
    if (!watching) NSLog(@"[KartPad] Ghost drops not watched: %s", SDL_GetError());
  }
  if (KPDroppedGhosts.count == 0 || KartPadGameStarting()) return;
  NSString *path = KPDroppedGhosts.firstObject;
  [KPDroppedGhosts removeAllObjects];
  dispatch_async(dispatch_get_main_queue(), ^{ KPGhostFileArrived(path); });
}

#pragma mark Exporting

static NSString *KPGhostFileName(NSDictionary *info) {
  NSString *time = [[info[@"time"] stringByReplacingOccurrencesOfString:@":" withString:@"'"] copy];
  NSString *name = info[@"name"] ? [NSString stringWithFormat:@" (%@)", info[@"name"]] : @"";
  NSString *file = [NSString stringWithFormat:@"%@ %@%@", info[@"course"], time, name];
  return [[file stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByAppendingPathExtension:@"rkg"];
}

// Straight into Downloads, so a controller can do it; a save panel if KartPad may not write there.
static void KPExportGhost(NSData *data, NSDictionary *info) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *downloads = [files URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
  NSString *base = KPGhostFileName(info);
  NSURL *target = [downloads URLByAppendingPathComponent:base];
  for (int copy = 2; [files fileExistsAtPath:target.path] && copy < 100; ++copy)
    target = [downloads URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.rkg", base.stringByDeletingPathExtension, copy]];
  NSError *error = nil;
  if (downloads && [data writeToURL:target options:NSDataWritingWithoutOverwriting error:&error]) {
    AppendSessionLine([NSString stringWithFormat:@"ghostExported=%@", target.lastPathComponent]);
    KPUIPlay(KPUISound::Saved);
    [KPOverlay() toast:@"Saved to Downloads" detail:target.lastPathComponent stripe:0 icon:^(CGContextRef c, CGRect r) {
      KPDrawGlyph(c, KPUIGlyph::Export, r, KPP->accentBottom);
    } image:nil];
    return;
  }
  NSSavePanel *panel = NSSavePanel.savePanel;
  panel.nameFieldStringValue = base;
  panel.allowedContentTypes = KPGhostTypes();
  [panel beginSheetModalForWindow:KPGameWindow() completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || panel.URL == nil) return;
    NSError *writeError = nil;
    if ([data writeToURL:panel.URL options:NSDataWritingAtomic error:&writeError]) {
      KPUIPlay(KPUISound::Saved);
      return;
    }
    KPGhostProblem(@"Couldn't Save the Ghost", writeError.localizedDescription);
  }];
}

#pragma mark Ghosts screen

@interface KPGhostsScreen : KPScreen
@property(nonatomic, copy) NSArray<NSDictionary *> *licenses;
@property(nonatomic) NSInteger license;  // index into licenses
@property(nonatomic, copy) NSArray<NSDictionary *> *ghosts;  // data, downloaded, and KPGhostInfo's keys
@property(nonatomic, copy) NSString *problem;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *tiles, *licensePills;
@property(nonatomic, strong) KPUIButton *import, *done, *restart;
@property(nonatomic) NSInteger page;
@end

@implementation KPGhostsScreen
static constexpr NSInteger KPGhostColumns = 4, KPGhostRows = 3;

- (void)build {
  self.solid = YES;
  self.title = @"Time Trial Ghosts";
  __weak KPGhostsScreen *weakSelf = self;
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
  self.done.sound = KPUISound::Close;
  self.import = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Plus, @"Import");
  } action:^{ KPChooseGhostToImport(); }];
  self.import.label = @"Import a ghost";
  self.restart = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPButtonFace(c, r, KPStyle::Plain, NO, state.enabled, state.pressed, state.focused);
    const CGFloat dy = state.pressed ? 2 : 0;
    KPFill(c, CGRectInset(CGRectMake(r.origin.x, r.origin.y + dy, r.size.width, r.size.height - 3), 2, 2), KPP->caution, 6, 0.22);
    KPDrawGlyph(c, KPUIGlyph::Restart, CGRectMake(r.origin.x + 16, CGRectGetMidY(r) - 14 + dy, 26, 26), KPP->cautionInk);
    KPTextWeight(@"Restart to apply", CGRectMake(r.origin.x + 50, CGRectGetMidY(r) - 13 + dy, r.size.width - 58, 26), 19, KPP->text,
                 NSFontWeightSemibold, NSTextAlignmentLeft);
  } action:^{
    KPAskWarning(@"Restart KartPad?", @"Unsaved progress will be lost.", @[@"Restart", @"Later"], 0, -1, ^(NSInteger choice) {
      if (choice == 0) KPRestartWithCurtain(@"Restarting", @"");
    });
  }];
  self.restart.label = @"Restart to apply changes";
  self.tiles = [NSMutableArray array];
  for (NSInteger i = 0; i < KPGhostColumns * KPGhostRows; ++i) {
    KPUIButton *tile = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      [weakSelf drawTile:i context:c in:r state:state];
    } action:^{ [weakSelf exportTile:i]; }];
    tile.tag2 = i;
    tile.radius = 16;
    tile.sound = KPUISound::Press;
    [self.tiles addObject:tile];
  }
  self.licensePills = [NSMutableArray array];
  self.licenses = KPGhostLicenses();
  for (NSUInteger i = 0; i < self.licenses.count; ++i) {
    KPUIButton *pill = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      KPGhostsScreen *screen = weakSelf;
      if (i >= screen.licenses.count) return;
      const BOOL chosen = (NSInteger)i == screen.license;
      KPButtonFace(c, r, KPStyle::Tab, chosen, state.enabled, state.pressed, state.focused);
      KPTextWeight(KPLicenseTitle(screen.licenses[i]), CGRectMake(r.origin.x + 10, CGRectGetMidY(r) - 13 + (state.pressed ? 2 : 0),
                                                             r.size.width - 20, 26), 18, chosen ? 0xffffff : KPP->text,
                   NSFontWeightSemibold);
    } action:^{ [weakSelf showLicense:(NSInteger)i]; }];
    pill.tag2 = (NSInteger)i;
    pill.label = KPLicenseTitle(self.licenses[i]);
    pill.sound = KPUISound::Tab;
    pill.hidden = self.licenses.count < 2;
    [self.licensePills addObject:pill];
  }
  [self load];
}

- (void)load {
  self.problem = nil;
  self.ghosts = @[];
  if (self.licenses.count == 0) {
    self.problem = @"Make a license in Mario Kart Wii first.";
    return;
  }
  NSError *error = nil;
  NSArray<NSDictionary *> *records = KartPadOriginalGhosts([self.licenses[self.license][@"slot"] unsignedIntegerValue], &error);
  if (records == nil) self.problem = error.localizedDescription ?: @"The save couldn't be read.";
  NSMutableArray *ghosts = [NSMutableArray array];
  for (NSDictionary *record in records) {
    NSMutableDictionary *ghost = [KPGhostInfo(record[@"data"], nil) mutableCopy];
    if (ghost == nil) continue;
    ghost[@"data"] = record[@"data"];
    ghost[@"downloaded"] = record[@"downloaded"] ?: @NO;
    [ghosts addObject:ghost];
  }
  // By course, in the game's order, the personal best first.
  [ghosts sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    if (![a[@"slot"] isEqual:b[@"slot"]]) return [a[@"slot"] compare:b[@"slot"]];
    return [a[@"downloaded"] compare:b[@"downloaded"]];
  }];
  self.ghosts = ghosts;
}

- (void)showLicense:(NSInteger)index {
  if (index == self.license) return;
  self.license = index;
  self.page = 0;
  [self load];
  [self layoutDesign];
  for (KPUIButton *pill in self.licensePills) pill.needsDisplay = YES;
  self.needsDisplay = YES;
}

- (NSInteger)perPage { return KPGhostColumns * KPGhostRows; }
- (NSInteger)pages { return std::max<NSInteger>(1, ((NSInteger)self.ghosts.count + self.perPage - 1) / self.perPage); }
- (NSDictionary *)ghostAt:(NSInteger)tile {
  const NSInteger index = self.page * self.perPage + tile;
  return index >= 0 && index < (NSInteger)self.ghosts.count ? self.ghosts[index] : nil;
}

- (CGFloat)gridTop { return self.safe.origin.y + (self.licenses.count > 1 ? 196 : 130); }

- (void)layoutDesign {
  const CGRect s = self.safe;
  const CGFloat right = CGRectGetMaxX(s) - 56, y = s.origin.y + 30;
  [self place:self.done at:CGRectMake(right - 150, y, 150, 60)];
  [self place:self.import at:CGRectMake(right - 150 - 16 - 180, y, 180, 60)];
  self.restart.hidden = !KartPadHasPendingGhost();
  [self place:self.restart at:CGRectMake(right - 150 - 16 - 180 - 16 - 236, y, 236, 60)];
  const CGFloat pillWidth = 236, pillGap = 14;
  for (KPUIButton *pill in self.licensePills)
    [self place:pill at:CGRectMake(s.origin.x + 56 + pill.tag2 * (pillWidth + pillGap), s.origin.y + 120, pillWidth, 54)];
  const CGFloat w = 278, h = 128, gap = 20, x0 = s.origin.x + (1280 - (KPGhostColumns * w + (KPGhostColumns - 1) * gap)) / 2;
  for (KPUIButton *tile in self.tiles) {
    const NSInteger i = tile.tag2;
    NSDictionary *ghost = [self ghostAt:i];
    tile.hidden = ghost == nil;
    tile.label = ghost ? [NSString stringWithFormat:@"%@ %@", ghost[@"course"], [ghost[@"downloaded"] boolValue] ? @"downloaded" : @"best"] : nil;
    [self place:tile at:CGRectMake(x0 + (i % KPGhostColumns) * (w + gap), self.gridTop + (i / KPGhostColumns) * (h + 16), w, h)];
    tile.needsDisplay = YES;
  }
}

- (KPUIButton *)initialFocus { return self.ghosts.count ? self.tiles.firstObject : self.import; }

- (void)willAppear {
  // Back from importing: the restart may be waiting now.
  [self layoutDesign];
  self.needsDisplay = YES;
}

- (void)exportTile:(NSInteger)i {
  NSDictionary *ghost = [self ghostAt:i];
  if (ghost) KPExportGhost(ghost[@"data"], ghost);
}

- (BOOL)handle:(KartPadMiiPadButton)button {
  if (button != KartPadMiiPadNextTab && button != KartPadMiiPadPreviousTab) return NO;
  const NSInteger next = self.page + (button == KartPadMiiPadNextTab ? 1 : -1);
  if (next < 0 || next >= self.pages) {
    KPUIPlay(KPUISound::Reject);
    return YES;
  }
  self.page = next;
  KPUIPlay(button == KartPadMiiPadNextTab ? KPUISound::PageNext : KPUISound::PagePrevious);
  [self layoutDesign];
  [KPOverlay() focus:self.tiles.firstObject sound:NO];
  self.needsDisplay = YES;
  return YES;
}

- (void)drawTile:(NSInteger)i context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  NSDictionary *ghost = [self ghostAt:i];
  if (ghost == nil) return;
  KPButtonFace(c, r, KPStyle::Tile, NO, YES, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  const CGRect well = CGRectMake(r.origin.x + 16, r.origin.y + 18 + dy, 68, 68);
  __weak KPUIButton *tile = self.tiles[i];
  NSImage *portrait = ghost[@"mii"] ? KartPadMiiPortrait(ghost[@"mii"], ^{ tile.needsDisplay = YES; }) : nil;
  KPDrawMiiWell(c, well, portrait, KPP->accentBottom, NO);
  const BOOL downloaded = [ghost[@"downloaded"] boolValue];
  const CGFloat x = r.origin.x + 98, width = CGRectGetMaxX(r) - x - 14;
  KPTextWeight(ghost[@"course"], CGRectMake(x, r.origin.y + 14 + dy, width, 24), 17, KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
  KPTextWeight(ghost[@"time"], CGRectMake(x, r.origin.y + 40 + dy, width, 36), 28, KPP->text, NSFontWeightHeavy, NSTextAlignmentLeft);
  NSString *kind = downloaded ? @"Downloaded" : @"Personal best";
  NSString *detail = ghost[@"name"] ? [NSString stringWithFormat:@"%@ · %@", kind, ghost[@"name"]] : kind;
  KPTextWeight(detail, CGRectMake(x, r.origin.y + 82 + dy, width, 22), 15, downloaded ? KPP->secondaryText : KPP->accentBottom,
               NSFontWeightMedium, NSTextAlignmentLeft);
}

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPTextWeight(@"Time Trial Ghosts", CGRectMake(s.origin.x + 56, s.origin.y + 26, 640, 50), 36, KPP->text, NSFontWeightBold,
               NSTextAlignmentLeft);
  NSString *subtitle = self.licenses.count == 1 ? [NSString stringWithFormat:@"Mario Kart Wii · %@", KPLicenseTitle(self.licenses.firstObject)]
                                                : @"Mario Kart Wii";
  KPTextWeight(subtitle, CGRectMake(s.origin.x + 58, s.origin.y + 76, 640, 26), 18, KPP->secondaryText, NSFontWeightMedium,
               NSTextAlignmentLeft);
  NSString *empty = self.problem ?: self.ghosts.count ? nil : @"No ghosts on this license yet.";
  if (empty)
    KPTextWeight(empty, CGRectMake(s.origin.x + 56, self.gridTop + 150, 1168, 30), 20, KPP->secondaryText, NSFontWeightMedium);
  std::vector<KPHint> hints = {{KartPadMiiPadBack, @"Back"}};
  if (self.ghosts.count) hints.insert(hints.begin(), {KartPadMiiPadConfirm, @"Save to Downloads"});
  if (self.pages > 1)
    hints.insert(hints.begin(), {KartPadMiiPadPreviousTab, [NSString stringWithFormat:@"Page %ld of %ld", (long)self.page + 1,
                                                            (long)self.pages], KartPadMiiPadNextTab});
  KPDrawHints(c, CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26), hints, 16, NSTextAlignmentRight);
  KPTextWeight(@"Drop an .rkg file here to import it.", CGRectMake(s.origin.x + 56, s.origin.y + 670, 600, 26), 16,
               KPP->secondaryText, NSFontWeightRegular, NSTextAlignmentLeft);
}

@end

static KPScreen *KPMakeGhostsScreen() { return [[KPGhostsScreen alloc] initWithFrame:NSZeroRect]; }
