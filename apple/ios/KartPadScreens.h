// KartPad's own screens over the game on iPhone and iPad (KartPadScreens.mm): HOME, Controllers,
// Settings, Ghosts and the card that waits for a disconnected player. They are the Mac's screens,
// drawn over the game and worked by touch or by any controller. The overlay host
// (KartPadRuntimeOverlayHost.mm) puts them over the game, holds the game while one is open, and
// answers what they ask of the rest of the app (KartPadScreensHost).
#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol KartPadScreensHost <NSObject>
// Which game is running, and whether Retro Rewind's files are in place for the other one.
- (BOOL)screensRetroRewindRunning;
- (BOOL)screensRetroRewindReady;
// Where sheets and pickers present from (the screens stay open underneath, the game held).
- (nullable UIViewController *)screensPresenter;
// The app's own screens for these, as the old three-dot menu opened them.
- (void)screensManageGameData;
- (void)screensManageRetroRewind;
- (void)screensManageSaves;
- (void)screensShowMultiplayer;
- (void)screensShowPrivateServer;
- (void)screensShowMotionSteering;
- (void)screensShowShakeTricks;
- (void)screensShowWiiRemoteInfo;
- (void)screensShowButtonMapping;
// These need the game itself on screen: the screens close first.
- (void)screensShowTouchControls;
- (void)screensReturnToLauncher;
- (void)screensReportProblem;
- (void)screensTestNativeCrash;
- (BOOL)screensDiagnosticsAvailable;
// Sound (the launcher's Sound sheet keeps the same settings): custom levels on or off, and the
// music and game levels, 0 to 1.
- (BOOL)screensSoundCustom;
- (void)screensSetSoundCustom:(BOOL)custom;
- (float)screensSoundLevel:(BOOL)music;
- (void)screensSetSoundLevel:(float)level music:(BOOL)music;
// The frame-rate counter's size: 0 small, 1 medium, 2 large.
- (NSInteger)screensFPSCounterSize;
- (void)screensSetFPSCounterSize:(NSInteger)size;
@end

// Once SDL's window is up: the screens go over the game in container (the view above the game's own),
// above everything else there.
void KartPadScreensAttach(UIWindow *gameWindow, UIView *container, id<KartPadScreensHost> host);
// Brings the screens back above the touch controls after the host re-adds those.
void KartPadScreensBringToFront(void);
// The three-dot button: HOME, or (with HOME open) back to the game.
void KartPadScreensToggleHome(void);
// A screen is open and the game should hold still under it (not online, where it can't).
BOOL KartPadScreensHoldGame(void);
// A screen is open: the game gets no input meanwhile.
BOOL KartPadScreensActive(void);
// Each game frame, from the game loop: the controllers (holding Menu opens HOME, a player's controller
// dropping out opens the reconnect card) and the toasts' view of them.
void KartPadScreensFrameTick(void);
// While the game is held: the screens' own ticks keep running (the pads, animations).
void KartPadScreensHoldTick(void);
// Back to the game: every screen closes (for what needs the game itself on screen).
void KartPadScreensCloseAll(void);
// Once the game runs again: the buttons each player still holds stay away from the game until
// they're let go, so the press that closed a screen doesn't also act in the game.
void KartPadScreensQuietHeldButtons(void);
// A player's Classic Controller buttons for the game, less those still held from a screen.
uint32_t KartPadScreensMaskHeld(NSUInteger player, uint32_t buttons);

NS_ASSUME_NONNULL_END
