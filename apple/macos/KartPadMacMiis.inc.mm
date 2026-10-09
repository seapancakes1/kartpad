// The Miis window: one place on Mac to create, edit, import and remove Miis.
// The Player menu and Settings open it, and the Mii editor opens above it.
#include "kartpad/mii/portrait.h"

static NSWindow *KPGameWindow() {
  // The SDL game window has no window controller; the Mii editor has one.
  for (NSWindow *window in NSApp.windows) {
    if (![window isKindOfClass:NSPanel.class] && window.visible &&
        window.windowController == nil) {
      return window;
    }
  }
  return nil;
}

// Exclusive SDL windows sit above the menu-bar level. A normal panel would open
// behind the game even though the menu item or hotkey was received.
static NSInteger KPAuxiliaryWindowLevel() {
  NSWindow *game = KPGameWindow();
  return std::max<NSInteger>(NSFloatingWindowLevel, game != nil ? game.level + 1 : 0);
}

static void KPCenterOnGameScreen(NSWindow *window) {
  NSScreen *screen = KPGameWindow().screen ?: NSScreen.mainScreen;
  if (screen == nil) return;
  NSRect available = screen.visibleFrame;
  NSRect frame = window.frame;
  frame.origin = NSMakePoint(NSMidX(available) - frame.size.width / 2,
                             NSMidY(available) - frame.size.height / 2);
  [window setFrame:frame display:NO];
}

@interface KPMiisWindow : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
// The shell controller, which owns player names, licenses and quitting.
@property(nonatomic, weak) id owner;
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *records;
@property(nonatomic, copy) NSString *readError;
@property(nonatomic, copy) NSString *lastChange;
@property(nonatomic, strong) NSTextField *summary;
@property(nonatomic, strong) NSStackView *pendingBanner;
@property(nonatomic, strong) NSTextField *pendingText;
@property(nonatomic, strong) NSButton *createButton;
@property(nonatomic, strong) NSButton *editButton;
@property(nonatomic, strong) NSButton *removeButton;
@property(nonatomic, strong) NSButton *importButton;
- (void)show;
- (void)createMii:(id)sender;
- (void)editSlot:(NSUInteger)slot;
- (void)importMii:(id)sender;
@end

@implementation KPMiisWindow

- (NSButton *)button:(NSString *)title action:(SEL)action target:(id)target {
  NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  return button;
}

- (NSTextField *)wrappingLabel:(NSString *)text size:(CGFloat)size {
  NSTextField *label = [NSTextField wrappingLabelWithString:text];
  label.font = [NSFont systemFontOfSize:size];
  label.textColor = NSColor.secondaryLabelColor;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
  return label;
}

