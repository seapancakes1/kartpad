// Synthetic files for MiiChangesTests.kt: a database with three Miis, three saves whose licenses
// race as them, and the MAC the runtime derives from console serial 123456789.
#include "console_identity.h"
#include "kartpad/mii/player_identity.h"

#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <utility>

int main(int argc, char** argv) {
  using namespace kartpad::mii;
  if (argc != 2) return 1;
  const std::filesystem::path root(argv[1]);
  constexpr std::array<uint8_t, 6> mac{2, 17, 171, 16, 32, 48};
  auto database = CreateSeedDatabase(mac);
  for (const auto& [name, id] : {std::pair{"Bob", 0x80000002u}, std::pair{"Cat", 0x80000003u}}) {
    auto mii = CreateDefaultMii(mac);
    WriteMiiName(mii, 2, name);
    WriteBigEndian32(mii, 0x18, id);
    if (!ImportMii(database, mii)) return 2;
  }
  // Licenses as (license slot, Mii slot); progress stand-ins must survive every change.
  const auto save = [&](std::initializer_list<std::pair<std::size_t, std::size_t>> licenses, uint8_t progress) {
    std::vector<uint8_t> bytes(kRksysSize, 0);
    std::copy_n("RKSD0006", 8, bytes.begin());
    for (const auto& [license, mii] : licenses) {
      const std::size_t offset = kRksysLicenseOffset + license * kRksysLicenseSize;
      const auto id = MiiCreateId(database, mii);
      std::copy_n("RKPD", 4, bytes.begin() + offset);
      std::copy(id.begin(), id.end(), bytes.begin() + offset + kRksysCreateIdOffset);
      WriteMiiName(bytes, offset + kRksysMiiNameOffset, "Player");
      bytes[offset + 0x90] = progress;
    }
    UpdateRksysCrc(bytes);
    return bytes;
  };
  const auto console = RuntimeConsoleIdentity::FromSerial("123456789").mac;
  const std::vector<std::pair<const char*, std::vector<uint8_t>>> files{
      {"mii.dat", database},
      {"original.dat", save({{0, 1}, {1, 0}}, 0x72)},
      {"retro_rewind.dat", save({{1, 1}}, 0x35)},
      {"retro_rewind_separate.dat", save({{0, 1}, {2, 2}}, 0x44)},
      {"console-mac.bin", std::vector<uint8_t>(console.begin(), console.end())},
  };
  for (const auto& [name, bytes] : files) {
    std::ofstream out(root / name, std::ios::binary);
    out.write(reinterpret_cast<const char*>(bytes.data()), std::streamsize(bytes.size()));
    if (!out) return 3;
  }
  return 0;
}
