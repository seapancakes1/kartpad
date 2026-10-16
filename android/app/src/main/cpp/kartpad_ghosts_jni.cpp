#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <span>
#include <string>
#include <vector>

#include "kartpad/ghost/rkg.h"
#include "kartpad/mii/appearance.h"

// Time Trial ghosts for the Ghosts screen (screens/GhostsScreen.kt): Mario Kart Wii's own .rkg files
// in the Original save, after the Mac's KartPadOriginalGhosts (apple/shared/KartPadMiiManager.mm) and
// KPGhostInfo (apple/macos/KartPadGhostsScreen.inc.mm). Rows are flat Object arrays (Integer,
// Boolean, String, byte[]); a failure throws IllegalArgumentException with why.

namespace {
namespace ghost = kartpad::ghost;
namespace mii = kartpad::mii;

constexpr size_t kLicenseAt = 8, kLicenseBytes = 0x8cc0, kLicenseName = 0x14, kGhostMii = 0x3c;

// What a ghost file says about itself: its course, its time and the racer's Mii (when it's a valid
// one, so a stranger's file never reaches the portrait renderer otherwise).
struct Described {
  unsigned slot = 0;
  std::string time;
  std::u16string name;
  bool hasMii = false;
  std::array<uint8_t, mii::kMiiBlockSize> mii{};
};

// A name of up to ten UTF-16 characters (big-endian), without control characters or unpaired
// surrogates (as KartPad's other names).
std::u16string Name(std::span<const uint8_t> b, size_t at) {
  auto unit = [&](size_t i) { return char16_t(b[at + 2 * i] << 8 | b[at + 2 * i + 1]); };
  std::u16string name;
  for (size_t i = 0; i < 10; ++i) {
    const char16_t first = unit(i);
    if (first == 0) break;
    if (first >= 0xd800 && first <= 0xdbff && i + 1 < 10) {
      const char16_t second = unit(i + 1);
      if (second >= 0xdc00 && second <= 0xdfff) {
        name += first;
        name += second;
        ++i;
        continue;
      }
    }
    if (first < 0x20 || (first >= 0xd800 && first <= 0xdfff)) continue;
    name += first;
  }
  return name;
}

Described Describe(std::span<const uint8_t> b) {
  const auto info = ghost::Validate(b);
  const uint32_t race = ghost::Read32(b, 4);
  const auto course = std::find(ghost::CourseIds.begin(), ghost::CourseIds.end(), info.course);
  ghost::Require(course != ghost::CourseIds.end(), "Only Mario Kart Wii courses are supported");
  Described d;
  d.slot = unsigned(course - ghost::CourseIds.begin());
  char time[16];
  std::snprintf(time, sizeof time, "%u:%02u.%03u", unsigned(race >> 25), unsigned((race >> 18) & 127),
                unsigned((race >> 8) & 1023));
  d.time = time;
  const auto record = b.subspan(kGhostMii, mii::kMiiBlockSize);
  try {
    if (mii::Appearance::Decode(record).Validate()) {
      std::copy(record.begin(), record.end(), d.mii.begin());
      d.hasMii = true;
    }
  } catch (const std::exception &) {
  }
  d.name = Name(b, kGhostMii + 2);
  return d;
}

// A saved ghost, as kartpad::ghost::Export finds it, in a save already validated (so a license's
// listing checks the save's checksum once, not once a ghost).
std::span<const uint8_t> Saved(std::span<const uint8_t> save, unsigned license, unsigned slot, bool downloaded) {
  const size_t at = 0x28000 + license * 0xa5000 + (downloaded ? 0x50000 : 0) + slot * ghost::GhostBytes;
  const auto data = save.subspan(at, ghost::GhostBytes);
  const auto info = ghost::Validate(data);
  ghost::Require(info.course == ghost::CourseIds[slot], "Ghost/course mismatch");
  return data.first(info.bytes);
}

struct Listed {
  bool downloaded;
  Described info;
};

// A license's ghosts in the save's order: personal bests, then downloaded ones, by slot. A corrupt
// ghost doesn't hide the others; a license whose listed ghosts all fail says why.
std::vector<Listed> List(std::span<const uint8_t> save, unsigned license) {
  ghost::ValidateSave(save, license);
  std::vector<Listed> listed;
  std::string firstError;
  for (bool downloaded : {false, true}) {
    const uint32_t bits = ghost::Read32(save, kLicenseAt + license * kLicenseBytes + (downloaded ? 8 : 4));
    for (unsigned slot = 0; slot < 32; ++slot) {
      if (!(bits & (1u << slot))) continue;
      try {
        listed.push_back({downloaded, Describe(Saved(save, license, slot, downloaded))});
      } catch (const std::exception &failure) {
        if (firstError.empty()) firstError = failure.what();
      }
    }
  }
  if (listed.empty() && !firstError.empty())
    throw std::runtime_error("This license lists saved ghosts, but they could not be exported. " + firstError +
                             ". Your save has not been changed.");
  return listed;
}

// The licenses made in the save: slot and name.
std::vector<std::pair<unsigned, std::u16string>> Licenses(std::span<const uint8_t> save) {
  ghost::Require(save.size() == ghost::SaveBytes && ghost::Read32(save, 0) == 0x524b5344, "Unsupported save");
  std::vector<std::pair<unsigned, std::u16string>> licenses;
  for (unsigned license = 0; license < 4; ++license) {
    const size_t at = kLicenseAt + license * kLicenseBytes;
    if (ghost::Read32(save, at) == 0x524b5044) licenses.emplace_back(license, Name(save, at + kLicenseName));
  }
  return licenses;
}

// MARK: JNI

struct Pending : std::exception {};  // a Java exception is already pending

std::vector<uint8_t> Copy(JNIEnv *env, jbyteArray array, size_t limit, const char *why) {
  ghost::Require(array != nullptr, why);
  const jsize size = env->GetArrayLength(array);
  ghost::Require(size >= 0 && size_t(size) <= limit, why);
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  if (size) env->GetByteArrayRegion(array, 0, size, reinterpret_cast<jbyte *>(bytes.data()));
  if (env->ExceptionCheck()) throw Pending();
  return bytes;
}

jbyteArray ByteArray(JNIEnv *env, std::span<const uint8_t> bytes) {
  jbyteArray array = env->NewByteArray(jsize(bytes.size()));
  if (array == nullptr) throw Pending();
  env->SetByteArrayRegion(array, 0, jsize(bytes.size()), reinterpret_cast<const jbyte *>(bytes.data()));
  return array;
}

class Row {
 public:
  Row(JNIEnv *env, size_t size) : env_(env) {
    jclass object = env->FindClass("java/lang/Object");
    if (object == nullptr) throw Pending();
    array_ = env->NewObjectArray(jsize(size), object, nullptr);
    env->DeleteLocalRef(object);
    if (array_ == nullptr) throw Pending();
  }
  jobjectArray array() const { return array_; }

