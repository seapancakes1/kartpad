#pragma once

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#import "SunPadControllerMapping.h"
#import "SunPadInputState.h"

NS_ASSUME_NONNULL_BEGIN

struct KartPadPhysicalControllerSample {
  SunPadPhysicalControllerButton faceButtons =
      static_cast<SunPadPhysicalControllerButton>(0);
  bool menu = false;
  bool dpadUp = false;
  bool dpadDown = false;
  bool dpadLeft = false;
  bool dpadRight = false;
  bool rightShoulder = false;
  float leftX = 0.0f;
  float leftY = 0.0f;
  float rightX = 0.0f;
  float rightY = 0.0f;
  float leftTrigger = 0.0f;
  float rightTrigger = 0.0f;
};

SunPadInputState KartPadAdaptPhysicalControllerSample(
    const KartPadPhysicalControllerSample& sample,
    SunPadControllerButtonMapping mapping) noexcept;

@interface KartPadPhysicalControllers : NSObject

+ (instancetype)sharedControllers;

- (void)start;
- (void)stop;
- (void)reconcileControllers;
- (BOOL)consumePlayer:(NSUInteger)player state:(SunPadInputState *)state;
- (BOOL)isPlayerConnected:(NSUInteger)player;
- (NSArray<NSString *> *)playerDescriptions;
- (NSUInteger)connectedControllerCount;
// The controller playing as player (0-3), nil for none. Main thread.
- (nullable GCController *)controllerForPlayer:(NSUInteger)player;
// Puts a controller on a player (0-3); whoever was there takes its old player, or stops playing.
// -1 takes it out until it's given a player again or reconnects. Main thread.
- (void)moveController:(GCController *)controller toPlayer:(NSInteger)player;

@end

// Switch Pro Controllers and Joy-Cons play with the letters printed on them (A on the right, B at the
// bottom), as on a Switch, unless this is off. On by default.
FOUNDATION_EXPORT NSString *const KartPadNintendoLayoutKey;
BOOL KartPadNintendoLayoutEnabled(void);
// The controller's face buttons are printed in Nintendo's layout: what iOS calls its A button (the
// bottom one) says B.
BOOL KartPadControllerHasNintendoFace(GCController *controller);

NS_ASSUME_NONNULL_END