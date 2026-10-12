// KartPad's own screens over the game on iPhone and iPad: HOME, Controllers, Settings, Ghosts and
// the reconnect card. They are the Mac shell's screens (apple/macos/KartPad*Screen.inc.mm and the
// overlay kit), built here from the same files: KartPadAppKitShim.h says their AppKit in UIKit,
// KartPadScreensPlatform.inc.mm stands in for the Mac shell around them, and the iOS glue after
// them hosts them over the game (KartPadScreens.h), takes touches and reads the controllers.
#import "KartPadScreens.h"
#import "KartPadMiiManager.h"
#import "KartPadMiiEditor.h"
#import "KartPadMenuButton.h"
#import <GameController/GameController.h>
#import "SunPadSettings.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <cmath>
#include <vector>

// The drawing kit sets type with Core Text; no product links it for the iOS shell.
__asm__(".linker_option \"-framework\", \"CoreText\"");

#include "KartPadStyle.h"
#include "KartPadAppKitShim.h"
#include "KartPadAppKitShim.inc.mm"
#include "KartPadAppKitShimNames.h"
#include "KartPadScreensPlatform.inc.mm"

#include "../macos/KartPadOverlay.inc.mm"
#include "../macos/KartPadUIGlyphs.inc.mm"
#include "../macos/KartPadHints.inc.mm"
#include "../macos/KartPadControllerArt.inc.mm"
#include "../macos/KartPadHomeScreen.inc.mm"
#include "../macos/KartPadControllersScreen.inc.mm"
#include "../macos/KartPadReconnect.inc.mm"
#include "../macos/KartPadGhostsScreen.inc.mm"
#include "../macos/KartPadSettingsScreen.inc.mm"
#include "KartPadScreensGlue.inc.mm"
