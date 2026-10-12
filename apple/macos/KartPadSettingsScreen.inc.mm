// Settings, as a screen over the game: five plain-word categories down the side (Picture, Sound,
// Controls, Game, Advanced) and big rows a controller can work. A flips a switch or opens a row;
// left and right step a choice or a level in place. Left from a switch (or a choice already at its
// first step) goes back to the categories, as B does before it leaves. LB and RB change category. Every row writes the same
// Config.toml keys and user defaults as the classic Settings window (KartPadMacSettings.inc.mm),
// which stays one row away under Advanced. A change that needs a restart says so on its row, and
// HOME offers the restart. Included by KartPadMacShell.mm after KartPadControllersScreen.inc.mm.

typedef NS_ENUM(NSInteger, KPRowKind) { KPRowSwitch, KPRowChoice, KPRowSlider, KPRowAction };

@interface KPSettingRow : NSObject
@property(nonatomic, copy) NSString *title, *detail;
@property(nonatomic) KPRowKind kind;
@property(nonatomic, copy) NSArray<NSString *> *choices;
@property(nonatomic, copy) BOOL (^on)(void);
@property(nonatomic, copy) void (^setOn)(BOOL on);
@property(nonatomic, copy) NSInteger (^index)(void);
@property(nonatomic, copy) void (^setIndex)(NSInteger index);
@property(nonatomic, copy) float (^level)(void);
@property(nonatomic, copy) void (^setLevel)(float level);
@property(nonatomic, copy) void (^run)(void);
@property(nonatomic, copy) NSString *(^value)(void);
@property(nonatomic, copy) BOOL (^restart)(void);
@property(nonatomic) BOOL inPlace;  // an action row that acts where it is (no chevron)
@property(nonatomic) BOOL soundLevel;  // a level the Sound switch silences
@end
@implementation KPSettingRow
@end

static KPSettingRow *KPRow(NSString *title, NSString *detail, KPRowKind kind) {
  KPSettingRow *row = [KPSettingRow new];
  row.title = title;
  row.detail = detail;
  row.kind = kind;
  return row;
}

static bool KPWriteConfig(const char *section, const char *key, const std::string &value, bool reload = true) {
  if (!RuntimeConfigFile::WriteSetting(section, key, value)) {
    KPUIPlay(KPUISound::Reject);
    [KPOverlay() toast:@"That setting couldn’t be saved" detail:@"KartPad’s settings file can’t be written." stripe:0
                  icon:^(CGContextRef c, CGRect r) { KPDrawGlyph(c, KPUIGlyph::Gear, r, 0xd0342c); } image:nil];
    return false;
  }
  if (reload) KartPadRequestSettingsReload();
  return true;
}
static std::string KPFloatText(float value) {
  std::ostringstream stream;
  stream << value;
  return stream.str();
}

@interface KPSettingsScreen : KPScreen
@property(nonatomic) NSInteger category, first;  // first: the top row showing
@property(nonatomic, strong) NSMutableArray<KPUIButton *> *tabs, *rowButtons;
@property(nonatomic, strong) NSArray<NSArray<KPSettingRow *> *> *rows;
@property(nonatomic) RuntimeUserConfig config;
@property(nonatomic, strong) KPUIButton *done;
// A level row being dragged shows slidingLevel until it's saved (KPSaveSlideSoon).
@property(nonatomic, strong) KPSettingRow *sliding;
@property(nonatomic) float slidingLevel;
@property(nonatomic) CGFloat scrolled;  // scrolling not yet a whole row
@property(nonatomic) CGFloat gaugeGrab;  // where in the scroll gauge's thumb the pointer holds it, or -1
@end

// Where a level row draws its track (unpressed), for the drawing and the pointer alike.
static CGRect KPSettingsSliderTrack(CGRect r) {
  const CGFloat controlWidth = 300, right = CGRectGetMaxX(r) - 20, mid = CGRectGetMidY(r) - 1.5;
  return CGRectMake(right - controlWidth, mid - 6, controlWidth - 70, 12);
}

@implementation KPSettingsScreen
static constexpr NSInteger KPSettingsVisibleRows = 7;

- (NSArray<NSString *> *)categoryNames { return @[@"Picture", @"Sound", @"Controls", @"Game", @"Advanced"]; }

- (void)reloadConfig { self.config = RuntimeConfigFile::LoadConfigFile(); }
- (float)levelOf:(KPSettingRow *)row { return row == self.sliding ? self.slidingLevel : row.level(); }
- (void)willDisappear { KPSaveSlide(); }

