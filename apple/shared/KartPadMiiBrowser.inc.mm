// The Miis screen (KartPadMiiEditor.h): every Mii as a portrait tile beside the selected Mii's
// details, actions and licenses. It is included after KartPadMiiEditor.inc.mm and shares its
// Mii Channel palette, button faces, sounds and resource loader, so the screen and the editor match.
// Every change is staged for the next launch. As in the editor, a pending change blocks the next one
// until KartPad restarts, and a banner says so.
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
__asm__(".linker_option \"-framework\", \"UniformTypeIdentifiers\"");

static void KPRefresh(id view){
#if TARGET_OS_OSX
    [(NSView*)view setNeedsDisplay:YES];
#else
    [(UIView*)view setNeedsDisplay];
#endif
}
static void KPDrawImage(KPMiiImage *image,CGRect rect){
    CGSize size=image.size;if(size.width<=0||size.height<=0)return;
    CGFloat scale=std::min(rect.size.width/size.width,rect.size.height/size.height);
    CGRect fit=CGRectMake(CGRectGetMidX(rect)-size.width*scale/2,CGRectGetMidY(rect)-size.height*scale/2,size.width*scale,size.height*scale);
#if TARGET_OS_OSX
    [image drawInRect:fit fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
#else
    [image drawInRect:fit];
#endif
}
static unsigned KPFavoriteIndex(NSDictionary *record){unsigned i=[record[@"favoriteColor"] unsignedIntValue];return i<kartpad::mii::Shirt.size()?i:0;}
static unsigned KPFavoriteHex(NSDictionary *record){auto c=kartpad::mii::Shirt[KPFavoriteIndex(record)];return (c[0]<<16)|(c[1]<<8)|c[2];}
static NSString *KPFavoriteName(NSDictionary *record){return @[@"Red",@"Orange",@"Yellow",@"Light green",@"Green",@"Blue",@"Light blue",@"Pink",@"Purple",@"Brown",@"White",@"Black"][KPFavoriteIndex(record)];}
static NSString *KPSlotName(NSDictionary *record){return [NSString stringWithFormat:@"Mii %lu",(unsigned long)([record[@"slot"] unsignedIntegerValue]+1)];}
static NSString *KPLicenseTitle(NSDictionary *license){return [NSString stringWithFormat:@"%@ · License %lu",license[@"profileTitle"]?:@"Mario Kart Wii",(unsigned long)([license[@"slot"] unsignedIntegerValue]+1)];}
static NSString *KPLicensePending(NSDictionary *license){
    NSString *operation=license[@"pendingOperation"];
    return [operation isEqual:@"delete"]?@"Deletion pending":[operation isEqual:@"rename"]?@"Rename pending":[operation isEqual:@"mii"]?@"Mii change pending":[license[@"missingLinkedMii"] boolValue]?@"Its Mii is missing":nil;
}
static NSString *KPMiiFileName(NSString *name){
    NSString *clean=[[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"-"];
    return [(clean.length?clean:@"Mii") stringByAppendingPathExtension:@"mii"];
}
static UTType *KPMiiFileType(){return [UTType typeWithFilenameExtension:@"mii" conformingToType:UTTypeData]?:UTTypeData;}
static NSString *const KPMiiRestartAdvice=
#if TARGET_OS_OSX
    @"Quit and reopen KartPad to apply it.";
#else
    @"Fully close KartPad from the app switcher and reopen it to apply it.";
#endif

// Head portraits render on the editor's resource worker and are cached by the Mii's 74 bytes, so an
// unchanged Mii renders once per session. Without the imported RFL archive, tiles fall back to a
// silhouette in the Mii's favorite color.
static NSCache<NSData*,KPMiiImage*> *KPMiiPortraits(){static NSCache *cache;static dispatch_once_t once;dispatch_once(&once,^{cache=[NSCache new];});return cache;}
static NSMutableSet<NSData*> *KPMiiPortraitsRendering(){static NSMutableSet *set;static dispatch_once_t once;dispatch_once(&once,^{set=[NSMutableSet set];});return set;}
static NSString *KPMiiPortraitProblem;
static void KPMiiRequestPortrait(NSData *mii,void(^ready)(void)){
    if(mii.length!=kartpad::mii::kMiiBlockSize||[KPMiiPortraits() objectForKey:mii]||[KPMiiPortraitsRendering() containsObject:mii])return;
    [KPMiiPortraitsRendering() addObject:mii];
    dispatch_async(KPMiiWorkQueue(),^{
        KPMiiImage *image=nil;NSString *problem=nil;
        try{auto resources=KPMiiLoadResources();image=KPMiiImageFromPixels(kartpad::mii::Portrait::Render(*resources,kartpad::mii::Appearance::Decode(Bytes(mii))),YES);}
        catch(const std::exception &e){problem=@(e.what());}
        dispatch_async(dispatch_get_main_queue(),^{
            [KPMiiPortraitsRendering() removeObject:mii];
            if(image){[KPMiiPortraits() setObject:image forKey:mii];KPMiiPortraitProblem=nil;}else KPMiiPortraitProblem=problem;
            ready();
        });
    });
}
// The well stays light in dark mode, like the editor's artwork tiles, so dark hair stays visible.
static void KPDrawPortrait(CGContextRef c,CGRect well,NSDictionary *record){
    KPFill(c,well,KPLightPalette.well,well.size.width*.08);
    if(KPMiiImage *image=[KPMiiPortraits() objectForKey:record[@"mii"]]){KPDrawImage(image,CGRectInset(well,well.size.width*.06,well.size.height*.06));return;}
    // Placeholder head and shoulders in the favorite color while the portrait renders (or without resources).
    CGFloat s=well.size.width;unsigned hex=KPFavoriteHex(record);
    CGRect head=CGRectMake(CGRectGetMidX(well)-s*.2,well.origin.y+s*.18,s*.4,s*.44),body=CGRectMake(CGRectGetMidX(well)-s*.32,well.origin.y+s*.66,s*.64,s*.24);
    KPFill(c,head,hex,s*.2,.45);KPFill(c,body,hex,s*.1,.3);
    // An outline keeps white and light favorite colors visible on the light well.
    KPStroke(c,head,0x000000,1,s*.2,.12);KPStroke(c,body,0x000000,1,s*.1,.1);
}

// One entry of a menu, action sheet, context menu or VoiceOver action list. A nil title is a separator.
@interface KPMiiMenuEntry : NSObject
@property(nonatomic,copy) NSString *title;
@property(nonatomic) BOOL enabled,destructive;
@property(nonatomic,copy) void(^run)(void);
@end
@implementation KPMiiMenuEntry
- (void)perform:(id)sender{if(self.run)self.run();}
@end
static KPMiiMenuEntry *KPEntry(NSString *title,BOOL enabled,BOOL destructive,void(^run)(void)){KPMiiMenuEntry *entry=[KPMiiMenuEntry new];entry.title=title;entry.enabled=enabled;entry.destructive=destructive;entry.run=run;return entry;}
#if TARGET_OS_OSX
static NSMenu *KPMiiMenu(NSArray<KPMiiMenuEntry*> *entries){
    NSMenu *menu=[NSMenu new];menu.autoenablesItems=NO;
    for(KPMiiMenuEntry *entry in entries){
        if(!entry.title){[menu addItem:NSMenuItem.separatorItem];continue;}
        // Menu item targets are weak; the represented object keeps the entry alive.
        NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:entry.title action:@selector(perform:) keyEquivalent:@""];item.target=entry;item.representedObject=entry;item.enabled=entry.enabled;[menu addItem:item];
    }
    return menu;
}
#else
static UIMenu *KPMiiMenu(NSArray<KPMiiMenuEntry*> *entries){
    NSMutableArray *actions=[NSMutableArray array];
    for(KPMiiMenuEntry *entry in entries){
        if(!entry.title)continue;
        UIAction *action=[UIAction actionWithTitle:entry.title image:nil identifier:nil handler:^(UIAction *a){if(entry.run)entry.run();}];
        action.attributes=(entry.enabled?0:UIMenuElementAttributesDisabled)|(entry.destructive?UIMenuElementAttributesDestructive:0);[actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:actions];
}
#endif
static NSArray *KPMiiAccessibilityActions(NSArray<KPMiiMenuEntry*> *entries){
    NSMutableArray *actions=[NSMutableArray array];
    for(KPMiiMenuEntry *entry in entries){
        if(!entry.title||!entry.enabled)continue;
#if TARGET_OS_OSX
        [actions addObject:[[NSAccessibilityCustomAction alloc]initWithName:entry.title handler:^BOOL{if(entry.run)entry.run();return YES;}]];
#else
        [actions addObject:[[UIAccessibilityCustomAction alloc]initWithName:entry.title actionHandler:^BOOL(UIAccessibilityCustomAction *a){if(entry.run)entry.run();return YES;}]];
#endif
    }
    return actions;
}

// Static artwork (portraits, color chips) drawn by a block.
#if TARGET_OS_OSX
@interface KPMiiPaintView : NSView
#else
@interface KPMiiPaintView : UIView
#endif
@property(nonatomic,copy) void(^paint)(CGContextRef c,CGRect bounds);
@end
@implementation KPMiiPaintView
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (NSView*)hitTest:(NSPoint)point{return nil;}
- (void)drawRect:(NSRect)rect{KPUsePalette(self);if(self.paint)self.paint(NSGraphicsContext.currentContext.CGContext,self.bounds);}
#else
- (instancetype)initWithFrame:(CGRect)frame{if((self=[super initWithFrame:frame])){self.opaque=NO;self.backgroundColor=UIColor.clearColor;self.userInteractionEnabled=NO;}return self;}
- (void)drawRect:(CGRect)rect{KPUsePalette(self);if(self.paint)self.paint(UIGraphicsGetCurrentContext(),self.bounds);}
#endif
@end

// A Wii-style control whose face a block paints: tiles, license rows and buttons.
// Mac tracks the mouse itself rather than through NSButton's modal loop, which would stall the game
// sharing this thread (see KPMiiWiiButton). Tiles can be dragged out as .mii files.
#if TARGET_OS_OSX
@interface KPMiiBrowserButton : NSButton <NSDraggingSource,NSFilePromiseProviderDelegate>
#else
@interface KPMiiBrowserButton : UIButton <UIContextMenuInteractionDelegate,UIDragInteractionDelegate>
#endif
@property(nonatomic,copy) void(^paint)(CGContextRef c,CGRect bounds,BOOL pressed,BOOL hovered);
@property(nonatomic,copy) void(^tapped)(void);
@property(nonatomic,copy) void(^doubleTapped)(void);
@property(nonatomic,copy) NSArray<KPMiiMenuEntry*> *(^menuEntries)(void);
// Tiles: the Mii a drag writes out, and its file name.
@property(nonatomic,copy) NSData *dragData;
@property(nonatomic,copy) NSString *dragName;
@property(nonatomic) BOOL pointerOver,pressing;
@property(nonatomic) NSUInteger slot;
@end
@implementation KPMiiBrowserButton{
#if TARGET_OS_OSX
    NSPoint _down;BOOL _dragging;NSData *_promised;
#endif
}
- (void)setHover:(BOOL)hovered{if(hovered==self.pointerOver)return;self.pointerOver=hovered;if(hovered&&self.enabled)KPPlay(KPSound::Hover);KPRefresh(self);}
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return self.enabled;}
- (BOOL)becomeFirstResponder{self.needsDisplay=YES;return [super becomeFirstResponder];}
- (BOOL)resignFirstResponder{self.needsDisplay=YES;return [super resignFirstResponder];}
- (void)setEnabled:(BOOL)enabled{[super setEnabled:enabled];self.needsDisplay=YES;[self.window invalidateCursorRectsForView:self];}
- (void)drawRect:(NSRect)rect{
    CGContextRef c=NSGraphicsContext.currentContext.CGContext;KPUsePalette(self);
    if(self.paint)self.paint(c,self.bounds,self.pressing,self.pointerOver&&self.enabled);
    if(self.window.firstResponder==self&&self.window.isKeyWindow)KPStroke(c,self.bounds,KPP->accentBottom,2.5,11);
}
- (void)press:(BOOL)pressing{if(pressing==self.pressing)return;self.pressing=pressing;self.needsDisplay=YES;}
- (void)mouseDown:(NSEvent*)event{if(!self.enabled)return;_down=event.locationInWindow;_dragging=NO;[self press:YES];}
- (void)mouseDragged:(NSEvent*)event{
    if(!self.enabled||_dragging)return;
    if(self.dragData&&std::hypot(event.locationInWindow.x-_down.x,event.locationInWindow.y-_down.y)>5){_dragging=YES;[self press:NO];[self beginDrag:event];return;}
    BOOL inside=NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds);[self press:inside];
}
- (void)mouseUp:(NSEvent*)event{
    if(_dragging){_dragging=NO;return;}
    BOOL inside=self.pressing;[self press:NO];if(!inside)return;
    if(event.clickCount==2&&self.doubleTapped)self.doubleTapped();else if(self.tapped)self.tapped();
}
- (void)keyDown:(NSEvent*)event{
    NSString *key=event.charactersIgnoringModifiers;
    if([key isEqual:@" "]&&self.tapped){self.tapped();return;}
    if([key isEqual:@"\r"]&&(self.doubleTapped||self.tapped)){if(self.doubleTapped)self.doubleTapped();else self.tapped();return;}
    [self.nextResponder keyDown:event];
}
- (NSMenu*)menuForEvent:(NSEvent*)event{NSArray *entries=self.menuEntries?self.menuEntries():nil;return entries.count?KPMiiMenu(entries):nil;}
- (void)updateTrackingAreas{[super updateTrackingAreas];for(NSTrackingArea *area in self.trackingAreas.copy)[self removeTrackingArea:area];[self addTrackingArea:[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]];}
- (void)mouseEntered:(NSEvent*)event{[self setHover:YES];}
- (void)mouseExited:(NSEvent*)event{[self setHover:NO];}
- (void)resetCursorRects{if(self.enabled&&self.tapped)[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];}
- (void)beginDrag:(NSEvent*)event{
    _promised=self.dragData;
    NSFilePromiseProvider *provider=[[NSFilePromiseProvider alloc]initWithFileType:KPMiiFileType().identifier delegate:self];
    NSDraggingItem *item=[[NSDraggingItem alloc]initWithPasteboardWriter:provider];
    NSBitmapImageRep *snapshot=[self bitmapImageRepForCachingDisplayInRect:self.bounds];[self cacheDisplayInRect:self.bounds toBitmapImageRep:snapshot];
    NSImage *image=[[NSImage alloc]initWithSize:self.bounds.size];[image addRepresentation:snapshot];
    [item setDraggingFrame:self.bounds contents:image];
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context{return context==NSDraggingContextOutsideApplication?NSDragOperationCopy:NSDragOperationNone;}
- (NSString*)filePromiseProvider:(NSFilePromiseProvider*)provider fileNameForType:(NSString*)type{return KPMiiFileName(self.dragName);}
- (void)filePromiseProvider:(NSFilePromiseProvider*)provider writePromiseToURL:(NSURL*)url completionHandler:(void(^)(NSError*))completion{
    NSError *error=nil;BOOL written=[_promised writeToURL:url options:NSDataWritingAtomic error:&error];
    dispatch_async(dispatch_get_main_queue(),^{KPPlay(written?KPSound::Saved:KPSound::Reject);});completion(written?nil:error);
}
#else
- (instancetype)initWithFrame:(CGRect)frame{
    if((self=[super initWithFrame:frame])){
        self.backgroundColor=UIColor.clearColor;self.opaque=NO;self.accessibilityTraits=UIAccessibilityTraitButton;
        [self addTarget:self action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc]initWithTarget:self action:@selector(hover:)]];
    }
    return self;
}
- (BOOL)hasInteraction:(Class)kind{for(id interaction in self.interactions)if([interaction isKindOfClass:kind])return YES;return NO;}
- (void)setMenuEntries:(NSArray<KPMiiMenuEntry*>*(^)(void))menuEntries{_menuEntries=[menuEntries copy];if(menuEntries&&![self hasInteraction:UIContextMenuInteraction.class])[self addInteraction:[[UIContextMenuInteraction alloc]initWithDelegate:self]];}
- (void)setDragData:(NSData*)dragData{_dragData=[dragData copy];if(dragData&&![self hasInteraction:UIDragInteraction.class]){UIDragInteraction *drag=[[UIDragInteraction alloc]initWithDelegate:self];drag.enabled=YES;[self addInteraction:drag];}}
- (void)setHighlighted:(BOOL)highlighted{[super setHighlighted:highlighted];if(highlighted!=self.pressing){self.pressing=highlighted;[self setNeedsDisplay];}}
- (void)setEnabled:(BOOL)enabled{[super setEnabled:enabled];self.accessibilityTraits=UIAccessibilityTraitButton|(enabled?0:UIAccessibilityTraitNotEnabled);[self setNeedsDisplay];}
- (void)drawRect:(CGRect)rect{KPUsePalette(self);if(self.paint)self.paint(UIGraphicsGetCurrentContext(),self.bounds,self.pressing,self.pointerOver&&self.enabled);}
- (void)hover:(UIHoverGestureRecognizer*)gesture{[self setHover:gesture.state==UIGestureRecognizerStateBegan||gesture.state==UIGestureRecognizerStateChanged];}
- (void)fire{if(self.tapped)self.tapped();}
- (UIContextMenuConfiguration*)contextMenuInteraction:(UIContextMenuInteraction*)interaction configurationForMenuAtLocation:(CGPoint)location{
    NSArray *entries=self.menuEntries?self.menuEntries():nil;if(!entries.count)return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu*(NSArray *suggested){return KPMiiMenu(entries);}];
}
- (NSArray<UIDragItem*>*)dragInteraction:(UIDragInteraction*)interaction itemsForBeginningSession:(id<UIDragSession>)session{
    NSData *data=self.dragData;NSString *file=KPMiiFileName(self.dragName);if(!data)return @[];
    NSItemProvider *provider=[NSItemProvider new];provider.suggestedName=file.stringByDeletingPathExtension;
    [provider registerFileRepresentationForTypeIdentifier:KPMiiFileType().identifier fileOptions:0 visibility:NSItemProviderRepresentationVisibilityAll loadHandler:^NSProgress*(void(^completion)(NSURL*,BOOL,NSError*)){
        NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];NSError *error=nil;
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
        NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file]];
        completion([data writeToURL:url options:NSDataWritingAtomic error:&error]?url:nil,NO,error);return nil;
    }];
    UIDragItem *item=[[UIDragItem alloc]initWithItemProvider:provider];item.localObject=self;
    return @[item];
}
#endif
@end

