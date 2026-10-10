// HOME: what the HOME / Guide / PS button (or Esc) opens over the game, in the spirit of the Wii's
// HOME Menu. The game holds still underneath (dimmed), a bar slides down from the top and the
// players' strip up from the bottom, and the big tiles in between do the everyday things: carry on,
// switch games, Miis, controllers. The volume has a row of its own (left and right only ever change
// it); full screen, Settings and Quit sit in the top bar, with a pending restart beside them.
// Included by KartPadMacShell.mm after the overlay.

extern "C" bool Network_HLE_HasOpenSockets();
extern "C" bool KartPadGameStarting();
static NSString *const KPHomeHintCountKey = @"KartPadHomeHintShownCount";
static NSString *const KPHomeOpenedCountKey = @"KartPadHomeOpenedCount";

static NSString *KPPlayerName(int slot) { return [NSString stringWithFormat:@"Player %d", slot + 1]; }
static NSString *KPGameTitle(NSString *profile) {
  return [profile isEqualToString:kKartPadRetroProfile] ? @"Retro Rewind" : @"Mario Kart Wii";
}
// The game this process plays (only the two-game build can play Retro Rewind).
static NSString *KPRunningProfile() {
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  return RunningRuntimeProfile();
#else
  return kKartPadBaseProfile;
#endif
}
static NSString *KPOtherProfile() {
  return [KPRunningProfile() isEqualToString:kKartPadRetroProfile] ? kKartPadBaseProfile : kKartPadRetroProfile;
}
static BOOL KPRetroRewindReady() {
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  NSError *error = nil;
  return ValidateRetroRewindRoot(ConfiguredRetroRewindRoot(), &error) == nil && error == nil;
#else
  return NO;
#endif
}
static BOOL KPCanSwitchGames() {
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  return YES;
#else
  return NO;
#endif
}

// Changes waiting for a restart, as what the restart will do ("start Retro Rewind").
static NSArray<NSString *> *KPRestartReasonsText() {
  NSMutableArray *reasons = [NSMutableArray array];
  NSSet *pending = Controller().restartReasons;
  if ([pending containsObject:@"game"]) [reasons addObject:[NSString stringWithFormat:@"start %@", KPGameTitle(KPOtherProfile())]];
  if (KartPadHasPendingMiiChanges()) [reasons addObject:@"apply your Mii changes"];
  if ([pending containsObject:@"game-data"] || [pending containsObject:@"retro-data"]) [reasons addObject:@"use the new game files"];
  if ([pending containsObject:@"online-service"]) [reasons addObject:@"switch the online service"];
  if ([pending containsObject:@"vsync"] || [pending containsObject:@"notch"]) [reasons addObject:@"apply your display settings"];
  return reasons;
}
// "a, b and c"
static NSString *KPListText(NSArray<NSString *> *items) {
  if (items.count < 2) return items.firstObject ?: @"";
  return [[[items subarrayWithRange:NSMakeRange(0, items.count - 1)] componentsJoinedByString:@", "]
      stringByAppendingFormat:@" and %@", items.lastObject];
}
static BOOL KPRestartWaiting() { return Controller().restartPending || KartPadHasPendingMiiChanges(); }

// Restarting (to switch game or apply changes) goes through the curtain, which keeps the window
// covered while KartPad restarts (KartPadCurtain.inc.mm).
static void KPRestartWithCurtain(NSString *heading, NSString *detail);

static float KPConfiguredVolume() {
  const RuntimeUserConfig config = RuntimeConfigFile::LoadConfigFile();
  return std::clamp(config.audioVolume.value_or(1.0f), 0.0f, 1.0f);
}
static bool KPConfiguredMute() { return RuntimeConfigFile::LoadConfigFile().audioMuted.value_or(false); }
static void KPWriteVolume(float volume, bool muted) {
  std::ostringstream stream;
  stream << std::round(std::clamp(volume, 0.0f, 1.0f) * 100) / 100.0;
  RuntimeConfigFile::WriteSetting("audio", "volume", stream.str());
  RuntimeConfigFile::WriteSetting("audio", "muted", muted ? "true" : "false");
  KartPadRequestSettingsReload();
}

#pragma mark Faces shared by the screens

