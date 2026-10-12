// Controller navigation for the Miis screen and the Mii editor on iPhone and iPad
// (KartPadMiiEditor.h), as the Mac's (KartPadMiiGamepad.inc.mm): KartPadScreens.mm reads the pads and
// sends each press here while one of them is in front. The D-pad or left stick moves a focus ring to
// the nearest control that way and A presses it (held adjustments repeat); B goes back (Done on the
// Miis screen, close in the editor); in the editor LB and RB change category, X and Y undo and
// redo, Start saves and the right stick turns the Mii. UIKit's alerts and keyboard don't take a
// controller, so with one the editor asks about unsaved changes on a card of its own, and names are
// typed on a pad keyboard. Touch works throughout as before; the ring goes once the screen is touched.
// Included by apple/shared/KartPadMiiGamepad.inc.mm.
#import <UIKit/UIGestureRecognizerSubclass.h>

@interface KPMiiBrowser (KPPadIOS)
- (void)selectSlot:(NSUInteger)slot;
- (void)finish;
@end
@interface KPMiiEditor (KPPadIOS)
- (NSString*)saveQuestion;
@end
@interface KPMiiWiiButton (KPPadIOS)
- (BOOL)holds;
- (void)down;
- (void)up;
- (void)tap;
@end
@interface KPMiiBodySlider (KPPadIOS)
- (void)step:(int)delta;
@end

#pragma mark Finding the front screen and its controls

static UIViewController *KPPadTop(){
    UIWindow *key=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *window in ((UIWindowScene*)scene).windows)if(window.isKeyWindow)key=window;
    }
    UIViewController *top=key.rootViewController;
    while(top.presentedViewController&&!top.presentedViewController.isBeingDismissed)top=top.presentedViewController;
    if([top isKindOfClass:UINavigationController.class])top=((UINavigationController*)top).topViewController;
    return top;
}
static KPMiiBrowser *KPPadBrowserIOS(){UIViewController *top=KPPadTop();return [top isKindOfClass:KPMiiBrowser.class]?(KPMiiBrowser*)top:nil;}
static KPMiiEditor *KPPadEditorIOS(){UIViewController *top=KPPadTop();return [top isKindOfClass:KPMiiEditor.class]?(KPMiiEditor*)top:nil;}
BOOL KartPadMiiWindowsVisible(void){return KPPadBrowserIOS()!=nil||KPPadEditorIOS()!=nil;}

static void KPPadCollectIOS(UIView *view,BOOL(^keep)(UIView*),NSMutableArray<UIView*> *into){
    for(UIView *child in view.subviews){if(child.hidden||child.alpha<0.01)continue;if(keep(child))[into addObject:child];KPPadCollectIOS(child,keep,into);}
}
// In window coordinates (y down), clipped to the scroll views it sits in so a control scrolled out
// of sight counts only for what shows (except within the focus's own list).
static CGRect KPPadFrameIOS(UIView *view){return [view convertRect:view.bounds toView:nil];}
static UIScrollView *KPPadScroll(UIView *view){
    for(UIView *up=view.superview;up;up=up.superview)if([up isKindOfClass:UIScrollView.class])return (UIScrollView*)up;
    return nil;
}
// The control the pressed direction leads to (dy positive downwards), as KPPadNearest on the Mac.
static UIView *KPPadNearestIOS(NSArray<UIView*> *candidates,UIView *from,int dx,int dy){
    struct Span{CGFloat lo,hi;};
    auto along=[&](CGRect r)->Span{
        return dx>0?Span{CGRectGetMinX(r),CGRectGetMaxX(r)}:dx<0?Span{-CGRectGetMaxX(r),-CGRectGetMinX(r)}
              :dy>0?Span{CGRectGetMinY(r),CGRectGetMaxY(r)}:Span{-CGRectGetMaxY(r),-CGRectGetMinY(r)};
    };
    auto across=[&](CGRect r)->Span{return dx?Span{CGRectGetMinY(r),CGRectGetMaxY(r)}:Span{CGRectGetMinX(r),CGRectGetMaxX(r)};};
    CGRect here=KPPadFrameIOS(from);Span a=along(here),p=across(here);UIScrollView *list=KPPadScroll(from);
    UIView *best=nil;int bestRank=INT_MAX;CGFloat bestScore=CGFLOAT_MAX;
    for(UIView *view in candidates){
        if(view==from)continue;
        BOOL inList=list&&KPPadScroll(view)==list;CGRect there=KPPadFrameIOS(view);
        if(!inList)for(UIScrollView *scroll=KPPadScroll(view);scroll;scroll=KPPadScroll(scroll))
            there=CGRectIntersection(there,KPPadFrameIOS(scroll));
        if(CGRectIsEmpty(there))continue;
        Span b=along(there),q=across(there);
        if(!((a.lo<b.lo||a.hi<=b.lo)&&a.hi<b.hi))continue;
        CGFloat gap=std::max(CGFloat(0),b.lo-a.hi),overlap=std::min(p.hi,q.hi)-std::max(p.lo,q.lo),side=std::max(CGFloat(0),-overlap);
        int tier=overlap>0?0:gap>=side?1:2,rank=inList?(tier<2?tier:4):(tier<2?2+tier:5);
        if(tier==2&&b.lo<a.hi)continue;
        CGFloat offset=(q.lo+q.hi-p.lo-p.hi)/2,score=13*gap*gap+offset*offset;
        if(rank<bestRank||(rank==bestRank&&score<bestScore)){bestRank=rank;bestScore=score;best=view;}
    }
    return best;
}
static BOOL KPPadDirectionIOS(KartPadMiiPadButton button,int *dx,int *dy){
    *dx=button==KartPadMiiPadLeft?-1:button==KartPadMiiPadRight?1:0;*dy=button==KartPadMiiPadUp?-1:button==KartPadMiiPadDown?1:0;
    return *dx||*dy;
}

