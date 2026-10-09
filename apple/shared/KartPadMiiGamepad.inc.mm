// Controller navigation for the Miis window and the Mii editor on Mac (KartPadMiiEditor.h). It is
// included after KartPadMiiBrowser.inc.mm. The shell reads the pads (KartPadMacMiis.inc.mm); this
// file decides what each press does.
// The D-pad or left stick moves the focus ring to the nearest control in that direction and A
// presses it (held adjustments repeat, as with the mouse). B goes back: Done on the Miis screen,
// close in the editor. In the editor LB and RB change category, X and Y undo and redo, and Start
// saves; on the Miis screen Start is Done. Alerts move their default button and press it with A,
// and B picks Cancel. Pop-up menus take arrows and Return, and B closes them.
#if TARGET_OS_OSX
#import <objc/runtime.h>

@interface KPMiiBrowser (KPPad)
- (void)selectSlot:(NSUInteger)slot;
- (void)finish;
@end
@interface KPMiiBrowserButton (KPPad)
- (void)press:(BOOL)pressing;
@end
@interface KPMiiWiiButton (KPPad)
- (BOOL)holds;
- (void)down;
- (void)up;
- (void)tap;
@end
@interface KPMiiBodySlider (KPPad)
- (void)step:(int)delta;
@end

// The pop-up menu being tracked, if any. Menus run their own loop and only hear key events.
static __weak NSMenu *KPPadMenu;
// The control A went down on, which its release presses.
static __weak NSView *KPPadPressed;
static void KPPadWatchMenus(){
    static dispatch_once_t once;
    dispatch_once(&once,^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note){KPPadMenu=note.object;}];
        [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note){if(KPPadMenu==note.object)KPPadMenu=nil;}];
    });
}

static KPMiiBrowser *KPPadBrowser(){return [(id)KPMiiSaveListener isKindOfClass:KPMiiBrowser.class]?(KPMiiBrowser*)KPMiiSaveListener:nil;}
static NSWindow *KPPadBrowserWindow(){KPMiiBrowser *browser=KPPadBrowser();return browser.isViewLoaded&&browser.view.window.visible?browser.view.window:nil;}
static NSWindow *KPPadEditorWindow(){NSWindow *window=KPMiiActiveEditor.window;return window.visible?window:nil;}
BOOL KartPadMiiWindowsVisible(void){KPPadWatchMenus();return KPPadBrowserWindow()!=nil||KPPadEditorWindow()!=nil;}

static void KPPadCollect(NSView *view,BOOL(^keep)(NSView*),NSMutableArray<NSView*> *into){
    for(NSView *child in view.subviews){if(child.hidden)continue;if(keep(child))[into addObject:child];KPPadCollect(child,keep,into);}
}
static NSRect KPPadFrame(NSView *view){return [view convertRect:view.bounds toView:nil];}
// The nearest candidate in the pressed direction, with sideways distance weighed as the editor's
// arrow keys weigh it. Window coordinates run upwards, so dy is flipped to make down positive.
static NSView *KPPadNearest(NSArray<NSView*> *candidates,NSRect here,int dx,int dy){
    NSView *best=nil;CGFloat score=CGFLOAT_MAX;
    for(NSView *view in candidates){
        NSRect there=KPPadFrame(view);CGFloat x=NSMidX(there)-NSMidX(here),y=NSMidY(here)-NSMidY(there);
        CGFloat primary=dx?x*dx:y*dy,secondary=dx?y:x;if(primary<=1)continue;
        CGFloat cost=primary+std::abs(secondary)*4;if(cost<score){score=cost;best=view;}
    }
    return best;
}
static void KPPadFocus(NSView *view){[view.window makeFirstResponder:view];[view scrollRectToVisible:view.bounds];}
static BOOL KPPadDirection(KartPadMiiPadButton button,int *dx,int *dy){
    *dx=button==KartPadMiiPadLeft?-1:button==KartPadMiiPadRight?1:0;*dy=button==KartPadMiiPadUp?-1:button==KartPadMiiPadDown?1:0;
    return *dx||*dy;
}
// A key press for the loops that only read keys (pop-up menus and file panels).
static void KPPadKey(unsigned short code,unichar character){
    NSString *text=[NSString stringWithCharacters:&character length:1];
    for(NSEventType type:{NSEventTypeKeyDown,NSEventTypeKeyUp})
        [NSApp postEvent:[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:NSApp.keyWindow.windowNumber context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code] atStart:NO];
}
static void KPPadArrow(int dx,int dy){
    if(dx)KPPadKey(dx<0?123:124,dx<0?NSLeftArrowFunctionKey:NSRightArrowFunctionKey);
    else KPPadKey(dy<0?126:125,dy<0?NSUpArrowFunctionKey:NSDownArrowFunctionKey);
}

