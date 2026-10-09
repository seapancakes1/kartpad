# Local Mac automatic updates

The local Mac build can opt in by bundling `Contents/Resources/LocalUpdater/updater.py` and `settings.json`. Ordinary public builds without those resources keep their existing behavior.

At each launch, KartPad starts a background update check against the official Retro Rewind feed. A compact, nonactivating banner attaches to the upper-right of the game window and follows resizing. It distinguishes checking, downloading, preparation, verification and readiness. Download progress uses the actual byte count when the server provides a size; preparation stays indeterminate. Dismissing the banner does not cancel the update or reopen it on the next progress tick.

The ready state hides the spinner, offers **Restart now**, and disappears automatically after five seconds. Restart asks the player to finish their race first. Otherwise the update waits for the next normal launch. Failures explain connectivity, disk-space or verification issues and offer **Try again**. `KartPad → Automatic Updates…` reopens the banner without an extra modal status dialog.

The helper validates the installed pack, copies it to a separate staging directory, applies every newer official patch in version order, and checks the resulting version and code/XML fingerprints. Download and extraction limits reject oversized or unsafe archives. It then invokes the locally configured translator/build/package command, verifies that the new pack fingerprints are present in the native app, adds its own helper resources, signs the app and runs the Mac package audit.

A completed update remains pending while the game runs. At the next launch, before opening game files, KartPad shows **Installing Retro Rewind update…** and activates the new app and data together. A helper waits for the old process to exit, then reopens the updated app. The previous app remains next to the installed app as `KartPad.before-VERSION.app`; previous game data is retained. A transaction journal restores the app, config and active-version metadata if activation is interrupted.

The feature depends on this machine's checkout, user-owned disc extraction, local build scripts, Python 3.11 or newer, .NET SDK, Xcode and cached native dependencies. Keep the workspace and toolchain installed. Rebuilds need at least 8 GB free and may take several minutes. A future incompatible pack may fail to translate or compile; the working app and pack remain in place and the notice reports the failure. Offline checks leave the installed game available.

Settings are local build resources, not a public distribution contract. `buildCommand` is an argument list with `{root}`, `{profile}` and `{app}` substitutions; remote manifest contents are never evaluated as commands. The official feed supplies patch URLs, not independent checksums; downloads use HTTPS and locally computed hashes record provenance.

Update state and rebuild logs for this installation are under `~/Library/Application Support/KartPad/LocalUpdater`. App and data activation is automatic; restart timing stays under the player's control. Saved games and identities are not modified by the updater.

Validation: `python3 scripts/test-macos-local-updater.py` covers the ordered patch flow, staged background rebuild, integrity rejection, unsafe ZIP paths, lock contention, offline behavior, rollback, and interrupted activation recovery. The local app passed native compilation, signing, package audit and ZIP integrity checks. A native UI fixture verified both updating and ready notices; the real feed check reported installed version 6.13.1 as current. A future live-version activation has not yet occurred.