// A tile on a screen: a big icon, a title and a line under it.
static void KPDrawTile(CGContextRef c, CGRect r, KPUIState state, BOOL primary, KPUIGlyph glyph, NSString *title,
                       NSString *detail, unsigned iconInk = 0) {
  KPButtonFace(c, r, primary ? KPStyle::Primary : KPStyle::Card, NO, state.enabled, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  const unsigned ink = primary ? 0xffffff : KPP->text, sub = primary ? 0xeaf7fd : KPP->secondaryText;
  const CGFloat icon = std::min<CGFloat>(78, r.size.height * 0.34);
  if ((int)glyph >= 0)
    KPDrawGlyph(c, glyph, CGRectMake(CGRectGetMidX(r) - icon / 2, r.origin.y + r.size.height * 0.17 + dy, icon, icon),
                iconInk ? iconInk : primary ? 0xffffff : KPP->accentBottom);
  const CGFloat titleY = r.origin.y + r.size.height * (detail.length ? 0.58 : 0.64) + dy;
  KPTextWeight(title, CGRectMake(r.origin.x + 10, titleY, r.size.width - 20, 34), 26, ink, NSFontWeightSemibold);
  if (detail.length)
    KPTextWeight(detail, CGRectMake(r.origin.x + 12, r.origin.y + r.size.height * 0.58 + 36 + dy, r.size.width - 24, 24), 17,
                 sub, NSFontWeightMedium);
}

// A pill button: an icon and a word.
static void KPDrawPill(CGContextRef c, CGRect r, KPUIState state, KPStyle style, KPUIGlyph glyph, NSString *title,
                       unsigned tint = 0) {
  KPButtonFace(c, r, style, NO, state.enabled, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  const unsigned ink = style == KPStyle::Primary ? 0xffffff : tint ? tint : KPP->text;
  const CGFloat iconSize = std::min<CGFloat>(30, r.size.height - 26);
  const CGSize text = title.length ? KPTextSize(title, 21, NSFontWeightSemibold) : CGSizeZero;
  const CGFloat width = iconSize + (title.length ? 10 + text.width : 0);
  const CGFloat x = CGRectGetMidX(r) - width / 2;
  KPDrawGlyph(c, glyph, CGRectMake(x, CGRectGetMidY(r) - iconSize / 2 - 1 + dy, iconSize, iconSize),
              style == KPStyle::Primary ? 0xffffff : tint ? tint : KPP->accentBottom);
  if (title.length)
    KPTextWeight(title, CGRectMake(x + iconSize + 10, CGRectGetMidY(r) - 15 + dy, text.width + 4, 30), 21, ink,
                 NSFontWeightSemibold, NSTextAlignmentLeft);
}

// A Mii face in a well, or a silhouette in the player's colour while there's none.
static void KPDrawMiiWell(CGContextRef c, CGRect well, NSImage *portrait, unsigned color, BOOL empty) {
  KPFill(c, well, KPLightPalette.well, well.size.width * 0.22);
  if (portrait) {
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    [portrait drawInRect:CGRectInset(well, well.size.width * 0.06, well.size.height * 0.06) fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES
                   hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    NSGraphicsContext.currentContext = previous;
  } else {
    const CGFloat s = well.size.width;
    KPFill(c, CGRectMake(CGRectGetMidX(well) - s * 0.19, well.origin.y + s * 0.16, s * 0.38, s * 0.42), color, s * 0.19,
           empty ? 0.18 : 0.5);
    KPFill(c, CGRectMake(CGRectGetMidX(well) - s * 0.31, well.origin.y + s * 0.63, s * 0.62, s * 0.3), color, s * 0.12,
           empty ? 0.12 : 0.36);
  }
}

// A Mii's favourite colour (Red, Orange, Yellow, Light green, Green, Blue, Light blue, Pink, Purple,
// Brown, White, Black), for its silhouette before the portrait is drawn.
static unsigned KPFavoriteColorHex(NSDictionary *record) {
  static const unsigned colors[12] = {0xd21e14, 0xff6e19, 0xffd820, 0x78d220, 0x007830, 0x0a48b4, 0x3caade, 0xf55a7d,
                                      0x7328ad, 0x483818, 0xe0e0e0, 0x181814};
  const unsigned index = [record[@"favoriteColor"] unsignedIntValue];
  return colors[index < 12 ? index : 0];
}

// A player's number in their colour.
static void KPDrawPlayerBadge(CGContextRef c, CGRect r, int slot, BOOL dim) {
  KPSetInk(c, KPPlayerColors[slot], dim ? 0.35 : 1);
  CGContextFillEllipseInRect(c, r);
  KPSetInk(c, KPPlayerDarkColors[slot], dim ? 0.3 : 0.9);
  CGContextSetLineWidth(c, 1.5);
  CGContextStrokeEllipseInRect(c, CGRectInset(r, 0.75, 0.75));
  KPTextWeight([NSString stringWithFormat:@"%d", slot + 1], CGRectMake(r.origin.x, CGRectGetMidY(r) - r.size.height * 0.36, r.size.width,
               r.size.height * 0.75), r.size.height * 0.56, dim ? KPP->secondaryText : KPPlayerInk[slot], NSFontWeightHeavy);
}

static void KPDrawBattery(CGContextRef c, CGRect r, KPPadDevice *device) {
  if (device.isKeyboard || (device.battery < 0 && !device.wired)) return;
  if (device.battery < 0) {
    KPDrawGlyph(c, KPUIGlyph::Battery, r, KPP->secondaryText, device.charging ? 1 : 0);
    return;
  }
  const unsigned ink = device.battery <= 15 && !device.charging ? 0xd0342c : KPP->secondaryText;
  KPDrawGlyph(c, KPUIGlyph::Battery, r, ink, device.battery / 100.0);
}

// The player's Mii portrait, asking for it (and redrawing view) when it isn't rendered yet.
static NSImage *KPPortraitFor(KPPadDevice *device, NSView *view) {
  NSData *mii = [KPControllerRoster.shared miiFor:device];
  if (mii == nil) return nil;
  __weak NSView *weakView = view;
  return KartPadMiiPortrait(mii, ^{ weakView.needsDisplay = YES; });
}

#pragma mark HOME screen

@class KPControllersScreen;
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
static void KPShowRetroDownload(BOOL start);  // KartPadRetroDownload.inc.mm
static BOOL KPRetroDownloadOffered();
#endif
static KPControllersScreen *KPMakeControllersScreen(int focusSlot);
static KPScreen *KPMakeControllersScreenFor(int slot);
static KPScreen *KPMakeSettingsScreen();
static KPScreen *KPMakeMiisScreen();

@interface KPHomeScreen : KPScreen <KPRosterListener>
@property(nonatomic, strong) KPUIView *topBar, *bottomBar;
@property(nonatomic, strong) KPUIButton *resume, *switchGame, *miis, *controllers, *volume, *displayToggle, *settings, *quit,
    *restart;
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *slots;
@property(nonatomic) NSInteger miiCount;
@property(nonatomic, copy) NSArray<NSDictionary *> *miiFaces;
@property(nonatomic) float shownVolume;
@property(nonatomic) BOOL shownMute, canPause;
@end

@implementation KPHomeScreen

- (void)build {
  self.title = @"HOME";
  __weak KPHomeScreen *weakSelf = self;
  self.topBar = [[KPUIView alloc] initWithFrame:NSZeroRect];
  self.topBar.paint = ^(CGContextRef c, CGSize size) { [weakSelf drawTopBar:c size:size]; };
  self.bottomBar = [[KPUIView alloc] initWithFrame:NSZeroRect];
  self.bottomBar.paint = ^(CGContextRef c, CGSize size) { [weakSelf drawBottomBar:c size:size]; };
  [self addSubview:self.topBar];
  [self addSubview:self.bottomBar];

  self.resume = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawTile(c, r, state, YES, KPUIGlyph::Play, @"Resume", nil);
  } action:^{ [KPOverlay() closeAll]; }];
  self.resume.label = @"Resume";
  self.resume.sound = KPUISound::Confirm;

  self.switchGame = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    const BOOL ready = KPRetroRewindReady() || [KPOtherProfile() isEqualToString:kKartPadBaseProfile];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
    NSString *detail = ready ? @"Switch game" : KPRetroDownloadOffered() ? @"Download first" : @"Set up first";
#else
    NSString *detail = ready ? @"Switch game" : @"Set up first";
#endif
    KPDrawTile(c, r, state, NO, KPUIGlyph::Swap, KPGameTitle(KPOtherProfile()), detail);
  } action:^{ [weakSelf askToSwitch]; }];
  self.switchGame.label = [NSString stringWithFormat:@"Switch to %@", KPGameTitle(KPOtherProfile())];
  self.switchGame.hidden = !KPCanSwitchGames();

  // The Miis tile shows up to three of the player's Miis, overlapping, instead of an icon.
  self.miis = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPHomeScreen *home = weakSelf;
    NSInteger count = home.miiCount;
    NSArray<NSDictionary *> *faces = home.miiFaces;
    (void)count;
    KPDrawTile(c, r, state, NO, faces.count ? (KPUIGlyph)-1 : KPUIGlyph::Mii, @"Miis", nil);
    if (!faces.count) return;
    const CGFloat size = 96, dy = state.pressed ? 2 : 0, overlap = 30;
    const CGFloat width = size + (faces.count - 1) * (size - overlap);
    CGFloat x = CGRectGetMidX(r) - width / 2;
    for (NSDictionary *record in faces) {
      __weak KPUIButton *tile = home.miis;
      NSImage *portrait = KartPadMiiPortrait(record[@"mii"], ^{ tile.needsDisplay = YES; });
      const CGRect well = CGRectMake(x, r.origin.y + r.size.height * 0.12 + dy, size, size);
      KPFill(c, CGRectInset(well, -3, -3), KPP->panel, size * 0.25);
      KPDrawMiiWell(c, well, portrait, KPFavoriteColorHex(record), NO);
      x += size - overlap;
    }
  } action:^{ [KPOverlay() present:KPMakeMiisScreen()]; }];
  self.miis.label = @"Miis";

  self.controllers = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawTile(c, r, state, NO, KPUIGlyph::Pad, @"Controllers", nil);
  } action:^{ [KPOverlay() present:(KPScreen *)KPMakeControllersScreen(-1)]; }];
  self.controllers.label = @"Controllers";

  // Volume: left and right change it in steps, A mutes.
  self.volume = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPHomeScreen *home = weakSelf;
    KPButtonFace(c, r, KPStyle::Plain, NO, state.enabled, state.pressed, state.focused);
    const BOOL muted = home.shownMute;
    const float volume = home.shownVolume;
    KPDrawGlyph(c, muted ? KPUIGlyph::SpeakerOff : KPUIGlyph::Speaker, CGRectMake(r.origin.x + 20, CGRectGetMidY(r) - 17, 34, 34),
                muted ? KPP->secondaryText : KPP->accentBottom, volume);
    const CGRect track = CGRectMake(r.origin.x + 70, CGRectGetMidY(r) - 6, r.size.width - 160, 12);
    KPFill(c, CGRectOffset(track, 0, -1), KPP->ledge, 6);
    KPFill(c, track, KPP->well, 6);
    KPStroke(c, track, KPP->buttonStroke, 1, 6);
    const CGFloat fill = track.size.width * (muted ? 0 : volume);
    if (fill > 2) KPGradientFill(c, CGRectMake(track.origin.x + 1, track.origin.y + 1, fill - 2, track.size.height - 2), 5,
                                 KPP->accentTop, KPP->accentBottom);
    const CGRect knob = CGRectMake(track.origin.x + fill - 11, CGRectGetMidY(track) - 11, 22, 22);
    KPFill(c, CGRectOffset(knob, 0, 1.5), 0x000000, 11, 0.22);
    KPGradientFill(c, knob, 11, 0xffffff, 0xe3e8eb);
    KPStroke(c, knob, KPP->buttonStroke, 1, 11);
    KPTextWeight(muted ? @"Off" : [NSString stringWithFormat:@"%d%%", (int)std::lround(volume * 100)],
                 CGRectMake(CGRectGetMaxX(r) - 80, CGRectGetMidY(r) - 14, 64, 28), 20, KPP->text, NSFontWeightSemibold,
                 NSTextAlignmentRight);
  } action:^{
    KPHomeScreen *home = weakSelf;
    home.shownMute = !home.shownMute;
    KPWriteVolume(home.shownVolume, home.shownMute);
    home.volume.needsDisplay = YES;
  }];
  self.volume.label = @"Volume";
  self.volume.sound = KPUISound::Confirm;
  self.volume.adjust = ^BOOL(int direction) {
    KPHomeScreen *home = weakSelf;
    const float next = std::clamp(home.shownVolume + direction * 0.05f, 0.0f, 1.0f);
    if (next == home.shownVolume && !home.shownMute) {
      KPUIPlay(KPUISound::Same);
      return YES;
    }
    home.shownVolume = next;
    home.shownMute = NO;
    KPWriteVolume(next, false);
    KPUIPlay(direction < 0 ? KPUISound::Left : KPUISound::Right);
    home.volume.needsDisplay = YES;
    return YES;
  };

  // Full screen or back to a window: the pill names what A switches to.
  self.displayToggle = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    const BOOL full = aurora_get_display_mode() != AURORA_DISPLAY_MODE_WINDOWED;
    KPDrawPill(c, r, state, KPStyle::Plain, full ? KPUIGlyph::Window : KPUIGlyph::FullScreen, full ? @"Window" : @"Full Screen");
  } action:^{ [weakSelf toggleDisplay]; }];
  self.displayToggle.label = @"Window or full screen";
  self.displayToggle.sound = KPUISound::Tab;

  self.settings = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPButtonFace(c, r, KPStyle::Round, NO, state.enabled, state.pressed, state.focused);
    KPDrawGlyph(c, KPUIGlyph::Gear, CGRectInset(r, r.size.width * 0.22, r.size.height * 0.22 + 1), KPP->accentBottom);
  } action:^{ [KPOverlay() present:KPMakeSettingsScreen()]; }];
  self.settings.label = @"Settings";
  self.settings.radius = 12;

  self.quit = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Power, @"Quit");
  } action:^{ [weakSelf askToQuit]; }];
  self.quit.label = @"Quit KartPad";

  self.restart = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPButtonFace(c, r, KPStyle::Plain, NO, state.enabled, state.pressed, state.focused);
    KPFill(c, CGRectInset(CGRectMake(r.origin.x, r.origin.y, r.size.width, r.size.height - 3), 2, 2), 0xf0a030, 7, 0.22);
    const CGFloat dy = state.pressed ? 2 : 0;
    KPDrawGlyph(c, KPUIGlyph::Restart, CGRectMake(r.origin.x + 16, CGRectGetMidY(r) - 14 + dy, 26, 26), 0xc6731a);
    KPTextWeight(@"Restart to apply", CGRectMake(r.origin.x + 50, CGRectGetMidY(r) - 13 + dy, r.size.width - 58, 26), 19, KPP->text,
                 NSFontWeightSemibold, NSTextAlignmentLeft);
  } action:^{ [weakSelf askToRestart]; }];
  self.restart.label = @"Restart to apply changes";

  self.slots = [NSMutableArray array];
  for (int slot = 0; slot < KPPlayerCount; ++slot) {
    KPUIButton *button = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      [weakSelf drawSlot:slot context:c in:r state:state];
    } action:^{ [KPOverlay() present:KPMakeControllersScreenFor(slot)]; }];
    button.tag2 = slot;
    button.radius = 16;
    button.focusScale = 1.03;
    button.label = [NSString stringWithFormat:@"%@ slot", KPPlayerName(slot)];
    [self.slots addObject:button];
  }
  [KPControllerRoster.shared.listeners addObject:self];
}