- (void)build {
  self.solid = YES;
  self.title = @"Settings";
  KPReadLaunchDisplaySettings();
  [self reloadConfig];
  [self makeRows];
  __weak KPSettingsScreen *weakSelf = self;
  self.tabs = [NSMutableArray array];
  const KPUIGlyph icons[] = {KPUIGlyph::Picture, KPUIGlyph::Speaker, KPUIGlyph::Pad, KPUIGlyph::Game, KPUIGlyph::Advanced};
  NSArray *names = self.categoryNames;
  for (NSInteger i = 0; i < (NSInteger)names.count; ++i) {
    const KPUIGlyph icon = icons[i];
    KPUIButton *tab = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      const BOOL chosen = weakSelf.category == i;
      KPButtonFace(c, r, KPStyle::Tab, chosen, YES, state.pressed, state.focused);
      const CGFloat dy = state.pressed ? 2 : 0;
      const unsigned ink = chosen ? 0xffffff : KPP->text;
      KPDrawGlyph(c, icon, CGRectMake(r.origin.x + 20, CGRectGetMidY(r) - 16 + dy, 32, 32), chosen ? 0xffffff : KPP->accentBottom, 1);
      KPTextWeight(names[i], CGRectMake(r.origin.x + 66, CGRectGetMidY(r) - 15 + dy, r.size.width - 76, 30), 22, ink,
                   NSFontWeightSemibold, NSTextAlignmentLeft);
    } action:nil];
    // A from a pad goes into the category's rows; a click just shows them.
    __weak KPUIButton *weakTab = tab;
    tab.activate = ^{ [weakSelf showCategory:i focusRows:!weakTab.clicked]; };
    tab.tag2 = i;
    tab.radius = 12;
    tab.label = names[i];
    tab.sound = KPUISound::Tab;
    [self.tabs addObject:tab];
  }
  self.rowButtons = [NSMutableArray array];
  for (NSInteger i = 0; i < KPSettingsVisibleRows; ++i) {
    KPUIButton *row = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
      [weakSelf drawRow:i context:c in:r state:state];
    } action:^{ [weakSelf press:i]; }];
    row.tag2 = i;
    row.radius = 12;
    row.margin = 6;
    row.focusScale = 1.012;
    row.adjust = ^BOOL(int direction) { return [weakSelf adjust:i by:direction]; };
    row.slide = ^BOOL(CGPoint point, CGRect face, BOOL began) { return [weakSelf slide:i to:point face:face began:began]; };
    [self.rowButtons addObject:row];
  }
  self.done = [self button:CGRectZero face:^(CGContextRef c, CGRect r, KPUIState state) {
    KPDrawPill(c, r, state, KPStyle::Primary, KPUIGlyph::Check, @"Done");
  } action:^{ [KPOverlay() pop]; }];
  self.done.label = @"Done";
  self.done.sound = KPUISound::Close;
  self.gaugeGrab = -1;
}

- (KPSettingRow *)rowAt:(NSInteger)visible {
  NSArray<KPSettingRow *> *rows = self.rows[self.category];
  const NSInteger index = self.first + visible;
  return index >= 0 && index < (NSInteger)rows.count ? rows[index] : nil;
}

- (void)layoutDesign {
  const CGRect s = self.safe;
  for (KPUIButton *tab in self.tabs) [self place:tab at:CGRectMake(s.origin.x + 52, s.origin.y + 118 + tab.tag2 * 78, 250, 66)];
  for (KPUIButton *row in self.rowButtons) {
    KPSettingRow *setting = [self rowAt:row.tag2];
    row.hidden = setting == nil;
    row.label = setting.title;
    [self place:row at:CGRectMake(s.origin.x + 336, s.origin.y + 112 + row.tag2 * 78, 880, 70)];
    row.needsDisplay = YES;
  }
  [self place:self.done at:CGRectMake(CGRectGetMaxX(s) - 52 - 150, s.origin.y + 26, 150, 58)];
  self.needsDisplay = YES;  // the scroll gauge follows first
}

- (KPUIButton *)initialFocus { return self.tabs.firstObject; }

- (void)showCategory:(NSInteger)category focusRows:(BOOL)focusRows {
  if (category != self.category) {
    self.category = category;
    self.first = 0;
    [self layoutDesign];
    for (KPUIButton *tab in self.tabs) tab.needsDisplay = YES;
    [KPOverlay() dismissToastsFrom:self];  // a toast about the last category's rows
  }
  if (focusRows) [KPOverlay() focus:self.rowButtons.firstObject sound:NO];
  self.needsDisplay = YES;
}

- (void)refreshRows {
  [self reloadConfig];
  for (KPUIButton *row in self.rowButtons) row.needsDisplay = YES;
}