#if TARGET_OS_OSX
@interface KPMiiBrowserDocument : NSView
@end
@implementation KPMiiBrowserDocument
- (BOOL)isFlipped{return YES;}
@end
#endif

@class KPMiiBrowser;
#if TARGET_OS_OSX
@interface KPMiiBrowserView : NSView
#else
@interface KPMiiBrowserView : UIView
#endif
@property(nonatomic,weak) KPMiiBrowser *browser;
@property(nonatomic) CGSize laidOut;
@property(nonatomic) CGRect gridCard,detailCard,banner,hintRect;
@property(nonatomic) CGFloat margin;
@property(nonatomic,copy) NSString *subtitle,*hint;
@property(nonatomic) BOOL dropTargeted;
@end

#if TARGET_OS_OSX
@interface KPMiiBrowser : NSViewController <KartPadMiiBrowser>
#else
@interface KPMiiBrowser : UIViewController <KartPadMiiBrowser,UIDocumentPickerDelegate,UIDropInteractionDelegate>
#endif
@property(nonatomic,copy) void(^done)(void);
@property(nonatomic,copy) void(^quit)(void);
@property(nonatomic,strong) KPMiiBrowserView *canvas;
@property(nonatomic,copy) NSArray<NSDictionary<NSString*,id>*> *records,*licenses;
@property(nonatomic,copy) NSString *readError,*licenseError,*lastChange;
@property(nonatomic) BOOL pending,loaded;
@property(nonatomic) NSUInteger selectedSlot,columns;
@property(nonatomic,strong) NSMutableArray<KPMiiBrowserButton*> *tiles;
@property(nonatomic,strong) id gridScroll,detailScroll;
@property(nonatomic,strong) KPMiiPaintView *detailPortrait;
@property(nonatomic) BOOL problemShown;
- (void)rebuild;
- (BOOL)handleKey:(NSString*)key;
- (BOOL)editable;
- (void)importFiles:(NSArray<NSData*>*)files names:(NSArray<NSString*>*)names;
@end

