#pragma once

#include "kartpad/ghost/rkg.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <string>

// What Discord shows for base Mario Kart Wii: the course and the mode while a
// race runs, otherwise that the player is in the menus. Read from the race
// scenario of the PAL RaceConfig (doldecomp/mkw src/system/RaceConfig.hpp, with
// addresses from config/RMCP01/module/symbols.txt).
namespace kartpad::discord {

// RaceConfig::spInstance, and RaceManager::spInstance, which is only set while
// a race or a battle runs.
inline constexpr uint32_t RaceConfigPointer = 0x809bd728;
inline constexpr uint32_t RaceManagerPointer = 0x809bd730;
// RaceConfig::mRaceScenario.mSettings, and the fields read from it.
inline constexpr uint32_t RaceSettingsOffset = 0xb68;
inline constexpr uint32_t CourseOffset = 0x00, EngineClassOffset = 0x04, GameModeOffset = 0x08,
                          CameraModeOffset = 0x0c, ModeFlagsOffset = 0x28;

// RaceConfig::Settings::GameMode.
enum GameMode : uint32_t {
  GrandPrix, VsRace, TimeTrial, Battle, MissionTournament, GhostRace, UnknownMode,
  PrivateVs, PublicVs, PublicBattle, PrivateBattle, Awards, Credits,
};
// The title screen's demo races use these cameras.
inline constexpr uint32_t TitleCameraFirst = 2, TitleCameraLast = 4;
inline constexpr uint32_t MirrorFlag = 1;

struct RaceSettings {
  uint32_t course = 0;
  uint32_t engineClass = 0;
  uint32_t gameMode = 0;
  uint32_t cameraMode = 0;
  uint32_t modeFlags = 0;
};

struct Lines {
  std::string details;
  std::string state;
  bool operator==(const Lines &) const = default;
};

// The battle arenas follow the 32 race courses, from 0x20.
inline constexpr uint32_t FirstArena = 0x20;
inline constexpr std::array<const char *, 10> ArenaNames{
    "Delfino Pier",      "Block Plaza",          "Chain Chomp Roulette", "Funky Stadium",
    "Thwomp Desert",     "GCN Cookie Land",      "DS Twilight House",    "SNES Battle Course 4",
    "GBA Battle Course 3", "N64 Skyscraper"};

// nullptr for the award ceremony, the credits and other scenes that aren't a course.
inline const char *CourseName(uint32_t course) {
  const auto slot = std::find(ghost::CourseIds.begin(), ghost::CourseIds.end(), course);
  if (slot != ghost::CourseIds.end()) return ghost::CourseNames[size_t(slot - ghost::CourseIds.begin())];
  if (course >= FirstArena && course - FirstArena < ArenaNames.size()) return ArenaNames[course - FirstArena];
  return nullptr;
}

inline const char *ModeName(uint32_t gameMode) {
  switch (gameMode) {
  case GrandPrix: return "Grand Prix";
  case VsRace: return "VS Race";
  case TimeTrial:
  case GhostRace: return "Time Trial";
  case Battle: return "Battle";
  case MissionTournament: return "Tournament";
  case PrivateVs:
  case PublicVs: return "Online";
  case PublicBattle:
  case PrivateBattle: return "Online Battle";
  default: return nullptr;
  }
}

// Nothing for battles (engine class 3) and for time trials, which are always 150cc.
inline const char *ClassName(const RaceSettings &settings) {
  if (settings.gameMode == TimeTrial || settings.gameMode == GhostRace) return nullptr;
  switch (settings.engineClass) {
  case 0: return "50cc";
  case 1: return "100cc";
  case 2: return settings.modeFlags & MirrorFlag ? "Mirror" : "150cc";
  default: return nullptr;
  }
}

// racing: RaceManager exists.
inline Lines ForRace(bool racing, const RaceSettings &settings) {
  const bool demo = settings.cameraMode >= TitleCameraFirst && settings.cameraMode <= TitleCameraLast;
  const char *course = racing && !demo ? CourseName(settings.course) : nullptr;
  if (!course) return {"In the menus", ""};
  std::string state;
  for (const char *part : {ModeName(settings.gameMode), ClassName(settings)}) {
    if (!part) continue;
    if (!state.empty()) state += " · ";
    state += part;
  }
  return {course, state};
}

}  // namespace kartpad::discord
