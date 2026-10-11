#include "kartpad/discord/race_presence.h"

#include <iostream>

namespace {

using namespace kartpad::discord;

bool Expect(bool racing, const RaceSettings &settings, const Lines &expected) {
  const Lines lines = ForRace(racing, settings);
  if (lines == expected) return true;
  std::cerr << "expected \"" << expected.details << "\" / \"" << expected.state << "\", got \""
            << lines.details << "\" / \"" << lines.state << "\"\n";
  return false;
}

}  // namespace

int main() {
  // Camera 5 is the ordinary race camera with the course intro.
  bool ok = true;
  ok &= Expect(true, {0x08, 2, GrandPrix, 5, 0}, {"Luigi Circuit", "Grand Prix · 150cc"});
  ok &= Expect(true, {0x00, 0, VsRace, 5, 0}, {"Mario Circuit", "VS Race · 50cc"});
  ok &= Expect(true, {0x1f, 2, GrandPrix, 5, MirrorFlag}, {"GBA Shy Guy Beach", "Grand Prix · Mirror"});
  ok &= Expect(true, {0x17, 1, PublicVs, 5, 0}, {"DS Delfino Square", "Online · 100cc"});
  ok &= Expect(true, {0x0d, 2, TimeTrial, 5, 0}, {"Rainbow Road", "Time Trial"});
  ok &= Expect(true, {0x0d, 2, GhostRace, 1, 0}, {"Rainbow Road", "Time Trial"});
  ok &= Expect(true, {0x21, 3, Battle, 5, 0}, {"Block Plaza", "Battle"});
  ok &= Expect(true, {0x29, 3, PrivateBattle, 5, 0}, {"N64 Skyscraper", "Online Battle"});
  // A mode it doesn't name still shows the course.
  ok &= Expect(true, {0x08, 2, UnknownMode, 5, 0}, {"Luigi Circuit", "150cc"});
  // No race, the title screen's demo race, the award ceremony, and garbage.
  ok &= Expect(false, {0x08, 2, GrandPrix, 5, 0}, {"In the menus", ""});
  ok &= Expect(true, {0x08, 2, VsRace, 3, 0}, {"In the menus", ""});
  ok &= Expect(true, {0x2b, 2, Awards, 7, 0}, {"In the menus", ""});
  ok &= Expect(true, {0xffffffff, 2, GrandPrix, 5, 0}, {"In the menus", ""});
  return ok ? 0 : 1;
}