- (void)build {
  self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 540, 470)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  self.panel.title = @"Miis";
  self.panel.releasedWhenClosed = NO;
  self.panel.contentMinSize = NSMakeSize(470, 380);
  self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.panel.hidesOnDeactivate = YES;
  self.panel.delegate = self;
  NSView *content = self.panel.contentView;

  NSTextField *intro = [self wrappingLabel:
      @"Double-click a Mii to edit it. Saved changes apply the next time KartPad opens. "
       "To race as a different Mii, choose it in the game under License Settings → Change Mii."
                                      size:NSFont.smallSystemFontSize];

  NSImageView *pendingIcon = [NSImageView imageViewWithImage:
      [NSImage imageWithSystemSymbolName:@"clock.arrow.circlepath"
                accessibilityDescription:@"Changes waiting"]];
  pendingIcon.contentTintColor = NSColor.systemOrangeColor;
  self.pendingText = [self wrappingLabel:@"" size:NSFont.smallSystemFontSize];
  self.pendingText.textColor = NSColor.labelColor;
  NSButton *quit = [self button:@"Quit KartPad" action:@selector(quitKartPad:) target:self.owner];
  quit.controlSize = NSControlSizeSmall;
  self.pendingBanner = [NSStackView stackViewWithViews:@[pendingIcon, self.pendingText, quit]];
  self.pendingBanner.alignment = NSLayoutAttributeCenterY;
  self.pendingBanner.spacing = 8;
  self.pendingBanner.edgeInsets = NSEdgeInsetsMake(8, 10, 8, 10);
  self.pendingBanner.translatesAutoresizingMaskIntoConstraints = NO;
  NSBox *pendingBackground = [NSBox new];
  pendingBackground.boxType = NSBoxCustom;
  pendingBackground.borderWidth = 0;
  pendingBackground.cornerRadius = 7;
  pendingBackground.fillColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.14];
  pendingBackground.translatesAutoresizingMaskIntoConstraints = NO;
  [self.pendingBanner addSubview:pendingBackground positioned:NSWindowBelow relativeTo:nil];

  self.table = [NSTableView new];
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"Mii"];
  column.resizingMask = NSTableColumnAutoresizingMask;
  [self.table addTableColumn:column];
  self.table.headerView = nil;
  self.table.rowHeight = 46;
  self.table.style = NSTableViewStyleFullWidth;
  self.table.usesAlternatingRowBackgroundColors = NO;
  self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.target = self;
  self.table.doubleAction = @selector(editSelected:);
  self.table.accessibilityLabel = @"Miis";
  NSScrollView *scroll = [NSScrollView new];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.documentView = self.table;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSBezelBorder;

  self.summary = [self wrappingLabel:@"" size:NSFont.smallSystemFontSize];

  self.createButton = [self button:@"Create Mii…" action:@selector(createMii:) target:self];
  self.editButton = [self button:@"Edit…" action:@selector(editSelected:) target:self];
  self.editButton.keyEquivalent = @"\r";
  self.removeButton = [self button:@"Remove…" action:@selector(removeSelected:) target:self];
  self.importButton = [self button:@"Import .mii File…" action:@selector(importMii:) target:self];
  NSStackView *actions = [NSStackView stackViewWithViews:@[self.createButton, self.editButton, self.removeButton]];
  [actions addView:self.importButton inGravity:NSStackViewGravityTrailing];
  actions.spacing = 8;

  NSBox *divider = [NSBox new];
  divider.boxType = NSBoxSeparator;
  divider.translatesAutoresizingMaskIntoConstraints = NO;

  NSButton *done = [self button:@"Done" action:@selector(close:) target:self];
  done.keyEquivalent = @"\033";
  NSStackView *footer = [NSStackView stackViewWithViews:@[
    [self button:@"Player Name…" action:@selector(showPlayerNameEditor) target:self.owner],
    [self button:@"Licenses…" action:@selector(showLicenseManager) target:self.owner],
  ]];
  [footer addView:done inGravity:NSStackViewGravityTrailing];
  footer.spacing = 8;

  NSArray<NSView *> *rows = @[intro, self.pendingBanner, scroll, self.summary, actions, divider, footer];
  NSStackView *stack = [NSStackView stackViewWithViews:rows];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 12;
  stack.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [stack setCustomSpacing:6 afterView:scroll];
  [content addSubview:stack];
  NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
    [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:150],
    [pendingBackground.topAnchor constraintEqualToAnchor:self.pendingBanner.topAnchor],
    [pendingBackground.bottomAnchor constraintEqualToAnchor:self.pendingBanner.bottomAnchor],
    [pendingBackground.leadingAnchor constraintEqualToAnchor:self.pendingBanner.leadingAnchor],
    [pendingBackground.trailingAnchor constraintEqualToAnchor:self.pendingBanner.trailingAnchor],
  ]];
  for (NSView *row in rows) {
    [constraints addObject:[row.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40]];
  }
  [NSLayoutConstraint activateConstraints:constraints];
  [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                     forOrientation:NSLayoutConstraintOrientationVertical];
  self.panel.initialFirstResponder = self.table;
}

- (void)show {
  if (self.panel == nil) {
    [self build];
    KPCenterOnGameScreen(self.panel);
  }
  [self refresh];
  self.panel.level = KPAuxiliaryWindowLevel();
  [NSApp activateIgnoringOtherApps:YES];
  [self.panel makeKeyAndOrderFront:nil];
}