@implementation KPMiiBrowserView
- (void)resized{if(!CGSizeEqualToSize(self.bounds.size,self.laidOut)){self.laidOut=self.bounds.size;[self.browser rebuild];}}
#if TARGET_OS_OSX
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)layout{[super layout];[self resized];}
- (void)viewDidChangeEffectiveAppearance{[super viewDidChangeEffectiveAppearance];if(self.browser.loaded)[self.browser rebuild];}
- (void)keyDown:(NSEvent*)event{
    NSDictionary *arrows=@{@123:@"←",@124:@"→",@125:@"↓",@126:@"↑",@51:@"\b",@117:@"\b"};
    NSString *key=arrows[@(event.keyCode)]?:event.charactersIgnoringModifiers;
    if(!(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))&&[self.browser handleKey:key])return;
    [super keyDown:event];
}
- (NSArray<NSURL*>*)miiURLs:(id<NSDraggingInfo>)info{
    NSArray<NSURL*> *urls=[info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    return [urls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url,NSDictionary *b){return [url.pathExtension.lowercaseString isEqual:@"mii"];}]];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info{BOOL accept=[self miiURLs:info].count&&[self.browser editable];if(accept!=self.dropTargeted){self.dropTargeted=accept;self.needsDisplay=YES;}return accept?NSDragOperationCopy:NSDragOperationNone;}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info{return self.dropTargeted?NSDragOperationCopy:NSDragOperationNone;}
- (void)draggingExited:(id<NSDraggingInfo>)info{self.dropTargeted=NO;self.needsDisplay=YES;}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info{
    self.dropTargeted=NO;self.needsDisplay=YES;
    NSMutableArray *files=[NSMutableArray array],*names=[NSMutableArray array];
    for(NSURL *url in [self miiURLs:info]){
        NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSData *data=size.unsignedLongLongValue<=4096?[NSData dataWithContentsOfURL:url]:nil;
        [files addObject:data?:[NSData data]];[names addObject:url.lastPathComponent.stringByDeletingPathExtension];
    }
    if(!files.count)return NO;
    // Let the drag session finish before a sheet can attach.
    dispatch_async(dispatch_get_main_queue(),^{[self.browser importFiles:files names:names];});
    return YES;
}
#else
- (void)layoutSubviews{[super layoutSubviews];[self resized];}
- (void)traitCollectionDidChange:(UITraitCollection*)previous{[super traitCollectionDidChange:previous];if(self.browser.loaded&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])[self.browser rebuild];}
#endif
- (void)drawRect:(CGRect)rect{
#if TARGET_OS_OSX
    CGContextRef c=NSGraphicsContext.currentContext.CGContext;
#else
    CGContextRef c=UIGraphicsGetCurrentContext();
#endif
    KPUsePalette(self);CGFloat w=self.bounds.size.width,h=self.bounds.size.height,m=self.margin;
    KPFill(c,self.bounds,KPP->background);
    KPSetInk(c,KPP->stripe);CGContextSetLineWidth(c,1);for(CGFloat y=1.5;y<h;y+=4)KPLine(c,0,y,w,y);
    KPText(@"Miis",CGRectMake(m,12,120,30),22,KPP->text,YES,NSTextAlignmentLeft);
    if(self.subtitle.length)KPText(self.subtitle,CGRectMake(m+66,19,std::max(CGFloat(0),w-2*m-66-120),20),14,KPP->secondaryText,NO,NSTextAlignmentLeft);
    if(!CGRectIsEmpty(self.banner)){KPFill(c,self.banner,0xf0a030,10,.18);KPStroke(c,self.banner,0xd98a1c,1,10,.5);}
    for(CGRect card:{self.gridCard,self.detailCard}){
        if(CGRectIsEmpty(card))continue;
        KPFill(c,CGRectOffset(card,0,2),0x000000,18,KPP->shadow*.6);KPFill(c,card,KPP->panel,18);KPStroke(c,card,KPP->panelStroke,1,18);
    }
    if(self.dropTargeted)KPStroke(c,CGRectInset(self.gridCard,-2,-2),KPP->accentBottom,3,20);
    if(self.hint.length)KPCenteredText(self.hint,self.hintRect,12,KPP->secondaryText,NO,NSTextAlignmentCenter);
}
@end

@implementation KPMiiBrowser
#if TARGET_OS_OSX
- (void)loadView{
    self.canvas=[[KPMiiBrowserView alloc]initWithFrame:NSMakeRect(0,0,820,560)];self.canvas.browser=self;
    [self.canvas registerForDraggedTypes:@[NSPasteboardTypeFileURL]];self.view=self.canvas;
}
- (id)presenter{return self.view.window;}
#else
- (void)viewDidLoad{
    [super viewDidLoad];
    self.view.backgroundColor=[UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection *traits){return KPColor(traits.userInterfaceStyle==UIUserInterfaceStyleDark?KPDarkPalette.background:KPLightPalette.background);}];
    self.canvas=[KPMiiBrowserView new];self.canvas.browser=self;self.canvas.translatesAutoresizingMaskIntoConstraints=NO;self.canvas.backgroundColor=UIColor.clearColor;
    [self.view addSubview:self.canvas];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[self.canvas.topAnchor constraintEqualToAnchor:safe.topAnchor],[self.canvas.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],[self.canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],[self.canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]]];
    [self.canvas addInteraction:[[UIDropInteraction alloc]initWithDelegate:self]];
}
- (void)viewWillAppear:(BOOL)animated{
    [super viewWillAppear:animated];
    // Also runs when the editor closes over this screen, so a save shows up straight away.
    if(self.isBeingPresented){[self willShow];self.loaded=NO;}
    [self reload];
}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];if(self.isBeingDismissed)[self willClose];}
- (id)presenter{return self;}
- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];[self becomeFirstResponder];}
- (BOOL)canBecomeFirstResponder{return YES;}
- (NSArray<UIKeyCommand*>*)keyCommands{
    NSMutableArray *commands=[NSMutableArray array];
    for(NSString *key in @[UIKeyInputLeftArrow,UIKeyInputRightArrow,UIKeyInputUpArrow,UIKeyInputDownArrow,@"\r",UIKeyInputEscape]){UIKeyCommand *command=[UIKeyCommand keyCommandWithInput:key modifierFlags:0 action:@selector(keyCommand:)];command.wantsPriorityOverSystemBehavior=YES;[commands addObject:command];}
    return commands;
}
- (void)keyCommand:(UIKeyCommand*)command{
    NSDictionary *keys=@{UIKeyInputLeftArrow:@"←",UIKeyInputRightArrow:@"→",UIKeyInputUpArrow:@"↑",UIKeyInputDownArrow:@"↓",UIKeyInputEscape:@"\033"};
    [self handleKey:keys[command.input]?:command.input];
}
#endif
- (void)willShow{[[KPMiiSounds shared] prepare:KPMiiSoundArchivePath()];KPPlay(KPSound::Open);}
- (void)willClose{KPPlay(KPSound::Close);[[KPMiiSounds shared] suspendSoon];}
- (BOOL)editable{return !self.pending&&!self.readError;}
- (NSDictionary*)recordForSlot:(NSUInteger)slot{for(NSDictionary *record in self.records)if([record[@"slot"] unsignedIntegerValue]==slot)return record;return nil;}
- (NSDictionary*)selectedRecord{return [self recordForSlot:self.selectedSlot];}
- (NSArray<NSDictionary*>*)licensesForRecord:(NSDictionary*)record{
    NSMutableArray *linked=[NSMutableArray array];
    for(NSDictionary *license in self.licenses)if(![license[@"missingLinkedMii"] boolValue]&&[license[@"createId"] isEqual:record[@"createIdBytes"]])[linked addObject:license];
    return linked;
}
- (NSArray<NSDictionary*>*)unlinkedLicenses{
    NSMutableArray *unlinked=[NSMutableArray array];for(NSDictionary *license in self.licenses)if([license[@"missingLinkedMii"] boolValue])[unlinked addObject:license];return unlinked;
}

#pragma mark Loading

