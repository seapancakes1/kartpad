#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const KartPadMiiManagerErrorDomain;

NSArray<NSDictionary<NSString *, id> *> *KartPadMiiRecords(NSError **error);
NSArray<NSDictionary<NSString *, id> *> *KartPadLicenseRecords(NSError **error);
BOOL KartPadStageMiiImport(NSData *miiData, NSString *_Nullable *_Nullable name,
                          NSError **error);
NSData *_Nullable KartPadReadMii(NSUInteger slot, NSError **error);
NSData *_Nullable KartPadNewMii(NSError **error);
// A copy of an existing Mii with a new identity, ready to save as a new Mii.
NSData *_Nullable KartPadDuplicateMii(NSUInteger slot, NSError **error);
NSData *_Nullable KartPadExportMii(NSData *edited, NSError **error);
BOOL KartPadStageMiiEditor(NSUInteger slot, NSData *_Nullable expected, NSData *edited, NSError **error);
BOOL KartPadStageMiiRemoval(NSUInteger slot, NSError **error);
BOOL KartPadStagePlayerName(NSUInteger slot, NSString *name,
                           NSUInteger *_Nullable updatedLicenses,
                           NSError **error);
BOOL KartPadStageLicenseRename(NSString *profileIdentifier, NSUInteger slot,
                              NSData *createId, NSString *name,
                              NSError **error);
// Select an existing Mii; preserves the license account/progress and never edits the Mii.
BOOL KartPadStageLicenseMii(NSString *profileIdentifier, NSUInteger slot,
                           NSData *createId, NSUInteger miiSlot, NSData *miiCreateId,
                           NSError **error);
BOOL KartPadStageLicenseDeletion(NSString *profileIdentifier, NSUInteger slot,
                                NSData *createId, NSError **error);
// Staged changes wait for the next launch, which applies them in order before the game starts.
// Several Mii and license changes can wait at once; a pending ghost import or save restore waits
// alone.
BOOL KartPadApplyPendingMiiDatabase(NSError **error);
BOOL KartPadHasPendingMiiChanges(void);
// NO while a pending ghost import, save restore or older version's change blocks new changes.
BOOL KartPadCanQueueMiiChanges(void);
NSUInteger KartPadPendingMiiChangeCount(void);
// Drops every waiting Mii and license change; live files are untouched. A pending ghost import or
// save restore has its own cancel.
BOOL KartPadCanDiscardPendingMiiChanges(void);
BOOL KartPadDiscardPendingMiiChanges(NSError **error);


// Original-course RKG exchange; imports use downloaded slots and preserve personal bests. Each ghost
// has its name, data, course slot (0-31, in the game's order) and whether it's the downloaded one.
NSArray<NSDictionary<NSString *, id> *> *KartPadOriginalGhosts(NSUInteger license, NSError **error);
BOOL KartPadStageOriginalGhost(NSData *ghost, NSUInteger license, NSError **error);

BOOL KartPadHasPendingGhost(void);
BOOL KartPadCancelPendingGhost(NSError **error);

FOUNDATION_EXPORT NSData * _Nullable KartPadReadSave(NSString *profile, NSError **error);
FOUNDATION_EXPORT BOOL KartPadStageSaveRestore(NSString *profile, NSData *data, NSError **error);
FOUNDATION_EXPORT BOOL KartPadCancelSaveRestore(NSError **error);
FOUNDATION_EXPORT BOOL KartPadHasPendingSaveRestore(void);
NS_ASSUME_NONNULL_END