#pragma mark The focus ring

// A Wii-blue ring over the focused control, above everything on its screen and touch-transparent.
@interface KPPadRingView : UIView
@end
@implementation KPPadRingView
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event{(void)point;(void)event;return nil;}
@end
static __weak UIView *KPPadFocused;
static void KPPadDropRing();
// A touch anywhere on the screen takes the ring away; the touch itself goes on as usual.
@interface KPPadTouchWatcher : UIGestureRecognizer
@end
@implementation KPPadTouchWatcher
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{
    (void)touches;(void)event;KPPadDropRing();self.state=UIGestureRecognizerStateFailed;
}
@end
static void KPPadWatchTouches(UIView *host){
    for(UIGestureRecognizer *recognizer in host.gestureRecognizers)if([recognizer isKindOfClass:KPPadTouchWatcher.class])return;
    KPPadTouchWatcher *watcher=[KPPadTouchWatcher new];watcher.cancelsTouchesInView=NO;watcher.delaysTouchesBegan=NO;
    watcher.delaysTouchesEnded=NO;[host addGestureRecognizer:watcher];
}
static KPPadRingView *KPPadRing(){
    static KPPadRingView *ring;
    if(!ring){
        ring=[KPPadRingView new];ring.userInteractionEnabled=NO;ring.layer.borderWidth=3.5;ring.layer.cornerRadius=12;
        ring.layer.borderColor=KPColor(KPLightPalette.accentTop).CGColor;
        ring.layer.shadowColor=KPColor(KPLightPalette.accentTop).CGColor;ring.layer.shadowOpacity=0.85;ring.layer.shadowRadius=6;
        ring.layer.shadowOffset=CGSizeZero;
    }
    return ring;
}
static void KPPadPlaceRing(){
    UIView *focus=KPPadFocused;KPPadRingView *ring=KPPadRing();
    UIView *host=focus.window?KPPadTop().view:nil;
    if(!focus||!host||focus.hidden){[ring removeFromSuperview];return;}
    if(ring.superview!=host){[host addSubview:ring];KPPadWatchTouches(host);}else [host bringSubviewToFront:ring];
    ring.frame=CGRectInset([focus convertRect:focus.bounds toView:host],-4,-4);
}
static void KPPadFocusIOS(UIView *view){
    KPPadFocused=view;
    if(UIScrollView *scroll=KPPadScroll(view))[scroll scrollRectToVisible:[view convertRect:view.bounds toView:scroll] animated:NO];
    KPPadPlaceRing();
}
static void KPPadDropRing(){KPPadFocused=nil;[KPPadRing() removeFromSuperview];}

