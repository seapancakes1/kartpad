// Discord shows the course and the mode while a Mario Kart Wii race runs, and "In the menus"
// otherwise (kartpad/discord/race_presence.h), under WiiCompiled's Discord application. Retro Rewind
// sends its own status through /dev/dolphin, so this reads nothing there. The runtime's
// DiscordPresence sends from its own thread, and only while Settings → Game → Discord Rich Presence
// ([discord] enabled) is on. Included by KartPadMacShell.mm after KartPadMacMiis.inc.mm, whose
// game-loop tick calls this.

#include "discord_presence.h"
#include "kartpad/discord/race_presence.h"
#include "memory.h"
#include "runtime_product.h"

static void KPDiscordPresenceTick() {
  // Once a second is plenty for a status; DiscordPresence drops repeats.
  static NSTimeInterval lastRead;
  if (RuntimeProduct::IsRetroRewind() || KPGameLoopTime - lastRead < 1) return;
  lastRead = KPGameLoopTime;
  namespace presence = kartpad::discord;
  presence::RaceSettings settings;
  uint32_t config = 0, manager = 0;
  const uint32_t at = presence::RaceSettingsOffset;
  const bool racing = Memory::TryRead32(presence::RaceConfigPointer, config) && config != 0 &&
                      Memory::TryRead32(presence::RaceManagerPointer, manager) && manager != 0 &&
                      Memory::TryRead32(config + at + presence::CourseOffset, settings.course) &&
                      Memory::TryRead32(config + at + presence::EngineClassOffset, settings.engineClass) &&
                      Memory::TryRead32(config + at + presence::GameModeOffset, settings.gameMode) &&
                      Memory::TryRead32(config + at + presence::CameraModeOffset, settings.cameraMode) &&
                      Memory::TryRead32(config + at + presence::ModeFlagsOffset, settings.modeFlags);
  const presence::Lines lines = presence::ForRace(racing, settings);
  DiscordPresence::SetBasicActivity(lines.details, lines.state);
}