- (BOOL)handle:(KartPadMiiPadButton)button {
  KPUIButton *focus = self.focus;
  const BOOL onRow = [self.rowButtons containsObject:focus], onTab = [self.tabs containsObject:focus];
  if (onRow && button == KartPadMiiPadBack) {
    KPUIPlay(KPUISound::Close);
    [KPOverlay() focus:self.tabs[self.category] sound:NO];
    return YES;
  }
  if (button == KartPadMiiPadNextTab || button == KartPadMiiPadPreviousTab) {
    const NSInteger next = std::clamp<NSInteger>(self.category + (button == KartPadMiiPadNextTab ? 1 : -1), 0, (NSInteger)self.tabs.count - 1);
    if (next == self.category) {
      KPUIPlay(KPUISound::Same);
      return YES;
    }
    KPUIPlay(KPUISound::Tab);
    [self showCategory:next focusRows:onRow];
    if (onTab) [KPOverlay() focus:self.tabs[next] sound:NO];
    return YES;
  }
  // Up and down walk the rows, scrolling through long categories.
  if (onRow && (button == KartPadMiiPadUp || button == KartPadMiiPadDown)) {
    const NSInteger count = (NSInteger)self.rows[self.category].count, index = self.first + focus.tag2;
    const NSInteger next = index + (button == KartPadMiiPadDown ? 1 : -1);
    if (next < 0 || next >= count) {
      if (next < 0) {
        [KPOverlay() focus:self.done sound:YES];
        return YES;
      }
      KPUIPlay(KPUISound::Same);
      return YES;
    }
    if (next < self.first) self.first = next;
    if (next >= self.first + KPSettingsVisibleRows) self.first = next - KPSettingsVisibleRows + 1;
    [self layoutDesign];
    [KPOverlay() focus:self.rowButtons[next - self.first] sound:YES];
    return YES;
  }
  // From a tab, Right goes to its rows. From a row, Left steps a choice or level down, and goes back to
  // the tab from a switch, a button row, or a choice already at its first step.
  if (onTab && button == KartPadMiiPadRight) {
    if (focus.tag2 != self.category) [self showCategory:focus.tag2 focusRows:NO];
    [KPOverlay() focus:self.rowButtons.firstObject sound:YES];
    return YES;
  }
  if (onTab && (button == KartPadMiiPadUp || button == KartPadMiiPadDown)) {
    const NSInteger next = focus.tag2 + (button == KartPadMiiPadDown ? 1 : -1);
    if (next < 0 || next >= (NSInteger)self.tabs.count) {
      if (next < 0) [KPOverlay() focus:self.done sound:YES];
      return YES;
    }
    [self showCategory:next focusRows:NO];
    [KPOverlay() focus:self.tabs[next] sound:YES];
    return YES;
  }
  if (onRow && button == KartPadMiiPadLeft) {
    KPSettingRow *row = [self rowAt:focus.tag2];
    const BOOL atStart = (row.kind == KPRowChoice && row.index() <= 0) || (row.kind == KPRowSlider && [self levelOf:row] <= 0.001f);
    if (row.kind == KPRowAction || row.kind == KPRowSwitch || atStart) [KPOverlay() focus:self.tabs[self.category] sound:YES];
    else [self adjust:focus.tag2 by:-1];
    return YES;
  }
  if (focus == self.done && button == KartPadMiiPadDown) {
    [KPOverlay() focus:self.tabs[self.category] sound:YES];
    return YES;
  }
  return NO;
}

// A wheel's notch scrolls a row; a trackpad, a row for every 40 points it moves.
- (void)scrollWheel:(NSEvent *)event {
  const NSInteger count = (NSInteger)self.rows[self.category].count;
  if (count <= KPSettingsVisibleRows) return;
  if (event.phase == NSEventPhaseBegan) self.scrolled = 0;
  const CGFloat step = event.hasPreciseScrollingDeltas ? 40 : 1;
  self.scrolled += event.scrollingDeltaY;
  const NSInteger rows = (NSInteger)(self.scrolled / step);
  if (rows == 0) return;
  self.scrolled -= rows * step;
  const NSInteger next = std::clamp<NSInteger>(self.first - rows, 0, count - KPSettingsVisibleRows);
  if (next == self.first) return;
  self.first = next;
  [self layoutDesign];
}

// The scroll gauge for long categories, and the part of it the showing rows take.
- (CGRect)gaugeTrack {
  const CGRect s = self.safe;
  return CGRectMake(CGRectGetMaxX(s) - 31, s.origin.y + 118, 8, KPSettingsVisibleRows * 78 - 14);
}
- (CGRect)gaugeThumb {
  const CGRect track = self.gaugeTrack;
  const CGFloat count = std::max<CGFloat>(1, self.rows[self.category].count);
  return CGRectMake(track.origin.x, track.origin.y + track.size.height * self.first / count, track.size.width,
                    track.size.height * std::min<CGFloat>(1, KPSettingsVisibleRows / count));
}

// The pointer drags the gauge's thumb, or takes it to where the track is clicked.
- (void)mouseDown:(NSEvent *)event {
  self.gaugeGrab = -1;
  if ((NSInteger)self.rows[self.category].count <= KPSettingsVisibleRows) return;
  const NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  const CGPoint point = CGPointMake(local.x / self.scale, local.y / self.scale);
  if (!CGRectContainsPoint(CGRectInset(self.gaugeTrack, -14, -6), point)) return;
  const CGRect thumb = self.gaugeThumb;
  self.gaugeGrab = point.y >= thumb.origin.y && point.y <= CGRectGetMaxY(thumb) ? point.y - thumb.origin.y : thumb.size.height / 2;
  [self dragGaugeTo:point.y];
}
- (void)mouseDragged:(NSEvent *)event {
  if (self.gaugeGrab < 0) return;
  [self dragGaugeTo:[self convertPoint:event.locationInWindow fromView:nil].y / self.scale];
}
- (void)mouseUp:(NSEvent *)event {
  (void)event;
  self.gaugeGrab = -1;
}
- (void)dragGaugeTo:(CGFloat)y {
  const CGRect track = self.gaugeTrack;
  const NSInteger count = (NSInteger)self.rows[self.category].count;
  const NSInteger next = std::clamp<NSInteger>(std::lround((y - self.gaugeGrab - track.origin.y) / track.size.height * count), 0,
                                               count - KPSettingsVisibleRows);
  if (next == self.first) return;
  self.first = next;
  [self layoutDesign];
}

