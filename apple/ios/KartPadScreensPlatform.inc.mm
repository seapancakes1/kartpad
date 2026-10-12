// What the Mac shell gives its screens (KartPadMacShell.mm and the files it includes before them),
// said for iPhone and iPad. Included by KartPadScreens.mm before the screens. Where the Mac has
// something iOS doesn't (a second window, the keyboard as a player, phones as controllers, a
// full-screen mode, quitting), the stand-in here says so and does nothing.

#include "runtime_config.h"
#include "audio_backend.h"
#include "kartpad/ghost/rkg.h"
#include <array>
#include <atomic>
#include <sstream>
#include <span>

// The two-game app: Retro Rewind is chosen at launch (KartPadRuntimeOverlayHost.mm), so HOME's game
// switch and Settings' Start KartPad with work as they do in the Mac's two-game build.
#define KARTPAD_RUNTIME_PRODUCT_DUAL 1

static NSString *const kKartPadBaseProfile = @"base";
static NSString *const kKartPadRetroProfile = @"retro_rewind";
// The game the launcher starts with next (KartPadRuntimeOverlayHost.mm's
// kKartPadRequestedRuntimeProfileKey): "ask", "base" or "retro_rewind".
static NSString *const kKartPadRuntimeProfileDefaultsKey = @"KartPadRequestedRuntimeProfile";
// The game the launcher starts with every time (Settings › Game › Start KartPad with), the same
// setting as the launcher's own (KartPadRuntimeOverlayHost.mm's kKartPadPreferredGameKey).
static NSString *const kKartPadPreferredGameKey = @"KartPadPreferredGame";
static NSString *const kKartPadFullScreenModeDefaultsKey = @"KartPadFullScreenMode";
static NSString *const kKartPadBackgroundPauseDefaultsKey = @"KartPadPauseInBackground";

// The game's window: SDL's UIWindow, which the overlay host hands over (KartPadScreensAttach).
static __weak UIWindow *KPScreensGameWindow;
static UIWindow *KPGameWindow() { return KPScreensGameWindow; }
// The Mac's hidden automated runs; iOS checks drive the Simulator instead.
static BOOL KPUIBackgroundAutomation() { return NO; }
// The Mac keeps a session log for problem reports; here the lines go to the system log.
static void AppendSessionLine(NSString *line) {
#if DEBUG
  NSLog(@"KartPad: %@", line);
#else
  (void)line;
#endif
}

// The player is using touch, not a controller: no button hints (KartPadScreensGlue.inc.mm).
static BOOL KPScreensTouching = YES;

#pragma mark The overlay host's side

// Everything the screens ask of the rest of the app, which KartPadRuntimeOverlayHost.mm answers.
static __weak id<KartPadScreensHost> KPScreensHostObject;
static id<KartPadScreensHost> KPHost() { return KPScreensHostObject; }

static NSString *RunningRuntimeProfile() { return [KPHost() screensRetroRewindRunning] ? kKartPadRetroProfile : kKartPadBaseProfile; }
static BOOL KPRetroRewindFilesReady() { return [KPHost() screensRetroRewindReady]; }
static BOOL KPGameDataReady() { return YES; }  // the game is running

// The Mac shell's controller object, for what the screens send it. iOS can't relaunch an app, so a
// restart is the player closing KartPad and opening it again (KPRestartWithCurtain).
@interface KPShellStandIn : NSObject
@property(nonatomic, strong) NSMutableSet<NSString *> *restartReasons;
@property(nonatomic, readonly) BOOL restartPending;
- (void)chooseRuntimeProfile:(NSString *)profile;
- (void)setRestartNeeded:(BOOL)needed for:(NSString *)reason;
- (void)toggleGameFullScreen:(id)sender;
- (void)quitKartPad:(id)sender;
- (void)chooseGameData:(id)sender;
- (void)chooseRetroRewindData:(id)sender;
@end
@implementation KPShellStandIn
- (instancetype)init {
  if ((self = [super init])) _restartReasons = [NSMutableSet set];
  return self;
}
- (BOOL)restartPending { return self.restartReasons.count > 0; }
- (void)chooseRuntimeProfile:(NSString *)profile {
  [NSUserDefaults.standardUserDefaults setObject:profile forKey:kKartPadRuntimeProfileDefaultsKey];
  [self setRestartNeeded:![profile isEqualToString:RunningRuntimeProfile()] for:@"game"];
}
- (void)setRestartNeeded:(BOOL)needed for:(NSString *)reason {
  if (needed) [self.restartReasons addObject:reason];
  else [self.restartReasons removeObject:reason];
}
- (void)toggleGameFullScreen:(id)sender { (void)sender; }
- (void)quitKartPad:(id)sender { (void)sender; }
- (void)chooseGameData:(id)sender { (void)sender; [KPHost() screensManageGameData]; }
- (void)chooseRetroRewindData:(id)sender { (void)sender; [KPHost() screensManageRetroRewind]; }
@end
static KPShellStandIn *Controller() {
  static KPShellStandIn *shell;
  if (shell == nil) shell = [KPShellStandIn new];
  return shell;
}