#pragma mark Pad keyboard

// Letters, digits and the punctuation names use, in rows the D-pad walks; A types, X deletes, Start
// (or OK) keeps the name, B cancels. It types into the name field, which the editor checks as usual.
@interface KPPadKeyboard : UIView
@property(nonatomic,weak) UITextField *field;
@property(nonatomic,copy) NSString *original;
@property(nonatomic,copy) void(^done)(BOOL ok);
@property(nonatomic,strong) NSMutableArray<UIButton*> *keys;
@property(nonatomic,strong) UILabel *text;
@property(nonatomic) BOOL shifted;
@end
@implementation KPPadKeyboard
- (UIButton*)key:(NSString*)title{
    UIButton *key=[UIButton buttonWithType:UIButtonTypeSystem];[key setTitle:title forState:UIControlStateNormal];
    key.titleLabel.font=KPStyleFont(20,UIFontWeightSemibold);key.backgroundColor=KPColor(KPP->buttonTop);
    key.layer.cornerRadius=10;key.layer.borderWidth=1;key.layer.borderColor=KPColor(KPP->buttonStroke).CGColor;
    [key setTitleColor:KPColor(KPP->text) forState:UIControlStateNormal];
    [key addTarget:self action:@selector(typed:) forControlEvents:UIControlEventTouchUpInside];
    [self.keys addObject:key];[self addSubview:key];return key;
}
- (instancetype)initForField:(UITextField*)field title:(NSString*)title{
    if((self=[super initWithFrame:CGRectZero])){
        self.field=field;self.original=field.text?:@"";self.keys=[NSMutableArray array];
        self.backgroundColor=KPColor(KPP->panel);self.layer.cornerRadius=24;self.layer.borderWidth=1.5;
        self.layer.borderColor=KPColor(KPP->panelStroke).CGColor;
        self.text=[UILabel new];self.text.font=KPStyleFont(24,UIFontWeightSemibold);self.text.textColor=KPColor(KPP->text);
        self.text.textAlignment=NSTextAlignmentCenter;[self addSubview:self.text];self.accessibilityLabel=title;
        for(NSString *row in @[@"1234567890",@"QWERTYUIOP",@"ASDFGHJKL-",@"ZXCVBNM.'!"])
            for(NSUInteger i=0;i<row.length;++i)[self key:[row substringWithRange:NSMakeRange(i,1)]];
        for(NSString *word in @[@"Shift",@"Space",@"Delete",@"OK"])[self key:word];
        [self refresh];
    }
    return self;
}
- (void)layoutSubviews{
    [super layoutSubviews];const CGFloat w=self.bounds.size.width,pad=16,gap=6,keyW=(w-2*pad-9*gap)/10,keyH=44;
    self.text.frame=CGRectMake(pad,12,w-2*pad,40);
    for(NSUInteger i=0;i<self.keys.count;++i){
        UIButton *key=self.keys[i];
        if(i<40){NSUInteger row=i/10,column=i%10;key.frame=CGRectMake(pad+column*(keyW+gap),60+row*(keyH+gap),keyW,keyH);continue;}
        const NSUInteger j=i-40;const CGFloat wide=(w-2*pad-3*gap)/4;
        key.frame=CGRectMake(pad+j*(wide+gap),60+4*(keyH+gap),wide,keyH);
    }
}
- (void)refresh{
    self.text.text=self.field.text.length?self.field.text:@" ";
    for(NSUInteger i=0;i<40;++i){
        NSString *title=[self.keys[i] titleForState:UIControlStateNormal];
        [self.keys[i] setTitle:self.shifted?title.uppercaseString:title.lowercaseString forState:UIControlStateNormal];
    }
}
- (void)typed:(UIButton*)key{
    NSString *title=[key titleForState:UIControlStateNormal];UITextField *field=self.field;NSString *text=field.text?:@"";
    if([title isEqual:@"OK"]){[self finish:YES];return;}
    if([title isEqual:@"Shift"]){self.shifted=!self.shifted;KPPlay(KPSound::Tab);[self refresh];return;}
    if([title isEqual:@"Delete"]){
        if(text.length){field.text=[text substringToIndex:text.length-1];[field sendActionsForControlEvents:UIControlEventEditingChanged];KPPlay(KPSound::Left);}
        else KPPlay(KPSound::Reject);
        [self refresh];return;
    }
    if(text.length>=10){KPPlay(KPSound::Reject);return;}
    field.text=[text stringByAppendingString:[title isEqual:@"Space"]?@" ":title];
    [field sendActionsForControlEvents:UIControlEventEditingChanged];KPPlay(KPSound::Tick);
    if(self.shifted&&text.length==0){self.shifted=NO;}
    [self refresh];
}
- (void)finish:(BOOL)ok{
    if(!ok){self.field.text=self.original;[self.field sendActionsForControlEvents:UIControlEventEditingChanged];}
    void(^done)(BOOL)=self.done;self.done=nil;[self removeFromSuperview];KPPlay(ok?KPSound::Confirm:KPSound::Close);
    if(done)done(ok);
}
@end
static __weak KPPadKeyboard *KPPadOpenKeyboard;
static void KPPadKeyboardOpenIOS(KPMiiEditor *editor,UITextField *field){
    KPPadKeyboard *keyboard=[[KPPadKeyboard alloc]initForField:field title:field.tag==54?@"Creator":@"Nickname"];
    keyboard.shifted=field.text.length==0;[keyboard refresh];
    UIView *host=editor.view;const CGFloat w=std::min<CGFloat>(640,host.bounds.size.width-32),h=60+5*50+16;
    keyboard.frame=CGRectMake((host.bounds.size.width-w)/2,std::max<CGFloat>(16,(host.bounds.size.height-h)/2),w,h);
    [host addSubview:keyboard];KPPadOpenKeyboard=keyboard;
    __weak KPMiiEditor *weak=editor;__weak UITextField *weakField=field;
    keyboard.done=^(BOOL ok){if(ok)[weak commitNames];KPPadFocusIOS(weakField);};
    KPPlay(KPSound::Dialog);KPPadFocusIOS(keyboard.keys[keyboard.shifted?10:11]);
}