- (void)reload{
    NSError *error=nil;NSArray *records=KartPadMiiRecords(&error);
    NSString *readError=error?(error.localizedDescription?:@"The Mii database could not be read."):nil;
    error=nil;NSArray *licenses=readError?@[]:KartPadLicenseRecords(&error);
    NSString *licenseError=error?(error.localizedDescription?:@"The game saves could not be read."):nil;
    BOOL pending=KartPadHasPendingMiiChanges();if(!pending)self.lastChange=nil;
    BOOL changed=!self.loaded||![records isEqual:self.records]||![licenses isEqual:self.licenses]||pending!=self.pending||!((readError==self.readError)||[readError isEqual:self.readError])||!((licenseError==self.licenseError)||[licenseError isEqual:self.licenseError]);
    self.records=records;self.licenses=licenses;self.readError=readError;self.licenseError=licenseError;self.pending=pending;
    if(![self selectedRecord])self.selectedSlot=records.count?[records.firstObject[@"slot"] unsignedIntegerValue]:NSNotFound;
    __weak KPMiiBrowser *weak=self;
    for(NSDictionary *record in records){NSData *mii=record[@"mii"];KPMiiRequestPortrait(mii,^{[weak portraitReady:mii];});}
    if(changed){self.loaded=YES;[self rebuild];}
}
- (void)portraitReady:(NSData*)mii{
    for(KPMiiBrowserButton *tile in self.tiles)if([tile.dragData isEqual:mii])KPRefresh(tile);
    if([[self selectedRecord][@"mii"] isEqual:mii]&&self.detailPortrait)KPRefresh(self.detailPortrait);
    // A failed render (no imported resources) is explained in the details once it is known.
    if(KPMiiPortraitProblem&&!self.problemShown&&[self selectedRecord])[self buildDetail];
}
- (void)changeScheduled:(NSString*)description{KPPlay(KPSound::Saved);self.lastChange=description;[self reload];}

#pragma mark Layout

- (id)scrollIn:(CGRect)frame{
#if TARGET_OS_OSX
    NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:frame];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;scroll.borderType=NSNoBorder;scroll.automaticallyAdjustsContentInsets=NO;
    scroll.documentView=[[KPMiiBrowserDocument alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];
#else
    UIScrollView *scroll=[[UIScrollView alloc]initWithFrame:frame];scroll.showsVerticalScrollIndicator=YES;scroll.alwaysBounceVertical=NO;
#endif
    [self.canvas addSubview:scroll];return scroll;
}
- (id)documentOf:(id)scroll{
#if TARGET_OS_OSX
    return [(NSScrollView*)scroll documentView];
#else
    return scroll;
#endif
}
// Usable document width, leaving room for a legacy (always-visible) Mac scroller.
- (CGFloat)widthOf:(id)scroll{
#if TARGET_OS_OSX
    return [scroll frame].size.width-(NSScroller.preferredScrollerStyle==NSScrollerStyleLegacy?[NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy]:0);
#else
    return [scroll frame].size.width;
#endif
}
- (void)finish:(id)scroll height:(CGFloat)height{
    CGSize size=CGSizeMake([self widthOf:scroll],std::max(height,[scroll frame].size.height));
#if TARGET_OS_OSX
    [[(NSScrollView*)scroll documentView] setFrameSize:size];
#else
    [(UIScrollView*)scroll setContentSize:size];
#endif
}
- (KPMiiBrowserButton*)button:(NSString*)title frame:(CGRect)frame style:(KPStyle)style enabled:(BOOL)enabled action:(void(^)(KPMiiBrowserButton *button))action{
    KPMiiBrowserButton *button=[[KPMiiBrowserButton alloc]initWithFrame:frame];__weak KPMiiBrowserButton *weak=button;
    button.paint=^(CGContextRef c,CGRect b,BOOL pressed,BOOL hovered){
        KPMiiBrowserButton *strong=weak;BOOL on=strong.enabled;CGRect r=CGRectInset(b,1,1),face=CGRectMake(r.origin.x,r.origin.y,r.size.width,r.size.height-3);
        KPButtonFace(c,r,style,NO,on,pressed,hovered);
        CGContextSaveGState(c);if(!on)CGContextSetAlpha(c,.42);if(pressed)CGContextTranslateCTM(c,0,2);
        KPCenteredText(title,CGRectInset(face,8,0),face.size.height<40?14:15,style==KPStyle::Primary?0xffffff:KPP->text,YES);
        CGContextRestoreGState(c);
    };
    button.tapped=^{if(action)action(weak);};button.enabled=enabled;
#if TARGET_OS_OSX
    button.bordered=NO;button.title=@"";[button setAccessibilityLabel:[title stringByReplacingOccurrencesOfString:@"…" withString:@""]];
#else
    button.accessibilityLabel=[title stringByReplacingOccurrencesOfString:@"…" withString:@""];
#endif
    return button;
}
- (id)label:(NSString*)text frame:(CGRect)frame size:(CGFloat)size bold:(BOOL)bold secondary:(BOOL)secondary{
    id label=KPLabelView(text,frame,size,bold,secondary);
#if TARGET_OS_OSX
    [(NSTextField*)label setSelectable:NO];
#endif
    return label;
}
// Sizes a label's height to its wrapped text (Dynamic Type included on iPhone/iPad) and returns it.
- (CGFloat)fit:(id)label{
    CGRect frame=[label frame];
#if TARGET_OS_OSX
    frame.size.height=std::ceil([[(NSTextField*)label cell] cellSizeForBounds:NSMakeRect(0,0,frame.size.width,10000)].height);
#else
    frame.size.height=std::ceil([(UILabel*)label sizeThatFits:CGSizeMake(frame.size.width,CGFLOAT_MAX)].height);
#endif
    [label setFrame:frame];return frame.size.height;
}
// Adds a wrapped label at y and returns the y below it.
- (CGFloat)note:(NSString*)text in:(id)document x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width size:(CGFloat)size bold:(BOOL)bold secondary:(BOOL)secondary{
    id label=[self label:text frame:CGRectMake(x,y,width,size*1.5) size:size bold:bold secondary:secondary];[document addSubview:label];return y+[self fit:label];
}
- (void)rebuild{
    if(!self.canvas||!self.loaded)return;
    KPUsePalette(self.canvas);
#if TARGET_OS_OSX
    NSResponder *focus=self.view.window.firstResponder;BOOL refocus=[focus isKindOfClass:NSView.class]&&[(NSView*)focus isDescendantOf:self.canvas];
#endif
    for(id view in self.canvas.subviews.copy)[view removeFromSuperview];
    self.tiles=[NSMutableArray array];self.detailPortrait=nil;
    KPMiiBrowserView *canvas=self.canvas;CGFloat w=canvas.bounds.size.width,h=canvas.bounds.size.height;
    BOOL compact=w<640,tight=h<480;CGFloat m=compact?12:20;canvas.margin=m;
    canvas.subtitle=self.readError?nil:[NSString stringWithFormat:@"%lu of %lu",(unsigned long)self.records.count,(unsigned long)kartpad::mii::kMaximumMiiSlots];
    __weak KPMiiBrowser *weak=self;

    // Header: the title (drawn) and the shared Sound switch.
    KPMiiBrowserButton *sound=[[KPMiiBrowserButton alloc]initWithFrame:CGRectMake(w-m-96,8,96,40)];__weak KPMiiBrowserButton *weakSound=sound;
    sound.paint=^(CGContextRef c,CGRect b,BOOL pressed,BOOL hovered){
        BOOL on=[KPMiiSounds shared].enabled;CGFloat side=26;CGRect box=CGRectMake(2,(b.size.height-side-3)/2+1,side,side+3);
        KPButtonFace(c,box,KPStyle::Plain,on,YES,pressed,hovered);
        if(on)KPControlIcon(c,CGRectMake(box.origin.x+3,box.origin.y+3+(pressed?2:0),side-6,side-6),KPGlyph::Check,0,KPP->accentBottom);
        KPCenteredText(@"Sound",CGRectMake(side+10,0,b.size.width-side-10,b.size.height),15,KPP->text,YES,NSTextAlignmentLeft);
    };
    sound.tapped=^{KPMiiSounds *sounds=[KPMiiSounds shared];sounds.enabled=!sounds.enabled;if(sounds.enabled)KPPlay(KPSound::Confirm);KPRefresh(weakSound);
#if TARGET_OS_OSX
        [weakSound setAccessibilityValue:@(sounds.enabled)];
#else
        weakSound.accessibilityValue=sounds.enabled?@"On":@"Off";
#endif
    };
#if TARGET_OS_OSX
    sound.bordered=NO;sound.title=@"";[sound setAccessibilityLabel:@"Sound effects"];[sound setAccessibilityRole:NSAccessibilityCheckBoxRole];[sound setAccessibilityValue:@([KPMiiSounds shared].enabled)];
#else
    sound.accessibilityLabel=@"Sound effects";sound.accessibilityValue=[KPMiiSounds shared].enabled?@"On":@"Off";
#endif
    [canvas addSubview:sound];
    CGFloat top=tight?52:58;

    // Banner: a change waiting for the next launch, or why the Miis can't be read.
    canvas.banner=CGRectZero;
    if(self.pending||self.readError){
        BOOL quit=self.pending&&self.quit;CGFloat bh=compact?66:48;
        canvas.banner=CGRectMake(m,top,w-2*m,bh);
        NSString *text=self.readError?[NSString stringWithFormat:@"The Miis can’t be shown. %@",self.readError]:[NSString stringWithFormat:@"%@ %@ Until then, Miis and licenses can’t be changed again.",self.lastChange?:@"A change is waiting for the next launch.",KPMiiRestartAdvice];
        CGFloat textW=w-2*m-28-(quit?140:0);
        id label=[self label:text frame:CGRectMake(m+14,top+(bh-(compact?52:34))/2,textW,compact?52:34) size:13 bold:NO secondary:NO];
#if TARGET_OS_OSX
        [label setAccessibilityRole:NSAccessibilityStaticTextRole];
#endif
        [canvas addSubview:label];
        if(quit)[canvas addSubview:[self button:@"Quit KartPad" frame:CGRectMake(w-m-14-128,top+(bh-38)/2,128,38) style:KPStyle::Plain enabled:YES action:^(KPMiiBrowserButton *b){KPPlay(KPSound::Press);if(weak.quit)weak.quit();}]];
        top+=bh+10;
    }

    // Footer: Import on the left, Done on the right, a hint between them when there is room.
    CGFloat footerH=tight?40:44,footerY=h-m-footerH;
    CGFloat importW=compact?140:170;
    KPMiiBrowserButton *import=[self button:@"Import .mii…" frame:CGRectMake(m,footerY,importW,footerH) style:KPStyle::Plain enabled:[self editable]&&self.records.count<kartpad::mii::kMaximumMiiSlots action:^(KPMiiBrowserButton *b){[weak importMii];}];
    [canvas addSubview:import];
    [canvas addSubview:[self button:@"Done" frame:CGRectMake(w-m-120,footerY,120,footerH) style:KPStyle::Primary enabled:YES action:^(KPMiiBrowserButton *b){[weak finish];}]];
    canvas.hintRect=CGRectMake(m+importW+12,footerY,w-2*m-importW-120-24,footerH);
#if TARGET_OS_OSX
    canvas.hint=canvas.hintRect.size.width>=300?@"Double-click a Mii to edit it. Drop .mii files here to import them.":nil;
#else
    canvas.hint=canvas.hintRect.size.width>=300?@"Changes apply after fully closing and reopening KartPad.":nil;
#endif
    CGFloat bottom=footerY-12;

    // Cards: the grid beside the details, or the grid above the details on narrow screens.
    if(compact){
        CGFloat available=bottom-top,gridH=std::max(CGFloat(150),available*.42);
        canvas.gridCard=CGRectMake(m,top,w-2*m,gridH);canvas.detailCard=CGRectMake(m,top+gridH+10,w-2*m,std::max(CGFloat(120),available-gridH-10));
    }else{
        CGFloat detailW=std::clamp(w*.4,CGFloat(300),CGFloat(390));
        canvas.gridCard=CGRectMake(m,top,w-3*m-detailW,bottom-top);canvas.detailCard=CGRectMake(w-m-detailW,top,detailW,bottom-top);
    }
    [self buildGrid];
    [self buildDetail];
    KPRefresh(canvas);
#if TARGET_OS_OSX
    if(refocus||!self.view.window.firstResponder||self.view.window.firstResponder==self.view.window)[self.view.window makeFirstResponder:self.canvas];
#endif
}