- (void)layoutDesign {
  const CGRect s = self.safe;
  const CGSize stage = self.designSize;
  const CGFloat topHeight = s.origin.y + 98, bottomTop = s.origin.y + 538;
  [self place:self.topBar at:CGRectMake(0, 0, stage.width, topHeight + 14)];
  [self place:self.bottomBar at:CGRectMake(0, bottomTop - 14, stage.width, stage.height - bottomTop + 14)];

  // The top bar, from the right: Quit, Settings, full screen, and a waiting restart.
  const BOOL restart = KPRestartWaiting();
  self.restart.hidden = !restart;
  CGFloat right = CGRectGetMaxX(s) - 52;
  [self place:self.quit at:CGRectMake(right - 140, s.origin.y + 22, 140, 58)];
  right -= 140 + 14;
  [self place:self.settings at:CGRectMake(right - 62, s.origin.y + 20, 62, 62)];
  right -= 62 + 14;
  [self place:self.displayToggle at:CGRectMake(right - 210, s.origin.y + 22, 210, 58)];
  right -= 210 + 14;
  [self place:self.restart at:CGRectMake(right - 236, s.origin.y + 22, 236, 58)];

  const BOOL canSwitch = KPCanSwitchGames();
  const CGFloat gap = 22, top = s.origin.y + 140, height = 230;
  const CGFloat wide = canSwitch ? 340 : 420, narrow = canSwitch ? 272 : 360;
  const CGFloat total = wide + narrow * (canSwitch ? 3 : 2) + gap * (canSwitch ? 3 : 2);
  CGFloat x = std::round(s.origin.x + (s.size.width - total) / 2);
  [self place:self.resume at:CGRectMake(x, top, wide, height)];
  x += wide + gap;
  if (canSwitch) {
    [self place:self.switchGame at:CGRectMake(x, top, narrow, height)];
    x += narrow + gap;
  }
  [self place:self.miis at:CGRectMake(x, top, narrow, height)];
  x += narrow + gap;
  [self place:self.controllers at:CGRectMake(x, top, narrow, height)];

  // The volume, alone on its row.
  [self place:self.volume at:CGRectMake(std::round(s.origin.x + (s.size.width - 820) / 2), s.origin.y + 396, 820, 74)];

  const CGFloat slotWidth = 266, slotGap = 16, slotTop = s.origin.y + 584;
  for (KPUIButton *button in self.slots)
    [self place:button at:CGRectMake(s.origin.x + 52 + button.tag2 * (slotWidth + slotGap), slotTop, slotWidth, 104)];
}

