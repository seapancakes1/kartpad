// Methods of KartPadMacShellController. Runtime changes are queued to the
// existing frame boundary, not applied while AppKit is pumping native events.
- (NSView *)settingsPage:(NSString *)title {
  NSView *page=[[NSView alloc] initWithFrame:NSMakeRect(0,0,780,740)];
  NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,780,740)];
  scroll.hasVerticalScroller=YES; scroll.autohidesScrollers=YES;
  scroll.drawsBackground=NO; scroll.documentView=page;
  NSTabViewItem *item=[[NSTabViewItem alloc] initWithIdentifier:title];
  item.label=title;item.view=scroll;[self.settingsTabs addTabViewItem:item];
  return page;
}
- (NSTextField *)settingsLabel:(NSString *)text page:(NSView *)page y:(CGFloat)y {
  NSTextField *label=[self label:text];label.frame=NSMakeRect(24,y,725,44);
  label.maximumNumberOfLines=2;label.lineBreakMode=NSLineBreakByWordWrapping;
  [page addSubview:label];return label;
}
- (void)setting:(NSString *)key label:(NSString *)label choices:(NSArray *)titles
        values:(NSArray *)values page:(NSView *)page y:(CGFloat)y {
  [self settingsLabel:label page:page y:y-20];
  NSPopUpButton *control=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(290,y,380,28) pullsDown:NO];
  [control addItemsWithTitles:titles];control.identifier=key;control.accessibilityLabel=label;
  control.target=self;control.action=@selector(settingChanged:);
  self.settingControls[key]=control;self.settingChoices[key]=values;
  [page addSubview:control];
}
- (void)setting:(NSString *)key checkbox:(NSString *)title page:(NSView *)page y:(CGFloat)y {
  NSButton *control=[NSButton checkboxWithTitle:title target:self action:@selector(settingChanged:)];
  control.frame=NSMakeRect(24,y,715,28);control.identifier=key;
  self.settingControls[key]=control;[page addSubview:control];
}
- (void)setting:(NSString *)key volume:(NSString *)title page:(NSView *)page y:(CGFloat)y {
  [self settingsLabel:title page:page y:y-20];
  NSSlider *control=[NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:@selector(settingChanged:)];
  control.frame=NSMakeRect(240,y,390,26);control.identifier=key;control.accessibilityLabel=title;
  control.continuous=NO;self.settingControls[key]=control;[page addSubview:control];
  NSTextField *value=[self label:@"100%"];
  value.frame=NSMakeRect(648,y,90,24);[page addSubview:value];self.settingValues[key]=value;
}
- (void)settingsHeading:(NSString *)text page:(NSView *)page y:(CGFloat)y {
  NSTextField *heading=[self label:text];heading.font=[NSFont boldSystemFontOfSize:13];
  heading.frame=NSMakeRect(24,y,725,22);[page addSubview:heading];
}
- (void)settingsButton:(NSString *)title action:(SEL)action page:(NSView *)page y:(CGFloat)y {
  NSButton *button=[NSButton buttonWithTitle:title target:self action:action];
  button.frame=NSMakeRect(24,y,350,32);[page addSubview:button];
}
- (void)refreshSettings {
  const auto c=RuntimeConfigFile::LoadConfigFile();
  NSDictionary *values=@{
    @"video.fullscreen_across_notch":@(KPFullscreenAcrossNotch()),
    @"video.resolution_multiplier":@(c.resolutionMultiplier.value_or(1.0f)),
    @"video.display_mode":[NSString stringWithUTF8String:c.displayMode.value_or("windowed").c_str()],
    @"video.frame_interpolation_fps":@(c.frameInterpolationFps.value_or(0)),
    @"video.vsync":@(c.vsync.value_or(false)),
    @"video.show_fps":@(c.showFps.value_or(true)),
    @"video.cursor_auto_hide_seconds":@(c.cursorAutoHideSeconds.value_or(3)),
    @"video.disable_copy_filter":@(c.disableCopyFilter.value_or(true)),
    @"video.skip_unready_pipelines":@(c.skipUnreadyPipelines.value_or(true)),
    @"video.disabled_post_processing_paths":@((c.disabledPostProcessingPaths.value_or(0)&0x10)!=0),
    @"audio.volume":@(c.audioVolume.value_or(1.0f)),
    @"audio.music_volume":@(c.audioMusicVolume.value_or(1.0f)),
    @"audio.sound_effects_volume":@(c.audioSoundEffectsVolume.value_or(1.0f)),
    @"audio.ui_volume":@(c.audioUiVolume.value_or(1.0f)),
    @"audio.voices_volume":@(c.audioVoicesVolume.value_or(1.0f)),
    @"audio.muted":@(c.audioMuted.value_or(false)),
    @"audio.mix_worker":@(c.audioMixWorker.value_or(true)),
    @"discord.enabled":@(c.discordPresenceEnabled.value_or(true))};
  for(NSString *key in self.settingControls) {
    NSControl *control=self.settingControls[key];id value=values[key];
    if([control isKindOfClass:NSPopUpButton.class]) {
      NSUInteger index=[self.settingChoices[key] indexOfObject:value];
      if(index!=NSNotFound)[(NSPopUpButton *)control selectItemAtIndex:index];
    } else if([control isKindOfClass:NSSlider.class]) {
      control.doubleValue=[value doubleValue]*100;
      self.settingValues[key].stringValue=[NSString stringWithFormat:@"%.0f%%",control.doubleValue];
    } else [(NSButton *)control setState:[value boolValue]?NSControlStateValueOn:NSControlStateValueOff];
  }
  [self refreshPadShortcuts];
}
// VSync and full-display fullscreen as KartPad started, read when Settings (this panel or the HOME
// one) is first built; only Settings changes them.
static bool KPLaunchVsync,KPLaunchNotch,KPLaunchDisplayRead;
static void KPReadLaunchDisplaySettings() {
  if(KPLaunchDisplayRead)return;
  KPLaunchDisplayRead=true;KPLaunchVsync=RuntimeConfigFile::LoadConfigFile().vsync.value_or(false);KPLaunchNotch=KPFullscreenAcrossNotch();
}
static NSArray<NSNumber *> *KPPadShortcutHolds() { return @[@0.5,@1,@2,@3]; }
// "View for 1 second"
static NSString *KPPadShortcutPhrase(int kind) {
  const NSTimeInterval hold=KPPadShortcutHold(kind);
  NSString *time=hold<1?@"½ second":hold==1?@"1 second":[NSString stringWithFormat:@"%g seconds",hold];
  return [NSString stringWithFormat:@"%@ for %@",KPPadButtonNames(KPPadShortcutButtons(kind)),time];
}
// Off, then Light, Medium and Strong: the rumble strengths behind them.
static NSArray<NSNumber *> *KPVibrationStrengths() { return @[@0,@0.25,@0.5,@1]; }
- (void)refreshPadShortcuts {
  const bool capturing=KPPadCapturing();
  for(int kind=0;kind<KPPadShortcutCount;++kind) {
    const bool on=KPPadShortcutEnabled(kind),choosing=capturing&&self.capturingShortcut==kind;
    self.padShortcutSwitches[kind].state=on?NSControlStateValueOn:NSControlStateValueOff;
    self.padShortcutButtons[kind].stringValue=choosing?@"Hold the new buttons…":[@"Hold " stringByAppendingString:KPPadButtonNames(KPPadShortcutButtons(kind))];
    self.padShortcutButtons[kind].textColor=on?NSColor.labelColor:NSColor.disabledControlTextColor;
    self.padShortcutChoose[kind].title=choosing?@"Cancel":@"Change Buttons…";
    self.padShortcutChoose[kind].enabled=on&&(!capturing||choosing);self.padShortcutHolds[kind].enabled=on&&!choosing;
    NSUInteger index=[KPPadShortcutHolds() indexOfObject:@(KPPadShortcutHold(kind))];
    [self.padShortcutHolds[kind] selectItemAtIndex:index==NSNotFound?1:index];
  }
  const auto c=RuntimeConfigFile::LoadConfigFile();
  NSInteger vibration=0;
  if(c.rumbleEnabled.value_or(true)) {
    // The nearest of Light, Medium and Strong.
    const float strength=std::clamp(c.rumbleStrength.value_or(0.5f),0.0f,1.0f);
    vibration=strength<0.375f?1:strength<0.75f?2:3;
  }
  [self.vibrationChoice selectItemAtIndex:vibration];
  self.backgroundPauseSwitch.state=KPBackgroundPauseEnabled()?NSControlStateValueOn:NSControlStateValueOff;
  self.settingsRestart.hidden=!self.restartPending;
}
- (NSString *)padShortcutSaved:(int)kind {
  return KPPadShortcutEnabled(kind)?[NSString stringWithFormat:@"Saved. Hold %@ to open %@.",KPPadShortcutPhrase(kind),KPPadShortcuts[kind].opens]:
      [NSString stringWithFormat:@"Saved. Controllers no longer open %@.",KPPadShortcuts[kind].opens];
}
- (void)padShortcutChanged:(NSControl *)sender {
  const int kind=(int)sender.tag;NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
  if([sender isKindOfClass:NSPopUpButton.class]) {
    [defaults setDouble:KPPadShortcutHolds()[((NSPopUpButton *)sender).indexOfSelectedItem].doubleValue forKey:KPPadShortcuts[kind].holdKey];
  } else {
    [defaults setBool:((NSButton *)sender).state==NSControlStateValueOn forKey:KPPadShortcuts[kind].enabledKey];
    if(!KPPadShortcutEnabled(kind)&&self.capturingShortcut==kind)KPPadCancelCapture();
  }
  self.settingsStatus.stringValue=[self padShortcutSaved:kind];
  [self refreshPadShortcuts];
}
// The buttons are whatever is held together on a controller before everything is let go.
- (void)choosePadShortcutButtons:(NSButton *)sender {
  const int kind=(int)sender.tag;
  if(KPPadCapturing()) {
    KPPadCancelCapture();
    self.settingsStatus.stringValue=[NSString stringWithFormat:@"%@ still opens with %@.",KPPadShortcuts[kind].opens,KPPadButtonNames(KPPadShortcutButtons(kind))];
    [self refreshPadShortcuts];return;
  }
  self.capturingShortcut=kind;
  __weak KartPadMacShellController *weak=self;
  KPPadBeginCapture(^(uint64_t buttons) {
    KPPadShortcutSetButtons(kind,buttons);
    NSString *saved=[weak padShortcutSaved:kind],*warning=KPPadButtonsWarning(buttons);
    weak.settingsStatus.stringValue=warning?[NSString stringWithFormat:@"%@ %@",saved,warning]:saved;
    [weak refreshPadShortcuts];
  });
  self.settingsStatus.stringValue=[NSString stringWithFormat:@"Hold the new buttons together on any controller, then let go. Cancel keeps %@.",KPPadButtonNames(KPPadShortcutButtons(kind))];
  [self refreshPadShortcuts];
}
- (void)vibrationChanged:(NSPopUpButton *)sender {
  const NSInteger index=sender.indexOfSelectedItem;
  std::ostringstream strength;strength<<KPVibrationStrengths()[index].floatValue;
  if(!RuntimeConfigFile::WriteSetting("controller","rumble",index>0?"true":"false")||
     (index>0&&!RuntimeConfigFile::WriteSetting("controller","rumble_strength",strength.str()))) {
    self.settingsStatus.stringValue=@"Could not save this setting. Check that Config.toml is writable.";
    [self refreshPadShortcuts];return;
  }
  self.settingsStatus.stringValue=index>0?[NSString stringWithFormat:@"Saved. Vibration is %@.",sender.titleOfSelectedItem.lowercaseString]:@"Saved. Controllers no longer vibrate.";
  KartPadRequestSettingsReload();
}
- (void)backgroundPauseChanged:(NSButton *)sender {
  const BOOL on=sender.state==NSControlStateValueOn;
  [NSUserDefaults.standardUserDefaults setBool:on forKey:kKartPadBackgroundPauseDefaultsKey];
  self.settingsStatus.stringValue=on?@"Saved. The game pauses while another app is in front.":@"Saved. The game keeps running while another app is in front.";
}
- (void)restartFromSettings:(id)sender {
  // Closing first saves changed controller profiles, as closing Settings always does.
  [self.settingsPanel performClose:sender];
  [self restartKartPad:sender];
}
- (void)settingChanged:(NSControl *)sender {
  NSString *key=sender.identifier;NSArray *parts=[key componentsSeparatedByString:@"."];
  std::string value;
  if([sender isKindOfClass:NSPopUpButton.class]) {
    id selected=self.settingChoices[key][((NSPopUpButton *)sender).indexOfSelectedItem];
    value=[selected isKindOfClass:NSString.class] ? RuntimeConfigFile::FormatString([selected UTF8String]) : [[selected stringValue] UTF8String];
  } else if([sender isKindOfClass:NSSlider.class]) {
    std::ostringstream stream;stream<<sender.doubleValue/100.0;value=stream.str();
  } else value=((NSButton *)sender).state==NSControlStateValueOn?"true":"false";
  if([key isEqual:@"video.disabled_post_processing_paths"]) {
    uint32_t mask=RuntimeConfigFile::LoadConfigFile().disabledPostProcessingPaths.value_or(0);
    mask=((NSButton *)sender).state==NSControlStateValueOn ? mask|0x10u : mask&~0x10u;
    value=std::to_string(mask);
  }
  if(!RuntimeConfigFile::WriteSetting([parts[0] UTF8String],[parts[1] UTF8String],value)) {
    self.settingsStatus.stringValue=@"Could not save this setting. Check that Config.toml is writable.";
    [self refreshSettings];return;
  }
  if([key isEqual:@"video.vsync"]) {
    const bool changed=RuntimeConfigFile::LoadConfigFile().vsync.value_or(false)!=KPLaunchVsync;
    [self setRestartNeeded:changed for:@"vsync"];
    self.settingsStatus.stringValue=changed?@"Saved. VSync changes when KartPad restarts.":@"Saved. VSync is back to how KartPad started.";
    [self refreshSettings];return;
  }
  if([key isEqual:@"video.fullscreen_across_notch"]) {
    const bool changed=KPFullscreenAcrossNotch()!=KPLaunchNotch;
    [self setRestartNeeded:changed for:@"notch"];
    self.settingsStatus.stringValue=changed?@"Saved. Full-display fullscreen changes when KartPad restarts.":@"Saved. Full-display fullscreen is back to how KartPad started.";
    [self refreshSettings];return;
  }
  // Preserve the renderer's existing high-frame-rate resolution restriction.
  auto c=RuntimeConfigFile::LoadConfigFile();
  if(c.frameInterpolationFps.value_or(0)>60 && c.resolutionMultiplier.value_or(1)>4) {
    if(!RuntimeConfigFile::WriteSetting("video","resolution_multiplier","4")) {
      self.settingsStatus.stringValue=@"Could not save the required 4× resolution limit. Check Config.toml permissions.";
      [self refreshSettings];return;
    }
    self.settingsStatus.stringValue=@"Saved. Interpolation limits render resolution to 4×.";
  } else self.settingsStatus.stringValue=[key isEqual:@"video.disabled_post_processing_paths"] ?
    @"Saved. Bloom changes apply when the next scene loads." : @"Saved. Changes apply immediately.";
  KartPadRequestSettingsReload();
  [self refreshSettings];
}
- (void)showControllerCompatibility:(id)sender {
  (void)sender;
  [KPControllers() cancelCapture];
  [KPControllers() windowWillClose:nil];
  [self.settingsPanel orderOut:nil];
  KartPadRequestControllerCompatibility();
}
- (void)showSettings:(id)sender {
  (void)sender;
  if(!self.settingsPanel) {
    KPReadLaunchDisplaySettings();
    CGFloat height=std::min<CGFloat>(810,NSScreen.mainScreen.visibleFrame.size.height-70);
    self.settingsPanel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,820,height)
      styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
    self.settingsPanel.title=@"KartPad Settings";self.settingsPanel.releasedWhenClosed=NO;
    self.settingsPanel.minSize=NSMakeSize(820,570);
    self.settingsPanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.settingsPanel.hidesOnDeactivate=YES;
    self.settingsPanel.delegate=KPControllers();
    self.settingControls=[NSMutableDictionary dictionary];self.settingChoices=[NSMutableDictionary dictionary];
    self.settingValues=[NSMutableDictionary dictionary];
    self.settingsTabs=[[NSTabView alloc] initWithFrame:NSMakeRect(10,42,800,height-52)];
    self.settingsTabs.delegate=self;
    self.settingsTabs.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [self.settingsPanel.contentView addSubview:self.settingsTabs];
    self.settingsStatus=[self label:@"Graphics and audio changes save automatically. Controllers has its own Save Profile button."];
    self.settingsStatus.frame=NSMakeRect(24,10,640,24);
    self.settingsStatus.autoresizingMask=NSViewWidthSizable;
    self.settingsStatus.font=[NSFont systemFontOfSize:11];
    self.settingsStatus.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.settingsPanel.contentView addSubview:self.settingsStatus];
    // Shown while a change waits for a restart.
    self.settingsRestart=[NSButton buttonWithTitle:@"Restart Now" target:self action:@selector(restartFromSettings:)];
    self.settingsRestart.frame=NSMakeRect(820-24-130,5,130,32);
    self.settingsRestart.autoresizingMask=NSViewMinXMargin;
    [self.settingsPanel.contentView addSubview:self.settingsRestart];

    NSView *graphics=[self settingsPage:@"Graphics"];
    [graphics setFrameSize:NSMakeSize(780,850)];
    [self settingsLabel:@"Graphics & Display" page:graphics y:790].font=[NSFont boldSystemFontOfSize:19];
    [self setting:@"video.cursor_auto_hide_seconds" label:@"Hide mouse pointer" choices:@[@"Never",@"After 3 seconds idle",@"After 5 seconds idle",@"After 10 seconds idle"] values:@[@0,@3,@5,@10] page:graphics y:730];
    [self setting:@"video.resolution_multiplier" label:@"Render resolution" choices:@[@"Auto (window size)",@"Native (1×)",@"1.5×",@"2×",@"3×",@"4×",@"6×",@"8×"] values:@[@0,@1,@1.5,@2,@3,@4,@6,@8] page:graphics y:675];
    [self setting:@"video.display_mode" label:@"Display mode" choices:@[@"Windowed",@"Borderless fullscreen",@"Exclusive fullscreen"] values:@[@"windowed",@"borderless",@"exclusive"] page:graphics y:620];
    [self setting:@"video.frame_interpolation_fps" label:@"Frame interpolation" choices:@[@"Off (60 FPS)",@"120 FPS — experimental",@"180 FPS — experimental"] values:@[@0,@120,@180] page:graphics y:565];
    [self settingsLabel:@"Interpolation may show visual artifacts. Resolution is limited to 4× when enabled." page:graphics y:505];
    [self setting:@"video.show_fps" checkbox:@"Show FPS counter" page:graphics y:455];
    [self setting:@"video.disable_copy_filter" checkbox:@"Disable the Wii copy filter (sharper picture)" page:graphics y:405];
    [self setting:@"video.disabled_post_processing_paths" checkbox:@"Disable bloom (applies at the next scene)" page:graphics y:355];
    [self setting:@"video.skip_unready_pipelines" checkbox:@"Skip draws while shaders compile" page:graphics y:305];
    [self setting:@"video.fullscreen_across_notch" checkbox:@"Use full display in borderless fullscreen (including notch area)" page:graphics y:245];
    [self settingsLabel:@"Requires restart. Uses desktop fullscreen instead of a separate Space. The notch can obscure the image; game aspect ratio is preserved." page:graphics y:185];
    [self setting:@"video.vsync" checkbox:@"VSync — experimental (requires restart)" page:graphics y:115];
    [self settingsLabel:@"Settings shortcut: Command-comma or F10 (Fn–F10 on media-key keyboards)." page:graphics y:65];

    NSView *audio=[self settingsPage:@"Audio"];
    [self settingsLabel:@"Audio" page:audio y:680].font=[NSFont boldSystemFontOfSize:19];
    NSArray *keys=@[@"volume",@"music_volume",@"sound_effects_volume",@"ui_volume",@"voices_volume"];
    NSArray *labels=@[@"Master volume",@"Music",@"Sound effects",@"Menu sounds",@"Character voices"];
    for(int i=0;i<5;++i)[self setting:[@"audio." stringByAppendingString:keys[i]] volume:labels[i] page:audio y:620-i*60];
    [self setting:@"audio.muted" checkbox:@"Mute game audio" page:audio y:295];
    [self setting:@"audio.mix_worker" checkbox:@"Mix audio on a worker thread" page:audio y:245];
    [self settingsLabel:@"The worker normally improves performance. Turn it off when troubleshooting audio problems." page:audio y:180];

    // Controllers: the mapping panel, then vibration and the controller shortcuts below it.
    NSView *controllers=[self settingsPage:@"Controllers"];
    [controllers setFrameSize:NSMakeSize(780,1160)];
    [KPControllers() prepareInPanel:self.settingsPanel];
    KPControllers().content.frame=NSMakeRect(0,420,760,740);
    KPControllers().content.autoresizingMask=NSViewWidthSizable;
    [controllers addSubview:KPControllers().content];
    // A controller starts on its player choice (it shows itself; see followPad:).
    [self.settingsTabs tabViewItemAtIndex:[self.settingsTabs indexOfTabViewItemWithIdentifier:@"Controllers"]].initialFirstResponder=KPControllers().player;
    [self settingsHeading:@"Vibration" page:controllers y:372];
    [self settingsLabel:@"Strength" page:controllers y:312];
    self.vibrationChoice=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(180,336,190,28) pullsDown:NO];
    [self.vibrationChoice addItemsWithTitles:@[@"Off",@"Light",@"Medium",@"Strong"]];
    self.vibrationChoice.target=self;self.vibrationChoice.action=@selector(vibrationChanged:);
    self.vibrationChoice.accessibilityLabel=@"Vibration strength";
    [controllers addSubview:self.vibrationChoice];
    NSButton *test=[NSButton buttonWithTitle:@"Test Vibration" target:self action:@selector(testVibration:)];
    test.frame=NSMakeRect(384,334,160,32);[controllers addSubview:test];
    [self settingsLabel:@"Controllers that can vibrate do when the game rumbles, for example when you crash or get hit. If nothing happens, check that rumble is on in the game’s own options." page:controllers y:280];
    [self settingsHeading:@"Controller shortcuts" page:controllers y:224];
    [self settingsLabel:@"Hold buttons on any controller to open these without a keyboard or mouse." page:controllers y:174];
    // One line for each shortcut: on or off, its buttons, how long to hold them, and changing them.
    NSMutableArray *switches=[NSMutableArray array],*names=[NSMutableArray array],*choose=[NSMutableArray array],*holds=[NSMutableArray array];
    for(int kind=0;kind<KPPadShortcutCount;++kind) {
      const CGFloat y=150-kind*44;
      NSButton *on=[NSButton checkboxWithTitle:[@"Open " stringByAppendingString:KPPadShortcuts[kind].opens] target:self action:@selector(padShortcutChanged:)];
      on.frame=NSMakeRect(24,y,150,28);on.tag=kind;[controllers addSubview:on];[switches addObject:on];
      NSTextField *buttons=[self label:@""];buttons.frame=NSMakeRect(180,y+2,200,20);
      buttons.lineBreakMode=NSLineBreakByTruncatingTail;[controllers addSubview:buttons];[names addObject:buttons];
      NSPopUpButton *hold=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(384,y,160,28) pullsDown:NO];
      [hold addItemsWithTitles:@[@"for ½ second",@"for 1 second",@"for 2 seconds",@"for 3 seconds"]];
      hold.target=self;hold.action=@selector(padShortcutChanged:);hold.tag=kind;
      hold.accessibilityLabel=[NSString stringWithFormat:@"How long to hold the %@ buttons",KPPadShortcuts[kind].opens];
      [controllers addSubview:hold];[holds addObject:hold];
      NSButton *pick=[NSButton buttonWithTitle:@"Change Buttons…" target:self action:@selector(choosePadShortcutButtons:)];
      pick.frame=NSMakeRect(554,y-2,170,32);pick.tag=kind;[controllers addSubview:pick];[choose addObject:pick];
    }
    self.padShortcutSwitches=switches;self.padShortcutButtons=names;self.padShortcutChoose=choose;self.padShortcutHolds=holds;
    self.capturingShortcut=-1;

    NSView *data=[self settingsPage:@"Game & Data"];
    [self settingsLabel:@"Game, Player & Data" page:data y:680].font=[NSFont boldSystemFontOfSize:19];
    [self settingsButton:@"Choose Mario Kart Wii Data…" action:@selector(chooseGameData:) page:data y:615];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
    [self settingsButton:@"Choose Retro Rewind Data…" action:@selector(chooseRetroRewindData:) page:data y:570];
