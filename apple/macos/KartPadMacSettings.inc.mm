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
    @"audio.mix_worker":@(c.audioMixWorker.value_or(true))};
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
// VSync and full-display fullscreen as KartPad started, read when Settings is first built (only
// Settings changes them).
static bool KPLaunchVsync,KPLaunchNotch;
static NSArray<NSNumber *> *KPPadShortcutHolds() { return @[@0.5,@1,@2,@3]; }
- (void)refreshPadShortcuts {
  const bool capturing=KPPadCapturing();
  for(int kind=0;kind<KPPadShortcutCount;++kind) {
    const bool on=KPPadShortcutEnabled(kind),choosing=capturing&&self.capturingShortcut==kind;
    self.padShortcutSwitches[kind].state=on?NSControlStateValueOn:NSControlStateValueOff;
    self.padShortcutButtons[kind].stringValue=choosing?@"Hold buttons on a controller…":[@"Buttons: " stringByAppendingString:KPPadButtonNames(KPPadShortcutButtons(kind))];
    self.padShortcutButtons[kind].textColor=on?NSColor.labelColor:NSColor.disabledControlTextColor;
    self.padShortcutChoose[kind].title=choosing?@"Cancel":@"Choose Buttons…";
    self.padShortcutChoose[kind].enabled=on&&(!capturing||choosing);self.padShortcutHolds[kind].enabled=on&&!choosing;
    NSUInteger index=[KPPadShortcutHolds() indexOfObject:@(KPPadShortcutHold(kind))];
    [self.padShortcutHolds[kind] selectItemAtIndex:index==NSNotFound?1:index];
  }
  self.backgroundPauseSwitch.state=KPBackgroundPauseEnabled()?NSControlStateValueOn:NSControlStateValueOff;
  self.settingsRestart.hidden=!self.restartPending;
}
- (NSString *)padShortcutSaved:(int)kind {
  return KPPadShortcutEnabled(kind)?[NSString stringWithFormat:@"Saved. Hold %@ to open %@.",KPPadButtonNames(KPPadShortcutButtons(kind)),KPPadShortcuts[kind].opens]:
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
    self.settingsStatus.stringValue=[NSString stringWithFormat:@"The %@ buttons are unchanged.",KPPadShortcuts[kind].opens];
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
  self.settingsStatus.stringValue=@"Let go of everything, then hold the buttons you want together on a controller and let go.";
  [self refreshPadShortcuts];
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
    KPLaunchVsync=RuntimeConfigFile::LoadConfigFile().vsync.value_or(false);KPLaunchNotch=KPFullscreenAcrossNotch();
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

    NSView *controllers=[self settingsPage:@"Controllers"];
    [KPControllers() prepareInPanel:self.settingsPanel];
    KPControllers().content.frame=NSMakeRect(0,0,760,740);
    KPControllers().content.autoresizingMask=NSViewWidthSizable;
    [controllers addSubview:KPControllers().content];

    NSView *data=[self settingsPage:@"Game & Data"];
    [data setFrameSize:NSMakeSize(780,900)];
    [self settingsLabel:@"Game, Player & Data" page:data y:840].font=[NSFont boldSystemFontOfSize:19];
    [self settingsButton:@"Choose Mario Kart Wii Data…" action:@selector(chooseGameData:) page:data y:775];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
    [self settingsButton:@"Choose Retro Rewind Data…" action:@selector(chooseRetroRewindData:) page:data y:730];
#endif
    [self settingsLabel:@"Game-data changes apply after restarting. Existing saves are preserved." page:data y:665];
    [self settingsButton:@"Miis…" action:@selector(showMiis:) page:data y:600];
    [self settingsLabel:@"Create, edit and import Miis, and rename, relink or delete licenses." page:data y:555];
    // One row for each controller shortcut: on or off, its buttons, and how long to hold them.
    NSMutableArray *switches=[NSMutableArray array],*names=[NSMutableArray array],*choose=[NSMutableArray array],*holds=[NSMutableArray array];
    for(int kind=0;kind<KPPadShortcutCount;++kind) {
      const CGFloat y=514-kind*90;
      NSButton *on=[NSButton checkboxWithTitle:[NSString stringWithFormat:@"Open %@ by holding buttons on a controller",KPPadShortcuts[kind].opens] target:self action:@selector(padShortcutChanged:)];
      on.frame=NSMakeRect(24,y,715,28);on.tag=kind;[data addSubview:on];[switches addObject:on];
      NSTextField *buttons=[self label:@""];buttons.frame=NSMakeRect(44,y-36,240,20);
      buttons.lineBreakMode=NSLineBreakByTruncatingTail;[data addSubview:buttons];[names addObject:buttons];
      NSButton *pick=[NSButton buttonWithTitle:@"Choose Buttons…" target:self action:@selector(choosePadShortcutButtons:)];
      pick.frame=NSMakeRect(290,y-44,180,32);pick.tag=kind;[data addSubview:pick];[choose addObject:pick];
      NSPopUpButton *hold=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(480,y-42,190,28) pullsDown:NO];
      [hold addItemsWithTitles:@[@"Hold for ½ second",@"Hold for 1 second",@"Hold for 2 seconds",@"Hold for 3 seconds"]];
      hold.target=self;hold.action=@selector(padShortcutChanged:);hold.tag=kind;
      hold.accessibilityLabel=[NSString stringWithFormat:@"How long to hold the %@ buttons",KPPadShortcuts[kind].opens];
      [data addSubview:hold];[holds addObject:hold];
    }
    self.padShortcutSwitches=switches;self.padShortcutButtons=names;self.padShortcutChoose=choose;self.padShortcutHolds=holds;
    self.capturingShortcut=-1;
    self.backgroundPauseSwitch=[NSButton checkboxWithTitle:@"Pause the game while another app is in front" target:self action:@selector(backgroundPauseChanged:)];
    self.backgroundPauseSwitch.frame=NSMakeRect(24,330,715,28);[data addSubview:self.backgroundPauseSwitch];
    [self settingsLabel:@"It keeps going while it loads and while you’re online. Turn this off to keep playing with a controller while another app is in front." page:data y:280];
    [self settingsButton:@"Open Application Support" action:@selector(showApplicationSupport:) page:data y:215];
    [self settingsButton:@"Open Cache Folder" action:@selector(showCache:) page:data y:170];
    [self settingsButton:@"Control Reference…" action:@selector(showControls:) page:data y:100];

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
