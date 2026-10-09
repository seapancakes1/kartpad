// The controller keyboard (Mac): a Wii-style key grid for typing names with a pad, used by the
// editor's Nickname and Creator fields and the Miis screen's Rename alerts. It is included after
// KartPadMiiBrowser.inc.mm (keys are browser buttons) and before KartPadMiiGamepad.inc.mm, which
// sends it the presses. Keys go through the field's own editor, so the field counts, checks and
// undoes them as it does typing. A presses the focused key, B deletes, X is Shift (once for one
// capital, twice for caps lock), Y types a space, LB and RB switch letters and symbols, and Start
// is OK. The mouse and a hardware keyboard work too.
#if TARGET_OS_OSX

// Letters and digits, then accented letters and punctuation. Shift capitalises either page.
static NSArray<NSString*> *KPPadKeyRows(NSUInteger page){
    return page?@[@"!?&#@()\":;",@"àáâäãåæçèé",@"êëìíîïñòóô",@"öõøœùúûüßÿ"]:@[@"1234567890",@"qwertyuiop",@"asdfghjkl'",@"zxcvbnm,.-"];
}
static constexpr CGFloat KPPadKeyW=50,KPPadKeyH=46,KPPadKeyGap=6,KPPadKeyMargin=20,KPPadKeyTop=104;

@interface KPPadKeyButton : KPMiiBrowserButton
@end
@implementation KPPadKeyButton
// Space and Return type and confirm rather than pressing the focused key.
- (void)keyDown:(NSEvent*)event{[self.nextResponder keyDown:event];}
@end

@class KPPadKeyboard;
@interface KPPadKeyboardView : NSView
@property(nonatomic,weak) KPPadKeyboard *keyboard;
@end

@interface KPPadKeyboard : NSObject <NSWindowDelegate>
@property(nonatomic,strong) NSPanel *panel;
@property(nonatomic,strong) KPPadKeyboardView *canvas;
@property(nonatomic,strong) NSMutableArray<KPPadKeyButton*> *keys;
@property(nonatomic,weak) NSTextField *field;
@property(nonatomic,copy) NSString *original,*problem;
@property(nonatomic) BOOL required,shift,capsLock;
@property(nonatomic) NSUInteger page;
@property(nonatomic,copy) void(^done)(BOOL ok);
// Watches the field's window closing (the editor closed by mouse, say), which cancels.
@property(nonatomic,strong) id closing;
- (void)type:(NSString*)text;
- (void)erase;
- (void)toggleShift;
- (void)togglePage;
- (void)finish:(BOOL)ok;
@end
static KPPadKeyboard *KPPadActiveKeyboard;

@implementation KPPadKeyboardView
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)drawRect:(NSRect)rect{
    CGContextRef c=NSGraphicsContext.currentContext.CGContext;KPUsePalette(self);
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;KPPadKeyboard *keyboard=self.keyboard;
    KPFill(c,self.bounds,KPP->background);
    KPSetInk(c,KPP->stripe);CGContextSetLineWidth(c,1);for(CGFloat y=1.5;y<h;y+=4)KPLine(c,0,y,w,y);
    // The name in a well, with a caret after it, and its count or what is wrong with it below.
    CGRect well=CGRectMake(KPPadKeyMargin,18,w-2*KPPadKeyMargin,52);
    KPFill(c,well,KPP->panel,12);KPStroke(c,well,keyboard.problem?0xd93a2b:KPP->panelStroke,keyboard.problem?2:1,12);
    NSString *text=keyboard.field.stringValue?:@"";
    KPCenteredText([text stringByAppendingString:@"|"],CGRectInset(well,16,0),24,KPP->text,NO,NSTextAlignmentLeft);
    KPText(keyboard.problem?:KPMiiNameCount(text),CGRectMake(KPPadKeyMargin+4,76,w-2*KPPadKeyMargin-8,18),12,keyboard.problem?0xd93a2b:KPP->secondaryText,NO,NSTextAlignmentLeft);
    KPText(@"A  Type     B  Delete     X  Shift     Y  Space     LB / RB  Symbols     Start  OK",CGRectMake(KPPadKeyMargin,h-26,w-2*KPPadKeyMargin,16),11,KPP->secondaryText,NO,NSTextAlignmentCenter);
}
- (void)keyDown:(NSEvent*)event{
    KPPadKeyboard *keyboard=self.keyboard;NSString *text=event.characters;
    if(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl)){[super keyDown:event];return;}
    switch(event.keyCode){
    case 53:[keyboard finish:NO];return;
    case 36:case 76:[keyboard finish:YES];return;
    case 51:case 117:[keyboard erase];return;
    case 123:case 124:case 125:case 126:KartPadMiiPadPress(event.keyCode==123?KartPadMiiPadLeft:event.keyCode==124?KartPadMiiPadRight:event.keyCode==125?KartPadMiiPadDown:KartPadMiiPadUp,YES);return;
    default:break;
    }
    if(text.length&&[text characterAtIndex:0]>=0x20&&[text characterAtIndex:0]<0xF700)[keyboard type:text];else [super keyDown:event];
}
@end

