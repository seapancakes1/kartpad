# Local Mac automatic updates

A local Mac build opts in by bundling `Contents/Resources/LocalUpdater/updater.py` and `settings.json`. Ordinary public builds without those resources keep their existing behavior.

## Packaging

`scripts/package-macos-runtime.sh` bundles the helper before signing when `KARTPAD_LOCAL_UPDATER_SETTINGS` names a settings file. Only the `KartPadDual` target accepts it. Packages built without the variable never include the helper, so release packaging is unaffected. Set the variable in the local packaging wrapper rather than adding the resources by hand afterwards, so a repackaged app can't silently lose automatic updates.

`scripts/audit-macos-package.sh` fails when the variable is set but the package has no helper, and when a bundled helper is incomplete or differs from `scripts/macos-local-updater.py`. `scripts/check-local-updater-settings.py` validates the settings file in both places.

## Checking

At each launch KartPad starts a background check at utility priority. Automatic checks are quiet: no banner appears while checking, when the game is current, or when the Mac is offline. A compact, nonactivating banner attaches to the upper-right of the game window when there is news: downloading, preparation, verification, a ready update, or a failure. Each distinct failure is shown once. Dismissing the banner doesn't cancel the update.

**KartPad → Automatic Updates…** runs a visible check, which also reports when the game is up to date, and reopens the banner for an update in progress. It ignores the retry rules below.

Failures don't repeat on every launch:

- **Offline:** automatic checks back off, starting at 10 minutes and doubling to at most 6 hours.
- **Not enough space:** the check runs again at the next launch.
- **Build, verification or configuration failure:** remembered for that feed version and download URL. Automatic checks skip it until the feed changes or the player chooses **Try again**.

## Preparing an update

The helper validates the installed pack, then clones it into a staging directory. APFS clones (`cp -c`) share unchanged files with the installed pack, so staging costs little extra space. It downloads every newer official patch in version order. Downloads retry transient failures and resume from the bytes already received. Each patch is extracted, then its ZIP is deleted.

After each patch the helper applies that version's entries from the official `RetroRewindDelete.txt`, so files a release removes don't survive the update. Only `/RetroRewind6/` paths apply; other entries are the official updater's own downloads at the SD card root. A path that escapes the pack, or an entry that removes the whole pack, rejects the update.

The helper then checks the resulting version and code/XML fingerprints. Download and extraction limits reject oversized or unsafe archives. The locally configured build command runs under `taskpolicy -b` so it doesn't compete with the game. The helper verifies that the new pack fingerprints are present in the native app, then signs the app and runs the Mac package audit.

## Installing

The ready banner offers **Restart game** and disappears after five seconds. Restart asks the player to finish their race first. A helper waits for KartPad to exit, installs the update, and reopens the updated app once. If the player quits normally instead, KartPad installs the update at the next launch, before opening game files, and reopens itself.

Installation moves the app bundles, rewrites the config and updates the state files as one journaled step. If it is interrupted, the next launch puts every piece back as it was. A pending build that can't be installed (failed integrity check, missing files, an unusable config) is discarded and recorded, so it can't block later updates. A build that only ran out of space stays pending for the next attempt.

## Trial and going back

A newly installed app is on trial until it has run for 90 seconds or ends a session cleanly. If two launches end without either, the next launch restores the previous app and game files, reopens KartPad and explains what happened. Automatic checks then skip that version.

**KartPad → Go Back to Retro Rewind VERSION…** does the same on demand. Afterwards, **Automatic Updates…** shows the skipped version with **Install anyway**. Going back changes only the `retro_rewind_root` line of the config, so settings changed since the update are kept. Saved games and identities are not modified by the updater.

## Disk use

The updater keeps the active version and one previous version: the `KartPad.before-VERSION.app` backup next to the installed app and that version's pack. After each installation it removes older staging directories and backups, the spare copy of the new app, and any leftovers from interrupted runs. Rebuilds still need at least 8 GB free.

## Requirements

The feature depends on this machine's checkout, user-owned disc extraction, local build scripts, the .NET SDK, Xcode and cached native dependencies. The helper needs Python 3.11 or newer at the path in the settings. The build command runs outside an interactive shell, so it must provide every tool the translate and package scripts call on its own `PATH`, including an `rg` (ripgrep or a compatible shim). A future incompatible pack may fail to translate or compile. The working app and pack stay in place, and the banner reports the failure.

Settings are local build resources, not a public distribution contract. `buildCommand` is an argument list with `{root}`, `{profile}` and `{app}` substitutions; remote manifest contents are never evaluated as commands. The official feed supplies patch URLs, not independent checksums; downloads use HTTPS, and locally computed hashes record provenance.

## State

Files are under `~/Library/Application Support/KartPad/LocalUpdater`:

| File | Purpose |
| --- | --- |
| `status.json` | Latest phase shown by the banner |
| `pending.json` | A finished build waiting to be installed |
| `active.json` | The installed version, pack and profile, once an update has been installed |
| `rollback.json` | The previous version and its app backup |
| `trial.json` | Launch count for a newly installed app |
| `failure.json` | The last failure, for retry and backoff decisions |
| `activation.json` | Journal of an installation in progress |
| `last-build.log` | Output of the last failed rebuild |

## Validation

`python3 scripts/test-macos-local-updater.py` covers the ordered patch flow, the live four-column feed format, delete-list selection and safety, APFS cloning, resumed downloads, the staged background rebuild, integrity rejection, discarding unusable builds, backup name collisions, interrupted-copy leftovers, pruning, failure memory and network backoff, declined versions, trial rollback, manual rollback, unsafe ZIP paths, lock contention, offline behavior and interrupted-installation recovery at every step.