#pragma mark Miis screen

static NSArray<NSView*> *KPPadBrowserControls(KPMiiBrowser *browser){
    NSMutableArray *controls=[NSMutableArray array];
    KPPadCollect(browser.canvas,^BOOL(NSView *view){return [view isKindOfClass:KPMiiBrowserButton.class]&&[(KPMiiBrowserButton*)view isEnabled];},controls);
    return controls;
}
// Moving onto a Mii selects it, so the details follow the ring.
static void KPPadBrowserFocus(KPMiiBrowser *browser,NSView *view){
    KPPadFocus(view);KPMiiBrowserButton *tile=(KPMiiBrowserButton*)view;
    if([browser.tiles containsObject:tile]&&tile.slot!=NSNotFound&&tile.slot!=browser.selectedSlot)[browser selectSlot:tile.slot];else KPPlay(KPSound::Hover);
}
static void KPPadBrowserRelease(KPMiiBrowserButton *button){
    [button press:NO];if(!button.enabled||!button.window.isKeyWindow)return;
    // As Return: a Mii opens in the editor, anything else is clicked.
    if(button.doubleTapped)button.doubleTapped();else if(button.tapped)button.tapped();
}
static void KPPadBrowserPress(KPMiiBrowser *browser,KartPadMiiPadButton button){
    NSResponder *responder=browser.view.window.firstResponder;
    KPMiiBrowserButton *focus=[responder isKindOfClass:KPMiiBrowserButton.class]&&[(NSView*)responder isDescendantOf:browser.canvas]?(KPMiiBrowserButton*)responder:nil;
    int dx,dy;
    if(KPPadDirection(button,&dx,&dy)||(button==KartPadMiiPadConfirm&&!focus)){
        NSArray *controls=KPPadBrowserControls(browser);NSView *next=nil;
        if(focus)next=KPPadNearest(controls,KPPadFrame(focus),dx,dy);
        // The first press shows the ring on the selected Mii.
        else{for(KPMiiBrowserButton *tile in browser.tiles)if(tile.slot==browser.selectedSlot&&[controls containsObject:tile])next=tile;next=next?:controls.firstObject;}
        if(next)KPPadBrowserFocus(browser,next);
        return;
    }
    switch(button){
    case KartPadMiiPadConfirm:if(focus.enabled){[focus press:YES];KPPadPressed=focus;}return;
    case KartPadMiiPadBack:case KartPadMiiPadStart:[browser finish];return;
    default:return;
    }
}

#pragma mark Editor