@implementation KPPadKeyboard
- (NSString*)label:(NSString*)character{
    if(!self.shift)return character;
    NSString *upper=character.uppercaseString;return upper.length==1?upper:character;
}
- (KPPadKeyButton*)key:(CGRect)frame style:(KPStyle)style title:(NSString*(^)(void))title size:(CGFloat)size selected:(BOOL(^)(void))selected action:(void(^)(void))action{
    KPPadKeyButton *key=[[KPPadKeyButton alloc]initWithFrame:frame];
    key.paint=^(CGContextRef c,CGRect b,BOOL pressed,BOOL hovered){
        CGRect r=CGRectInset(b,1,1),face=CGRectMake(r.origin.x,r.origin.y,r.size.width,r.size.height-3);
        KPButtonFace(c,r,style,selected?selected():NO,YES,pressed,hovered);
        CGContextSaveGState(c);if(pressed)CGContextTranslateCTM(c,0,2);
        KPCenteredText(title(),CGRectInset(face,4,0),size,style==KPStyle::Primary?0xffffff:KPP->text,YES);
        CGContextRestoreGState(c);
    };
    key.tapped=action;key.bordered=NO;key.title=@"";[key setAccessibilityLabel:title()];
    [self.canvas addSubview:key];[self.keys addObject:key];
    return key;
}
- (void)build{
    __weak KPPadKeyboard *weak=self;
    const CGFloat gridW=10*KPPadKeyW+9*KPPadKeyGap,w=gridW+2*KPPadKeyMargin,bottomY=KPPadKeyTop+4*(KPPadKeyH+KPPadKeyGap),h=bottomY+KPPadKeyH+40;
    self.panel=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,w,h) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.panel.releasedWhenClosed=NO;self.panel.hidesOnDeactivate=YES;self.panel.delegate=self;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorMoveToActiveSpace;
    self.canvas=[[KPPadKeyboardView alloc]initWithFrame:NSMakeRect(0,0,w,h)];self.canvas.keyboard=self;self.panel.contentView=self.canvas;
    self.keys=[NSMutableArray array];
    for(NSUInteger row=0;row<4;row++)for(NSUInteger column=0;column<10;column++){
        NSString *(^character)(void)=^NSString*{NSString *keys=KPPadKeyRows(weak.page)[row];return [keys substringWithRange:NSMakeRange(column,1)];};
        [self key:CGRectMake(KPPadKeyMargin+column*(KPPadKeyW+KPPadKeyGap),KPPadKeyTop+row*(KPPadKeyH+KPPadKeyGap),KPPadKeyW,KPPadKeyH) style:KPStyle::Plain
            title:^NSString*{return [weak label:character()];} size:18 selected:nil action:^{[weak type:[weak label:character()]];}];
    }
    // Shift, symbols, space, delete, Cancel and OK fill the bottom row.
    const CGFloat widths[]={76,76,160,76,68,68};CGFloat x=KPPadKeyMargin;
    NSString *(^titles[])(void)={^NSString*{return weak.capsLock?@"⇪":@"⇧";},^NSString*{return weak.page?@"ABC":@"àé?";},^NSString*{return @"Space";},^NSString*{return @"⌫";},^NSString*{return @"Cancel";},^NSString*{return @"OK";}};
    void(^actions[])(void)={^{[weak toggleShift];},^{[weak togglePage];},^{[weak type:@" "];},^{[weak erase];},^{[weak finish:NO];},^{[weak finish:YES];}};
    for(int i=0;i<6;i++){
        KPPadKeyButton *key=[self key:CGRectMake(x,bottomY,widths[i],KPPadKeyH) style:i==5?KPStyle::Primary:KPStyle::Plain title:titles[i] size:i<2||i==3?18:14
            selected:i==0?^BOOL{return weak.shift;}:(BOOL(^)(void))nil action:actions[i]];
        if(i==0)[key setAccessibilityLabel:@"Shift"];if(i==1)[key setAccessibilityLabel:@"Symbols"];if(i==3)[key setAccessibilityLabel:@"Delete"];
        x+=widths[i]+KPPadKeyGap;
    }
}
- (void)refresh{for(KPPadKeyButton *key in self.keys)key.needsDisplay=YES;self.canvas.needsDisplay=YES;}
// The field's editor, with the caret at the end; the field starts editing if it wasn't.
- (NSTextView*)editor{
    NSTextField *field=self.field;if(!field.window)return nil;
    if(!field.currentEditor)[field.window makeFirstResponder:field];
    NSTextView *editor=(NSTextView*)field.currentEditor;[editor setSelectedRange:NSMakeRange(editor.string.length,0)];
    return editor;
}
- (void)type:(NSString*)text{
    NSTextView *editor=[self editor];if(!editor)return;
    if(NSString *problem=KPMiiNameProblem([self.field.stringValue stringByAppendingString:text],NO)){self.problem=problem;KPPlay(KPSound::Reject);[self refresh];return;}
    [editor insertText:text replacementRange:editor.selectedRange];KPPlay(KPSound::Key);
    self.problem=nil;if(self.shift&&!self.capsLock)self.shift=NO;[self refresh];
}
- (void)erase{
    NSTextView *editor=[self editor];if(!editor)return;
    if(!editor.string.length){KPPlay(KPSound::Reject);return;}
    [editor deleteBackward:nil];KPPlay(KPSound::Erase);
    self.problem=nil;if(!editor.string.length&&!self.capsLock)self.shift=YES;[self refresh];
}
// Off, then one capital, then caps lock, then off.
- (void)toggleShift{
    if(!self.shift)self.shift=YES;else if(!self.capsLock)self.capsLock=YES;else self.shift=self.capsLock=NO;
    KPPlay(KPSound::Tab);[self refresh];
}
- (void)togglePage{self.page=1-self.page;KPPlay(KPSound::Tab);[self refresh];}
// done runs only while the field's window is still up (an alert may have been answered by mouse).
- (void)finish:(BOOL)ok{
    NSTextField *field=self.field;NSWindow *window=field.window;BOOL alive=window.visible;
    if(ok&&alive){
        NSString *problem=KPMiiNameProblem([field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],self.required);
        if(problem){self.problem=problem;KPPlay(KPSound::Reject);[self refresh];return;}
    }else if(alive&&![field.stringValue isEqual:self.original]){
        NSTextView *editor=[self editor];[editor setSelectedRange:NSMakeRange(0,editor.string.length)];
        if(self.original.length)[editor insertText:self.original replacementRange:editor.selectedRange];else [editor delete:nil];
    }
    void(^done)(BOOL)=self.done;self.done=nil;
    if(self.closing)[NSNotificationCenter.defaultCenter removeObserver:self.closing];self.closing=nil;
    [self.panel orderOut:nil];
    if(alive){[window makeKeyAndOrderFront:nil];[self editor];}
    KPPlay(ok?KPSound::Confirm:KPSound::Close);
    // Released on the next turn, since this can run inside one of the panel's own events.
    KPPadKeyboard *keep=self;dispatch_async(dispatch_get_main_queue(),^{(void)keep;});
    if(KPPadActiveKeyboard==self)KPPadActiveKeyboard=nil;
    if(done&&alive)done(ok);
}
- (BOOL)windowShouldClose:(NSWindow*)window{[self finish:NO];return NO;}
- (void)dealloc{_panel.delegate=nil;}
@end