  void Int(int value) { Box("java/lang/Integer", "(I)Ljava/lang/Integer;", jvalue{.i = value}); }
  void Bool(bool value) { Box("java/lang/Boolean", "(Z)Ljava/lang/Boolean;", jvalue{.z = jboolean(value ? JNI_TRUE : JNI_FALSE)}); }
  void Text(const char *text) { Put(env_->NewStringUTF(text)); }
  // Null for an empty name.
  void Text(const std::u16string &text) {
    if (text.empty()) return Skip();
    Put(env_->NewString(reinterpret_cast<const jchar *>(text.data()), jsize(text.size())));
  }
  void Bytes(std::span<const uint8_t> bytes) { Put(ByteArray(env_, bytes)); }
  void Skip() { ++next_; }

  void Info(const Described &info) {
    Int(int(info.slot));
    Text(ghost::CourseNames[info.slot]);
    Text(info.time.c_str());
    Text(info.name);
    if (info.hasMii) Bytes(info.mii);
    else Skip();
  }

 private:
  void Put(jobject value) {
    if (value == nullptr) throw Pending();
    env_->SetObjectArrayElement(array_, jsize(next_++), value);
    env_->DeleteLocalRef(value);
    if (env_->ExceptionCheck()) throw Pending();
  }
  void Box(const char *type, const char *signature, jvalue value) {
    jclass boxed = env_->FindClass(type);
    if (boxed == nullptr) throw Pending();
    jmethodID valueOf = env_->GetStaticMethodID(boxed, "valueOf", signature);
    jobject object = valueOf ? env_->CallStaticObjectMethodA(boxed, valueOf, &value) : nullptr;
    const bool failed = env_->ExceptionCheck();
    env_->DeleteLocalRef(boxed);
    if (failed) throw Pending();
    Put(object);
  }