#pragma mark Save question

// The editor's "save your changes?" with a controller: a card of three big choices over the editor.
@interface KPPadQuestion : UIView
@property(nonatomic,strong) NSMutableArray<UIButton*> *choices;
@property(nonatomic,copy) void(^chose)(NSInteger index);
@end
@implementation KPPadQuestion
- (instancetype)initWithTitle:(NSString*)title choices:(NSArray<NSString*>*)names{
    if((self=[super initWithFrame:CGRectZero])){
        self.backgroundColor=KPColor(KPP->panel);self.layer.cornerRadius=24;self.layer.borderWidth=1.5;
        self.layer.borderColor=KPColor(KPP->panelStroke).CGColor;self.choices=[NSMutableArray array];
        UILabel *label=[UILabel new];label.text=title;label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;
        label.font=KPStyleFont(24,UIFontWeightBold);label.textColor=KPColor(KPP->text);label.tag=1;[self addSubview:label];
        for(NSUInteger i=0;i<names.count;++i){
            UIButton *choice=[UIButton buttonWithType:UIButtonTypeSystem];[choice setTitle:names[i] forState:UIControlStateNormal];
            choice.titleLabel.font=KPStyleFont(21,UIFontWeightSemibold);choice.layer.cornerRadius=14;choice.tag=100+i;
            choice.backgroundColor=KPColor(i==0?KPP->accentBottom:KPP->buttonTop);
            [choice setTitleColor:i==0?UIColor.whiteColor:KPColor(i==2?KPP->danger:KPP->text) forState:UIControlStateNormal];
            choice.layer.borderWidth=i==0?0:1;choice.layer.borderColor=KPColor(KPP->buttonStroke).CGColor;
            [choice addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
            [self.choices addObject:choice];[self addSubview:choice];
        }
    }
    return self;
}
- (void)layoutSubviews{
    [super layoutSubviews];const CGFloat w=self.bounds.size.width;[self viewWithTag:1].frame=CGRectMake(24,20,w-48,64);
    for(NSUInteger i=0;i<self.choices.count;++i)self.choices[i].frame=CGRectMake(24,96+i*64,w-48,54);
}
- (void)picked:(UIButton*)choice{void(^chose)(NSInteger)=self.chose;self.chose=nil;[self removeFromSuperview];if(chose)chose(choice.tag-100);}
@end
static __weak KPPadQuestion *KPPadOpenQuestion;
static void KPPadAskToSave(KPMiiEditor *editor){
    KPPadQuestion *question=[[KPPadQuestion alloc]initWithTitle:[editor saveQuestion] choices:@[@"Save",@"Keep Editing",@"Discard Changes"]];
    UIView *host=editor.view;const CGFloat w=std::min<CGFloat>(460,host.bounds.size.width-32),h=96+3*64+12;
    question.frame=CGRectMake((host.bounds.size.width-w)/2,(host.bounds.size.height-h)/2,w,h);
    [host addSubview:question];KPPadOpenQuestion=question;
    __weak KPMiiEditor *weak=editor;
    question.chose=^(NSInteger index){
        KPMiiEditor *editor=weak;
        if(index==0)[editor save];
        else if(index==2){KPPlay(KPSound::PagePrevious);[editor dismissViewControllerAnimated:YES completion:nil];}
        else KPPlay(KPSound::Close);
    };
    KPPlay(KPSound::Dialog);KPPadFocusIOS(question.choices.firstObject);
}

#pragma mark Presses

static __weak UIView *KPPadPressedIOS;

// A card of the pad's own (the keyboard, the save question) takes the presses while it's up.
static BOOL KPPadCardPress(UIView *card,NSArray<UIView*> *controls,KartPadMiiPadButton button,BOOL down,void(^back)(void)){
    if(!card.superview)return NO;
    UIView *focus=[controls containsObject:KPPadFocused]?KPPadFocused:nil;
    if(!down){
        if(button==KartPadMiiPadConfirm&&KPPadPressedIOS&&KPPadPressedIOS==focus){
            UIButton *pressed=(UIButton*)focus;pressed.highlighted=NO;KPPadPressedIOS=nil;
            [pressed sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
        return YES;
    }
    int dx,dy;
    if(KPPadDirectionIOS(button,&dx,&dy)){
        UIView *next=focus?KPPadNearestIOS(controls,focus,dx,dy):controls.firstObject;
        if(next){KPPadFocusIOS(next);KPPlay(KPSound::Hover);}else KPPlay(KPSound::Same);
        return YES;
    }
    if(button==KartPadMiiPadConfirm&&[focus isKindOfClass:UIButton.class]){((UIButton*)focus).highlighted=YES;KPPadPressedIOS=focus;return YES;}
    if(button==KartPadMiiPadBack){back();return YES;}
    return YES;
}

static void KPPadBrowserPressIOS(KPMiiBrowser *browser,KartPadMiiPadButton button,BOOL down){
    NSMutableArray<UIView*> *controls=[NSMutableArray array];
    KPPadCollectIOS(browser.view,^BOOL(UIView *view){return [view isKindOfClass:KPMiiBrowserButton.class]&&((UIButton*)view).enabled;},controls);
    UIView *focus=[controls containsObject:KPPadFocused]?KPPadFocused:nil;
    if(!down){
        if(button!=KartPadMiiPadConfirm||!KPPadPressedIOS||KPPadPressedIOS!=focus)return;
        KPMiiBrowserButton *pressed=(KPMiiBrowserButton*)focus;pressed.highlighted=NO;KPPadPressedIOS=nil;
        // As a double tap: a Mii opens in the editor; anything else is tapped.
        if(pressed.doubleTapped)pressed.doubleTapped();else if(pressed.tapped)pressed.tapped();
        return;
    }
    int dx,dy;
    if(KPPadDirectionIOS(button,&dx,&dy)||(button==KartPadMiiPadConfirm&&!focus)){
        UIView *next=nil;
        if(focus)next=KPPadNearestIOS(controls,focus,dx,dy);
        else{for(KPMiiBrowserButton *tile in browser.tiles)if(tile.slot==browser.selectedSlot&&[controls containsObject:tile])next=tile;next=next?:controls.firstObject;}
        if(!next)return;
        KPPadFocusIOS(next);KPMiiBrowserButton *tile=(KPMiiBrowserButton*)next;
        if([browser.tiles containsObject:tile]&&tile.slot!=NSNotFound&&tile.slot!=browser.selectedSlot)[browser selectSlot:tile.slot];
        else KPPlay(KPSound::Hover);
        KPPadPlaceRing();
        return;
    }
    switch(button){
    case KartPadMiiPadConfirm:if(((UIButton*)focus).enabled){((UIButton*)focus).highlighted=YES;KPPadPressedIOS=focus;}return;
    case KartPadMiiPadBack:case KartPadMiiPadStart:KPPadDropRing();[browser finish];return;
    default:return;
    }
}

static BOOL KPPadEditorControlIOS(UIView *view){
    return ([view isKindOfClass:KPMiiWiiButton.class]&&((UIButton*)view).enabled)||[view isKindOfClass:KPMiiBodySlider.class]
        ||([view isKindOfClass:UITextField.class]&&((UITextField*)view).enabled);
}
static NSArray<UIView*> *KPPadEditorControlsIOS(KPMiiEditor *editor){
    NSMutableArray *controls=[NSMutableArray array];
    KPPadCollectIOS(editor.canvas,^BOOL(UIView *view){return KPPadEditorControlIOS(view);},controls);
    return controls;
}
static const KPItem *KPPadItemIOS(UIView *view){
    if(![view isKindOfClass:KPMiiWiiButton.class])return nullptr;KPMiiWiiButton *button=(KPMiiWiiButton*)view;
    KPMiiCanvas *canvas=button.canvas;
    return canvas&&button.index<canvas->_items.size()?&canvas->_items[button.index]:nullptr;
}
static UIView *KPPadEditorDefaultIOS(KPMiiEditor *editor,NSArray<UIView*> *controls,BOOL page=NO){
    if(page)controls=[controls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIView *view,NSDictionary *b){
        (void)b;return view.superview!=editor.canvas;
    }]];
    auto a=KPShown(editor.draft);UIView *tab=nil;
    for(UIView *view in controls){
        const KPItem *item=KPPadItemIOS(view);if(!item)continue;
        if(item->action==KPAction::Select&&a.Get(item->field)==unsigned(item->value))return view;
        if(!tab&&item->selected)tab=view;
    }
    return tab?:controls.firstObject;
}
// Pages, categories and undo rebuild the controls; the ring returns to the same control.
static void KPPadEditorRefocusIOS(KPMiiEditor *editor,KPAction action,unsigned field,int value){
    if(KPPadFocused.window&&[KPPadFocused isDescendantOfView:editor.canvas]){KPPadPlaceRing();return;}
    NSArray *controls=KPPadEditorControlsIOS(editor);
    for(UIView *view in controls){
        const KPItem *item=KPPadItemIOS(view);
        if(item&&item->action==action&&item->field==field&&item->value==value){KPPadFocusIOS(view);return;}
    }
    if(UIView *view=KPPadEditorDefaultIOS(editor,controls))KPPadFocusIOS(view);
}
static void KPPadEditorPressIOS(KPMiiEditor *editor,KartPadMiiPadButton button,BOOL down){
    if(KPPadKeyboard *keyboard=KPPadOpenKeyboard){
        if(down&&button==KartPadMiiPadStart){[keyboard finish:YES];return;}
        if(down&&button==KartPadMiiPadUndo){[keyboard typed:keyboard.keys[42]];return;}
        KPPadCardPress(keyboard,keyboard.keys,button,down,^{[keyboard finish:NO];});return;
    }
    if(KPPadQuestion *question=KPPadOpenQuestion){
        KPPadCardPress(question,question.choices,button,down,^{[question picked:question.choices[1]];});return;
    }
    UIView *focus=KPPadEditorControlIOS(KPPadFocused)&&[KPPadFocused isDescendantOfView:editor.canvas]?KPPadFocused:nil;
    if(!down){
        if(button!=KartPadMiiPadConfirm||![KPPadPressedIOS isKindOfClass:KPMiiWiiButton.class])return;
        KPMiiWiiButton *pressed=(KPMiiWiiButton*)KPPadPressedIOS;KPPadPressedIOS=nil;
        BOOL inside=pressed.highlighted;pressed.highlighted=NO;[pressed setNeedsDisplay];
        if([pressed holds]){[pressed up];return;}
        const KPItem *item=KPPadItemIOS(pressed);if(!inside||!item)return;
        KPAction action=item->action;unsigned field=item->field;int value=item->value;
        [pressed tap];
        if(editor.view.window)KPPadEditorRefocusIOS(editor,action,field,value);
        return;
    }
    int dx,dy;
    if(KPPadDirectionIOS(button,&dx,&dy)||(button==KartPadMiiPadConfirm&&!focus)){
        if([focus isKindOfClass:KPMiiBodySlider.class]&&dx){[(KPMiiBodySlider*)focus step:dx*4];return;}
        NSArray *controls=KPPadEditorControlsIOS(editor);
        UIView *next=focus?KPPadNearestIOS(controls,focus,dx,dy):KPPadEditorDefaultIOS(editor,controls);
        const KPItem *from=KPPadItemIOS(focus),*to=KPPadItemIOS(next);
        if(dy>0&&from&&from->action==KPAction::Category&&!(to&&to->action==KPAction::Category))
            next=KPPadEditorDefaultIOS(editor,controls,YES)?:next;
        if(next){KPPadFocusIOS(next);KPPlay(KPSound::Hover);}
        return;
    }
    KPItem item{};
    switch(button){
    case KartPadMiiPadConfirm:
        if([focus isKindOfClass:UITextField.class]){KPPadKeyboardOpenIOS(editor,(UITextField*)focus);return;}
        if(![focus isKindOfClass:KPMiiWiiButton.class])return;
        {KPMiiWiiButton *control=(KPMiiWiiButton*)focus;if(!control.enabled)return;
        control.highlighted=YES;[control setNeedsDisplay];KPPadPressedIOS=control;if([control holds])[control down];}
        return;
    case KartPadMiiPadBack:
        if(editor.creating&&editor.pickingLookAlike){
            item.action=KPAction::Back;[editor performItem:item];KPPadEditorRefocusIOS(editor,KPAction::Start,0,1);return;
        }
        if(!editor.allowClose&&[editor dirty]){KPPadAskToSave(editor);return;}
        KPPadDropRing();[editor quit];return;
    case KartPadMiiPadStart:
        if(editor.creating)return;
        if([editor dirty])[editor save];else KPPlay(KPSound::Reject);
        return;
    case KartPadMiiPadPreviousTab:case KartPadMiiPadNextTab:{
        if(editor.creating)return;
        unsigned next=unsigned((editor.category+(button==KartPadMiiPadNextTab?1:9))%10);
        item.action=KPAction::Category;item.field=next;[editor performItem:item];
        if(editor.category==NSInteger(next)){KPPadFocused=nil;KPPadEditorRefocusIOS(editor,KPAction::Category,next,0);}
        return;}
    case KartPadMiiPadUndo:case KartPadMiiPadRedo:{
        if(editor.creating)return;
        const KPItem *focused=KPPadItemIOS(focus);KPAction action=focused?focused->action:KPAction::Undo;
        unsigned field=focused?focused->field:0;int value=focused?focused->value:0;
        item.action=button==KartPadMiiPadUndo?KPAction::Undo:KPAction::Redo;[editor performItem:item];
        if(focused){KPPadFocused=nil;KPPadEditorRefocusIOS(editor,action,field,value);}
        return;}
    default:return;
    }
}

void KartPadMiiPadPress(KartPadMiiPadButton button,BOOL down){
    if(KPMiiEditor *editor=KPPadEditorIOS())KPPadEditorPressIOS(editor,button,down);
    else if(KPMiiBrowser *browser=KPPadBrowserIOS())KPPadBrowserPressIOS(browser,button,down);
    KPPadPlaceRing();
}
void KartPadMiiPadTurn(float x,double seconds){
    KPMiiEditor *editor=KPPadEditorIOS();
    // Only the editor in front, with no card over it, and only while it shows the Mii.
    if(!x||!editor||KPPadOpenKeyboard||KPPadOpenQuestion||editor.preview.hidden)return;
    [editor.preview noteInteraction];
    // Half a turn a second at full tilt.
    editor.preview.yaw+=x*float(std::min(seconds,.1)*M_PI);
}
void KartPadMiiPadShowFocus(void){
    if(KPMiiBrowser *browser=KPPadBrowserIOS())KPPadBrowserPressIOS(browser,KartPadMiiPadConfirm,YES),KPPadPressedIOS=nil;
}