- (KPUIButton *)initialFocus { return self.resume; }

- (void)willAppear {
  [KPControllerRoster.shared.listeners addObject:self];
  self.canPause = !Network_HLE_HasOpenSockets();
  self.shownVolume = KPConfiguredVolume();
  self.shownMute = KPConfiguredMute();
  NSArray<NSDictionary *> *records = KartPadMiiRecords(nil);
  self.miiCount = (NSInteger)records.count;
  self.miiFaces = [records subarrayWithRange:NSMakeRange(0, std::min<NSUInteger>(3, records.count))];
  [KPControllerRoster.shared refresh];
  [self layoutDesign];
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setInteger:[defaults integerForKey:KPHomeOpenedCountKey] + 1 forKey:KPHomeOpenedCountKey];
}

- (void)didAppear {
  if (KPUIReduceMotion()) return;
  // The bars slide in from the edges and the tiles pop up, staggered, as the Wii's HOME Menu does.
  auto slide = [](NSView *view, CGFloat from, CFTimeInterval delay) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"transform.translation.y"];
    spring.fromValue = @(from);
    spring.toValue = @0;
    spring.damping = 18;
    spring.stiffness = 220;
    spring.duration = spring.settlingDuration;
    spring.beginTime = CACurrentMediaTime() + delay;
    spring.fillMode = kCAFillModeBackwards;
    [view.layer addAnimation:spring forKey:@"slide"];
  };
  // Which way is up for the layers depends on whether AppKit flipped this view's layer.
  const CGFloat up = self.layer.geometryFlipped ? -1 : 1;
  const CGFloat top = self.topBar.frame.size.height, bottom = self.bottomBar.frame.size.height;
  slide(self.topBar, up * top, 0);
  slide(self.bottomBar, -up * bottom, 0);
  for (KPUIButton *button in self.slots) slide(button, -up * bottom, 0.02);
  for (KPUIButton *button in @[self.quit, self.settings, self.displayToggle, self.restart]) slide(button, up * top, 0);
  NSArray *tiles = @[self.resume, self.switchGame, self.miis, self.controllers];
  CFTimeInterval delay = 0.04;
  for (KPUIButton *tile in tiles) {
    if (tile.hidden) continue;
    CASpringAnimation *pop = [CASpringAnimation animationWithKeyPath:@"opacity"];
    pop.fromValue = @0;
    pop.toValue = @1;
    pop.damping = 20;
    pop.stiffness = 260;
    pop.duration = 0.3;
    pop.beginTime = CACurrentMediaTime() + delay;
    pop.fillMode = kCAFillModeBackwards;
    [tile.layer addAnimation:pop forKey:@"fade"];
    slide(tile, -up * 24 * self.scale, delay);
    delay += 0.035;
  }
}

