#pragma once

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const KartPadExperimentalWiimoteDefaultsKey;

void KartPadShowWiimotePairing(void);
void KartPadApplyExperimentalWiimotePreference(void);
// Pairing without its own window, for KartPad's Connect a Controller screen: status reports each step
// on the main thread (busy while it is still working).
void KartPadBeginWiimotePairing(void (^status)(NSString *message, BOOL busy));
void KartPadCancelWiimotePairing(void);

// The same for other Bluetooth controllers (PlayStation, Switch and most others): KartPad finds one in
// pairing mode and pairs it itself, then macOS connects it like any controller. Searching stops on
// its own after about a minute. Newer Xbox controllers use Bluetooth LE, which this doesn't find.
// log gets a line for the session log at each step.
void KartPadBeginGamepadPairing(void (^status)(NSString *message, BOOL busy), void (^log)(NSString *line));
void KartPadCancelGamepadPairing(void);