static BOOL KPPadEditorControl(NSView *view){return ([view isKindOfClass:KPMiiWiiButton.class]&&[(KPMiiWiiButton*)view isEnabled])||[view isKindOfClass:KPMiiBodySlider.class];}
static NSArray<NSView*> *KPPadEditorControls(KPMiiEditor *editor){
    NSMutableArray *controls=[NSMutableArray array];KPPadCollect(editor.window.contentView,^BOOL(NSView *view){return KPPadEditorControl(view);},controls);return controls;
}
static const KPItem *KPPadItem(NSView *view){
    if(![view isKindOfClass:KPMiiWiiButton.class])return nullptr;KPMiiWiiButton *button=(KPMiiWiiButton*)view;KPMiiCanvas *canvas=button.canvas;
    return canvas&&button.index<canvas->_items.size()?&canvas->_items[button.index]:nullptr;
}
// The current choice (a feature, the gender), else the open category, else the first control.
static NSView *KPPadEditorDefault(KPMiiEditor *editor,NSArray<NSView*> *controls){
    auto a=kartpad::mii::Appearance::Decode(Bytes(editor.draft));NSView *tab=nil;
    for(NSView *view in controls){
        const KPItem *item=KPPadItem(view);if(!item)continue;
        if(item->action==KPAction::Select&&a.Get(item->field)==unsigned(item->value))return view;
        if(!tab&&item->selected)tab=view;
    }
    return tab?:controls.firstObject;
}
// Pages, categories and undo rebuild the controls; the ring returns to the same control.
static void KPPadEditorRefocus(KPMiiEditor *editor,KPAction action,unsigned field,int value){
    if([editor.window.firstResponder isKindOfClass:KPMiiWiiButton.class]&&[(NSView*)editor.window.firstResponder window])return;
    NSArray *controls=KPPadEditorControls(editor);
    for(NSView *view in controls){const KPItem *item=KPPadItem(view);if(item&&item->action==action&&item->field==field&&item->value==value){KPPadFocus(view);return;}}
    if(NSView *view=KPPadEditorDefault(editor,controls))KPPadFocus(view);
}
static void KPPadEditorRelease(KPMiiWiiButton *button){
    BOOL inside=button.highlighted;[button highlight:NO];
    if([button holds]){[button up];return;}
    KPMiiEditor *editor=button.canvas.editor;const KPItem *item=KPPadItem(button);if(!inside||!editor||!item||!button.window.isKeyWindow)return;
    KPAction action=item->action;unsigned field=item->field;int value=item->value;
    [button tap];
    if(editor.window.visible)KPPadEditorRefocus(editor,action,field,value);
}
static void KPPadEditorPress(KPMiiEditor *editor,KartPadMiiPadButton button){
    NSResponder *responder=editor.window.firstResponder;
    NSView *focus=[responder isKindOfClass:NSView.class]&&KPPadEditorControl((NSView*)responder)?(NSView*)responder:nil;
    int dx,dy;
    if(KPPadDirection(button,&dx,&dy)||(button==KartPadMiiPadConfirm&&!focus)){
        // Height and weight move with left and right; up and down leave the gauge.
        if([focus isKindOfClass:KPMiiBodySlider.class]&&dx){[(KPMiiBodySlider*)focus step:dx*4];return;}
        NSArray *controls=KPPadEditorControls(editor);
        NSView *next=focus?KPPadNearest(controls,KPPadFrame(focus),dx,dy):KPPadEditorDefault(editor,controls);
        if(next){KPPadFocus(next);KPPlay(KPSound::Hover);}
        return;
    }
    KPItem item{};
    switch(button){
    case KartPadMiiPadConfirm:{
        if(![focus isKindOfClass:KPMiiWiiButton.class])return;
        KPMiiWiiButton *control=(KPMiiWiiButton*)focus;if(!control.enabled)return;
        [control highlight:YES];KPPadPressed=control;if([control holds])[control down];
        return;}
    case KartPadMiiPadBack:
        // The look-alike grid steps back to the create screen; everything else closes, asking about unsaved changes.
        if(editor.creating&&editor.pickingLookAlike){item.action=KPAction::Back;[editor performItem:item];KPPadEditorRefocus(editor,KPAction::Start,0,1);return;}
        [editor quit];return;
    case KartPadMiiPadStart:
        if(editor.creating)return;
        if([editor dirty])[editor save];else KPPlay(KPSound::Reject);
        return;
    case KartPadMiiPadPreviousTab:case KartPadMiiPadNextTab:{
        if(editor.creating)return;
        unsigned next=unsigned((editor.category+(button==KartPadMiiPadNextTab?1:9))%10);
        item.action=KPAction::Category;item.field=next;[editor performItem:item];
        if(editor.category==NSInteger(next))KPPadEditorRefocus(editor,KPAction::Category,next,0);
        return;}
    case KartPadMiiPadUndo:case KartPadMiiPadRedo:{
        if(editor.creating)return;
        const KPItem *focused=KPPadItem(focus);KPAction action=focused?focused->action:KPAction::Undo;unsigned field=focused?focused->field:0;int value=focused?focused->value:0;
        item.action=button==KartPadMiiPadUndo?KPAction::Undo:KPAction::Redo;[editor performItem:item];
        if(focused)KPPadEditorRefocus(editor,action,field,value);
        return;}
    default:return;
    }
}

#pragma mark Alerts, file panels and menus