- (void)willDisappear { [KPControllerRoster.shared.listeners removeObject:self]; }

- (void)rosterChanged {
  for (KPUIButton *slot in self.slots) slot.needsDisplay = YES;
  self.controllers.needsDisplay = YES;
}

- (void)tick {
  static NSTimeInterval last;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - last < 0.25) return;
  last = now;
  [KPControllerRoster.shared refresh];
  for (KPUIButton *slot in self.slots) slot.needsDisplay = YES;
  const BOOL online = Network_HLE_HasOpenSockets();
  if (online == self.canPause) {
    self.canPause = !online;
    self.topBar.needsDisplay = YES;
    self.resume.needsDisplay = YES;
  }
  if (self.restart.hidden == KPRestartWaiting()) [self layoutDesign];
  self.displayToggle.needsDisplay = YES;
}

// X on a player identifies their controller (it buzzes and flashes); Y opens Controllers.
- (BOOL)handle:(KartPadMiiPadButton)button {
  KPUIButton *focus = self.focus;
  if (button == KartPadMiiPadUndo && [self.slots containsObject:focus]) {
    KPPadDevice *device = [KPControllerRoster.shared deviceInSlot:(int)focus.tag2];
    if (device) {
      [KPControllerRoster.shared identify:device];
      KPUIPlay(KPUISound::Confirm);
      KPUIWobble(focus);
      [focus springTo:1.08];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [focus springTo:focus.focused ? focus.focusScale : 1];
      });
    } else {
      KPUIPlay(KPUISound::Reject);
    }
    return YES;
  }
  return NO;
}

- (void)back { [KPOverlay() closeAll]; }

#pragma mark Drawing

- (void)drawTopBar:(CGContextRef)c size:(CGSize)size {
  const CGRect s = self.safe;
  const CGFloat height = size.height - 14;
  const BOOL dark = KPP == &KPDarkPalette;
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, 4), 12, [NSColor colorWithWhite:0 alpha:0.3].CGColor);
  KPGradientFill(c, CGRectMake(0, 0, size.width, height), 0, dark ? 0x353c42 : 0xffffff, dark ? 0x23292d : 0xe6edf1);
  CGContextRestoreGState(c);
  KPPinstripes(c, CGRectMake(0, 0, size.width, height - 4), dark ? 0x2b3136 : 0xeef2f4);
  KPFill(c, CGRectMake(0, height - 4, size.width, 4), KPP->accentBottom);
  KPFill(c, CGRectMake(0, height - 4, size.width, 1.5), KPP->accentTop, 0, 0.8);
  KPDrawGlyph(c, KPUIGlyph::Home, CGRectMake(s.origin.x + 52, s.origin.y + 26, 46, 46), KPP->accentBottom);
  KPTextWeight(@"HOME", CGRectMake(s.origin.x + 110, s.origin.y + 24, 200, 50), 38, KPP->text, NSFontWeightHeavy, NSTextAlignmentLeft);
  // What's playing, beside the title.
  NSString *playing = KPGameTitle(KPRunningProfile());
  KPTextWeight(playing, CGRectMake(s.origin.x + 260, s.origin.y + 38, 460, 28), 20, KPP->secondaryText, NSFontWeightMedium,
               NSTextAlignmentLeft);
  if (!self.canPause) {
    NSString *note = @"Online: the race carries on";
    const CGSize text = KPTextSize(note, 17, NSFontWeightSemibold);
    const CGRect pill = CGRectMake(s.origin.x + 260 + KPTextSize(playing, 20, NSFontWeightMedium).width + 18, s.origin.y + 36,
                                   text.width + 34, 32);
    KPFill(c, pill, 0xf0a030, 16, 0.22);
    KPStroke(c, pill, 0xd98a1c, 1, 16, 0.6);
    KPTextWeight(note, CGRectMake(pill.origin.x + 17, pill.origin.y + 6, text.width + 4, 22), 17, dark ? 0xffd28a : 0x8a4b00,
                 NSFontWeightSemibold, NSTextAlignmentLeft);
  }
}