- (void)buildGrid{
    KPMiiBrowserView *canvas=self.canvas;
    CGRect frame=CGRectInset(canvas.gridCard,10,10);id scroll=[self scrollIn:frame];self.gridScroll=scroll;id document=[self documentOf:scroll];
    CGFloat gw=[self widthOf:scroll],gap=10,base=gw<380?96:112;
    NSUInteger columns=std::max<NSUInteger>(1,NSUInteger((gw+gap)/(base+gap)));self.columns=columns;
    CGFloat tw=std::floor((gw-gap*(columns-1))/columns),th=tw+24;
    if(self.readError){[self finish:scroll height:[self note:@"Start the game once to create the Mii database, then open this screen again." in:document x:6 y:6 width:gw-12 size:14 bold:NO secondary:YES]+6];return;}
    NSUInteger count=self.records.count+1;
    for(NSUInteger i=0;i<count;i++){
        CGRect tileFrame=CGRectMake((i%columns)*(tw+gap),2+(i/columns)*(th+gap),tw,th);
        KPMiiBrowserButton *tile=i<self.records.count?[self tileFor:self.records[i] frame:tileFrame]:[self newTile:tileFrame];
        [document addSubview:tile];
    }
    CGFloat y=2+((count+columns-1)/columns)*(th+gap)+4;
    // Licenses whose Mii is gone can't be reached from a Mii, so they are listed under the grid.
    NSArray *unlinked=[self unlinkedLicenses];
    if(unlinked.count){
        y=[self note:@"Licenses without a Mii" in:document x:4 y:y width:gw-8 size:14 bold:YES secondary:YES]+4;
        y=[self note:@"The game shows these as Player. Choose a Mii to repair one; its progress and friend code are kept." in:document x:4 y:y width:gw-8 size:12 bold:NO secondary:YES]+10;
        for(NSDictionary *license in unlinked){[document addSubview:[self licenseRow:license frame:CGRectMake(0,y,gw,56)]];y+=64;}
    }
    [self finish:scroll height:y];
}
- (KPMiiBrowserButton*)tileFor:(NSDictionary*)record frame:(CGRect)frame{
    __weak KPMiiBrowser *weak=self;NSUInteger slot=[record[@"slot"] unsignedIntegerValue];
    KPMiiBrowserButton *tile=[[KPMiiBrowserButton alloc]initWithFrame:frame];tile.slot=slot;
    tile.paint=^(CGContextRef c,CGRect b,BOOL pressed,BOOL hovered){
        BOOL selected=weak.selectedSlot==slot;CGRect r=CGRectInset(b,1,1);
        KPButtonFace(c,r,KPStyle::Tile,selected,YES,pressed,hovered);
        CGContextSaveGState(c);if(pressed)CGContextTranslateCTM(c,0,2);
        CGFloat side=r.size.width-16;CGRect well=CGRectMake(r.origin.x+8,r.origin.y+8,side,side);
        KPDrawPortrait(c,well,record);
        CGRect dot=CGRectMake(well.origin.x+6,well.origin.y+6,12,12);KPFill(c,dot,KPFavoriteHex(record),6);KPStroke(c,dot,0xffffff,1.5,6,.9);
        KPCenteredText(record[@"name"],CGRectMake(r.origin.x+5,CGRectGetMaxY(well)+1,r.size.width-10,r.size.height-side-14),13,KPP->text,YES);
        CGContextRestoreGState(c);
    };
    tile.tapped=^{[weak selectSlot:slot];};
    tile.doubleTapped=^{[weak editSlot:slot];};
    tile.menuEntries=^NSArray*{return [weak actionsFor:record];};
    tile.dragData=record[@"mii"];tile.dragName=record[@"name"];
    NSString *label=[NSString stringWithFormat:@"%@, %@",record[@"name"],KPSlotName(record)];
#if TARGET_OS_OSX
    tile.bordered=NO;tile.title=@"";[tile setAccessibilityLabel:label];[tile setAccessibilityHelp:@"Double-click to edit."];
#else
    tile.accessibilityLabel=label;
#endif
    tile.accessibilityCustomActions=KPMiiAccessibilityActions([self actionsFor:record]);
    [self.tiles addObject:tile];[self markTile:tile];
    return tile;
}
- (void)markTile:(KPMiiBrowserButton*)tile{
    BOOL selected=tile.slot==self.selectedSlot;
#if TARGET_OS_OSX
    [tile setAccessibilityValue:selected?@"Selected":nil];
#else
    tile.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);
#endif
}
- (KPMiiBrowserButton*)newTile:(CGRect)frame{
    __weak KPMiiBrowser *weak=self;BOOL enabled=[self editable]&&self.records.count<kartpad::mii::kMaximumMiiSlots;
    KPMiiBrowserButton *tile=[[KPMiiBrowserButton alloc]initWithFrame:frame];tile.slot=NSNotFound;__weak KPMiiBrowserButton *weakTile=tile;
    tile.paint=^(CGContextRef c,CGRect b,BOOL pressed,BOOL hovered){
        BOOL on=weakTile.enabled;CGRect r=CGRectInset(b,1,1);KPButtonFace(c,r,KPStyle::Tile,NO,on,pressed,hovered);
        CGContextSaveGState(c);if(!on)CGContextSetAlpha(c,.42);if(pressed)CGContextTranslateCTM(c,0,2);
        CGFloat side=r.size.width-16,arm=side*.3,bar=std::max(CGFloat(5),side*.07);CGPoint mid=CGPointMake(CGRectGetMidX(r),r.origin.y+8+side/2);
        KPFill(c,CGRectMake(mid.x-arm,mid.y-bar/2,arm*2,bar),KPP->icon,bar/2);KPFill(c,CGRectMake(mid.x-bar/2,mid.y-arm,bar,arm*2),KPP->icon,bar/2);
        KPCenteredText(@"New Mii",CGRectMake(r.origin.x+5,r.origin.y+8+side+1,r.size.width-10,r.size.height-side-14),13,KPP->text,YES);
        CGContextRestoreGState(c);
    };
    tile.tapped=^{[weak createMii];};tile.enabled=enabled;
#if TARGET_OS_OSX
    tile.bordered=NO;tile.title=@"";[tile setAccessibilityLabel:@"Create Mii"];
#else
    tile.accessibilityLabel=@"Create Mii";
#endif
    return tile;
}