static NSArray<NSButton*> *KPPadDialogButtons(NSWindow *window){
    NSMutableArray *buttons=[NSMutableArray array];
    KPPadCollect(window.contentView,^BOOL(NSView *view){return [view isKindOfClass:NSButton.class]&&[(NSButton*)view bezelStyle]==NSBezelStylePush&&[(NSButton*)view title].length;},buttons);
    return buttons;
}
static const void *KPPadCancelKey=&KPPadCancelKey;
// The button Escape presses. Moving the default button takes over its key equivalent, so the
// first move remembers it.
static NSButton *KPPadCancelButton(NSWindow *window,NSArray<NSButton*> *buttons){
    NSButton *cancel=objc_getAssociatedObject(window,KPPadCancelKey);if([buttons containsObject:cancel])return cancel;
    for(NSButton *button in buttons)if([button.keyEquivalent isEqual:@"\033"])return button;
    for(NSButton *button in buttons)if([button.title isEqual:@"Cancel"]||[button.title isEqual:@"Keep Editing"])return button;
    return nil;
}
static void KPPadDialogPress(NSWindow *window,KartPadMiiPadButton button){
    int dx,dy;BOOL direction=KPPadDirection(button,&dx,&dy);
    // File panels (and anything without alert buttons) get the keys instead.
    NSArray<NSButton*> *buttons=[window isKindOfClass:NSSavePanel.class]?@[]:KPPadDialogButtons(window);
    if(!buttons.count){
        if(direction)KPPadArrow(dx,dy);else if(button==KartPadMiiPadConfirm)KPPadKey(36,'\r');else if(button==KartPadMiiPadBack)KPPadKey(53,0x1b);
        return;
    }
    NSButton *current=nil;
    for(NSButton *candidate in buttons)if([candidate.keyEquivalent isEqual:@"\r"])current=candidate;
    if(direction){
        NSMutableArray *enabled=[NSMutableArray array];for(NSButton *candidate in buttons)if(candidate.enabled)[enabled addObject:candidate];
        NSButton *next=current?(NSButton*)KPPadNearest(enabled,KPPadFrame(current),dx,dy):enabled.firstObject;if(!next||next==current)return;
        NSButton *cancel=KPPadCancelButton(window,buttons);if(cancel)objc_setAssociatedObject(window,KPPadCancelKey,cancel,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for(NSButton *candidate in buttons)candidate.keyEquivalent=candidate==next?@"\r":candidate==cancel?@"\033":@"";
        KPPlay(KPSound::Hover);return;
    }
    switch(button){
    case KartPadMiiPadConfirm:if(current.enabled)[current performClick:nil];return;
    case KartPadMiiPadBack:if(NSButton *cancel=KPPadCancelButton(window,buttons))[cancel performClick:nil];else KPPadKey(53,0x1b);return;
    default:return;
    }
}
static void KPPadMenuPress(NSMenu *menu,KartPadMiiPadButton button){
    int dx,dy;
    if(KPPadDirection(button,&dx,&dy))KPPadArrow(dx,dy);
    else if(button==KartPadMiiPadConfirm)KPPadKey(36,'\r');
    else if(button==KartPadMiiPadBack)[menu cancelTracking];
}

void KartPadMiiPadPress(KartPadMiiPadButton button,BOOL down){
    KPPadWatchMenus();
    if(!down){
        // A's release presses what its press went down on, wherever the focus is now.
        if(button!=KartPadMiiPadConfirm)return;
        NSView *pressed=KPPadPressed;KPPadPressed=nil;
        if([pressed isKindOfClass:KPMiiWiiButton.class])KPPadEditorRelease((KPMiiWiiButton*)pressed);
        else if([pressed isKindOfClass:KPMiiBrowserButton.class])KPPadBrowserRelease((KPMiiBrowserButton*)pressed);
        return;
    }
    if(!NSApp.active)return;
    if(NSMenu *menu=KPPadMenu){KPPadMenuPress(menu,button);return;}
    NSWindow *browserWindow=KPPadBrowserWindow(),*editorWindow=KPPadEditorWindow(),*key=NSApp.keyWindow;
    if(!browserWindow&&!editorWindow)return;
    if(key&&key==editorWindow){KPPadEditorPress(KPMiiActiveEditor,button);return;}
    if(key&&key==browserWindow){KPPadBrowserPress(KPPadBrowser(),button);return;}
    // Sheets on either window, and the editor's questions and file panels, which run modally.
    if(key&&((key.sheetParent&&(key.sheetParent==browserWindow||key.sheetParent==editorWindow))||key==NSApp.modalWindow)){KPPadDialogPress(key,button);return;}
    // Settings and Controllers keep their own focus (Controllers listens to the pads itself).
    if([key isKindOfClass:NSPanel.class])return;
    // The game window is in front: bring the Mii window back, and let this press only do that.
    NSWindow *front=editorWindow?:browserWindow;[NSApp activateIgnoringOtherApps:YES];[front makeKeyAndOrderFront:nil];
}
#endif