- (void)drawBottomBar:(CGContextRef)c size:(CGSize)size {
  const CGRect s = self.safe;
  const BOOL dark = KPP == &KPDarkPalette;
  const CGRect bar = CGRectMake(0, 14, size.width, size.height - 14);
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeMake(0, -4), 12, [NSColor colorWithWhite:0 alpha:0.3].CGColor);
  KPGradientFill(c, bar, 0, dark ? 0x23292d : 0xe6edf1, dark ? 0x353c42 : 0xffffff);
  CGContextRestoreGState(c);
  KPPinstripes(c, CGRectMake(0, 18, size.width, size.height - 18), dark ? 0x2b3136 : 0xeef2f4);
  KPFill(c, CGRectMake(0, 14, size.width, 4), KPP->accentBottom);
  KPFill(c, CGRectMake(0, 16.5, size.width, 1.5), KPP->accentTop, 0, 0.8);
  // The bar's own coordinates start at the screen's y 524 (safe area).
  const CGFloat origin = s.origin.y + 524;
  KPTextWeight(@"Players", CGRectMake(s.origin.x + 56, s.origin.y + 552 - origin, 300, 26), 18, KPP->secondaryText,
               NSFontWeightSemibold, NSTextAlignmentLeft);
  // Which buttons do what, for the controller in hand.
  NSString *hint = @"Ⓐ Select    Ⓧ Find controller    Ⓑ Close";
  KPTextWeight(hint, CGRectMake(s.origin.x + 1280 - 52 - 640, s.origin.y + 552 - origin, 640, 26), 16, KPP->secondaryText,
               NSFontWeightMedium, NSTextAlignmentRight);
}

