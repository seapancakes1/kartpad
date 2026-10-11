// Automated checks of KartPad's screens on the real game window. Only with KARTPAD_QA_DIR set: the
// app reads commands, one per line, from commands.txt in that folder as lines are added, and writes
// what it's asked to photograph there as PNGs (the window as drawn: game and screens together). Run
// it with KARTPAD_MUTED=1 KARTPAD_BACKGROUND=1 so it stays silent and never takes the focus.
//   home | close | screen settings|controllers|miis|pair-wii|pair-phone | pad up|down|left|right|a|b|x|y|lb|rb|start
//   shot NAME | resize W H | fullscreen | appearance light|dark|system | restart | quit | wait SECONDS
//   focus LABEL | click LABEL | where | navmap | roster | vpad add|press|release|remove | key NAME
//   move IDENTIFIER|vpadN SLOT | phone start|status|background-input
// Included by KartPadMacShell.mm at the end.

#import <objc/objc-exception.h>

extern "C" uint64_t KartPadPresentedFrames();  // runtime settings_overlay.cpp

static NSString *KPQADirectory() {
  static NSString *directory = NSProcessInfo.processInfo.environment[@"KARTPAD_QA_DIR"];
  return directory.length ? directory : nil;
}

static void KPQALog(NSString *line) {
  NSString *path = [KPQADirectory() stringByAppendingPathComponent:@"log.txt"];
  NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
  if (file == nil) {
    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    file = [NSFileHandle fileHandleForWritingAtPath:path];
  }
  [file seekToEndOfFile];
  [file writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
  [file closeFile];
}

static void KPQAShot(NSString *name) {
  NSWindow *game = KPOverlay().hostWindow ?: KPGameWindow();
  if (game == nil) {
    KPQALog([NSString stringWithFormat:@"shot %@: no game window", name]);
    return;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)game.windowNumber,
                                             kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
#pragma clang diagnostic pop
  NSBitmapImageRep *rep = nil;
  if (image) {
    rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
  }
  // Without window capture, at least the screens (the game's Metal frame doesn't draw this way).
  if (rep == nil || rep.pixelsWide < 8) {
    NSView *content = game.contentView;
    rep = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
    KPQALog([NSString stringWithFormat:@"shot %@: window capture unavailable, views only", name]);
  }
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  NSString *path = [KPQADirectory() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
  [png writeToFile:path atomically:YES];
  KPQALog([NSString stringWithFormat:@"shot %@ %ldx%ld", name, (long)rep.pixelsWide, (long)rep.pixelsHigh]);
}

// A focus that found nothing: the press after it is skipped, so it can't land on whatever happened
// to be focused instead (and, say, put the keyboard on a player in preferences shared with the user).
static BOOL KPQAFocusMissed;
// The virtual controllers `vpad add` made, by joystick ID; `vpadN` names one in other commands.
static NSMutableArray<NSNumber *> *KPQAVirtualPads = [NSMutableArray array];

static void KPQAPad(NSString *name) {
  NSDictionary<NSString *, NSNumber *> *buttons = @{
    @"up": @(KartPadMiiPadUp), @"down": @(KartPadMiiPadDown), @"left": @(KartPadMiiPadLeft), @"right": @(KartPadMiiPadRight),
    @"a": @(KartPadMiiPadConfirm), @"b": @(KartPadMiiPadBack), @"x": @(KartPadMiiPadUndo), @"y": @(KartPadMiiPadRedo),
    @"lb": @(KartPadMiiPadPreviousTab), @"rb": @(KartPadMiiPadNextTab), @"start": @(KartPadMiiPadStart)};
  NSNumber *button = buttons[name];
  if (button == nil) return;
  if (KPQAFocusMissed && ([name isEqualToString:@"a"] || [name isEqualToString:@"x"] || [name isEqualToString:@"y"])) {
    KPQAFocusMissed = NO;
    KPQALog([NSString stringWithFormat:@"pad %@ skipped: the focus before it found nothing", name]);
    return;
  }
  const KartPadMiiPadButton value = (KartPadMiiPadButton)button.integerValue;
  if (KPOverlayTakesPads()) {
    KPOverlayPadPress(value, YES);
    if (value == KartPadMiiPadConfirm) KPOverlayPadPress(value, NO);
  } else {
    KartPadMiiPadPress(value, YES);
    if (value == KartPadMiiPadConfirm) KartPadMiiPadPress(value, NO);
  }
}

static void KPQARun(NSString *line) {
  NSArray<NSString *> *words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSString *command = words.firstObject.lowercaseString;
  NSString *argument = words.count > 1 ? words[1] : @"";
  KPQALog([@"> " stringByAppendingString:line]);
  if ([command isEqualToString:@"home"]) KPShowScreen(@"home");
  else if ([command isEqualToString:@"close"]) [KPOverlay() closeAll];
  else if ([command isEqualToString:@"screen"]) KPShowScreen(argument);
  else if ([command isEqualToString:@"pad"]) KPQAPad(argument.lowercaseString);
  else if ([command isEqualToString:@"shot"]) KPQAShot(argument);
  else if ([command isEqualToString:@"fullscreen"]) [Controller() toggleGameFullScreen:nil];
  else if ([command isEqualToString:@"toast"]) {
    [KPOverlay() toast:@"Xbox controller connected" detail:@"Player 2" stripe:KPPlayerColors[1] icon:^(CGContextRef c, CGRect r) {
      KPDrawGlyph(c, KPUIGlyph::Pad, r, KPP->accentBottom);
    } image:nil seconds:6];
    KPOverlayController *overlay = KPOverlay();
    KPQALog([NSString stringWithFormat:@"toast host=%@ hidden=%d frame=%@ superview=%@ last=%d toasts=%lu", overlay.host, overlay.host.hidden,
             NSStringFromRect(overlay.host.frame), overlay.host.superview, overlay.host.superview.subviews.lastObject == overlay.host,
             (unsigned long)overlay.toasts.count]);
    for (NSView *toast in overlay.toasts) KPQALog([NSString stringWithFormat:@"  toast frame=%@ alpha=%.2f", NSStringFromRect(toast.frame), toast.alphaValue]);
  } else if ([command isEqualToString:@"roster"]) {
    // Every controller as the roster sees it, and which player Aurora has it on.
    KPControllerRoster *roster = KPControllerRoster.shared;
    [roster refresh];
    NSMutableString *text = [NSMutableString stringWithFormat:@"roster keyboardPort=%d lastPresser=%u keyboardInput=%d", KPKeyboardPort(),
                             (unsigned)KPPadLastPresser, KPOverlay().keyboardInput];
    for (KPPadDevice *device in roster.devices) {
      SDL_Gamepad *pad = device.gamepad;
      [text appendFormat:@"\n  %@ %@ slot=%d port=%d index=%d", device.identifier, device.name, device.slot,
                         pad ? KPPortForGamepad(pad) : -9, pad ? KPIndexForGamepad(pad) : -9];
    }
    for (int port = 0; port < KPPlayerCount; ++port) [text appendFormat:@"\n  port%d index=%d", port, PADGetIndexForPort(port)];
    KPQALog(text);
  } else if ([command isEqualToString:@"frames"]) {
    KPQALog([NSString stringWithFormat:@"frames %llu", (unsigned long long)KartPadPresentedFrames()]);
  } else if ([command isEqualToString:@"editmii"]) {
    KartPadPresentMiiEditor(KPGameWindow(), (NSUInteger)argument.integerValue);
  } else if ([command isEqualToString:@"closewindows"]) {
    for (NSWindow *window in NSApp.windows)
      if (window.visible && window != KPGameWindow() && window.windowController) [window performClose:nil];
  } else if ([command isEqualToString:@"shotwindow"]) {
    // A KartPad window other than the game's (the Mii editor over it), drawn on its own.
    for (NSWindow *window in NSApp.windows)
      if (window.visible && window != KPGameWindow() && window.windowController) {
        NSView *view = window.contentView;
        NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[KPQADirectory() stringByAppendingPathComponent:[(words.count > 1 ? words[1] : @"window") stringByAppendingPathExtension:@"png"]]
             atomically:YES];
        KPQALog([NSString stringWithFormat:@"shotwindow %@ frame=%@ game=%@", window.className, NSStringFromRect(window.frame),
                 NSStringFromRect(KPGameWindow().frame)]);
      }
  } else if ([command isEqualToString:@"setupuse"]) {
    NSString *path = [line substringFromIndex:MIN(line.length, (NSUInteger)9)];
    if ([KPOverlay().top isKindOfClass:KPSetupScreen.class]) [(KPSetupScreen *)KPOverlay().top useGame:path];
#if defined(KARTPAD_RUNTIME_PRODUCT_DUAL)
  } else if ([command isEqualToString:@"rrtest"]) {
    // The small 6.13.1 update archive through the whole pipeline; it ends at the final check.
    [KPRetroDownload.shared startWith:{@"https://cdn.update.rwfc.net/RetroRewind/zip/6.13.1.zip",
                                        @"ee32da6fde457700cb60ad173e163ecd05a9ed61b41e39bea6b003406be3e6ce", 29403976}];
  } else if ([command isEqualToString:@"rrstatus"]) {
    KPRetroDownload *download = KPRetroDownload.shared;
    KPQALog([NSString stringWithFormat:@"rr stage=%ld progress=%.2f done=%lld problem=%@", (long)download.stage, download.progress,
             download.done, download.problem]);
    if ([argument isEqualToString:@"screen"]) KPShowRetroDownload(NO);
#endif
  } else if ([command isEqualToString:@"hint"]) {
    KPShowHomeHint();
  } else if ([command isEqualToString:@"key"]) {
    // A key the game reads as typed, by SDL's name (key return, key up): how a run reaches the game
    // itself, since controllers don't while KartPad is in the background.
    SDL_Event event{};
    event.type = SDL_EVENT_KEY_DOWN;
    event.key.scancode = SDL_GetScancodeFromName(argument.UTF8String);
    event.key.down = true;
    SDL_PushEvent(&event);
    event.type = SDL_EVENT_KEY_UP;
    event.key.down = false;
    SDL_PushEvent(&event);
    KPQALog([NSString stringWithFormat:@"key %@ scancode=%d", argument, (int)event.key.scancode]);
  }
  else if ([command isEqualToString:@"restart"]) KPRestartWithCurtain(@"Restarting", @"");
  else if ([command isEqualToString:@"quit"]) [Controller() quitKartPad:nil];
  else if ([command isEqualToString:@"resize"] && words.count >= 3) {
    NSWindow *game = KPGameWindow();
    NSRect frame = game.frame;
    const NSSize content = NSMakeSize(words[1].doubleValue, words[2].doubleValue);
    frame.size = [game frameRectForContentRect:NSMakeRect(0, 0, content.width, content.height)].size;
    [game setFrame:frame display:YES];
  } else if ([command isEqualToString:@"appearance"]) {
    NSApp.appearance = [argument isEqualToString:@"dark"] ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                     : [argument isEqualToString:@"light"] ? [NSAppearance appearanceNamed:NSAppearanceNameAqua] : nil;
  } else if ([command isEqualToString:@"focus"]) {
    // Select a control by its label on the current screen.
    NSString *label = [line substringFromIndex:MIN(line.length, (NSUInteger)6)];
    KPQAFocusMissed = YES;
    for (KPUIButton *button in KPOverlay().top.focusables)
      if ([button.label isEqualToString:label]) {
        [KPOverlay() focus:button sound:NO];
        KPQAFocusMissed = NO;
      }
    if (KPQAFocusMissed) KPQALog([NSString stringWithFormat:@"focus %@: not found", label]);
  } else if ([command isEqualToString:@"move"] && words.count >= 3) {
    // Put a controller on a player, or (-1) take it off, the way Controllers does but without
    // benching it: move IDENTIFIER SLOT (identifiers as roster prints them).
    KPControllerRoster *roster = KPControllerRoster.shared;
    [roster refresh];
    NSString *identifier = words[1];
    if ([identifier hasPrefix:@"vpad"] && identifier.length > 4 && [identifier substringFromIndex:4].integerValue < (NSInteger)KPQAVirtualPads.count)
      identifier = [NSString stringWithFormat:@"sdl:%@", KPQAVirtualPads[[identifier substringFromIndex:4].integerValue]];
    KPPadDevice *device = [roster deviceWithIdentifier:identifier];
    if (device) [roster move:device toSlot:words[2].intValue];
    KPQALog([NSString stringWithFormat:@"move %@ %@: %@", words[1], words[2], device ? @"done" : @"no such controller"]);
  } else if ([command isEqualToString:@"sdldelegate"]) {
    // SDL's app delegate, and whether it has had its first activation (KPFocusGameWindowAtLaunch).
    NSObject *delegate = (NSObject *)NSApp.delegate;
    id seen = nil;
    @try { seen = [delegate valueForKey:@"seenFirstActivate"]; } @catch (NSException *exception) { seen = exception.reason; }
    KPQALog([NSString stringWithFormat:@"sdldelegate %@ seenFirstActivate=%@ app=%@", delegate.class, seen, NSApp.class]);
  } else if ([command isEqualToString:@"where"]) {
    KPUIButton *focus = KPOverlay().top.focus;
    KPQALog([NSString stringWithFormat:@"where %@ focus=%@", NSStringFromClass(KPOverlay().top.class),
             focus.label.length ? focus.label : focus ? [NSString stringWithFormat:@"#%ld", (long)focus.tag2] : @"-"]);
  } else if ([command isEqualToString:@"vpad"]) {
    // Virtual controllers (SDL's own), so choosing controllers by pressing can be checked without any:
    // vpad add | vpad press N BUTTON | vpad release N BUTTON | vpad remove N
    NSMutableArray<NSNumber *> *pads = KPQAVirtualPads;
    NSDictionary<NSString *, NSNumber *> *buttons = @{
      @"a": @(SDL_GAMEPAD_BUTTON_SOUTH), @"b": @(SDL_GAMEPAD_BUTTON_EAST), @"x": @(SDL_GAMEPAD_BUTTON_WEST),
      @"y": @(SDL_GAMEPAD_BUTTON_NORTH), @"start": @(SDL_GAMEPAD_BUTTON_START), @"up": @(SDL_GAMEPAD_BUTTON_DPAD_UP),
      @"down": @(SDL_GAMEPAD_BUTTON_DPAD_DOWN), @"left": @(SDL_GAMEPAD_BUTTON_DPAD_LEFT), @"right": @(SDL_GAMEPAD_BUTTON_DPAD_RIGHT)};
    if ([argument isEqualToString:@"add"]) {
      SDL_VirtualJoystickDesc desc;
      SDL_INIT_INTERFACE(&desc);
      desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
      desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
      desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
      desc.name = "KartPad QA Pad";
      const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
      if (id) {
        [pads addObject:@(id)];
        SDL_OpenJoystick(id);
      }
      KPQALog([NSString stringWithFormat:@"vpad %lu id=%u gamepad=%d %s", (unsigned long)pads.count - 1, (unsigned)id, SDL_IsGamepad(id),
               id ? "" : SDL_GetError()]);
    } else if (words.count >= 3 && words[2].integerValue < (NSInteger)pads.count) {
      const SDL_JoystickID id = pads[words[2].integerValue].unsignedIntValue;
      if ([argument isEqualToString:@"remove"]) {
        SDL_DetachVirtualJoystick(id);
      } else if (words.count >= 4 && buttons[words[3].lowercaseString]) {
        SDL_SetJoystickVirtualButton(SDL_GetJoystickFromID(id), buttons[words[3].lowercaseString].intValue,
                                     [argument isEqualToString:@"press"]);
      }
    }
  } else if ([command isEqualToString:@"phone"]) {
    // Phone controllers without a camera: phone start (the server, as Connect a Controller → Phone
    // starts it) | phone status (the link, which a test script opens as a phone would, and the phones)
    // | phone background-input (SDL keeps controller input while KartPad is in the background, so a
    // hidden run sees what the phones press; Aurora refuses to start with the environment variable).
    if ([argument isEqualToString:@"start"]) [KPPhoneServer.shared start];
    if ([argument isEqualToString:@"background-input"])
      SDL_SetHintWithPriority(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1", SDL_HINT_OVERRIDE);
    KPQALog([@"phone " stringByAppendingString:[KPPhoneServer.shared status]]);
  } else if ([command isEqualToString:@"navmap"]) {
    // Where each direction leads from every control (by layout; a screen's own handling and controls
    // that change in place with left and right are noted, not followed).
    KPScreen *screen = KPOverlay().top;
    NSArray<KPUIButton *> *controls = screen.focusables;
    auto name = [](KPUIButton *b) -> NSString * {
      return b == nil ? @"-" : b.label.length ? b.label : [NSString stringWithFormat:@"#%ld", (long)b.tag2];
    };
    NSMutableString *text = [NSMutableString stringWithFormat:@"navmap %@ focus=%@", NSStringFromClass(screen.class), name(screen.focus)];
    for (KPUIButton *b in controls) {
      const NSRect r = [screen convertRect:b.bounds fromView:b];
      const CGFloat s = screen.scale;
      [text appendFormat:@"\n  %@ [%.0f,%.0f %.0fx%.0f]%@  U:%@ D:%@ L:%@ R:%@", name(b), r.origin.x / s - screen.safe.origin.x,
                         r.origin.y / s - screen.safe.origin.y, r.size.width / s, r.size.height / s, b.adjust ? @" (adjusts)" : @"",
                         name(KPUINearest(controls, b, 0, -1)), name(KPUINearest(controls, b, 0, 1)), name(KPUINearest(controls, b, -1, 0)),
                         name(KPUINearest(controls, b, 1, 0))];
    }
    KPQALog(text);
  } else if ([command isEqualToString:@"click"]) {
    // A mouse click on a control by its label: what the window's hit test finds there, then the click.
    NSString *label = [line substringFromIndex:MIN(line.length, (NSUInteger)6)];
    KPUIButton *target = nil;
    for (KPUIButton *button in KPOverlay().top.focusables)
      if ([button.label isEqualToString:label]) target = button;
    NSWindow *window = KPOverlay().host.window;
    if (target == nil || window == nil) {
      KPQALog([NSString stringWithFormat:@"click %@: no such control", label]);
      return;
    }
    const NSPoint point = [target convertPoint:NSMakePoint(NSMidX(target.bounds), NSMidY(target.bounds)) toView:nil];
    NSView *frame = window.contentView.superview ?: window.contentView;
    NSView *hit = [frame hitTest:point];
    KPQALog([NSString stringWithFormat:@"click %@: hit %@%@", label, NSStringFromClass(hit.class), hit == target ? @" (the control)" : @""]);
    for (NSEventType type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
      NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1
                                          pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
      if (type == NSEventTypeLeftMouseDown) [hit mouseDown:event];
      else [hit mouseUp:event];
    }
  }
}

// Every Objective-C exception, as it is thrown: the game's own handler later sees only "a non-std
// C++ exception", so this is the one place its reason and stack are still known.
static objc_exception_preprocessor KPQAPreviousPreprocessor;
static id KPQAExceptionPreprocessor(id exception) {
  if ([exception isKindOfClass:NSException.class]) {
    NSException *e = exception;
    KPQALog([NSString stringWithFormat:@"exception %@: %@\n%@", e.name, e.reason,
                                       [e.callStackSymbols componentsJoinedByString:@"\n"]]);
  }
  return KPQAPreviousPreprocessor ? KPQAPreviousPreprocessor(exception) : exception;
}

static void KPStartQA() {
  static bool started;
  NSString *directory = KPQADirectory();
  if (directory == nil || started) return;
  started = true;
  KPQAPreviousPreprocessor = objc_setExceptionPreprocessor(KPQAExceptionPreprocessor);
  [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *commands = [directory stringByAppendingPathComponent:@"commands.txt"];
  // After a restart (the curtain's new copy), carry on after the "restart" that caused it.
  __block NSUInteger done = 0;
  if (NSProcessInfo.processInfo.environment[@"KARTPAD_CURTAIN_TOKEN"].length) {
    NSArray<NSString *> *lines = [[NSString stringWithContentsOfFile:commands encoding:NSUTF8StringEncoding error:nil]
        componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < lines.count; ++i)
      if ([[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:@"restart"]) done = i + 1;
    KPQALog(@"qa=restarted");
  }
  __block NSTimeInterval waitUntil = 0;
  KPQALog(@"qa=started");
  NSTimer *timer = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
    (void)t;
    if (NSProcessInfo.processInfo.systemUptime < waitUntil) return;
    NSString *text = [NSString stringWithContentsOfFile:commands encoding:NSUTF8StringEncoding error:nil];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    // One command per tick, so each has drawn before the next.
    while (done < lines.count) {
      NSString *line = [lines[done] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (done + 1 == lines.count && ![text hasSuffix:@"\n"]) return;  // still being written
      ++done;
      if (line.length == 0) continue;
      if ([line hasPrefix:@"wait "]) {
        waitUntil = NSProcessInfo.processInfo.systemUptime + [line substringFromIndex:5].doubleValue;
        KPQALog([@"> " stringByAppendingString:line]);
        return;
      }
      @autoreleasepool { KPQARun(line); }
      return;
    }
  }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