- (BOOL)adjust:(NSInteger)visible by:(int)direction {
  KPSettingRow *row = [self rowAt:visible];
  if (row == nil) return NO;
  KPSaveSlide();
  switch (row.kind) {
    case KPRowSwitch: return NO;  // only A flips a switch
    case KPRowChoice: {
      const NSInteger next = row.index() + direction;
      if (next < 0 || next >= (NSInteger)row.choices.count) {
        KPUIPlay(KPUISound::Reject);
        return YES;
      }
      row.setIndex(next);
      KPUIPlay(direction < 0 ? KPUISound::Left : KPUISound::Right);
      break;
    }
    case KPRowSlider: {
      const float now = row.level(), next = std::clamp(now + direction * 0.05f, 0.0f, 1.0f);
      if (next == now) {
        KPUIPlay(KPUISound::Same);
        return YES;
      }
      row.setLevel(next);
      KPUIPlay(KPUISound::Tick);
      break;
    }
    case KPRowAction: return NO;
  }
  [self refreshRows];
  return YES;
}

// A level row's track follows the pointer; the level is saved once the drag rests or ends.
- (BOOL)slide:(NSInteger)visible to:(CGPoint)point face:(CGRect)r began:(BOOL)began {
  KPSettingRow *row = [self rowAt:visible];
  float next;
  if (row.kind != KPRowSlider || !KPSliderLevel(KPSettingsSliderTrack(r), point, began, &next)) return NO;
  const float now = [self levelOf:row];
  if (std::fabs(next - now) < 0.005f) return YES;
  if (std::floor(next * 20) != std::floor(now * 20)) KPUIPlay(KPUISound::Tick);
  self.sliding = row;
  self.slidingLevel = next;
  __weak KPSettingsScreen *weakSelf = self;
  KPSaveSlideSoon(^{
    row.setLevel(next);
    KPSettingsScreen *screen = weakSelf;
    if (screen.sliding == row && screen.slidingLevel == next) screen.sliding = nil;
    [screen refreshRows];
  });
  self.rowButtons[visible].needsDisplay = YES;
  return YES;
}

- (void)press:(NSInteger)visible {
  KPSettingRow *row = [self rowAt:visible];
  if (row == nil) return;
  KPSaveSlide();
  switch (row.kind) {
    case KPRowSwitch: row.setOn(!row.on()); break;
    case KPRowChoice: row.setIndex((row.index() + 1) % (NSInteger)row.choices.count); break;
    case KPRowSlider: row.setLevel(row.level() > 0.01f ? 0 : 1); break;
    case KPRowAction: if (row.run) row.run(); break;
  }
  [self refreshRows];
}

#pragma mark Drawing

- (void)drawRow:(NSInteger)visible context:(CGContextRef)c in:(CGRect)r state:(KPUIState)state {
  KPSettingRow *row = [self rowAt:visible];
  if (row == nil) return;
  KPButtonFace(c, r, KPStyle::Plain, NO, YES, state.pressed, state.focused);
  const CGFloat dy = state.pressed ? 2 : 0;
  const CGFloat controlWidth = row.kind == KPRowSwitch ? 90 : row.kind == KPRowAction ? 220 : 300;
  const CGFloat textWidth = r.size.width - controlWidth - 60;
  if (row.detail.length) {
    KPTextWeight(row.title, CGRectMake(r.origin.x + 22, r.origin.y + 9 + dy, textWidth, 28), 21, KPP->text, NSFontWeightSemibold,
                 NSTextAlignmentLeft);
    KPTextWeight(row.detail, CGRectMake(r.origin.x + 22, r.origin.y + 37 + dy, textWidth, 22), 15, KPP->secondaryText,
                 NSFontWeightRegular, NSTextAlignmentLeft);
  } else {
    KPTextWeight(row.title, CGRectMake(r.origin.x + 22, CGRectGetMidY(r) - 16 + dy, textWidth, 30), 21, KPP->text, NSFontWeightSemibold,
                 NSTextAlignmentLeft);
  }
  const CGFloat right = CGRectGetMaxX(r) - 20, mid = CGRectGetMidY(r) - 1.5 + dy;
  if (row.restart && row.restart()) {
    NSString *badge = @"Restart to Apply";
    const CGSize size = KPTextSize(badge, 14, NSFontWeightBold);
    const CGRect pill = CGRectMake(right - controlWidth - size.width - 40, mid - 13, size.width + 22, 26);
    KPFill(c, pill, 0xf0a030, 13, 0.25);
    KPTextWeight(badge, CGRectMake(pill.origin.x, pill.origin.y + 4, pill.size.width, 20), 14, KPP == &KPDarkPalette ? 0xffd28a : 0x8a4b00,
                 NSFontWeightBold);
  }
  switch (row.kind) {
    case KPRowSwitch:
      KPSwitch(c, CGRectMake(right - 72, mid - 17, 72, 34), row.on());
      break;
    case KPRowChoice: {
      const NSInteger index = row.index();
      const CGRect box = CGRectMake(right - controlWidth, mid - 20, controlWidth, 40);
      KPFill(c, box, KPP->well, 20);
      KPStroke(c, box, KPP->buttonStroke, 1, 20);
      const BOOL canLeft = index > 0, canRight = index + 1 < (NSInteger)row.choices.count;
      KPDrawGlyph(c, KPUIGlyph::Back, CGRectMake(box.origin.x + 8, mid - 12, 24, 24), canLeft ? KPP->accentBottom : KPP->buttonStroke);
      KPDrawGlyph(c, KPUIGlyph::Chevron, CGRectMake(CGRectGetMaxX(box) - 32, mid - 12, 24, 24), canRight ? KPP->accentBottom : KPP->buttonStroke);
      NSString *value = index >= 0 && index < (NSInteger)row.choices.count ? row.choices[index] : @"—";
      KPTextWeight(value, CGRectMake(box.origin.x + 34, mid - 13, box.size.width - 68, 26), 18, KPP->text, NSFontWeightSemibold);
      break;
    }
    case KPRowSlider: {
      const float level = [self levelOf:row];
      // With Sound off the levels keep their place, greyed, as HOME's volume does.
      const BOOL silenced = row.soundLevel && self.config.audioMuted.value_or(false);
      KPDrawSlider(c, CGRectOffset(KPSettingsSliderTrack(r), 0, dy), level, silenced);
      KPTextWeight([NSString stringWithFormat:@"%d%%", (int)std::lround(level * 100)], CGRectMake(right - 62, mid - 13, 62, 26), 18,
                   silenced ? KPP->secondaryText : KPP->text, NSFontWeightSemibold, NSTextAlignmentRight);
      break;
    }
    case KPRowAction: {
      NSString *value = row.value ? row.value() : nil;
      if (value.length)
        KPTextWeight(value, CGRectMake(right - controlWidth, mid - 13, controlWidth - 36, 26), 17, KPP->secondaryText,
                     NSFontWeightMedium, NSTextAlignmentRight);
      if (row.inPlace) KPDrawGlyph(c, KPUIGlyph::Find, CGRectMake(right - 32, mid - 16, 32, 32), KPP->accentBottom);
      else KPDrawGlyph(c, KPUIGlyph::Chevron, CGRectMake(right - 28, mid - 14, 28, 28), KPP->accentBottom);
      break;
    }
  }
}