// The Mac runtime reloads Config.toml when a screen changes it; here the one setting the screens
// write there that the game reads live is the volume, which goes straight to the audio backend.
extern "C" void KartPadRequestSettingsReload() {
  const RuntimeUserConfig config = RuntimeConfigFile::LoadConfigFile();
  AudioBackend::Instance().SetMasterVolume(std::clamp(config.audioVolume.value_or(1.0f), 0.0f, 1.0f));
  AudioBackend::Instance().SetMuted(config.audioMuted.value_or(false));
}
static void KPReadLaunchDisplaySettings() {}
static bool KPFullscreenAcrossNotch() { return false; }
static bool KPBackgroundPauseEnabled() { return true; }
static bool KPLaunchVsync = false, KPLaunchNotch = false;

// No full-screen modes on iOS: the game always fills the screen.
typedef int AuroraDisplayMode;
enum { AURORA_DISPLAY_MODE_WINDOWED = 0, AURORA_DISPLAY_MODE_BORDERLESS = 1, AURORA_DISPLAY_MODE_EXCLUSIVE = 2 };
static AuroraDisplayMode aurora_get_display_mode() { return AURORA_DISPLAY_MODE_EXCLUSIVE; }

#pragma mark Controllers the Mac has and iOS doesn't

// The Mac's classic Controllers panel; iOS has none.
@interface KPControllersStandIn : NSObject
@property(nonatomic, readonly) UIWindow *panel;
@property(nonatomic, strong) NSMutableSet *applied;
@property(nonatomic) SDL_JoystickID selectedID;
@end
@implementation KPControllersStandIn
- (instancetype)init {
  if ((self = [super init])) _applied = [NSMutableSet set];
  return self;
}
- (UIWindow *)panel { return nil; }
@end
static KPControllersStandIn *KPControllers() {
  static KPControllersStandIn *controllers;
  if (controllers == nil) controllers = [KPControllersStandIn new];
  return controllers;
}
// SDL's pads, which the Mac reads; on iOS the roster reads GameController instead.
static const std::vector<SDL_JoystickID> &KPConnectedPads() {
  static const std::vector<SDL_JoystickID> none;
  return none;
}
static int KPPortForGamepad(SDL_Gamepad *pad) {
  (void)pad;
  return -1;
}
static NSString *const KPKeyboardPlayerKey = @"KartPadKeyboardPlayer";
// The pad reader's state (KartPadScreensPads.inc.mm): the last pad to press, and whether a screen
// is listening for presses itself (Controllers choosing by pressing).
static SDL_JoystickID KPPadLastPresser = 0;
static bool KPPadListening = false;

// Vibration strength per controller is the Mac's (the runtime drives the motors there).
static NSArray<NSString *> *KPVibrationNames() { return @[@"Off", @"Light", @"Medium", @"Strong"]; }
static NSArray<NSNumber *> *KPVibrationStrengths() { return @[@0, @0.35, @0.65, @1]; }
static NSInteger KPVibrationFor(NSString *profileKey) {
  (void)profileKey;
  return 2;
}
static NSInteger KPDefaultVibration(const RuntimeUserConfig &config) {
  (void)config;
  return 2;
}

// Phones as controllers are the Mac's; there are none here.
namespace kpp {
constexpr int MaxPhones = 1;
}
static std::array<std::atomic<bool>, kpp::MaxPhones> KPPhoneLinked{};
static std::atomic<bool> KPPhoneStarted{false};
struct KPPhoneEntry {
  int phone = 0, player = 0;
  bool linked = false;
};
@interface KPPhoneServer : NSObject
+ (instancetype)shared;
- (std::vector<KPPhoneEntry>)entries;
@end
@implementation KPPhoneServer
+ (instancetype)shared {
  static KPPhoneServer *server;
  if (server == nil) server = [KPPhoneServer new];
  return server;
}
- (std::vector<KPPhoneEntry>)entries { return {}; }
@end
static NSString *KPPhonePageURL() { return nil; }
static NSString *const KPPhoneOfflineKey = @"KartPadPhoneOffline";

#include "KartPadScreensRoster.inc.mm"

@class KPControllersScreen;
// The touch screen's card on Controllers (KartPadScreensGlue.inc.mm).
static void KPOpenTouchCard(KPControllersScreen *screen, int slot, KPPadDevice *device);
// Vibration (KartPadScreensGlue.inc.mm), for Settings.
static NSString *const KPVibrationKey = @"KartPadVibration";
static BOOL KPVibrationEnabled();
static void KPRumbleStopAll();
// Files in and out, for the Ghosts screen (KartPadScreensGlue.inc.mm).
static void KPScreensChooseFile(NSArray<UTType *> *types, void (^done)(NSURL *url));
static void KPScreensShareFile(NSURL *file);