- (void)close:(id)sender {
  (void)sender;
  [self.panel performClose:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  // The editor closes after saving; show the pending state when focus returns.
  [self refresh];
}

- (NSDictionary<NSString *, id> *)selectedRecord {
  const NSInteger row = self.table.selectedRow;
  return row >= 0 && row < (NSInteger)self.records.count ? self.records[row] : nil;
}

- (void)refresh {
  NSNumber *selectedSlot = self.selectedRecord[@"slot"];
  NSError *error = nil;
  self.records = KartPadMiiRecords(&error);
  self.readError = error != nil
      ? (error.localizedDescription ?: @"The Mii database could not be read.") : nil;
  [self.table reloadData];
  NSUInteger row = [self.records indexOfObjectPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
    (void)index; (void)stop;
    return [record[@"slot"] isEqual:selectedSlot];
  }];
  if (row == NSNotFound && self.records.count > 0) row = 0;
  if (row != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];

  const BOOL pending = KartPadHasPendingMiiChanges();
  self.pendingBanner.hidden = !pending;
  if (!pending) self.lastChange = nil;
  self.pendingText.stringValue = [NSString stringWithFormat:@"%@ Quit and reopen KartPad to apply it. Until then, Miis can’t be changed again.",
      self.lastChange ?: @"A change is waiting for the next launch."];
  if (self.readError != nil) {
    self.summary.stringValue = self.readError;
  } else if (self.records.count == 0) {
    self.summary.stringValue = @"No Miis yet. Start the game once to create the Mii database.";
  } else {
    self.summary.stringValue = [NSString stringWithFormat:@"%lu Mii%@",
        (unsigned long)self.records.count, self.records.count == 1 ? @"" : @"s"];
  }
  [self updateButtons];
}