#endif
    [self settingsLabel:@"Game-data changes apply after restarting. Existing saves are preserved." page:data y:505];
    [self settingsButton:@"Miis…" action:@selector(showMiis:) page:data y:440];
    [self settingsLabel:@"Create, edit and import Miis, and rename, relink or delete licenses. To open Miis from a controller, see Controllers → Controller shortcuts." page:data y:395];
    self.backgroundPauseSwitch=[NSButton checkboxWithTitle:@"Pause the game while another app is in front" target:self action:@selector(backgroundPauseChanged:)];
    self.backgroundPauseSwitch.frame=NSMakeRect(24,350,715,28);[data addSubview:self.backgroundPauseSwitch];
    [self settingsLabel:@"It keeps going while it loads and while you’re online. Turn this off to keep playing with a controller while another app is in front." page:data y:300];
    [self setting:@"discord.enabled" checkbox:@"Show what you’re playing in your Discord status" page:data y:255];
    [self settingsButton:@"Open Application Support" action:@selector(showApplicationSupport:) page:data y:195];
    [self settingsButton:@"Open Cache Folder" action:@selector(showCache:) page:data y:150];
    [self settingsButton:@"Control Reference…" action:@selector(showControls:) page:data y:80];

    NSView *advanced=[self settingsPage:@"Advanced"];
    [self settingsLabel:@"Advanced & Diagnostics" page:advanced y:680].font=[NSFont boldSystemFontOfSize:19];
    [self settingsButton:@"Save Diagnostics Report…" action:@selector(saveDiagnostics:) page:advanced y:615];
    [self settingsButton:@"Controller Compatibility Tools…" action:@selector(showControllerCompatibility:) page:advanced y:540];
    [self settingsLabel:@"Opens the in-game tools for unmapped joysticks, GameCube adapters and legacy presets. Standard controllers use the Controllers tab." page:advanced y:480];
    [self settingsButton:@"Pair Wii Remote…" action:@selector(pairWiimote:) page:advanced y:410];
    [self settingsLabel:@"Experimental original Wii Remote / Nunchuk support. Pairing enables the existing experimental driver." page:advanced y:345];
    [self settingsButton:@"Private Wii Server…" action:@selector(showPrivateServer:) page:advanced y:275];
    [self settingsLabel:@"Private server changes apply on the next launch." page:advanced y:215];
    [self.settingsPanel center];
    __weak KartPadMacShellController *weak=self;
    KartPadMiiPadSetSettings(self.settingsPanel,self.settingsTabs,^{
      [weak.settingsPanel performClose:nil];
      [KPGameWindow() makeKeyAndOrderFront:nil];
    });
  }
  [self refreshSettings];
  self.settingsPanel.level=KPAuxiliaryWindowLevel();
  NSWindow *gameWindow=KPGameWindow();
  if(gameWindow.screen) {
    NSRect available=gameWindow.screen.visibleFrame;
    NSRect frame=self.settingsPanel.frame;
    frame.origin=NSMakePoint(NSMidX(available)-frame.size.width/2,NSMidY(available)-frame.size.height/2);
    [self.settingsPanel setFrame:frame display:NO];
  }
  [NSApp activateIgnoringOtherApps:YES];[KPControllers() activateInput];
  [self.settingsPanel makeKeyAndOrderFront:nil];
  // Show the top of each scrollable settings page, including smaller displays.
  for(NSTabViewItem *item in self.settingsTabs.tabViewItems) {
    NSScrollView *scroll=(NSScrollView *)item.view;
    [scroll.contentView scrollToPoint:NSMakePoint(0,std::max<CGFloat>(0,scroll.documentView.frame.size.height-scroll.contentView.bounds.size.height))];
    [scroll reflectScrolledClipView:scroll.contentView];
  }
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item {
  (void)tabView;
  // A hidden capture must never change a binding while editing another tab.
  if(![item.identifier isEqual:@"Controllers"]) [KPControllers() cancelCapture];
  NSScrollView *scroll=(NSScrollView *)item.view;
  [scroll.contentView scrollToPoint:NSMakePoint(0,std::max<CGFloat>(0,scroll.documentView.frame.size.height-scroll.contentView.bounds.size.height))];
  [scroll reflectScrolledClipView:scroll.contentView];
}
