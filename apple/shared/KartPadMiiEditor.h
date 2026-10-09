#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// parent is an NSWindow on Mac and a UIViewController on iOS. NSNotFound creates a new Mii.
void KartPadPresentMiiEditor(id parent, NSUInteger slot);

// The Miis screen: every Mii as a portrait, with the selected Mii's details, actions and licenses.
// Mac: an NSViewController for the Miis window. iPhone/iPad: a UIViewController presented full screen.
@protocol KartPadMiiBrowser <NSObject>
// Done. Mac closes the Miis window here; iPhone/iPad dismiss the screen when this is nil.
@property(nonatomic, copy, nullable) void (^done)(void);
// Mac: Restart KartPad in the pending-change banner. Without it the banner only explains.
@property(nonatomic, copy, nullable) void (^restart)(void);
// Re-reads the Miis, licenses and pending state; redraws only when something changed.
- (void)reload;
// Mac: the Miis window is opening or closing (sounds).
- (void)willShow;
- (void)willClose;
- (void)createMii;
- (void)editSlot:(NSUInteger)slot;
- (void)importMii;
@end
id<KartPadMiiBrowser> KartPadMakeMiiBrowser(void);

#if TARGET_OS_OSX
// Controller navigation for the Miis window and the Mii editor (KartPadMiiGamepad.inc.mm). The Mac
// shell reads the pads and sends each press here; the game ignores the pads meanwhile.
typedef NS_ENUM(NSInteger, KartPadMiiPadButton) {
    KartPadMiiPadUp, KartPadMiiPadDown, KartPadMiiPadLeft, KartPadMiiPadRight,
    // A and B (the game's confirm and back buttons), X and Y, LB and RB, and Start.
    KartPadMiiPadConfirm, KartPadMiiPadBack, KartPadMiiPadUndo, KartPadMiiPadRedo,
    KartPadMiiPadPreviousTab, KartPadMiiPadNextTab, KartPadMiiPadStart,
    KartPadMiiPadButtonCount
};
// The Miis window or the Mii editor is on screen.
BOOL KartPadMiiWindowsVisible(void);
// down is NO when the button is released; only Confirm acts on release. Directions repeat while
// held, as further presses.
void KartPadMiiPadPress(KartPadMiiPadButton button, BOOL down);
// The Miis window has just opened from a controller: show the focus ring on the selected Mii.
void KartPadMiiPadShowFocus(void);
#endif
NS_ASSUME_NONNULL_END