  JNIEnv *env_;
  jobjectArray array_ = nullptr;
  size_t next_ = 0;
};

// Runs body, turning a C++ failure into IllegalArgumentException (null comes back to Java).
template <typename Body>
auto Guard(JNIEnv *env, Body body) -> decltype(body()) {
  try {
    return body();
  } catch (const Pending &) {
  } catch (const std::exception &failure) {
    if (!env->ExceptionCheck())
      if (jclass type = env->FindClass("java/lang/IllegalArgumentException")) env->ThrowNew(type, failure.what());
  }
  return nullptr;
}

constexpr const char *kNoSave = "Unsupported save";
constexpr const char *kNoGhost = "Not an RKG ghost";

}  // namespace

// The licenses made in an Original save: slot (Integer) and name (String, null when empty), each.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_screens_GhostsNative_nativeListLicenses(JNIEnv *env, jobject, jbyteArray save) {
  return Guard(env, [&]() -> jobjectArray {
    const auto bytes = Copy(env, save, ghost::SaveBytes, kNoSave);
    const auto licenses = Licenses(bytes);
    Row row(env, licenses.size() * 2);
    for (const auto &[slot, name] : licenses) {
      row.Int(int(slot));
      row.Text(name);
    }
    return row.array();
  });
}

// A license's saved ghosts, six entries each: downloaded (Boolean), then the course slot (Integer,
// 0–31 in the game's order), course, time ("1:23.456"), the Mii's name (null when it has none) and
// its 74-byte record (null when it isn't a valid Mii).
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_screens_GhostsNative_nativeListGhosts(JNIEnv *env, jobject, jbyteArray save, jint license) {
  return Guard(env, [&]() -> jobjectArray {
    const auto bytes = Copy(env, save, ghost::SaveBytes, kNoSave);
    ghost::Require(license >= 0 && license < 4, "Choose an initialized license");
    const auto listed = List(bytes, unsigned(license));
    Row row(env, listed.size() * 6);
    for (const auto &entry : listed) {
      row.Bool(entry.downloaded);
      row.Info(entry.info);
    }
    return row.array();
  });
}

// A saved ghost's .rkg, as the game wrote it.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_kartpad_android_screens_GhostsNative_nativeExportGhost(JNIEnv *env, jobject, jbyteArray save, jint license,
                                                               jint slot, jboolean downloaded) {
  return Guard(env, [&]() -> jbyteArray {
    const auto bytes = Copy(env, save, ghost::SaveBytes, kNoSave);
    ghost::Require(license >= 0 && license < 4, "Choose an initialized license");
    ghost::Require(slot >= 0 && slot < 32, "Invalid course");
    return ByteArray(env, ghost::Export(bytes, unsigned(license), unsigned(slot), downloaded == JNI_TRUE));
  });
}

// What a ghost file says about itself, five entries: the course slot, course, time, Mii name and
// Mii record, as a listed ghost has them.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_screens_GhostsNative_nativeInspectGhost(JNIEnv *env, jobject, jbyteArray rkg) {
  return Guard(env, [&]() -> jobjectArray {
    const auto bytes = Copy(env, rkg, ghost::GhostBytes, kNoGhost);
    const auto info = Describe(bytes);
    Row row(env, 5);
    row.Info(info);
    return row.array();
  });
}

// The save with the ghost as the license's downloaded ghost for its course (personal bests stay), for
// KartPadSaveStorage.writePendingGhost to stage.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_kartpad_android_screens_GhostsNative_nativeImportGhost(JNIEnv *env, jobject, jbyteArray save, jbyteArray rkg,
                                                               jint license) {
  return Guard(env, [&]() -> jbyteArray {
    const auto bytes = Copy(env, save, ghost::SaveBytes, kNoSave);
    const auto data = Copy(env, rkg, ghost::GhostBytes, kNoGhost);
    ghost::Require(license >= 0 && license < 4, "Choose an initialized license");
    return ByteArray(env, ghost::Import(bytes, data, unsigned(license)));
  });
}