- (void)buildDetail{
    KPMiiBrowserView *canvas=self.canvas;__weak KPMiiBrowser *weak=self;
    [self.detailScroll removeFromSuperview];
    CGRect frame=CGRectInset(canvas.detailCard,14,14);id scroll=[self scrollIn:frame];self.detailScroll=scroll;id document=[self documentOf:scroll];
    CGFloat dw=[self widthOf:scroll],y=0;BOOL editable=[self editable];
    NSDictionary *record=[self selectedRecord];
    self.problemShown=NO;
    if(!record){[self finish:scroll height:[self note:self.readError?@"No Miis to show.":@"Choose a Mii." in:document x:2 y:2 width:dw-4 size:15 bold:NO secondary:YES]];return;}
    NSUInteger slot=[record[@"slot"] unsignedIntegerValue];NSArray *linked=[self licensesForRecord:record];

    // Portrait beside the name, slot, creator and favorite color.
    CGFloat side=std::min(CGFloat(150),std::floor(dw*.42));
    KPMiiPaintView *portrait=[[KPMiiPaintView alloc]initWithFrame:CGRectMake(0,0,side,side)];
    portrait.paint=^(CGContextRef c,CGRect b){KPDrawPortrait(c,b,record);};
#if TARGET_OS_OSX
    [portrait setAccessibilityElement:YES];[portrait setAccessibilityRole:NSAccessibilityImageRole];[portrait setAccessibilityLabel:[NSString stringWithFormat:@"Portrait of %@",record[@"name"]]];
#else
    portrait.isAccessibilityElement=YES;portrait.accessibilityTraits=UIAccessibilityTraitImage;portrait.accessibilityLabel=[NSString stringWithFormat:@"Portrait of %@",record[@"name"]];
#endif
    [document addSubview:portrait];self.detailPortrait=portrait;
    CGFloat ix=side+14,iw=dw-ix;
    CGFloat iy=[self note:record[@"name"] in:document x:ix y:2 width:iw size:22 bold:YES secondary:NO]+4;
    NSString *creator=[record[@"creator"] isEqual:@"Unknown"]?KPSlotName(record):[NSString stringWithFormat:@"%@ · Created by %@",KPSlotName(record),record[@"creator"]];
    iy=[self note:creator in:document x:ix y:iy width:iw size:13 bold:NO secondary:YES]+10;
    KPMiiPaintView *chip=[[KPMiiPaintView alloc]initWithFrame:CGRectMake(ix,iy,18,18)];unsigned hex=KPFavoriteHex(record);
    chip.paint=^(CGContextRef c,CGRect b){KPFill(c,b,hex,5);KPStroke(c,b,0x000000,1,5,.18);};[document addSubview:chip];
    iy=std::max(iy+18,[self note:[NSString stringWithFormat:@"Favorite color: %@",KPFavoriteName(record)] in:document x:ix+26 y:iy width:iw-26 size:13 bold:NO secondary:NO])+8;
    NSString *uses=linked.count==0?@"Not used by a license":linked.count==1?@"Used by 1 license":[NSString stringWithFormat:@"Used by %lu licenses",(unsigned long)linked.count];
    iy=[self note:uses in:document x:ix y:iy width:iw size:13 bold:NO secondary:YES]+6;
    if(KPMiiPortraitProblem&&![KPMiiPortraits() objectForKey:record[@"mii"]]){iy=[self note:[NSString stringWithFormat:@"Portraits unavailable: %@",KPMiiPortraitProblem] in:document x:ix y:iy width:iw size:11 bold:NO secondary:YES]+6;self.problemShown=YES;}
    y=std::max(side,iy)+16;

    // Actions: Edit first, then the rest two by two.
    [document addSubview:[self button:@"Edit Mii" frame:CGRectMake(0,y,dw,48) style:KPStyle::Primary enabled:editable action:^(KPMiiBrowserButton *b){[weak editSlot:slot];}]];y+=58;
    CGFloat half=(dw-8)/2;
    [document addSubview:[self button:@"Rename…" frame:CGRectMake(0,y,half,44) style:KPStyle::Plain enabled:editable action:^(KPMiiBrowserButton *b){[weak rename:record];}]];
    [document addSubview:[self button:@"Duplicate" frame:CGRectMake(half+8,y,half,44) style:KPStyle::Plain enabled:editable&&self.records.count<kartpad::mii::kMaximumMiiSlots action:^(KPMiiBrowserButton *b){[weak duplicate:record];}]];y+=52;
    [document addSubview:[self button:@"Export…" frame:CGRectMake(0,y,half,44) style:KPStyle::Plain enabled:YES action:^(KPMiiBrowserButton *b){[weak exportRecord:record from:b];}]];
    [document addSubview:[self button:@"Remove…" frame:CGRectMake(half+8,y,half,44) style:KPStyle::Plain enabled:editable action:^(KPMiiBrowserButton *b){[weak remove:record];}]];y+=60;

    // Licenses that race as this Mii, and linking another license to it.
    y=[self note:@"Licenses" in:document x:2 y:y width:dw-4 size:15 bold:YES secondary:NO]+8;
    if(self.licenseError)y=[self note:self.licenseError in:document x:2 y:y width:dw-4 size:12 bold:NO secondary:YES]+8;
    else{
        for(NSDictionary *license in linked){[document addSubview:[self licenseRow:license frame:CGRectMake(0,y,dw,56)]];y+=64;}
        if(!linked.count)y=[self note:@"No license races as this Mii yet." in:document x:2 y:y width:dw-4 size:13 bold:NO secondary:YES]+10;
        NSArray *others=[self licensesToLink:record];
        [document addSubview:[self button:@"Use for a License…" frame:CGRectMake(0,y,dw,44) style:KPStyle::Plain enabled:editable&&others.count>0 action:^(KPMiiBrowserButton *b){[weak chooseLicenseFor:record from:b];}]];y+=52;
    }
    y=[self note:@"To start a new license, choose New on the game’s license screen and pick this Mii." in:document x:2 y:y width:dw-4 size:12 bold:NO secondary:YES]+8;
    [self finish:scroll height:y];
}
- (KPMiiBrowserButton*)licenseRow:(NSDictionary*)license frame:(CGRect)frame{
    __weak KPMiiBrowser *weak=self;NSString *pending=KPLicensePending(license),*title=KPLicenseTitle(license);
    BOOL missing=[license[@"missingLinkedMii"] boolValue];
    KPMiiBrowserButton *row=[[KPMiiBrowserButton alloc]initWithFrame:frame];__weak KPMiiBrowserButton *weakRow=row;
    row.paint=^(CGContextRef c,CGRect b,BOOL pressed,BOOL hovered){
        BOOL on=weakRow.enabled;CGRect r=CGRectInset(b,1,1);KPButtonFace(c,r,KPStyle::Plain,NO,on,pressed,hovered);
        CGContextSaveGState(c);if(!on)CGContextSetAlpha(c,.42);if(pressed)CGContextTranslateCTM(c,0,2);
        CGFloat textW=r.size.width-60;
        KPText(license[@"name"]?:@"Unnamed",CGRectMake(14,8,textW,22),15,KPP->text,YES,NSTextAlignmentLeft);
        KPText(pending?[NSString stringWithFormat:@"%@ · %@",title,pending]:title,CGRectMake(14,29,textW,18),12,pending?0xc77a14:KPP->secondaryText,NO,NSTextAlignmentLeft);
        KPControlIcon(c,CGRectMake(r.size.width-40,(r.size.height-3)/2-13,26,26),KPGlyph::More,0,KPP->icon);
        CGContextRestoreGState(c);
    };
    NSArray *(^entries)(void)=^NSArray*{
        BOOL can=[weak editable]&&!weak.licenseError&&[license[@"pendingOperation"] length]==0;
        NSMutableArray *list=[NSMutableArray array];
        if(missing)[list addObject:KPEntry(@"Choose Mii…",can,NO,^{[weak chooseMiiForLicense:license from:weakRow];})];
        else [list addObject:KPEntry(@"Rename License…",can,NO,^{[weak renameLicense:license];})];
        [list addObject:KPEntry(@"Delete License…",can,YES,^{[weak deleteLicense:license];})];
        return list;
    };
    row.tapped=^{KPPlay(KPSound::Press);[weak showMenu:entries() title:title from:weakRow];};
    row.menuEntries=entries;row.enabled=YES;
    NSString *label=[NSString stringWithFormat:@"%@, %@%@",license[@"name"]?:@"Unnamed",title,pending?[@", " stringByAppendingString:pending]:@""];
#if TARGET_OS_OSX
    row.bordered=NO;row.title=@"";[row setAccessibilityLabel:label];
#else
    row.accessibilityLabel=label;
#endif
    row.accessibilityCustomActions=KPMiiAccessibilityActions(entries());
    return row;
}
- (NSArray*)licensesToLink:(NSDictionary*)record{
    NSMutableArray *others=[NSMutableArray array];
    for(NSDictionary *license in self.licenses)if(![license[@"createId"] isEqual:record[@"createIdBytes"]]&&[license[@"pendingOperation"] length]==0)[others addObject:license];
    return others;
}

#pragma mark Selection and keys

