#pragma once

#include <array>
#include <cstdint>

#include "kartpad/network/phone_pad.h"

// What each player's phone shows (phone_pad::RaceView), read from base Mario
// Kart Wii's memory: whether a race is on and at which stage, whether it's
// paused, which racers are players on this Mac and have finished, whose kart
// is off the course and back with Lakitu, and whose has been hit. Racers are matched to players by
// the GameCube pad channel their controller reads, which is the player's slot,
// or (Match::LocalPlayer) by local player, whatever their controller.
// PAL layout, from doldecomp/mkw (src/system/RaceManager.hpp, KPadDirector.hpp,
// KPadController.hpp and src/kart/KartObjectProxy.hpp, KartState.hpp, with
// addresses from config/RMCP01), the kart manager from mkw-sp, and the respawn
// flags and timers from Kinoko (source/game/kart/Status.hh, KartMove.cc).
namespace kartpad::phone_pad::race {

// KPadDirector::spInstance and RaceManager::spInstance (only set during a race
// or a battle).
inline constexpr uint32_t DirectorPointer = 0x809bd70c;
inline constexpr uint32_t RaceManagerPointer = 0x809bd730;
// KPadDirector: its four KPadPlayers, its four KPadGCControllers, and whether
// the race is paused (a bool, the first byte of its word).
inline constexpr uint32_t DirectorPlayers = 0x4, KPadPlayerSize = 0xec;
inline constexpr uint32_t DirectorGCControllers = 0x3ba0, GCControllerSize = 0xb0;
inline constexpr uint32_t DirectorPaused = 0x4154;
// KPad::mController, and KPadGCController::mChan.
inline constexpr uint32_t KPadController = 0x4, GCControllerChannel = 0x9c;
// RaceManager::players (RaceManagerPlayer *[]) and ::stage.
inline constexpr uint32_t ManagerPlayers = 0x0c, ManagerStage = 0x28;
enum Stage : uint32_t { IntroCamera = 0, Countdown = 1, Racing = 2, FinishedRace = 3 };
// RaceManagerPlayer::flags (FINISHED) and ::kpadPlayer.
inline constexpr uint32_t PlayerFlags = 0x38, PlayerKPad = 0x48, FinishedFlag = 2;
inline constexpr int MaxRacers = 12, Channels = 4;
// Kart::KartObjectManager::s_instance, and its KartObject *[] (in the race
// manager's order of racers).
inline constexpr uint32_t KartManagerPointer = 0x809c18f8, KartManagerObjects = 0x20;
// A KartObject's KartAccessor (its first word), and the accessor's KartState
// and KartMove.
inline constexpr uint32_t AccessorState = 0x4, AccessorMove = 0x28;
// KartState's flags, five words from +0x4 (flag n is bit n % 32 of word n / 32):
// BeforeRespawn (4: off the course, until Lakitu has the kart), InRespawn (77:
// Lakitu carries it) and AfterRespawn (78: dropped, until it lands), and InAction
// (32: spun out, tumbling or flipped by a hit, until KartAction::end).
inline constexpr uint32_t StateFlags = 0x4;
inline constexpr uint32_t BeforeRespawnBit = 1u << 4, InOrAfterRespawnBits = 3u << 13;  // in words 0 and 2
inline constexpr uint32_t InActionBit = 1u;                                             // in word 1
// KartMove::m_respawnPostLandTimer, in the high half of this word: the frames
// left after landing to press A for Lakitu's boost.
inline constexpr uint32_t MovePostLandTimer = 0x238;

// The Wii's two RAM areas, where every pointer read here must land.
inline bool InRam(uint32_t address) {
  return (address >= 0x80000000u && address < 0x81800000u) || (address >= 0x90000000u && address < 0x94000000u);
}

using Views = std::array<RaceView, Channels>;

// How racers are matched to Views' slots: by GameCube pad channel (phones on the
// Mac), or by local player, the KPadPlayer they read (the touch controls on
// iPhone and iPad, a Classic Controller to the game).
enum class Match { PadChannel, LocalPlayer };

// Racer i's view while racing: Fall while the kart is off the course and back
// with Lakitu, until the moment to press A for his boost has passed; Hit while
// it's spun out or flipped by a hit; otherwise Race. Anything unreadable counts
// as neither, so the race view stands.
template <typename Read>
RaceView Driving(Read &&read, int i) {
  uint32_t manager = 0, objects = 0, kart = 0, accessor = 0, state = 0, move = 0, flags0 = 0, flags1 = 0, flags2 = 0,
           timers = 0;
  if (!read(KartManagerPointer, manager) || !InRam(manager) || !read(manager + KartManagerObjects, objects) ||
      !InRam(objects) || !read(objects + 4 * i, kart) || !InRam(kart) || !read(kart, accessor) || !InRam(accessor) ||
      !read(accessor + AccessorState, state) || !InRam(state) || !read(accessor + AccessorMove, move) || !InRam(move) ||
      !read(state + StateFlags, flags0) || !read(state + StateFlags + 4, flags1) ||
      !read(state + StateFlags + 8, flags2) || !read(move + MovePostLandTimer, timers))
    return RaceView::Race;
  if ((flags0 & BeforeRespawnBit) || (flags2 & InOrAfterRespawnBits) || static_cast<int16_t>(timers >> 16) > 0)
    return RaceView::Fall;
  return (flags1 & InActionBit) ? RaceView::Hit : RaceView::Race;
}

// read(address, value) reads a big-endian word as the game sees it and returns
// false where nothing is mapped. Anything that doesn't add up (another game
// build, a Retro Rewind layout) gives Unknown rather than a wrong layout.
template <typename Read>
Views ReadViews(Read &&read, Match match = Match::PadChannel) {
  Views unknown, views;
  unknown.fill(RaceView::Unknown);
  views.fill(RaceView::Menus);
  uint32_t director = 0, manager = 0;
  if (!read(DirectorPointer, director)) return unknown;
  if (director == 0) return views;  // the game is still starting
  if (!InRam(director) || !read(RaceManagerPointer, manager)) return unknown;
  if (manager == 0) return views;
  uint32_t stage = 0, players = 0, paused = 0;
  if (!InRam(manager) || !read(manager + ManagerStage, stage) || stage > FinishedRace ||
      !read(manager + ManagerPlayers, players) || !InRam(players) || !read(director + DirectorPaused, paused))
    return unknown;
  const uint32_t kpads = director + DirectorPlayers, controllers = director + DirectorGCControllers;
  for (int i = 0; i < MaxRacers; ++i) {
    uint32_t player = 0, kpad = 0, controller = 0, channel = 0, flags = 0;
    if (!read(players + 4 * i, player) || !InRam(player)) break;
    if (!read(player + PlayerKPad, kpad) || !read(player + PlayerFlags, flags)) return unknown;
    // Players on this Mac read one of the director's own KPadPlayers; computer
    // racers, ghosts and online opponents don't.
    if (kpad < kpads || kpad >= kpads + 4 * KPadPlayerSize || (kpad - kpads) % KPadPlayerSize != 0) continue;
    if (match == Match::LocalPlayer) {
      channel = (kpad - kpads) / KPadPlayerSize;
    } else {
      if (!read(kpad + KPadController, controller)) return unknown;
      // A GameCube pad: a Wii Remote is never a phone.
      if (controller < controllers || controller >= controllers + 4 * GCControllerSize ||
          (controller - controllers) % GCControllerSize != 0)
        continue;
      if (!read(controller + GCControllerChannel, channel) || channel >= Channels) return unknown;
    }
    RaceView view = RaceView::Menus;
    if (stage <= Countdown) view = RaceView::Start;
    else if (stage == Racing && !(flags & FinishedFlag)) view = Driving(read, i);
    if (paused >> 24) view = RaceView::Menus;
    views[channel] = view;
  }
  return views;
}

}  // namespace kartpad::phone_pad::race