// Opens the keyboard on an editable field in a Mii window or one of its alerts. done runs after OK
// (the name can be stored) or Cancel (the field is back as it was).
static void KPPadKeyboardOpen(NSTextField *field,NSString *title,BOOL required,void(^done)(BOOL ok)){
    // One left behind (KartPad was in the background when its window went) is cancelled first.
    if(KPPadActiveKeyboard.panel.visible||!field.window.visible)return;
    [KPPadActiveKeyboard finish:NO];
    KPPadKeyboard *keyboard=[KPPadKeyboard new];[keyboard build];KPPadActiveKeyboard=keyboard;
    keyboard.field=field;keyboard.original=field.stringValue;keyboard.required=required;keyboard.done=done;
    keyboard.shift=!field.stringValue.length;keyboard.panel.title=title;
    // Over the bottom of the window the field is in (an alert's parent), above it and its alerts.
    NSWindow *parent=field.window.sheetParent?:field.window;NSRect frame=keyboard.panel.frame,area=parent.frame;
    if(frame.size.width>area.size.width||frame.size.height>area.size.height)area=parent.screen.visibleFrame;
    frame.origin=NSMakePoint(NSMidX(area)-frame.size.width/2,area.origin.y+std::max(CGFloat(16),std::min(CGFloat(40),area.size.height-frame.size.height)));
    [keyboard.panel setFrame:frame display:NO];
    keyboard.panel.level=std::max(parent.level,field.window.level)+1;
    __weak KPPadKeyboard *weak=keyboard;
    keyboard.closing=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:parent queue:nil usingBlock:^(NSNotification *note){[weak finish:NO];}];
    [keyboard editor];
    [keyboard.panel makeKeyAndOrderFront:nil];
    // The first letter on the top row of letters.
    [keyboard.panel makeFirstResponder:keyboard.keys[10]];
    KPPlay(KPSound::Open);
}
// The keyboard on screen, if any. One whose field has gone (its alert answered by mouse) closes.
static NSWindow *KPPadKeyboardWindow(){
    KPPadKeyboard *keyboard=KPPadActiveKeyboard;if(!keyboard)return nil;
    if(!keyboard.field.window.visible){[keyboard finish:NO];return nil;}
    return keyboard.panel.visible?keyboard.panel:nil;
}
#endif