- (void)updateButtons {
  const BOOL editable = !KartPadHasPendingMiiChanges() && self.readError == nil;
  const BOOL selected = self.selectedRecord != nil;
  self.createButton.enabled = editable;
  self.importButton.enabled = editable;
  self.editButton.enabled = editable && selected;
  self.removeButton.enabled = editable && selected && self.records.count > 1;
  self.removeButton.toolTip = self.records.count <= 1 ? @"KartPad always keeps at least one Mii." : nil;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return (NSInteger)self.records.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  (void)column;
  NSTableCellView *cell = [tableView makeViewWithIdentifier:@"MiiRow" owner:self];
  if (cell == nil) {
    cell = [NSTableCellView new];
    cell.identifier = @"MiiRow";
    NSBox *swatch = [NSBox new];
    swatch.identifier = @"swatch";
    swatch.boxType = NSBoxCustom;
    swatch.cornerRadius = 10;
    swatch.borderWidth = 1;
    swatch.borderColor = NSColor.separatorColor;
    NSTextField *name = [NSTextField labelWithString:@""];
    name.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textField = name;
    NSTextField *detail = [NSTextField labelWithString:@""];
    detail.identifier = @"detail";
    detail.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    detail.textColor = NSColor.secondaryLabelColor;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSView *view in @[swatch, name, detail]) {
      view.translatesAutoresizingMaskIntoConstraints = NO;
      [cell addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
      [swatch.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
      [swatch.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      [swatch.widthAnchor constraintEqualToConstant:20],
      [swatch.heightAnchor constraintEqualToConstant:20],
      [name.leadingAnchor constraintEqualToAnchor:swatch.trailingAnchor constant:10],
      [name.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-6],
      [name.bottomAnchor constraintEqualToAnchor:cell.centerYAnchor constant:1],
      [detail.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
      [detail.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-6],
      [detail.topAnchor constraintEqualToAnchor:cell.centerYAnchor constant:2],
    ]];
  }
  NSDictionary<NSString *, id> *record = self.records[row];
  const NSUInteger colorIndex = [record[@"favoriteColor"] unsignedIntegerValue];
  const auto color = kartpad::mii::Shirt[colorIndex < kartpad::mii::Shirt.size() ? colorIndex : 0];
  NSBox *swatch = nil;
  NSTextField *detail = nil;
  for (NSView *view in cell.subviews) {
    if ([view.identifier isEqual:@"swatch"]) swatch = (NSBox *)view;
    if ([view.identifier isEqual:@"detail"]) detail = (NSTextField *)view;
  }
  swatch.fillColor = [NSColor colorWithSRGBRed:color[0] / 255.0
      green:color[1] / 255.0 blue:color[2] / 255.0 alpha:1];
  cell.textField.stringValue = record[@"name"];
  NSString *slot = [NSString stringWithFormat:@"Mii %lu",
      (unsigned long)([record[@"slot"] unsignedIntegerValue] + 1)];
  NSString *creator = record[@"creator"];
  detail.stringValue = [creator isEqual:@"Unknown"] ? slot
      : [NSString stringWithFormat:@"%@ · Created by %@", slot, creator];
  cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", record[@"name"], detail.stringValue];
  return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  (void)notification;
  [self updateButtons];
}

- (void)showProblem:(NSString *)title message:(NSString *)message {
  NSAlert *alert = [NSAlert new];
  alert.messageText = title;
  alert.informativeText = message ?: @"";
  [alert beginSheetModalForWindow:self.panel completionHandler:nil];
}

- (void)changeScheduled:(NSString *)description {
  self.lastChange = description;
  [self refresh];
}

- (void)createMii:(id)sender {
  (void)sender;
  if (!self.createButton.enabled) return;
  KartPadPresentMiiEditor(self.panel, NSNotFound);
}

- (void)editSlot:(NSUInteger)slot {
  if (KartPadHasPendingMiiChanges() || self.readError != nil) return;
  NSUInteger row = [self.records indexOfObjectPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
    (void)index; (void)stop;
    return [record[@"slot"] unsignedIntegerValue] == slot;
  }];
  if (row == NSNotFound) return;
  [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  KartPadPresentMiiEditor(self.panel, slot);
}

- (void)editSelected:(id)sender {
  // Double-clicking empty space below the rows must not open the selected Mii.
  if (sender == self.table && self.table.clickedRow < 0) return;
  NSDictionary<NSString *, id> *record = self.selectedRecord;
  if (record == nil || !self.editButton.enabled) return;
  KartPadPresentMiiEditor(self.panel, [record[@"slot"] unsignedIntegerValue]);
}

- (void)removeSelected:(id)sender {
  (void)sender;
  NSDictionary<NSString *, id> *record = self.selectedRecord;
  if (record == nil || !self.removeButton.enabled) return;
  NSAlert *confirm = [NSAlert new];
  confirm.messageText = [NSString stringWithFormat:@"Remove “%@”?", record[@"name"]];
  confirm.informativeText = @"The Mii is removed the next time KartPad opens. The current Mii database is backed up first.";
  [confirm addButtonWithTitle:@"Remove"].hasDestructiveAction = YES;
  [confirm addButtonWithTitle:@"Cancel"];
  [confirm beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn) return;
    NSError *error = nil;
    if (!KartPadStageMiiRemoval([record[@"slot"] unsignedIntegerValue], &error)) {
      [self showProblem:@"Mii Could Not Be Removed" message:error.localizedDescription];
      return;
    }
    [self changeScheduled:[NSString stringWithFormat:@"“%@” will be removed.", record[@"name"]]];
  }];
}

- (void)importMii:(id)sender {
  (void)sender;
  if (!self.importButton.enabled) return;
  NSOpenPanel *open = NSOpenPanel.openPanel;
  open.message = @"Choose a standard 74-byte .mii file.";
  open.prompt = @"Import";
  open.canChooseFiles = YES;
  open.canChooseDirectories = NO;
  open.allowsMultipleSelection = NO;
  UTType *miiType = [UTType typeWithFilenameExtension:@"mii" conformingToType:UTTypeData];
  open.allowedContentTypes = miiType != nil ? @[miiType] : @[UTTypeData];
  [open beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || open.URL == nil) return;
    // Let the open sheet finish closing before a problem sheet can attach.
    dispatch_async(dispatch_get_main_queue(), ^{
      NSError *error = nil;
      NSData *data = [NSData dataWithContentsOfURL:open.URL options:0 error:&error];
      NSString *name = nil;
      if (data == nil || !KartPadStageMiiImport(data, &name, &error)) {
        [self showProblem:@"Mii Could Not Be Imported"
                  message:error.localizedDescription ?: @"The selected file could not be imported."];
        return;
      }
      [self changeScheduled:[NSString stringWithFormat:@"“%@” will be added.",
          name.length > 0 ? name : open.URL.lastPathComponent.stringByDeletingPathExtension]];
    });
  }];
}

@end
