#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Progress sync (optional, off until a folder is chosen): Miis, the three saves and Retro Rewind
// ratings travel between devices through a folder both can reach, such as one in iCloud Drive. Each
// device writes only its own file there, so the folder's sync never has two writers for one file.
// A device remembers which progress it last sent or loaded; progress is only loaded at launch, and
// when both sides changed the player chooses which to keep. Console identity never travels.

typedef NS_ENUM(NSInteger, KartPadSyncChoice) {
  KartPadSyncChoiceKeepThisDevice,
  KartPadSyncChoiceUseOther,
  KartPadSyncChoiceLater,
};

// One device's progress, for choices and "Use Progress From…".
@interface KartPadSyncProgress : NSObject
@property(nonatomic, copy) NSString *deviceID;
@property(nonatomic, copy) NSString *deviceName;
@property(nonatomic, strong, nullable) NSDate *played;  // newest change to its files
@property(nonatomic, copy) NSArray<NSString *> *licenses;  // license names, saves in order
@end

BOOL KartPadSyncEnabled(void);
// The chosen folder's name, or nil while sync is off.
NSString *_Nullable KartPadSyncFolderName(void);
NSString *KartPadSyncThisDeviceName(void);
// Turns sync on with this folder (a security-scoped URL from a picker on iPhone/iPad), or moves it.
// Afterwards this device sends its progress when nothing newer is waiting.
BOOL KartPadSyncChooseFolder(NSURL *folder, NSError **error);
void KartPadSyncTurnOff(void);

// A short line for Settings: Off, when it last synced, or what's waiting.
NSString *KartPadSyncStatus(void);
// "SeaPancake · Nov 18, 2026 at 5:02 PM": its licenses and when it was played.
NSString *KartPadSyncDescribe(KartPadSyncProgress *progress);
// YES while progress waits to load (or to be chosen) at the next launch.
BOOL KartPadSyncNeedsRestart(void);

// At launch, after pending Mii and save changes are applied and before the game opens its files.
// Loads newer progress, sends this device's, or asks (on the calling thread) which to keep. Waits
// for the folder at most `timeout` seconds; then the game starts with this device's progress.
void KartPadSyncAtLaunch(NSTimeInterval timeout,
                         KartPadSyncChoice (^choose)(KartPadSyncProgress *thisDevice,
                                                     KartPadSyncProgress *other));
// While the game runs: checks every minute and sends progress that changed (never loads).
void KartPadSyncStartWatching(void);
// Sends now if progress changed, waiting at most `timeout` seconds (quit, going to the background).
void KartPadSyncSendNow(NSTimeInterval timeout);
// Sends in the background if progress changed; `done` runs on the main queue.
void KartPadSyncSendSoon(void (^_Nullable done)(void));

// Other devices' progress in the folder, newest first.
NSArray<KartPadSyncProgress *> *KartPadSyncOtherDevices(NSTimeInterval timeout);
// Replaces this device's progress with that device's at the next launch (after a backup).
BOOL KartPadSyncUseProgressAtNextLaunch(NSString *deviceID, NSError **error);
BOOL KartPadSyncCancelUseProgress(void);

NS_ASSUME_NONNULL_END