- (void)drawSlot:(int)slot context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  KPPadDevice *device = [KPControllerRoster.shared deviceInSlot:slot];
  const BOOL empty = device == nil;
  if (empty) {
    KPFill(c, r, KPP->panel, 16, 0.55);
    CGContextSaveGState(c);
    const CGFloat dash[] = {7, 6};
    CGContextSetLineDash(c, 0, dash, 2);
    KPStroke(c, CGRectInset(r, 1, 1), KPP->buttonStroke, 2, 15);
    CGContextRestoreGState(c);
    if (state.focused) KPStroke(c, r, KPP->accentTop, 2.5, 16);
    KPDrawPlayerBadge(c, CGRectMake(r.origin.x + 18, CGRectGetMidY(r) - 16, 32, 32), slot, YES);
    KPTextWeight(@"No controller", CGRectMake(r.origin.x + 62, CGRectGetMidY(r) - 13, r.size.width - 74, 26), 19, KPP->secondaryText,
                 NSFontWeightSemibold, NSTextAlignmentLeft);
    return;
  }
  KPButtonFace(c, r, KPStyle::Card, NO, YES, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  // The player's colour down the leading edge.
  CGContextSaveGState(c);
  CGPathRef clip = CGPathCreateWithRoundedRect(CGRectMake(r.origin.x, r.origin.y + dy, r.size.width, r.size.height - 3), 14, 14, nullptr);
  CGContextAddPath(c, clip);
  CGContextClip(c);
  CGPathRelease(clip);
  KPFill(c, CGRectMake(r.origin.x, r.origin.y, 9, r.size.height), KPPlayerColors[slot]);
  CGContextRestoreGState(c);
  NSDictionary *mii = [KPControllerRoster.shared miiRecordFor:device];
  NSImage *portrait = KPPortraitFor(device, self.slots[slot]);
  const CGRect well = CGRectMake(r.origin.x + 20, r.origin.y + 14 + dy, 74, 74);
  KPDrawMiiWell(c, well, portrait, KPPlayerColors[slot], NO);
  KPDrawPlayerBadge(c, CGRectMake(well.origin.x - 6, well.origin.y - 6, 28, 28), slot, NO);
  // The Mii's name (or the player), then the controller.
  KPTextWeight(mii[@"name"] ?: KPPlayerName(slot), CGRectMake(r.origin.x + 106, r.origin.y + 16 + dy, r.size.width - 118, 28), 20,
               KPP->text, NSFontWeightSemibold, NSTextAlignmentLeft);
  KPDrawGlyph(c, device.isKeyboard ? KPUIGlyph::Keyboard : device.family == KPFamilyWiiRemote ? KPUIGlyph::WiiRemote : KPUIGlyph::Pad,
              CGRectMake(r.origin.x + 106, r.origin.y + 50 + dy, 24, 24), KPP->secondaryText);
  KPTextWeight(device.name, CGRectMake(r.origin.x + 136, r.origin.y + 52 + dy, r.size.width - 190, 22), 15,
               KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  KPDrawBattery(c, CGRectMake(CGRectGetMaxX(r) - 48, r.origin.y + 50 + dy, 30, 24), device);
}

#pragma mark Actions

- (void)toggleDisplay {
  [Controller() toggleGameFullScreen:nil];
  self.displayToggle.needsDisplay = YES;
}

- (void)askToSwitch {
  NSString *other = KPOtherProfile(), *title = KPGameTitle(other);
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  if ([other isEqualToString:kKartPadRetroProfile] && !KPRetroRewindReady() && KPRetroDownloadOffered()) {
    KPShowRetroDownload(NO);
    return;
  }
  if ([other isEqualToString:kKartPadRetroProfile] && !KPRetroRewindReady()) {
    KPAsk(@"Set Up Retro Rewind First", [NSString stringWithFormat:@"Choose your Retro Rewind %@ folder (RetroRewind6). This step needs a mouse.", @KARTPAD_RR_VERSION],
          @[@"Choose Folder…", @"Cancel"], 0, -1, ^(NSInteger choice) {
            if (choice != 0) return;
            [KPOverlay() closeAll];
            dispatch_async(dispatch_get_main_queue(), ^{ [Controller() chooseRetroRewindData:nil]; });
          });
    return;
  }
#endif
  NSString *message = KartPadHasPendingMiiChanges()
      ? @"KartPad restarts to switch. Saves and settings are kept, and your Mii changes are applied."
      : @"KartPad restarts to switch. Saves and settings are kept.";
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  KPAsk([NSString stringWithFormat:@"Switch to %@?", title], message, @[@"Switch", @"Cancel"], 0, -1, ^(NSInteger choice) {
    if (choice != 0) return;
    [Controller() chooseRuntimeProfile:other];
    KPRestartWithCurtain([NSString stringWithFormat:@"Starting %@", title], @"");
  });
#else
  (void)message;
#endif
}

- (void)askToRestart {
  NSArray *reasons = KPRestartReasonsText();
  NSString *list = reasons.count ? KPListText(reasons) : @"apply your changes";
  KPAsk(@"Restart KartPad?", [NSString stringWithFormat:@"This will %@. The race in progress ends; saves are kept.", list],
        @[@"Restart", @"Later"], 0, -1, ^(NSInteger choice) {
          if (choice == 0) KPRestartWithCurtain(@"Restarting", @"");
        });
}

- (void)askToQuit {
  KPAsk(@"Quit KartPad?", @"Anything not saved in the game is lost.", @[@"Quit", @"Cancel"], 1, 0, ^(NSInteger choice) {
    if (choice == 0) dispatch_async(dispatch_get_main_queue(), ^{ [Controller() quitKartPad:nil]; });
  });
}

@end

#pragma mark Opening HOME

static void KPOpenHome() {
  KPOverlayController *overlay = KPOverlay();
  if (overlay.active) return;
  if (KartPadGameStarting()) {
    [overlay toast:@"Still starting…" detail:@"HOME opens once the game is up." stripe:0 icon:^(CGContextRef c, CGRect r) {
      KPDrawGlyph(c, KPUIGlyph::Home, r, KPP->accentBottom);
    } image:nil];
    return;
  }
  NSWindow *game = KPGameWindow();
  if (game == nil) return;
  if (!KPUIBackgroundAutomation()) {
    [NSApp activateIgnoringOtherApps:YES];
    [game makeKeyAndOrderFront:nil];
  }
  AppendSessionLine(@"home=opened");
  [overlay present:[[KPHomeScreen alloc] initWithFrame:NSZeroRect]];
}

static void KPOpenHomeFromController() { KPOpenHome(); }



// HOME again closes everything, as on the Wii.
static void KPToggleHome() {
  if (KPOverlay().active) [KPOverlay() closeAll];
  else KPOpenHome();
}

// The HOME / Guide / PS button on any controller, and a Wii Remote's own HOME (a raw button on SDL's
// Wii driver). One press per controller, so holding it doesn't flicker.
static void KPHomeTick() {
  static NSMutableSet<NSNumber *> *held;
  if (held == nil) held = [NSMutableSet set];
  NSMutableSet<NSNumber *> *now = [NSMutableSet set];
  bool pressed = false;
  int count = 0;
  SDL_JoystickID *ids = SDL_GetGamepads(&count);
  for (int i = 0; i < count; ++i) {
    SDL_Gamepad *pad = SDL_GetGamepadFromID(ids[i]);
    if (pad == nullptr) continue;
    bool home = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_GUIDE);
    if (!home && KPIsWiiRemoteName(SDL_GetGamepadName(pad)))
      home = SDL_GetJoystickButton(SDL_GetGamepadJoystick(pad), SDL_GAMEPAD_BUTTON_MISC1 + 6);
    if (!home) continue;
    [now addObject:@(ids[i])];
    if (![held containsObject:@(ids[i])]) pressed = true;
  }
  SDL_free(ids);
  [held setSet:now];
  if (!pressed || !NSApp.active || KPOverlay().hostWindow) return;
  // The old-style windows (the Mii editor, the classic Settings) keep HOME to themselves.
  if (!KPOverlay().active && (KartPadMiiWindowsVisible() || KPControllers().panel.visible)) return;
  if (KPOverlay().active && NSApp.keyWindow != nil && NSApp.keyWindow != KPOverlay().host.window) return;
  // The game loop can run inside a guest fiber; AppKit opens HOME on the next turn.
  dispatch_async(dispatch_get_main_queue(), ^{ KPToggleHome(); });
}

#pragma mark Hooks for the pad reader and the runtime

static bool KPOverlayActive() { return KPOverlay().active; }
// The overlay takes the pads while a screen is up and nothing else (the Mii editor's window, an
// alert or a menu) has them.
static bool KPOverlayTakesPads() {
  KPOverlayController *overlay = KPOverlay();
  if (!overlay.active) return false;
  NSWindow *key = NSApp.keyWindow;
  return key == nil || key == overlay.host.window;
}
static void KPOverlayPadPress(KartPadMiiPadButton button, BOOL down) {
  KPOverlay().keyboardInput = NO;
  // The Miis screen hosts the shared Mii browser, which has its own controller handling.
  if (KPOverlay().top.forwardsPads) {
    KartPadMiiPadPress(button, down);
    return;
  }
  [KPOverlay() padPress:button down:down];
}