- (void)drawDesign:(CGContextRef)c size:(CGSize)size {
  [super drawDesign:c size:size];
  const CGRect s = self.safe;
  KPDrawGlyph(c, KPUIGlyph::Gear, CGRectMake(s.origin.x + 52, s.origin.y + 30, 42, 42), KPP->accentBottom);
  KPTextWeight(@"Settings", CGRectMake(s.origin.x + 106, s.origin.y + 26, 400, 50), 36, KPP->text, NSFontWeightBold, NSTextAlignmentLeft);
  const NSInteger count = (NSInteger)self.rows[self.category].count;
  if (count > KPSettingsVisibleRows) {
    KPFill(c, self.gaugeTrack, KPP->buttonStroke, 4, 0.45);
    KPFill(c, self.gaugeThumb, KPP->accentBottom, 4);
  }
  KPDrawHints(c, CGRectMake(s.origin.x + 52, s.origin.y + 672, 1176, 26),
              {{KartPadMiiPadConfirm, @"Select"}, {KartPadMiiPadLeft, @"Adjust", KartPadMiiPadRight},
               {KartPadMiiPadPreviousTab, @"Category", KartPadMiiPadNextTab}, {KartPadMiiPadBack, @"Back"}}, 16, NSTextAlignmentRight);
}

#pragma mark Rows

