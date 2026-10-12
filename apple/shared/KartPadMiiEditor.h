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

// Controller navigation for the Miis window and the Mii editor (KartPadMiiGamepad.inc.mm). The Mac
// shell (and on iPhone/iPad, KartPadScreens.mm) reads the pads and sends each press here; the game
// ignores the pads meanwhile.
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
// The right stick turns the editor's Mii: x runs from -1 (full left) to 1, over seconds since the last call.
void KartPadMiiPadTurn(float x, double seconds);
// The Miis window has just opened from a controller: show the focus ring on the selected Mii.
void KartPadMiiPadShowFocus(void);
#if TARGET_OS_OSX
// Settings takes the same presses while it is the key window. The Mac shell gives its window and
// tabs once, and what B and Start do (close it).
@class NSWindow, NSTabView;
void KartPadMiiPadSetSettings(NSWindow *window, NSTabView *tabs, void (^close)(void));
// Settings has just opened from a controller: show the focus ring.
void KartPadSettingsPadShowFocus(void);
#endif

// The Mac shell's own screens (HOME, Controllers, Settings) share the Mii screens' menu sounds and
// Mii portraits (on iPhone/iPad too). sound is a kartpad::mii::EditorSound; prepare renders them from
// the game data once.
void KartPadUIPrepareSounds(void);
void KartPadUIPlaySound(NSInteger sound);
BOOL KartPadUISoundsEnabled(void);
void KartPadUISetSoundsEnabled(BOOL enabled);
// The Mii's head portrait (an NSImage, a UIImage on iPhone/iPad), or nil while it renders; ready runs
// on the main thread once it is there (or failed).
id _Nullable KartPadMiiPortrait(NSData *mii, void (^ready)(void));
NS_ASSUME_NONNULL_END