extern "C" bool KartPadOverlayPauseWanted() {
  KPOverlayController *overlay = KPOverlay();
  return overlay.active && overlay.top.pausesGame;
}

static void KPShowHomeHint();
static void KPCurtainDone();  // KartPadCurtain.inc.mm
// From the game loop: the roster's view of the pads, the first-launch hint once the game is up, and
// after a restart, the curtain told it can go.
static void KPOverlayGameTick() {
  static NSTimeInterval lastRefresh;
  static bool hinted;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - lastRefresh > 0.5) {
    lastRefresh = now;
    [KPControllerRoster.shared refresh];
    [KPOverlay() attach];
  }
  // The hint waits for the player's first press once the game is up (or 20 seconds), so it's seen.
  static NSTimeInterval readyAt;
  if (!hinted && !KartPadGameStarting()) {
    if (readyAt == 0) {
      readyAt = now;
      KPCurtainDone();
    }
    KPPadDevice *last = KPControllerRoster.shared.lastActive;
    if ((last && last.lastInput > readyAt) || now - readyAt > 20) {
      hinted = true;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KPShowHomeHint(); });
    }
  }
}

// The first few times KartPad starts: "Press HOME for menus", with the right button for the pad in hand.
// It stops once HOME has been opened a couple of times.
static void KPShowHomeHint() {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  const NSInteger shown = [defaults integerForKey:KPHomeHintCountKey];
  if (shown >= 3 || [defaults integerForKey:KPHomeOpenedCountKey] >= 2 || KPOverlay().active) return;
  [defaults setInteger:shown + 1 forKey:KPHomeHintCountKey];
  KPControllerRoster *roster = KPControllerRoster.shared;
  KPPadDevice *pad = roster.lastActive;
  if (pad == nil)
    for (KPPadDevice *device in roster.devices)
      if (!device.isKeyboard && device.slot >= 0) { pad = device; break; }
  NSString *button = KPHomeButtonName(pad ? pad.family : KPFamilyKeyboard);
  NSString *detail = pad && !pad.isKeyboard ? @"On the keyboard: esc" : @"On a controller: HOME";
  [KPOverlay() toast:[NSString stringWithFormat:@"Press %@ for menus", button] detail:detail stripe:0 icon:^(CGContextRef c, CGRect r) {
    KPDrawGlyph(c, KPUIGlyph::Home, r, KPP->accentBottom);
  } image:nil seconds:7];
  AppendSessionLine(@"homeHint=shown");
}

#pragma mark Controller toasts

@implementation KPControllerRoster (Toasts)
- (void)announceConnected:(KPPadDevice *)device {
  const int slot = device.slot;
  NSString *detail = slot >= 0 ? [NSString stringWithFormat:@"Player %d", slot + 1] : @"Not playing yet: add it in HOME › Controllers";
  NSImage *portrait = nil;
  if (NSData *mii = [self miiFor:device]) portrait = KartPadMiiPortrait(mii, ^{});
  const KPPadFamily family = device.family;
  [KPOverlay() toast:[NSString stringWithFormat:@"%@ connected", device.name] detail:detail
              stripe:slot >= 0 ? KPPlayerColors[slot] : 0 icon:^(CGContextRef c, CGRect r) {
    KPDrawGlyph(c, family == KPFamilyWiiRemote ? KPUIGlyph::WiiRemote : KPUIGlyph::Pad, r, KPP->accentBottom);
  } image:portrait];
  KPUIPlay(KPUISound::Confirm);
}
- (void)announceGone:(KPPadDevice *)device {
  const int slot = device.slot;
  NSString *heading = slot >= 0 ? [NSString stringWithFormat:@"Player %d's controller disconnected", slot + 1]
                                : [NSString stringWithFormat:@"%@ disconnected", device.name];
  [KPOverlay() toast:heading detail:@"Turn it back on to keep playing."
              stripe:slot >= 0 ? KPPlayerColors[slot] : 0 icon:^(CGContextRef c, CGRect r) {
    KPDrawGlyph(c, KPUIGlyph::Pad, r, KPP->secondaryText);
  } image:nil];
  KPUIPlay(KPUISound::Close);
}
// Once as a battery drops to 20%, again at 5%; it re-arms after charging back above 30%.
- (void)checkBattery:(KPPadDevice *)device announce:(BOOL)announce {
  static NSMutableDictionary<NSString *, NSNumber *> *warned;
  if (warned == nil) warned = [NSMutableDictionary dictionary];
  if (device.battery < 0 || device.charging) {
    if (device.charging) [warned removeObjectForKey:device.identifier];
    return;
  }
  const int level = device.battery <= 5 ? 2 : device.battery <= 20 ? 1 : 0;
  if (device.battery > 30) [warned removeObjectForKey:device.identifier];
  if (level == 0 || warned[device.identifier].intValue >= level) return;
  warned[device.identifier] = @(level);
  if (!announce) return;
  const int slot = device.slot;
  const int percent = device.battery;
  [KPOverlay() toast:slot >= 0 ? [NSString stringWithFormat:@"Player %d's battery is low", slot + 1]
                               : [NSString stringWithFormat:@"%@ battery is low", device.name]
              detail:[NSString stringWithFormat:@"%d%% left", percent]
              stripe:slot >= 0 ? KPPlayerColors[slot] : 0 icon:^(CGContextRef c, CGRect r) {
    KPDrawGlyph(c, KPUIGlyph::Battery, r, 0xd0342c, percent / 100.0);
  } image:nil];
}
@end