- (void)selectSlot:(NSUInteger)slot{
    KPPlay(slot==self.selectedSlot?KPSound::Same:KPSound::Tab);
    if(slot==self.selectedSlot)return;
    self.selectedSlot=slot;
    for(KPMiiBrowserButton *tile in self.tiles){[self markTile:tile];KPRefresh(tile);}
    [self buildDetail];
    for(KPMiiBrowserButton *tile in self.tiles)if(tile.slot==slot){
#if TARGET_OS_OSX
        [tile scrollRectToVisible:tile.bounds];
#else
        [(UIScrollView*)self.gridScroll scrollRectToVisible:CGRectInset(tile.frame,0,-6) animated:YES];
#endif
    }
}
- (BOOL)handleKey:(NSString*)key{
    NSUInteger index=NSNotFound;for(NSUInteger i=0;i<self.records.count;i++)if([self.records[i][@"slot"] unsignedIntegerValue]==self.selectedSlot)index=i;
    if([key isEqual:@"\033"]){[self finish];return YES;}
    if(index==NSNotFound)return NO;
    NSInteger step=[key isEqual:@"←"]?-1:[key isEqual:@"→"]?1:[key isEqual:@"↑"]?-NSInteger(self.columns):[key isEqual:@"↓"]?NSInteger(self.columns):0;
    if(step){
        NSInteger next=std::clamp(NSInteger(index)+step,NSInteger(0),NSInteger(self.records.count)-1);
        NSUInteger slot=[self.records[next][@"slot"] unsignedIntegerValue];[self selectSlot:slot];
#if TARGET_OS_OSX
        for(KPMiiBrowserButton *tile in self.tiles)if(tile.slot==slot&&[self.view.window.firstResponder isKindOfClass:KPMiiBrowserButton.class])[self.view.window makeFirstResponder:tile];
#endif
        return YES;
    }
    if([key isEqual:@"\r"]){[self editSlot:self.selectedSlot];return YES;}
    if([key isEqual:@"\b"]){[self remove:self.records[index]];return YES;}
    return NO;
}
- (void)finish{
#if TARGET_OS_OSX
    if(self.done)self.done();
#else
    if(self.done)self.done();else [self dismissViewControllerAnimated:YES completion:nil];
#endif
}
- (NSArray<KPMiiMenuEntry*>*)actionsFor:(NSDictionary*)record{
    __weak KPMiiBrowser *weak=self;NSUInteger slot=[record[@"slot"] unsignedIntegerValue];BOOL editable=[self editable];
    return @[KPEntry(@"Edit Mii…",editable,NO,^{[weak editSlot:slot];}),KPEntry(@"Rename…",editable,NO,^{[weak rename:record];}),
             KPEntry(@"Duplicate",editable&&weak.records.count<kartpad::mii::kMaximumMiiSlots,NO,^{[weak duplicate:record];}),KPEntry(@"Export…",YES,NO,^{[weak exportRecord:record from:nil];}),
             KPEntry(nil,NO,NO,nil),KPEntry(@"Remove…",editable,YES,^{[weak remove:record];})];
}

#pragma mark Dialogs

- (void)showMenu:(NSArray<KPMiiMenuEntry*>*)entries title:(NSString*)title from:(KPMiiBrowserButton*)button{
#if TARGET_OS_OSX
    if(button)[KPMiiMenu(entries) popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,button.bounds.size.height+2) inView:button];
    else [KPMiiMenu(entries) popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMidX(self.canvas.bounds),NSMidY(self.canvas.bounds)) inView:self.canvas];
#else
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for(KPMiiMenuEntry *entry in entries){if(!entry.title)continue;UIAlertAction *action=[UIAlertAction actionWithTitle:entry.title style:entry.destructive?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(entry.run)entry.run();}];action.enabled=entry.enabled;[sheet addAction:action];}
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a){KPPlay(KPSound::Close);}]];
    sheet.popoverPresentationController.sourceView=button?:self.canvas;sheet.popoverPresentationController.sourceRect=button?button.bounds:CGRectMake(CGRectGetMidX(self.canvas.bounds),CGRectGetMidY(self.canvas.bounds),1,1);
    [self presentViewController:sheet animated:YES completion:nil];
#endif
}
- (void)tell:(NSString*)title message:(NSString*)message{
    KPPlay(KPSound::Reject);
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=message?:@"";[alert beginSheetModalForWindow:self.view.window completionHandler:nil];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)confirm:(NSString*)title message:(NSString*)message action:(NSString*)action destructive:(BOOL)destructive then:(void(^)(void))then{
    KPPlay(KPSound::Dialog);
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=message?:@"";[alert addButtonWithTitle:action].hasDestructiveAction=destructive;[alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn)then();else KPPlay(KPSound::Close);}];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a){KPPlay(KPSound::Close);}]];
    [alert addAction:[UIAlertAction actionWithTitle:action style:destructive?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction *a){then();}]];
    [self presentViewController:alert animated:YES completion:nil];
#endif
}
- (void)ask:(NSString*)title message:(NSString*)message text:(NSString*)text action:(NSString*)action then:(void(^)(NSString *text))then{
    KPPlay(KPSound::Dialog);
#if TARGET_OS_OSX
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=message?:@"";
    NSTextField *field=[NSTextField textFieldWithString:text?:@""];field.frame=NSMakeRect(0,0,300,26);field.placeholderString=@"Name";alert.accessoryView=field;
    [alert addButtonWithTitle:action];[alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn)then(field.stringValue);else KPPlay(KPSound::Close);}];
    [alert.window makeFirstResponder:field];
#else
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=text;field.placeholder=@"Name";field.clearButtonMode=UITextFieldViewModeWhileEditing;field.autocapitalizationType=UITextAutocapitalizationTypeWords;field.autocorrectionType=UITextAutocorrectionTypeNo;field.returnKeyType=UIReturnKeyDone;}];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a){KPPlay(KPSound::Close);}]];
    [alert addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){then(weakAlert.textFields.firstObject.text?:@"");}]];
    [self presentViewController:alert animated:YES completion:nil];
#endif
}
- (BOOL)blocked{
    if([self editable])return NO;
    [self tell:self.readError?@"Miis Unavailable":@"Restart KartPad First" message:self.readError?:[NSString stringWithFormat:@"A change is already waiting for the next launch. %@",KPMiiRestartAdvice]];
    return YES;
}

#pragma mark Mii actions

- (void)createMii{if([self blocked])return;KartPadPresentMiiEditor([self presenter],NSNotFound);}
- (void)editSlot:(NSUInteger)slot{
    if(![self recordForSlot:slot]||[self blocked])return;
    if(slot!=self.selectedSlot)[self selectSlot:slot];
    KartPadPresentMiiEditor([self presenter],slot);
}
- (void)rename:(NSDictionary*)record{
    if([self blocked])return;NSUInteger slot=[record[@"slot"] unsignedIntegerValue];__weak KPMiiBrowser *weak=self;
    [self ask:[NSString stringWithFormat:@"Rename “%@”",record[@"name"]] message:@"Up to 10 characters. Every license that races as this Mii gets the new name too, keeping its friend code and progress." text:record[@"name"] action:@"Rename" then:^(NSString *name){
        NSError *error=nil;NSUInteger updated=0;
        if(!KartPadStagePlayerName(slot,name,&updated,&error)){[weak tell:@"Mii Could Not Be Renamed" message:error.localizedDescription];return;}
        NSString *trimmed=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *licenses=updated==0?@"":updated==1?@" Its license will use the new name.":[NSString stringWithFormat:@" Its %lu licenses will use the new name.",(unsigned long)updated];
        [weak changeScheduled:[NSString stringWithFormat:@"“%@” will be renamed “%@”.%@",record[@"name"],trimmed,licenses]];
    }];
}
- (void)duplicate:(NSDictionary*)record{
    if([self blocked])return;NSError *error=nil;NSData *copy=KartPadDuplicateMii([record[@"slot"] unsignedIntegerValue],&error);
    if(!copy){[self tell:@"Mii Could Not Be Duplicated" message:error.localizedDescription];return;}
    KPMiiPresentEditor([self presenter],NSNotFound,copy,YES);
}
- (void)remove:(NSDictionary*)record{
    if([self blocked])return;NSUInteger linked=[self licensesForRecord:record].count;__weak KPMiiBrowser *weak=self;
    if(self.records.count<=1){[self tell:@"This Mii Can’t Be Removed" message:@"KartPad always keeps at least one Mii."];return;}
    if(linked){[self tell:[NSString stringWithFormat:@"“%@” Is In Use",record[@"name"]] message:[NSString stringWithFormat:@"%@ races as this Mii. Delete %@, or move %@ to another Mii with Use for a License…, then remove this Mii.",linked==1?@"A license":[NSString stringWithFormat:@"%lu licenses",(unsigned long)linked],linked==1?@"that license":@"those licenses",linked==1?@"it":@"them"]];return;}
    [self confirm:[NSString stringWithFormat:@"Remove “%@”?",record[@"name"]] message:@"The Mii is removed the next time KartPad opens. The current Mii database is backed up first." action:@"Remove" destructive:YES then:^{
        NSError *error=nil;
        if(!KartPadStageMiiRemoval([record[@"slot"] unsignedIntegerValue],&error)){[weak tell:@"Mii Could Not Be Removed" message:error.localizedDescription];return;}
        [weak changeScheduled:[NSString stringWithFormat:@"“%@” will be removed.",record[@"name"]]];
    }];
}
- (void)exportRecord:(NSDictionary*)record from:(KPMiiBrowserButton*)button{
    NSError *error=nil;NSData *data=KartPadExportMii(record[@"mii"],&error);
    if(!data){[self tell:@"Mii Could Not Be Exported" message:error.localizedDescription];return;}
    KPPlay(KPSound::Press);
#if TARGET_OS_OSX
    NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=KPMiiFileName(record[@"name"]);panel.allowedContentTypes=@[KPMiiFileType()];panel.message=@"Saves a standard 74-byte .mii file.";
    __weak KPMiiBrowser *weak=self;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
        if(response!=NSModalResponseOK||!panel.URL){KPPlay(KPSound::Close);return;}
        NSError *writeError=nil;
        if([data writeToURL:panel.URL options:NSDataWritingAtomic error:&writeError])KPPlay(KPSound::Saved);
        else dispatch_async(dispatch_get_main_queue(),^{[weak tell:@"Mii Could Not Be Exported" message:writeError.localizedDescription];});
    }];
