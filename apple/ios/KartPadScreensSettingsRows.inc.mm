// -[KPSettingsScreen makeRows] on iPhone and iPad: what the old three-dot menu held, as rows. The
// picture settings are SunPad's (the game reads them every frame, so they apply at once); sound
// keeps the launcher's Sound sheet's settings; actions open the app's own screens for them.
// Included by apple/macos/KartPadSettingsScreen.inc.mm in place of the Mac's rows.
- (void)makeRows {
  __weak KPSettingsScreen *weakSelf = self;
  auto config = [weakSelf]() -> RuntimeUserConfig { return weakSelf ? weakSelf.config : RuntimeConfigFile::LoadConfigFile(); };
  auto action = [](NSString *title, NSString *detail, void (^run)(void)) {
    KPSettingRow *row = KPRow(title, detail, KPRowAction);
    row.run = run;
    return row;
  };

  // Picture.
  NSMutableArray *picture = [NSMutableArray array];
  {
    KPSettingRow *row = KPRow(@"Picture quality", nil, KPRowChoice);
    row.choices = @[@"1× (Native)", @"2×", @"3×", @"4×"];
    row.index = ^NSInteger { return std::clamp<NSInteger>(SunPadSettings.sharedSettings.renderScale - 1, 0, 3); };
    row.setIndex = ^(NSInteger index) {
      SunPadSettings.sharedSettings.renderScale = index + 1;
      [SunPadSettings.sharedSettings synchronize];
    };
    [picture addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Aspect ratio", nil, KPRowChoice);
    row.choices = @[@"Original 4:3", @"16:9 (Experimental)", @"Fill Screen (Experimental)"];
    const std::array<SunPadAspectRatioMode, 3> modes = {SunPadAspectRatioOriginal, SunPadAspectRatioWidescreen, SunPadAspectRatioFillScreen};
    row.index = ^NSInteger {
      for (NSInteger i = 0; i < 3; ++i)
        if (SunPadSettings.sharedSettings.aspectRatioMode == modes[i]) return i;
      return 0;
    };
    row.setIndex = ^(NSInteger index) {
      SunPadSettings.sharedSettings.aspectRatioMode = modes[index];
      [SunPadSettings.sharedSettings synchronize];
    };
    [picture addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Show frame rate", nil, KPRowSwitch);
    row.on = ^BOOL { return SunPadSettings.sharedSettings.showFPSCounter; };
    row.setOn = ^(BOOL on) {
      SunPadSettings.sharedSettings.showFPSCounter = on;
      [SunPadSettings.sharedSettings synchronize];
    };
    [picture addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Frame rate size", nil, KPRowChoice);
    row.choices = @[@"Small", @"Medium", @"Large"];
    row.index = ^NSInteger { return std::clamp<NSInteger>([KPHost() screensFPSCounterSize], 0, 2); };
    row.setIndex = ^(NSInteger index) { [KPHost() screensSetFPSCounterSize:index]; };
    [picture addObject:row];
  }
  if (UIApplication.sharedApplication.supportsAlternateIcons) {
    // Original KartPad artwork only (branding/PROVENANCE.md). nil is the default icon.
    KPSettingRow *row = KPRow(@"App icon", nil, KPRowChoice);
    row.choices = @[@"Red K", @"Circuit", @"Mono"];
    NSArray *names = @[NSNull.null, @"AppIcon-Circuit", @"AppIcon-Mono"];
    row.index = ^NSInteger {
      NSString *current = UIApplication.sharedApplication.alternateIconName;
      for (NSInteger i = 1; i < 3; ++i)
        if ([names[i] isEqual:current]) return i;
      return 0;
    };
    row.setIndex = ^(NSInteger index) {
      NSString *name = names[index] == NSNull.null ? nil : names[index];
      [UIApplication.sharedApplication setAlternateIconName:name completionHandler:^(NSError *error) {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshRows]; });
      }];
    };
    [picture addObject:row];
  }

  // Sound.
  NSMutableArray *sound = [NSMutableArray array];
  {
    KPSettingRow *row = KPRow(@"Sound", nil, KPRowSwitch);
    row.on = ^BOOL { return !config().audioMuted.value_or(false); };
    row.setOn = ^(BOOL on) { KPWriteConfig("audio", "muted", on ? "false" : "true"); };
    [sound addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Volume", nil, KPRowSlider);
    row.soundLevel = YES;
    row.level = ^float { return std::clamp(config().audioVolume.value_or(1.0f), 0.0f, 1.0f); };
    row.setLevel = ^(float level) { KPWriteConfig("audio", "volume", KPFloatText(std::round(level * 100) / 100)); };
    [sound addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Adjust music and game sounds", nil, KPRowSwitch);
    row.on = ^BOOL { return [KPHost() screensSoundCustom]; };
    row.setOn = ^(BOOL on) { [KPHost() screensSetSoundCustom:on]; };
    [sound addObject:row];
  }
  for (const BOOL music : {YES, NO}) {
    KPSettingRow *row = KPRow(music ? @"Music" : @"Game sounds", nil, KPRowSlider);
    row.soundLevel = YES;
    row.level = ^float { return [KPHost() screensSoundCustom] ? [KPHost() screensSoundLevel:music] : 1.0f; };
    row.setLevel = ^(float level) {
      [KPHost() screensSetSoundCustom:YES];
      [KPHost() screensSetSoundLevel:level music:music];
    };
    [sound addObject:row];
  }
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
    KPSettingRow *row = action(@"Controllers", nil, ^{ [KPOverlay() present:(KPScreen *)KPMakeControllersScreen(-1)]; });
    row.value = ^NSString * {
      NSInteger playing = 0;
      for (KPPadDevice *device in KPControllerRoster.shared.devices)
        if (device.slot >= 0) ++playing;
      return playing == 1 ? @"1 player" : [NSString stringWithFormat:@"%ld players", (long)playing];
    };
    [controls addObject:row];
  }
  [controls addObject:action(@"Controller buttons", nil, ^{ [KPHost() screensShowButtonMapping]; })];
  {
    KPSettingRow *row = KPRow(@"Vibration", nil, KPRowSwitch);
    row.on = ^BOOL { return KPVibrationEnabled(); };
    row.setOn = ^(BOOL on) {
      [NSUserDefaults.standardUserDefaults setBool:on forKey:KPVibrationKey];
      if (!on) KPRumbleStopAll();
    };
    [controls addObject:row];
  }
  {
    KPSettingRow *row = KPRow(@"Nintendo button layout", nil, KPRowSwitch);
    row.on = ^BOOL { return KartPadNintendoLayoutEnabled(); };
    row.setOn = ^(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:KartPadNintendoLayoutKey]; };
    [controls addObject:row];
  }
  [controls addObject:action(@"Touch controls", nil, ^{ [KPHost() screensShowTouchControls]; })];
  [controls addObject:action(@"Motion steering", nil, ^{ [KPHost() screensShowMotionSteering]; })];
  [controls addObject:action(@"Shake to trick", nil, ^{ [KPHost() screensShowShakeTricks]; })];

  // Game.
  NSMutableArray *game = [NSMutableArray array];
  {
    KPSettingRow *row = KPRow(@"Start KartPad with", nil, KPRowChoice);
    row.choices = @[@"Ask every time", @"Mario Kart Wii", @"Retro Rewind"];
    NSArray *values = @[@"ask", kKartPadBaseProfile, kKartPadRetroProfile];
    row.index = ^NSInteger {
      const NSUInteger index =
          [values indexOfObject:[NSUserDefaults.standardUserDefaults stringForKey:kKartPadPreferredGameKey] ?: @"ask"];
      return index == NSNotFound ? 0 : (NSInteger)index;
    };
    row.setIndex = ^(NSInteger index) {
      if (index == 2 && !KPRetroRewindReady()) {
        KPUIPlay(KPUISound::Reject);
        [KPOverlay() toast:@"Retro Rewind isn’t set up yet" detail:@"Set up Retro Rewind files below first." stripe:0
                      icon:^(CGContextRef c, CGRect r) { KPDrawGlyph(c, KPUIGlyph::Disc, r, KPP->secondaryText); } image:nil];
        return;
      }
      [NSUserDefaults.standardUserDefaults setObject:values[index] forKey:kKartPadPreferredGameKey];
    };
    [game addObject:row];
  }
  {
    KPSettingRow *row = action(@"Miis", nil, ^{ [KPOverlay() present:KPMakeMiisScreen()]; });
    row.restart = ^BOOL { return KartPadHasPendingMiiChanges(); };
    [game addObject:row];
  }
  {
    KPSettingRow *row = action(@"Time Trial ghosts", nil, ^{ [KPOverlay() present:KPMakeGhostsScreen()]; });
    row.restart = ^BOOL { return KartPadHasPendingGhost(); };
    [game addObject:row];
  }
  [game addObject:action(@"Saves", nil, ^{ [KPHost() screensManageSaves]; })];
  [game addObject:action(@"Multiplayer", nil, ^{ [KPHost() screensShowMultiplayer]; })];
  {
    KPSettingRow *row = action(@"Retro Rewind files", nil, ^{ [KPHost() screensManageRetroRewind]; });
    row.value = ^NSString * { return KPRetroRewindReady() ? @"Ready" : @"Not set up"; };
    [game addObject:row];
  }
  [game addObject:action(@"KartPad menu", nil, ^{ [KPHost() screensReturnToLauncher]; })];

  // Advanced.
  NSMutableArray *advanced = [NSMutableArray array];
  [advanced addObject:action(@"Mario Kart Wii files", nil, ^{ [KPHost() screensManageGameData]; })];
  [advanced addObject:action(@"Private Wii server", nil, ^{ [KPHost() screensShowPrivateServer]; })];
  [advanced addObject:action(@"Wii Remote + Nunchuk", nil, ^{ [KPHost() screensShowWiiRemoteInfo]; })];
  [advanced addObject:action(@"Report a problem", nil, ^{ [KPHost() screensReportProblem]; })];
  if ([KPHost() screensDiagnosticsAvailable])
    [advanced addObject:action(@"Test native crash", @"Closes KartPad.", ^{ [KPHost() screensTestNativeCrash]; })];

  self.rows = @[picture, sound, controls, game, advanced];
}
