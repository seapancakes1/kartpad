// The Mii editor's tables and record edits for Android's MiiEditorScreen, from the shared headers the
// Apple editor uses (runtime/include/kartpad/mii/appearance.h, editor.h, body.h, portrait.h): the 46
// fields and their ranges, Mii Channel tile order, the per-category layout tables, look-alikes,
// birthdays, the build name and names in the record. No game data; header-only, so it builds in the
// source-only fixture too. Records are 74 bytes; anything else throws IllegalArgumentException.
#include <jni.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <exception>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "kartpad/mii/body.h"
#include "kartpad/mii/editor.h"
// portrait.h has an unused lambda parameter; only its colour tables are used here.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "kartpad/mii/portrait.h"
#pragma clang diagnostic pop

namespace {

using namespace kartpad::mii;

constexpr jint kNone = -1;

struct Invalid : std::exception {
  const char* what() const noexcept override { return "A Mii must contain exactly 74 bytes."; }
};

void Throw(JNIEnv* env, const char* message) {
  if (env->ExceptionCheck()) return;
  if (jclass type = env->FindClass("java/lang/IllegalArgumentException")) env->ThrowNew(type, message);
}

Appearance Read(JNIEnv* env, jbyteArray record) {
  if (!record || env->GetArrayLength(record) != jsize(kMiiBlockSize)) throw Invalid();
  Appearance a;
  env->GetByteArrayRegion(record, 0, jsize(kMiiBlockSize), reinterpret_cast<jbyte*>(a.bytes.data()));
  return a;
}

void Write(JNIEnv* env, jbyteArray record, const Appearance& a) {
  env->SetByteArrayRegion(record, 0, jsize(kMiiBlockSize), reinterpret_cast<const jbyte*>(a.bytes.data()));
}

jbyteArray NewRecord(JNIEnv* env, const Appearance& a) {
  jbyteArray out = env->NewByteArray(jsize(kMiiBlockSize));
  if (out) Write(env, out, a);
  return out;
}

jintArray Ints(JNIEnv* env, const std::vector<jint>& values) {
  jintArray out = env->NewIntArray(jsize(values.size()));
  if (out && !values.empty()) env->SetIntArrayRegion(out, 0, jsize(values.size()), values.data());
  return out;
}

jobjectArray Strings(JNIEnv* env, const std::vector<const char*>& values) {
  jclass type = env->FindClass("java/lang/String");
  if (!type) return nullptr;
  jobjectArray out = env->NewObjectArray(jsize(values.size()), type, nullptr);
  for (size_t i = 0; out && i < values.size(); i++) {
    jstring text = env->NewStringUTF(values[i]);
    if (!text) return nullptr;
    env->SetObjectArrayElement(out, jsize(i), text);
    env->DeleteLocalRef(text);
  }
  return out;
}

bool Field(jint field) { return field >= 0 && size_t(field) < AppearanceFields.size(); }
bool Category(jint category) { return category >= 0 && size_t(category) < EditorCategories.size(); }

// Runs body, turning C++ failures into IllegalArgumentException; fallback when one is thrown.
template <class T, class F> T Guard(JNIEnv* env, T fallback, F body) {
  try {
    return body();
  } catch (const std::exception& error) {
    Throw(env, error.what());
  } catch (...) {
    Throw(env, "Invalid Mii.");
  }
  return fallback;
}

// The name at offset 2 (nickname) or 54 (creator): up to 10 UTF-16 units, as ReadMiiName reads
// it (control characters and unpaired surrogates dropped), kept as UTF-16 so emoji survive JNI.
std::vector<jchar> NameUnits(const Appearance& a, size_t offset) {
  std::vector<jchar> out;
  for (size_t i = 0; i < 10; i++) {
    const uint16_t unit = ReadBigEndian16(a.bytes, offset + i * 2);
    if (unit == 0) break;
    if (unit >= 0xD800u && unit <= 0xDBFFu && i + 1 < 10) {
      const uint16_t low = ReadBigEndian16(a.bytes, offset + (i + 1) * 2);
      if (low >= 0xDC00u && low <= 0xDFFFu) {
        out.push_back(jchar(unit));
        out.push_back(jchar(low));
        i++;
        continue;
      }
    }
    if (unit < 0x20u || (unit >= 0xD800u && unit <= 0xDFFFu)) continue;
    out.push_back(jchar(unit));
  }
  return out;
}

unsigned ChipColor(unsigned field, unsigned value) {
  Color color;
  switch (field) {
  case 3: color = At(Shirt, value); break;
  case 8: color = At(Skin, value); break;
  case 17: color = At(Eyes, value); break;
  case 30: color = At(Lip0, value); break;
  case 34: color = At(Glasses, value); break;
  default: color = At(Hair, value); break;  // Hair, eyebrow and facial-hair colours.
  }
  return unsigned(color[0]) << 16 | unsigned(color[1]) << 8 | color[2];
}

}  // namespace

