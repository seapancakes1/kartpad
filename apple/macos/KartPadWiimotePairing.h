#pragma once

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const KartPadExperimentalWiimoteDefaultsKey;

void KartPadShowWiimotePairing(void);
void KartPadApplyExperimentalWiimotePreference(void);
// Pairing without its own window, for KartPad's Connect a Controller screen: status reports each step
// on the main thread (busy while it is still working).
void KartPadBeginWiimotePairing(void (^status)(NSString *message, BOOL busy));
void KartPadCancelWiimotePairing(void);
