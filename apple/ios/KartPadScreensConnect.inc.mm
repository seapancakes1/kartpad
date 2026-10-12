// Connecting a controller on iPhone and iPad (in place of the Mac's KPConnectScreen, which pairs
// controllers itself): apps can't pair, so the page says how to put each kind in pairing mode and
// where to pair it (Settings › Bluetooth), and closes by itself once a new controller shows up.
// Included by apple/macos/KartPadControllersScreen.inc.mm.

@interface KPConnectScreen : KPScreen <KPRosterListener>
@property(nonatomic, strong) KPUIButton *settings, *done;
@property(nonatomic, strong) NSSet<NSString *> *before;
@end

static const struct {
  NSString *brand, *how;
  KPPadFamily family;
} KPPairModes[] = {
    {@"PlayStation", @"Hold Create (or Share) and PS until the light flashes.", KPFamilyPlayStation},
    {@"Xbox", @"Hold the pair button until the Xbox button flashes fast.", KPFamilyXbox},
    {@"Switch", @"Hold the sync button (on a Joy‑Con, the rail) until the lights run.", KPFamilySwitch},
    {@"Others", @"Usually: hold the pair button. Controllers that plug in work too.", KPFamilyGeneric},
};

@implementation KPConnectScreen
- (void)build {
  self.solid = YES;
  self.title = @"Connect a Controller";
  NSMutableSet *before = [NSMutableSet set];
  for (KPPadDevice *device in KPControllerRoster.shared.devices) [before addObject:device.identifier];
  self.before = before;
  self.settings = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Plain, KPUIGlyph::Gear, @"Open Settings");
  } action:^{
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{}
                           completionHandler:nil];
  }];
  self.settings.label = @"Open Settings";
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
  self.done.sound = KPUISound::Close;
  [KPControllerRoster.shared.listeners addObject:self];
}
- (void)layoutDesign {
  const CGRect s = self.safe;
  const CGFloat doneX = CGRectGetMaxX(s) - 56 - 170;
  [self place:self.done at:CGRectMake(doneX, s.origin.y + 590, 170, 64)];
  [self place:self.settings at:CGRectMake(doneX - 16 - 260, s.origin.y + 590, 260, 64)];
}
- (KPUIButton *)initialFocus { return self.done; }
- (void)willDisappear { [KPControllerRoster.shared.listeners removeObject:self]; }
// A controller that wasn't here before: it's connected, so the page has done its job.
- (void)rosterChanged {
  for (KPPadDevice *device in KPControllerRoster.shared.devices) {
    if (device.isTouch || [self.before containsObject:device.identifier]) continue;
    if (KPOverlay().top == self) [KPOverlay() pop];
    return;
  }
}
- (void)tick { [KPControllerRoster.shared refresh]; }
- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPTextWeight(@"Connect a Controller", CGRectMake(s.origin.x + 56, s.origin.y + 26, 800, 50), 38, KPP->text, NSFontWeightBold,
               NSTextAlignmentLeft);
  KPTextWeight(@"Put it in pairing mode, then choose it in Settings › Bluetooth.", CGRectMake(s.origin.x + 58, s.origin.y + 80, 1000, 26),
               19, KPP->secondaryText, NSFontWeightMedium, NSTextAlignmentLeft);
  const CGFloat w = 280, gap = 16, x0 = s.origin.x + (1280 - (4 * w + 3 * gap)) / 2;
  for (int i = 0; i < 4; ++i) {
    const CGRect card = CGRectMake(x0 + i * (w + gap), s.origin.y + 150, w, 400);
    KPButtonFace(c, card, KPStyle::Card, NO, YES, NO, NO);
    KPArtState art;
    art.accent = KPP->accentBottom;
    KPDrawControllerArt(c, CGRectMake(card.origin.x + 24, card.origin.y + 26, w - 48, 130), KPPairModes[i].family, art);
    KPTextWeight(KPPairModes[i].brand, CGRectMake(card.origin.x + 16, card.origin.y + 184, w - 32, 32), 24, KPP->text,
                 NSFontWeightSemibold);
    KPTextWeight(KPPairModes[i].how, CGRectMake(card.origin.x + 24, card.origin.y + 230, w - 48, 150), 18, KPP->secondaryText,
                 NSFontWeightRegular);
  }
  KPDrawHints(c, CGRectMake(s.origin.x + 56, s.origin.y + 670, 1168, 26), {{KartPadMiiPadBack, @"Back"}}, 16, NSTextAlignmentRight);
}
@end

static KPScreen *KPMakeConnectScreen() { return [[KPConnectScreen alloc] initWithFrame:NSZeroRect]; }