#define KP_EDITOR(name) Java_dev_kartpad_android_screens_mii_MiiEditorNative_##name

extern "C" {

// [minimum, maximum] for each of the 46 fields, in AppearanceFields order.
JNIEXPORT jintArray JNICALL KP_EDITOR(nativeFieldLimits)(JNIEnv* env, jobject) {
  std::vector<jint> out;
  for (const auto& f : AppearanceFields) {
    out.push_back(jint(f.minimum));
    out.push_back(jint(f.maximum));
  }
  return Ints(env, out);
}

JNIEXPORT jobjectArray JNICALL KP_EDITOR(nativeFieldNames)(JNIEnv* env, jobject) {
  std::vector<const char*> names;
  for (const auto& f : AppearanceFields) names.push_back(f.name);
  return Strings(env, names);
}

// Every field as stored, or clamped to its range (what the editor shows).
JNIEXPORT jintArray JNICALL KP_EDITOR(nativeValues)(JNIEnv* env, jobject, jbyteArray record, jboolean clamped) {
  return Guard<jintArray>(env, nullptr, [&] {
    const auto a = Read(env, record);
    std::vector<jint> out;
    for (size_t i = 0; i < AppearanceFields.size(); i++) out.push_back(jint(clamped ? a.Clamped(i) : a.Get(i)));
    return Ints(env, out);
  });
}

// Sets a field in place; false (and the record untouched) when the value is out of its range.
JNIEXPORT jboolean JNICALL KP_EDITOR(nativeSet)(JNIEnv* env, jobject, jbyteArray record, jint field, jint value) {
  return Guard<jboolean>(env, JNI_FALSE, [&] {
    auto a = Read(env, record);
    if (!Field(field) || value < 0) return JNI_FALSE;
    const auto& f = AppearanceFields[size_t(field)];
    if (unsigned(value) < f.minimum || unsigned(value) > f.maximum) return JNI_FALSE;
    a.Set(size_t(field), unsigned(value));
    Write(env, record, a);
    return JNI_TRUE;
  });
}

// A copy with every field at its nearest valid value (a duplicate, or what the tiles draw).
JNIEXPORT jbyteArray JNICALL KP_EDITOR(nativeInRange)(JNIEnv* env, jobject, jbyteArray record) {
  return Guard<jbyteArray>(env, nullptr, [&] { return NewRecord(env, Read(env, record).InRange()); });
}

// A field's tiles in Mii Channel order, 12 to a page; empty for fields without tiles.
JNIEXPORT jintArray JNICALL KP_EDITOR(nativeFeatureIds)(JNIEnv* env, jobject, jint field) {
  std::vector<jint> out;
  if (field >= 0)
    for (unsigned id : FeatureIds(unsigned(field))) out.push_back(jint(id));
  return Ints(env, out);
}

JNIEXPORT jint JNICALL KP_EDITOR(nativeFeaturePage)(JNIEnv*, jobject, jint field, jint value) {
  return field < 0 || value < 0 ? 0 : jint(FeaturePage(unsigned(field), unsigned(value)));
}

// Each category's feature field (0 for Profile and Body).
JNIEXPORT jintArray JNICALL KP_EDITOR(nativePrimaryFeatures)(JNIEnv* env, jobject) {
  return Ints(env, std::vector<jint>(PrimaryFeatures.begin(), PrimaryFeatures.end()));
}

JNIEXPORT jobjectArray JNICALL KP_EDITOR(nativeCategories)(JNIEnv* env, jobject) {
  return Strings(env, std::vector<const char*>(EditorCategories.begin(), EditorCategories.end()));
}

JNIEXPORT jint JNICALL KP_EDITOR(nativeColorField)(JNIEnv*, jobject, jint category) {
  if (!Category(category)) return kNone;
  const unsigned field = CategoryColorField(unsigned(category));
  return field == NoField ? kNone : jint(field);
}

// A two-part switch's fields (Shape/Details, Mustache/Beard) and their titles; empty elsewhere.
JNIEXPORT jintArray JNICALL KP_EDITOR(nativeModeFields)(JNIEnv* env, jobject, jint category) {
  std::vector<jint> out;
  if (Category(category))
    for (const auto& mode : CategoryModes(unsigned(category))) out.push_back(jint(mode.field));
  return Ints(env, out);
}

JNIEXPORT jobjectArray JNICALL KP_EDITOR(nativeModeTitles)(JNIEnv* env, jobject, jint category) {
  std::vector<const char*> out;
  if (Category(category))
    for (const auto& mode : CategoryModes(unsigned(category))) out.push_back(mode.title);
  return Strings(env, out);
}

// Flip hair (Hair) and Mole (Facial hair); -1 and "" elsewhere.
JNIEXPORT jint JNICALL KP_EDITOR(nativeToggleField)(JNIEnv*, jobject, jint category) {
  if (!Category(category)) return kNone;
  const unsigned field = CategoryToggleField(unsigned(category));
  return field == NoField ? kNone : jint(field);
}

JNIEXPORT jstring JNICALL KP_EDITOR(nativeToggleTitle)(JNIEnv* env, jobject, jint category) {
  return env->NewStringUTF(Category(category) ? CategoryToggleTitle(unsigned(category)) : "");
}

// The adjustments a category shows for this Mii (Facial hair's depend on the mole), their fields...
JNIEXPORT jintArray JNICALL KP_EDITOR(nativeAdjustmentFields)(JNIEnv* env, jobject, jint category, jbyteArray record) {
  return Guard<jintArray>(env, nullptr, [&] {
    const auto a = Read(env, record);
    std::vector<jint> out;
    if (Category(category))
      for (const auto& adjustment : CategoryAdjustments(unsigned(category), a)) out.push_back(jint(adjustment.field));
    return Ints(env, out);
  });
}

// ...and title, less and more, three to an adjustment.
JNIEXPORT jobjectArray JNICALL KP_EDITOR(nativeAdjustmentTitles)(JNIEnv* env, jobject, jint category, jbyteArray record) {
  return Guard<jobjectArray>(env, nullptr, [&] {
    const auto a = Read(env, record);
    std::vector<const char*> out;
    if (Category(category))
      for (const auto& adjustment : CategoryAdjustments(unsigned(category), a)) {
        out.push_back(adjustment.title);
        out.push_back(adjustment.less);
        out.push_back(adjustment.more);
      }
    return Strings(env, out);
  });
}

// Create Mii's random face on base (its identity, names and birthday stay); one seed, one face.
JNIEXPORT jbyteArray JNICALL KP_EDITOR(nativeLookAlike)(JNIEnv* env, jobject, jbyteArray base, jint gender, jint seed) {
  return Guard<jbyteArray>(env, nullptr, [&] {
    return NewRecord(env, LookAlike(Read(env, base), gender ? 1u : 0u, uint32_t(seed)));
  });
}

// Days in a month (February has 29: the record has no year); 0 for Not set.
JNIEXPORT jint JNICALL KP_EDITOR(nativeBirthdayDays)(JNIEnv*, jobject, jint month) {
  return month < 0 ? 0 : jint(BirthdayDays(unsigned(month)));
}

// The body model height + weight pick, as the Body page names it.
JNIEXPORT jstring JNICALL KP_EDITOR(nativeBuildName)(JNIEnv* env, jobject, jbyteArray record) {
  return Guard<jstring>(env, nullptr, [&] {
    const auto a = Read(env, record);
    const auto build = BuildFor(a.Clamped(5), a.Clamped(6));
    return env->NewStringUTF(build == MiiBuild::Small ? "Small build" : build == MiiBuild::Medium ? "Medium build" : "Large build");
  });
}

// The nickname (offset 2) or creator (54).
JNIEXPORT jstring JNICALL KP_EDITOR(nativeName)(JNIEnv* env, jobject, jbyteArray record, jint offset) {
  return Guard<jstring>(env, nullptr, [&] {
    const auto a = Read(env, record);
    if (offset != 2 && offset != 54) throw std::invalid_argument("Invalid Mii name field.");
    const auto units = NameUnits(a, size_t(offset));
    static const jchar empty = 0;
    return env->NewString(units.empty() ? &empty : units.data(), jsize(units.size()));
  });
}

// Stores a name in place as UTF-16BE, zero-filled. False (record untouched) when it doesn't fit in
// 10 units or has a character a Mii can't use; an empty name is stored as empty.
JNIEXPORT jboolean JNICALL KP_EDITOR(nativeSetName)(JNIEnv* env, jobject, jbyteArray record, jint offset, jstring name) {
  return Guard<jboolean>(env, JNI_FALSE, [&] {
    auto a = Read(env, record);
    if ((offset != 2 && offset != 54) || !name) return JNI_FALSE;
    const jsize length = env->GetStringLength(name);
    if (length > jsize(kMiiNameByteSize / 2)) return JNI_FALSE;
    std::array<jchar, kMiiNameByteSize / 2> units{};
    env->GetStringRegion(name, 0, length, units.data());
    std::array<uint8_t, kMiiNameByteSize> bytes{};
    for (jsize i = 0; i < length; i++) {
      bytes[size_t(i) * 2] = uint8_t(units[size_t(i)] >> 8);
      bytes[size_t(i) * 2 + 1] = uint8_t(units[size_t(i)]);
    }
    if (length && !ValidateUtf16BigEndianName(std::span<const uint8_t>(bytes.data(), size_t(length) * 2))) return JNI_FALSE;
    std::copy(bytes.begin(), bytes.end(), a.bytes.begin() + offset);
    Write(env, record, a);
    return JNI_TRUE;
  });
}

// Why the record can't be stored or exported, or null. With previous (the Mii an edit replaces),
// fields it already had out of range may stay so.
JNIEXPORT jstring JNICALL KP_EDITOR(nativeValidate)(JNIEnv* env, jobject, jbyteArray record, jbyteArray previous) {
  try {
    const auto a = Read(env, record);
    DatabaseResult result;
    if (previous) {
      const auto before = Read(env, previous);
      result = a.Validate(&before);
    } else {
      result = a.Validate();
    }
    return result ? nullptr : env->NewStringUTF(result.message.c_str());
  } catch (const std::exception& error) {
    return env->NewStringUTF(error.what());
  }
}

// A colour chip as 0xRRGGBB: favorite (3), skin (8), eye (17), lip (30), glasses (34), else hair.
JNIEXPORT jint JNICALL KP_EDITOR(nativeColor)(JNIEnv*, jobject, jint field, jint value) {
  return jint(ChipColor(unsigned(std::max(field, 0)), unsigned(std::max(value, 0))));
}

}  // extern "C"