- (void)makeRows {
  __weak KPSettingsScreen *weakSelf = self;
  auto config = [weakSelf]() -> RuntimeUserConfig { return weakSelf ? weakSelf.config : RuntimeConfigFile::LoadConfigFile(); };
  // By value: the blocks these make outlive this method, so nothing they use may point into it.
  auto boolRow = [config](NSString *title, NSString *detail, const char *section, const char *key, bool fallback,
                     bool (^read)(const RuntimeUserConfig &), bool invert, bool reload) {
    KPSettingRow *row = KPRow(title, detail, KPRowSwitch);
    std::string sectionText = section, keyText = key;
    auto settings = config;
    row.on = ^BOOL { const bool v = read(settings()); return invert ? !v : v; };
    row.setOn = ^(BOOL on) { KPWriteConfig(sectionText.c_str(), keyText.c_str(), (invert ? !on : on) ? "true" : "false", reload); };
    (void)fallback;
    return row;
  };
  auto levelRow = [config](NSString *title, const char *key, float (^read)(const RuntimeUserConfig &)) {
    KPSettingRow *row = KPRow(title, nil, KPRowSlider);
    row.soundLevel = YES;
    std::string keyText = key;
    auto settings = config;
    row.level = ^float { return std::clamp(read(settings()), 0.0f, 1.0f); };
    row.setLevel = ^(float level) { KPWriteConfig("audio", keyText.c_str(), KPFloatText(std::round(level * 100) / 100)); };
    return row;
  };

  // Picture.
  NSMutableArray *picture = [NSMutableArray array];
  {
    KPSettingRow *row = KPRow(@"Full screen", nil, KPRowSwitch);
    row.on = ^BOOL { return aurora_get_display_mode() != AURORA_DISPLAY_MODE_WINDOWED; };
    row.setOn = ^(BOOL on) {
      if (on != (aurora_get_display_mode() != AURORA_DISPLAY_MODE_WINDOWED)) [Controller() toggleGameFullScreen:nil];
    };
    [picture addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Picture quality", nil, KPRowChoice);
    NSArray<NSNumber *> *values = @[@0, @1, @1.5, @2, @3, @4, @6, @8];
    row.choices = @[@"Auto", @"1×", @"1.5×", @"2×", @"3×", @"4×", @"6×", @"8×"];
    row.index = ^NSInteger {
      const float value = config().resolutionMultiplier.value_or(1.0f);
      NSInteger best = 1;
      for (NSInteger i = 0; i < (NSInteger)values.count; ++i)
        if (std::fabs(values[i].floatValue - value) < std::fabs(values[best].floatValue - value)) best = i;
      return best;
    };
    row.setIndex = ^(NSInteger index) {
      float value = values[index].floatValue;
      // The renderer's limit with smoother motion on.
      if (config().frameInterpolationFps.value_or(0) > 60 && value > 4) value = 4;
      KPWriteConfig("video", "resolution_multiplier", KPFloatText(value));
    };
    [picture addObject:row];
  }
  [picture addObject:boolRow(@"Sharper picture", nil, "video", "disable_copy_filter", true,
                             ^bool(const RuntimeUserConfig &c) { return c.disableCopyFilter.value_or(true); }, false, true)];
  {
    KPSettingRow *row = KPRow(@"Bloom", nil, KPRowSwitch);
    row.on = ^BOOL { return (config().disabledPostProcessingPaths.value_or(0) & 0x10u) == 0; };
    row.setOn = ^(BOOL on) {
      uint32_t mask = config().disabledPostProcessingPaths.value_or(0);
      mask = on ? mask & ~0x10u : mask | 0x10u;
      KPWriteConfig("video", "disabled_post_processing_paths", std::to_string(mask));
    };
    [picture addObject:row];
  }
  [picture addObject:boolRow(@"Show frame rate", nil, "video", "show_fps", false,
                             ^bool(const RuntimeUserConfig &c) { return c.showFps.value_or(false); }, false, true)];
  {
    KPSettingRow *row = KPRow(@"Smoother motion", @"Caps picture quality at 4×.", KPRowChoice);
    NSArray<NSNumber *> *values = @[@0, @120, @180];
    row.choices = @[@"Off · 60 fps", @"120 fps", @"180 fps"];
    row.index = ^NSInteger {
      const NSUInteger index = [values indexOfObject:@(config().frameInterpolationFps.value_or(0))];
      return index == NSNotFound ? 0 : (NSInteger)index;
    };
    row.setIndex = ^(NSInteger index) {
      if (index > 0 && config().resolutionMultiplier.value_or(1) > 4) KPWriteConfig("video", "resolution_multiplier", "4", false);
      KPWriteConfig("video", "frame_interpolation_fps", std::to_string(values[index].intValue));
    };
    [picture addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Full-screen style", nil, KPRowChoice);
    row.choices = @[@"Standard", @"Exclusive"];
    row.index = ^NSInteger {
      const AuroraDisplayMode mode = aurora_get_display_mode();
      if (mode == AURORA_DISPLAY_MODE_EXCLUSIVE) return 1;
      if (mode == AURORA_DISPLAY_MODE_BORDERLESS) return 0;
      return [[NSUserDefaults.standardUserDefaults stringForKey:kKartPadFullScreenModeDefaultsKey] isEqualToString:@"exclusive"] ? 1 : 0;
    };
    row.setIndex = ^(NSInteger index) {
      NSString *mode = index ? @"exclusive" : @"borderless";
      [NSUserDefaults.standardUserDefaults setObject:mode forKey:kKartPadFullScreenModeDefaultsKey];
      if (aurora_get_display_mode() != AURORA_DISPLAY_MODE_WINDOWED)
        KPWriteConfig("video", "display_mode", RuntimeConfigFile::FormatString(mode.UTF8String));
    };
    [picture addObject:row];
  }

  // Sound.
  NSMutableArray *sound = [NSMutableArray array];
  [sound addObject:boolRow(@"Sound", nil, "audio", "muted", false,
                           ^bool(const RuntimeUserConfig &c) { return c.audioMuted.value_or(false); }, true, true)];
  [sound addObject:levelRow(@"Master volume", "volume", ^float(const RuntimeUserConfig &c) { return c.audioVolume.value_or(1); })];
  [sound addObject:levelRow(@"Music", "music_volume", ^float(const RuntimeUserConfig &c) { return c.audioMusicVolume.value_or(1); })];
  [sound addObject:levelRow(@"Sound effects", "sound_effects_volume",
                            ^float(const RuntimeUserConfig &c) { return c.audioSoundEffectsVolume.value_or(1); })];
  [sound addObject:levelRow(@"Menu sounds in the game", "ui_volume", ^float(const RuntimeUserConfig &c) { return c.audioUiVolume.value_or(1); })];
  [sound addObject:levelRow(@"Character voices", "voices_volume",
                            ^float(const RuntimeUserConfig &c) { return c.audioVoicesVolume.value_or(1); })];
  {
    KPSettingRow *row = KPRow(@"HOME and Mii sounds", nil, KPRowSwitch);
    row.on = ^BOOL { return KartPadUISoundsEnabled(); };
    row.setOn = ^(BOOL on) {
      KartPadUISetSoundsEnabled(on);
      if (on) KPUIPlay(KPUISound::Confirm);
    };
    [sound addObject:row];
  }

  // Controls.
  NSMutableArray *controls = [NSMutableArray array];
  {
    KPSettingRow *row = KPRow(@"Controllers", nil, KPRowAction);
    row.run = ^{ [KPOverlay() present:(KPScreen *)KPMakeControllersScreen(-1)]; };
    row.value = ^NSString * {
      NSInteger playing = 0;
      for (KPPadDevice *device in KPControllerRoster.shared.devices)
        if (device.slot >= 0) ++playing;
      if (playing == 0) return @"None";
      return playing == 1 ? @"1 player" : [NSString stringWithFormat:@"%ld players", (long)playing];
    };
    [controls addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Vibration", nil, KPRowChoice);
    row.choices = @[@"Off", @"Light", @"Medium", @"Strong"];
    row.index = ^NSInteger {
      const RuntimeUserConfig c = config();
      if (!c.rumbleEnabled.value_or(true)) return 0;
      const float strength = std::clamp(c.rumbleStrength.value_or(0.5f), 0.0f, 1.0f);
      return strength < 0.375f ? 1 : strength < 0.75f ? 2 : 3;
    };
    row.setIndex = ^(NSInteger index) {
      KPWriteConfig("controller", "rumble", index > 0 ? "true" : "false", index == 0);
      if (index > 0) KPWriteConfig("controller", "rumble_strength", KPFloatText(KPVibrationStrengths()[index].floatValue));
    };
    [controls addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Test vibration", nil, KPRowAction);
    row.inPlace = YES;
    row.run = ^{
      const RuntimeUserConfig c = config();
      const auto level = static_cast<Uint16>(std::lround(std::clamp(c.rumbleStrength.value_or(0.5f), 0.0f, 1.0f) * 65535.0f));
      int tested = 0;
      if (c.rumbleEnabled.value_or(true))
        for (KPPadDevice *device in KPControllerRoster.shared.devices)
          if (device.canRumble && device.gamepad && SDL_RumbleGamepad(device.gamepad, level, level, 500)) ++tested;
      if (tested == 0)
        [KPOverlay() toast:c.rumbleEnabled.value_or(true) ? @"No controller that can vibrate" : @"Vibration is off"
                    detail:nil stripe:0 icon:^(CGContextRef ctx, CGRect r) { KPDrawGlyph(ctx, KPUIGlyph::Pad, r, KPP->secondaryText); }
                     image:nil];
    };
    [controls addObject:row];
  }

  {
    KPSettingRow *row = KPRow(@"Hide the mouse pointer", nil, KPRowChoice);
    NSArray<NSNumber *> *values = @[@0, @3, @5, @10];
    row.choices = @[@"Never", @"After 3 s", @"After 5 s", @"After 10 s"];
    row.index = ^NSInteger {
      const NSUInteger index = [values indexOfObject:@(config().cursorAutoHideSeconds.value_or(3))];
      return index == NSNotFound ? 1 : (NSInteger)index;
    };
    row.setIndex = ^(NSInteger index) { KPWriteConfig("video", "cursor_auto_hide_seconds", std::to_string(values[index].intValue)); };
    [controls addObject:row];
  }

  // Game.
  NSMutableArray *game = [NSMutableArray array];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  {
    KPSettingRow *row = KPRow(@"Start KartPad with", nil, KPRowChoice);
    row.choices = @[@"Mario Kart Wii", @"Retro Rewind"];
    row.index = ^NSInteger {
      return [[NSUserDefaults.standardUserDefaults stringForKey:kKartPadRuntimeProfileDefaultsKey] isEqualToString:kKartPadRetroProfile] ? 1 : 0;
    };
    row.setIndex = ^(NSInteger index) {
      if (index == 1 && !KPRetroRewindReady()) {
        KPUIPlay(KPUISound::Reject);
        [KPOverlay() toast:@"Retro Rewind isn’t set up yet" detail:@"Set up Retro Rewind files below first." stripe:0
                      icon:^(CGContextRef c, CGRect r) { KPDrawGlyph(c, KPUIGlyph::Disc, r, KPP->secondaryText); } image:nil];
        return;
      }
      [Controller() chooseRuntimeProfile:index ? kKartPadRetroProfile : kKartPadBaseProfile];
    };
    row.restart = ^BOOL { return [Controller().restartReasons containsObject:@"game"]; };
    [game addObject:row];
  }
#endif
  {
    KPSettingRow *row = KPRow(@"Pause when you switch apps", nil, KPRowSwitch);
    row.on = ^BOOL { return KPBackgroundPauseEnabled(); };
    row.setOn = ^(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:kKartPadBackgroundPauseDefaultsKey]; };
    [game addObject:row];
  }
  [game addObject:boolRow(@"Discord Rich Presence", nil, "discord", "enabled", false,
                          ^bool(const RuntimeUserConfig &c) { return c.discordPresenceEnabled.value_or(false); }, false, true)];
  {
    KPSettingRow *row = KPRow(@"Miis", nil, KPRowAction);
    row.run = ^{ [KPOverlay() present:KPMakeMiisScreen()]; };
    row.restart = ^BOOL { return KartPadHasPendingMiiChanges(); };
    [game addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Time Trial ghosts", nil, KPRowAction);
    row.run = ^{ [KPOverlay() present:KPMakeGhostsScreen()]; };
    row.restart = ^BOOL { return KartPadHasPendingGhost(); };
    [game addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Mario Kart Wii files", @"Needs a mouse.", KPRowAction);
    row.value = ^NSString * { return KPGameDataReady() ? @"Ready" : @"Needs attention"; };
    row.run = ^{
      [KPOverlay() closeAll];
      dispatch_async(dispatch_get_main_queue(), ^{ [Controller() chooseGameData:nil]; });
    };
    row.restart = ^BOOL { return [Controller().restartReasons containsObject:@"game-data"]; };
    [game addObject:row];
  }
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  {
    KPSettingRow *row = KPRow(@"Retro Rewind files", nil, KPRowAction);
    row.value = ^NSString * {
      if (KPRetroRewindReady()) return [NSString stringWithFormat:@"Ready · %@", @KARTPAD_RR_VERSION];
      KPRetroDownload *download = KPRetroDownload.shared;
      if (download.available) return download.stage == KPRetroIdle ? @"Download · 2 GB" : download.summary;
      return @"Not set up";
    };
    // Downloaded for the player where this KartPad can; otherwise (or to use one already here) a folder.
    row.run = ^{
      if (!KPRetroRewindReady() && KPRetroDownload.shared.available) {
        KPRetroDownload *download = KPRetroDownload.shared;
        KPShowRetroDownload(download.stage == KPRetroIdle || download.stage == KPRetroFailed);
        return;
      }
      [KPOverlay() closeAll];
      dispatch_async(dispatch_get_main_queue(), ^{ [Controller() chooseRetroRewindData:nil]; });
    };
    row.restart = ^BOOL { return [Controller().restartReasons containsObject:@"retro-data"]; };
    [game addObject:row];
  }
#endif

  // Advanced.
  NSMutableArray *advanced = [NSMutableArray array];
  [advanced addObject:boolRow(@"Skip effects still loading", @"Less stutter the first time a course loads.", "video",
                              "skip_unready_pipelines", true,
                              ^bool(const RuntimeUserConfig &c) { return c.skipUnreadyPipelines.value_or(true); }, false, true)];
  {
    KPSettingRow *row = KPRow(@"VSync (Experimental)", nil, KPRowSwitch);
    row.on = ^BOOL { return config().vsync.value_or(false); };
    row.setOn = ^(BOOL on) {
      if (!KPWriteConfig("video", "vsync", on ? "true" : "false", false)) return;
      [Controller() setRestartNeeded:on != KPLaunchVsync for:@"vsync"];
    };
    row.restart = ^BOOL { return [Controller().restartReasons containsObject:@"vsync"]; };
    [advanced addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Use the notch area", nil, KPRowSwitch);
    row.on = ^BOOL { return KPFullscreenAcrossNotch(); };
    row.setOn = ^(BOOL on) {
      if (!KPWriteConfig("video", "fullscreen_across_notch", on ? "true" : "false", false)) return;
      [Controller() setRestartNeeded:on != KPLaunchNotch for:@"notch"];
    };
    row.restart = ^BOOL { return [Controller().restartReasons containsObject:@"notch"]; };
    [advanced addObject:row];
  }
  [advanced addObject:boolRow(@"Mix audio on its own thread", @"Turn off only if sound crackles.", "audio", "mix_worker", true,
                              ^bool(const RuntimeUserConfig &c) { return c.audioMixWorker.value_or(true); }, false, true)];
  auto legacy = [](NSString *title, NSString *detail, SEL action) {
    KPSettingRow *row = KPRow(title, detail, KPRowAction);
    row.run = ^{
      [KPOverlay() closeAll];
      dispatch_async(dispatch_get_main_queue(), ^{
        // Old-style windows open above the game; they need a mouse or the keyboard.
        ((void (*)(id, SEL, id))[Controller() methodForSelector:action])(Controller(), action, nil);
      });
    };
    return row;
  };
  [advanced addObject:legacy(@"Private Wii server", nil, @selector(showPrivateServer:))];
  [advanced addObject:legacy(@"Controller compatibility tools", nil, @selector(showControllerCompatibility:))];
  [advanced addObject:legacy(@"Save a diagnostics report", nil, @selector(saveDiagnostics:))];
  [advanced addObject:legacy(@"Report a problem", nil, @selector(reportProblem:))];
  [advanced addObject:legacy(@"Show KartPad files", nil, @selector(showApplicationSupport:))];
  [advanced addObject:legacy(@"Classic settings window", nil, @selector(showSettings:))];

  self.rows = @[picture, sound, controls, game, advanced];
}
@end

static KPScreen *KPMakeSettingsScreen() { return [[KPSettingsScreen alloc] initWithFrame:NSZeroRect]; }