#else
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
    NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:KPMiiFileName(record[@"name"])]];
    if(![data writeToURL:url options:NSDataWritingAtomic error:&error]){[self tell:@"Mii Could Not Be Exported" message:error.localizedDescription];return;}
    UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView=button?:self.canvas;share.popoverPresentationController.sourceRect=button?button.bounds:CGRectMake(CGRectGetMidX(self.canvas.bounds),CGRectGetMidY(self.canvas.bounds),1,1);
    share.completionWithItemsHandler=^(UIActivityType type,BOOL completed,NSArray *items,NSError *e){if(completed)KPPlay(KPSound::Saved);[NSFileManager.defaultManager removeItemAtPath:directory error:nil];};
    [self presentViewController:share animated:YES completion:nil];
#endif
}
- (void)importMii{
    if([self blocked])return;
    KPPlay(KPSound::Press);
#if TARGET_OS_OSX
    NSOpenPanel *open=NSOpenPanel.openPanel;open.message=@"Choose a standard 74-byte .mii file.";open.prompt=@"Import";open.canChooseFiles=YES;open.canChooseDirectories=NO;open.allowsMultipleSelection=NO;open.allowedContentTypes=@[KPMiiFileType()];
    __weak KPMiiBrowser *weak=self;
    [open beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response){
        if(response!=NSModalResponseOK||!open.URL){KPPlay(KPSound::Close);return;}
        NSURL *url=open.URL;NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSData *data=size.unsignedLongLongValue<=4096?[NSData dataWithContentsOfURL:url]:nil;
        // Let the open sheet finish closing before a problem sheet can attach.
        dispatch_async(dispatch_get_main_queue(),^{[weak importFiles:@[data?:[NSData data]] names:@[url.lastPathComponent.stringByDeletingPathExtension]];});
    }];
#else
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[KPMiiFileType(),UTTypeData] asCopy:YES];
    picker.delegate=self;picker.allowsMultipleSelection=NO;[self presentViewController:picker animated:YES completion:nil];
#endif
}
// One import per launch: the first file is staged, and any others wait for a restart.
- (void)importFiles:(NSArray<NSData*>*)files names:(NSArray<NSString*>*)names{
    if(!files.count||[self blocked])return;
    NSError *error=nil;NSString *name=nil;
    if(!KartPadStageMiiImport(files.firstObject,&name,&error)){[self tell:@"Mii Could Not Be Imported" message:error.localizedDescription?:@"The selected file is not a standard 74-byte .mii file."];return;}
    NSString *added=name.length?name:names.firstObject;
    [self changeScheduled:[NSString stringWithFormat:@"“%@” will be added.",added]];
    if(files.count>1)[self tell:@"One Mii at a Time" message:[NSString stringWithFormat:@"Only “%@” was imported. %@ Then import the others.",added,KPMiiRestartAdvice]];
}
#if !TARGET_OS_OSX
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls{
    NSURL *url=urls.firstObject;if(!url)return;
    NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    NSData *data=size.unsignedLongLongValue<=4096?[NSData dataWithContentsOfURL:url]:nil;[NSFileManager.defaultManager removeItemAtURL:url error:nil];
    [self importFiles:@[data?:[NSData data]] names:@[url.lastPathComponent.stringByDeletingPathExtension]];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller{KPPlay(KPSound::Close);}
- (BOOL)dropInteraction:(UIDropInteraction*)interaction canHandleSession:(id<UIDropSession>)session{return session.localDragSession==nil&&[session hasItemsConformingToTypeIdentifiers:@[KPMiiFileType().identifier]];}
- (UIDropProposal*)dropInteraction:(UIDropInteraction*)interaction sessionDidUpdate:(id<UIDropSession>)session{
    BOOL accept=[self editable];if(accept!=self.canvas.dropTargeted){self.canvas.dropTargeted=accept;[self.canvas setNeedsDisplay];}
    return [[UIDropProposal alloc]initWithDropOperation:accept?UIDropOperationCopy:UIDropOperationForbidden];
}
- (void)dropInteraction:(UIDropInteraction*)interaction sessionDidExit:(id<UIDropSession>)session{self.canvas.dropTargeted=NO;[self.canvas setNeedsDisplay];}
- (void)dropInteraction:(UIDropInteraction*)interaction sessionDidEnd:(id<UIDropSession>)session{self.canvas.dropTargeted=NO;[self.canvas setNeedsDisplay];}
- (void)dropInteraction:(UIDropInteraction*)interaction performDrop:(id<UIDropSession>)session{
    NSString *type=KPMiiFileType().identifier;NSMutableArray *files=[NSMutableArray array],*names=[NSMutableArray array];dispatch_group_t group=dispatch_group_create();
    NSMutableArray *slots=[NSMutableArray array];
    for(UIDragItem *item in session.items){
        if(![item.itemProvider hasItemConformingToTypeIdentifier:type])continue;
        NSUInteger index=slots.count;[slots addObject:[NSNull null]];[names addObject:item.itemProvider.suggestedName?:@"Mii"];dispatch_group_enter(group);
        [item.itemProvider loadDataRepresentationForTypeIdentifier:type completionHandler:^(NSData *data,NSError *error){
            dispatch_async(dispatch_get_main_queue(),^{if(data.length<=4096&&data)slots[index]=data;dispatch_group_leave(group);});
        }];
    }
    __weak KPMiiBrowser *weak=self;
    dispatch_group_notify(group,dispatch_get_main_queue(),^{for(id data in slots)[files addObject:[data isKindOfClass:NSData.class]?data:[NSData data]];[weak importFiles:files names:names];});
}
#endif

#pragma mark License actions

- (void)renameLicense:(NSDictionary*)license{
    if([self blocked])return;__weak KPMiiBrowser *weak=self;
    [self ask:@"Rename License" message:[NSString stringWithFormat:@"%@. Up to 10 characters. The license keeps its friend code, online account, records and progress.",KPLicenseTitle(license)] text:license[@"name"] action:@"Rename" then:^(NSString *name){
        NSError *error=nil;
        if(!KartPadStageLicenseRename(license[@"profileIdentifier"],[license[@"slot"] unsignedIntegerValue],license[@"createId"],name,&error)){[weak tell:@"License Could Not Be Renamed" message:error.localizedDescription];return;}
        [weak changeScheduled:[NSString stringWithFormat:@"%@ will be renamed “%@”.",KPLicenseTitle(license),[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]];
    }];
}
- (void)deleteLicense:(NSDictionary*)license{
    if([self blocked])return;__weak KPMiiBrowser *weak=self;
    [self confirm:[NSString stringWithFormat:@"Delete “%@” from %@?",license[@"name"]?:@"Unnamed",KPLicenseTitle(license)] message:@"This permanently removes the license’s friend code, online account data, records and progress. Its Mii stays. The save is backed up first." action:@"Delete License" destructive:YES then:^{
        NSError *error=nil;
        if(!KartPadStageLicenseDeletion(license[@"profileIdentifier"],[license[@"slot"] unsignedIntegerValue],license[@"createId"],&error)){[weak tell:@"License Could Not Be Deleted" message:error.localizedDescription];return;}
        [weak changeScheduled:[NSString stringWithFormat:@"%@ (“%@”) will be deleted.",KPLicenseTitle(license),license[@"name"]?:@"Unnamed"]];
    }];
}
- (void)link:(NSDictionary*)license to:(NSDictionary*)record{
    __weak KPMiiBrowser *weak=self;
    [self confirm:[NSString stringWithFormat:@"Race as “%@”?",record[@"name"]] message:[NSString stringWithFormat:@"%@ (“%@”) will use this Mii’s name and appearance. Its progress and friend code are kept, and the save is backed up first.",KPLicenseTitle(license),license[@"name"]?:@"Unnamed"] action:@"Use This Mii" destructive:NO then:^{
        NSError *error=nil;
        if(!KartPadStageLicenseMii(license[@"profileIdentifier"],[license[@"slot"] unsignedIntegerValue],license[@"createId"],[record[@"slot"] unsignedIntegerValue],record[@"createIdBytes"],&error)){[weak tell:@"Mii Could Not Be Linked" message:error.localizedDescription];return;}
        [weak changeScheduled:[NSString stringWithFormat:@"%@ will race as “%@”.",KPLicenseTitle(license),record[@"name"]]];
    }];
}
- (void)chooseLicenseFor:(NSDictionary*)record from:(KPMiiBrowserButton*)button{
    if([self blocked])return;__weak KPMiiBrowser *weak=self;NSMutableArray *entries=[NSMutableArray array];
    for(NSDictionary *license in [self licensesToLink:record])[entries addObject:KPEntry([NSString stringWithFormat:@"%@ · %@",license[@"name"]?:@"Unnamed",KPLicenseTitle(license)],YES,NO,^{[weak link:license to:record];})];
    KPPlay(KPSound::Press);[self showMenu:entries title:[NSString stringWithFormat:@"Choose a license to race as “%@”",record[@"name"]] from:button];
}
- (void)chooseMiiForLicense:(NSDictionary*)license from:(KPMiiBrowserButton*)anchor{
    if([self blocked])return;__weak KPMiiBrowser *weak=self;NSMutableArray *entries=[NSMutableArray array];
    for(NSDictionary *record in self.records)[entries addObject:KPEntry(record[@"name"],YES,NO,^{[weak link:license to:record];})];
    KPPlay(KPSound::Press);[self showMenu:entries title:[NSString stringWithFormat:@"Choose a Mii for %@",KPLicenseTitle(license)] from:anchor];
}
@end

id<KartPadMiiBrowser> KartPadMakeMiiBrowser(void){return [KPMiiBrowser new];}
