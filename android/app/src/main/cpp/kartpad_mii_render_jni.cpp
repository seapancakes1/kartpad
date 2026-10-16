// Mii portraits, feature tiles and preview scenes for the Android screens, drawn from the
// player's imported RFLRes01.arc and MiiBody.szs. Apple counterpart:
// apple/shared/KartPadMiiEditor.inc.mm (resource loading, KPMiiFeatureImage, KPMiiTileInputs).
#include <android/bitmap.h>
#include <jni.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "kartpad/mii/scene.h"

namespace {

using namespace kartpad::mii;

constexpr const char* kUnavailable = "Preview resources unavailable. Reimport your game-data folder.";

// Path, size and modification time: an unchanged file isn't read again.
std::string Stamp(const std::string& path) {
  std::error_code error;
  const auto size = std::filesystem::file_size(path, error);
  if (path.empty() || error) return path + "|missing";
  const auto time = std::filesystem::last_write_time(path, error);
  if (error) return path + "|missing";
  return path + "|" + std::to_string(size) + "|" + std::to_string(std::chrono::duration_cast<std::chrono::nanoseconds>(time.time_since_epoch()).count());
}

std::vector<uint8_t> ReadFile(const std::string& path) {
  std::ifstream in(path, std::ios::binary | std::ios::ate);
  if (!in) return {};
  const auto size = static_cast<std::streamoff>(in.tellg());
  if (size <= 0 || size > 64 * 1024 * 1024) throw std::runtime_error(kUnavailable);
  std::vector<uint8_t> data(static_cast<size_t>(size));
  in.seekg(0);
  if (!in.read(reinterpret_cast<char*>(data.data()), size)) throw std::runtime_error(kUnavailable);
  return data;
}

// Resources decodes lazily into mutable maps, so every use (portraits, tiles, scene builds)
// holds this lock. MiiImages' single worker is the only caller in practice.
std::mutex g_lock;

template <class T> struct Loaded {
  std::shared_ptr<const T> value;
  std::string stamp, failedStamp, failure;
};
Loaded<Resources> g_faces;
Loaded<BodyResources> g_bodies;

// A missing or damaged archive fails again without being read until the file changes.
const Resources& Faces(const std::string& path) {
  const auto now = Stamp(path);
  if (g_faces.value && now == g_faces.stamp) return *g_faces.value;
  if (!g_faces.failure.empty() && now == g_faces.failedStamp) throw std::runtime_error(g_faces.failure);
  try {
    const auto data = ReadFile(path);
    if (data.empty()) throw std::runtime_error(kUnavailable);
    auto next = std::make_shared<const Resources>(std::span<const uint8_t>(data));
    g_faces = {next, now, {}, {}};
    return *next;
  } catch (const std::exception& error) {
    g_faces = {nullptr, {}, now, error.what()};
    throw;
  }
}

// Without a usable body archive the preview keeps the head.
const BodyResources* Bodies(const std::string& path) {
  const auto now = Stamp(path);
  if (g_bodies.value && now == g_bodies.stamp) return g_bodies.value.get();
  if (!g_bodies.failure.empty() && now == g_bodies.failedStamp) return nullptr;
  try {
    const auto data = ReadFile(path);
    if (data.empty()) throw std::runtime_error("Body missing.");
    g_bodies = {std::make_shared<const BodyResources>(std::span<const uint8_t>(data)), now, {}, {}};
    return g_bodies.value.get();
  } catch (const std::exception& error) {
    g_bodies = {nullptr, {}, now, error.what()};
    return nullptr;
  }
}

// Premultiplied RGBA, as Android bitmaps hold it.
struct Pixels {
  unsigned width = 0, height = 0;
  std::vector<uint8_t> rgba;
};

// One axis of an area-averaging shrink: per output index, the source indices and their weights.
std::vector<std::vector<std::pair<unsigned, float>>> Weights(unsigned from, unsigned to) {
  std::vector<std::vector<std::pair<unsigned, float>>> out(to);
  const double step = double(from) / to;
  for (unsigned d = 0; d < to; d++) {
    const double low = d * step, high = (d + 1) * step;
    for (unsigned s = unsigned(low); s < from && s < high; s++)
      out[d].push_back({s, float((std::min(high, s + 1.) - std::max(low, double(s))) / step)});
  }
  return out;
}

// KPMiiImageFromPixels: cropHead keeps the drawn pixels plus a margin, in pixels of their own.
// Larger results are shrunk to maxSize on their longer side (0 keeps the full size).
Pixels ToPixels(const Image& image, bool cropHead, unsigned maxSize) {
  unsigned x0 = 0, y0 = 0, x1 = image.width, y1 = image.height;
  if (cropHead) {
    unsigned left = image.width, top = image.height, right = 0, bottom = 0;
    for (unsigned y = 0; y < image.height; y++)
      for (unsigned x = 0; x < image.width; x++)
        if (image.rgba[(y * image.width + x) * 4 + 3] > 4) {
          left = std::min(left, x); right = std::max(right, x);
          top = std::min(top, y); bottom = std::max(bottom, y);
        }
    if (left <= right) {
      const auto pad = unsigned(std::max(2., std::round(std::max(image.width, image.height) * .05)));
      x0 = left > pad ? left - pad : 0; y0 = top > pad ? top - pad : 0;
      x1 = std::min(image.width, right + 1 + pad); y1 = std::min(image.height, bottom + 1 + pad);
    }
  }
  Pixels out{x1 - x0, y1 - y0, {}};
  out.rgba.resize(size_t(out.width) * out.height * 4);
  for (unsigned y = 0; y < out.height; y++)
    for (unsigned x = 0; x < out.width; x++) {
      const uint8_t* p = &image.rgba[((y + y0) * image.width + x + x0) * 4];
      uint8_t* q = &out.rgba[(size_t(y) * out.width + x) * 4];
      for (unsigned c = 0; c < 3; c++) q[c] = uint8_t((unsigned(p[c]) * p[3] + 127) / 255);
      q[3] = p[3];
    }
  const unsigned longest = std::max(out.width, out.height);
  if (!maxSize || longest <= maxSize) return out;
  const unsigned w = std::max(1u, unsigned(std::lround(double(out.width) * maxSize / longest))),
                 h = std::max(1u, unsigned(std::lround(double(out.height) * maxSize / longest)));
  const auto across = Weights(out.width, w), down = Weights(out.height, h);
  std::vector<float> rows(size_t(w) * out.height * 4);
  for (unsigned y = 0; y < out.height; y++)
    for (unsigned x = 0; x < w; x++)
      for (auto [s, weight] : across[x])
        for (unsigned c = 0; c < 4; c++)
          rows[(size_t(y) * w + x) * 4 + c] += out.rgba[(size_t(y) * out.width + s) * 4 + c] * weight;
  Pixels small{w, h, std::vector<uint8_t>(size_t(w) * h * 4)};
  for (unsigned y = 0; y < h; y++)
    for (unsigned x = 0; x < w; x++)
      for (unsigned c = 0; c < 4; c++) {
        float sum = 0;
        for (auto [s, weight] : down[y]) sum += rows[(size_t(s) * w + x) * 4 + c] * weight;
        small.rgba[(size_t(y) * w + x) * 4 + c] = uint8_t(std::clamp(std::lround(sum), 0l, 255l));
      }
  return small;
}

// KPMiiFeatureImage: tiles show each feature in the Mii's own colours, as the Mii Channel does.
// Nothing for "none" (no glasses, mustache or beard). The bool says whether to crop.
std::optional<std::pair<Image, bool>> FeatureImage(const Resources& r, unsigned field, unsigned value,
                                                   const Appearance& current) {
  // Feature textures sit off-centre in their canvases; crop to the drawn pixels so tiles centre them.
  if (field == 14) {
    const Color first = value == 9 ? Color{255, 130, 0} : value == 20 ? Color{0, 255, 255} : Color{0, 0, 0};
    return {{Portrait::ColorMask(r.Texture(1, value), first, At(Eyes, current.Clamped(17))), true}};
  }
  if (field == 20) {
    Image image = r.Texture(2, value);
    const Color color = At(Hair, current.Clamped(22));
    for (size_t i = 0; i < image.rgba.size(); i += 4)
      for (int c = 0; c < 3; c++) image.rgba[i + c] = color[c];
    return {{std::move(image), true}};
  }
  if (field == 29)
    return {{Portrait::ColorMask(r.Texture(11, value), At(Lip0, current.Clamped(30)),
                                 At(Lip1, current.Clamped(30))), true}};
  if ((field == 33 || field == 37 || field == 38) && value == 0) return std::nullopt;
  if ((field == 33 || field == 37) && value)
    return {{Portrait::AccessoryThumbnail(r, field, value, current.Clamped(field == 33 ? 34 : 39)), true}};
  // Face shapes share one framing (no per-tile crop) so their outlines can be compared.
  if (field == 7) return {{Portrait::FaceShapeThumbnail(r, value, At(Skin, current.Clamped(8))), false}};
  // Other features sit on the Mii's own face shape so tiles match the preview.
  auto a = Appearance::Decode(CreateDefaultMii({0, 0, 0, 0, 0, 0}));
  a.Set(field, value);
  a.Set(7, current.Clamped(7)); a.Set(8, current.Clamped(8));
  a.Set(12, current.Clamped(12)); a.Set(39, current.Clamped(39));
  if (field == 9) a.Set(11, 30);
  return {{Portrait::Render(r, a), true}};
}

// KPMiiTileInputs: the face shape and colours a field's tiles are drawn with, for cache keys.
std::string TileInputs(unsigned field, const Appearance& a) {
  auto n = [&](size_t f) { return std::to_string(a.Clamped(f)); };
  switch (field) {
    case 7: return n(8);
    case 14: return n(17);
    case 20: return n(22);
    case 29: return n(30);
    case 33: return n(34);
    case 37: return n(39);
    default: return n(7) + "." + n(8) + "." + n(12) + "." + n(39);
  }
}

Pixels RenderPortrait(const std::string& faces, std::span<const uint8_t> mii, unsigned maxSize) {
  const auto appearance = Appearance::Decode(mii);
  std::lock_guard hold(g_lock);
  return ToPixels(Portrait::Render(Faces(faces), appearance), true, maxSize);
}

std::optional<Pixels> RenderFeatureTile(const std::string& faces, unsigned field, unsigned value,
                                        std::span<const uint8_t> mii, unsigned maxSize) {
  const auto appearance = Appearance::Decode(mii);
  std::lock_guard hold(g_lock);
  auto image = FeatureImage(Faces(faces), field, value, appearance);
  if (!image) return std::nullopt;
  return ToPixels(image->first, image->second, maxSize);
}

std::unique_ptr<PreviewScene> BuildScene(const std::string& faces, const std::string& bodies,
                                         std::span<const uint8_t> mii) {
  const auto appearance = Appearance::Decode(mii);
  std::lock_guard hold(g_lock);
  const auto& resources = Faces(faces);
  return std::make_unique<PreviewScene>(PreviewScene::Build(resources, appearance, Bodies(bodies)));
}

std::optional<std::string> UnavailableReason(const std::string& faces) {
  std::lock_guard hold(g_lock);
  try {
    (void)Faces(faces);
    return std::nullopt;
  } catch (const std::exception& error) {
    return std::string(error.what());
  }
}

// JNI plumbing.
std::string ToString(JNIEnv* env, jstring value) {
  if (!value) return {};
  const char* raw = env->GetStringUTFChars(value, nullptr);
  if (!raw) return {};
  std::string out(raw);
  env->ReleaseStringUTFChars(value, raw);
  return out;
}

std::vector<uint8_t> ToBytes(JNIEnv* env, jbyteArray array) {
  if (!array) return {};
  std::vector<uint8_t> bytes(static_cast<size_t>(env->GetArrayLength(array)));
  if (!bytes.empty())
    env->GetByteArrayRegion(array, 0, jsize(bytes.size()), reinterpret_cast<jbyte*>(bytes.data()));
  return bytes;
}

void Throw(JNIEnv* env, const char* message) {
  if (env->ExceptionCheck()) return;
  if (jclass type = env->FindClass("java/lang/IllegalStateException")) env->ThrowNew(type, message);
}

jobject ToBitmap(JNIEnv* env, const Pixels& pixels) {
  jclass bitmapClass = env->FindClass("android/graphics/Bitmap");
  jclass configClass = env->FindClass("android/graphics/Bitmap$Config");
  if (!bitmapClass || !configClass) return nullptr;
  jfieldID argb = env->GetStaticFieldID(configClass, "ARGB_8888", "Landroid/graphics/Bitmap$Config;");
  jmethodID create = env->GetStaticMethodID(bitmapClass, "createBitmap",
      "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
  if (!argb || !create) return nullptr;
  jobject config = env->GetStaticObjectField(configClass, argb);
  jobject bitmap = env->CallStaticObjectMethod(bitmapClass, create, jint(pixels.width), jint(pixels.height), config);
  if (!bitmap || env->ExceptionCheck()) return nullptr;
  AndroidBitmapInfo info{};
  void* target = nullptr;
  if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
      info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width != pixels.width ||
      info.height != pixels.height || info.stride < pixels.width * 4 ||
      AndroidBitmap_lockPixels(env, bitmap, &target) != ANDROID_BITMAP_RESULT_SUCCESS || !target) {
    Throw(env, "The Mii image couldn't be drawn.");
    return nullptr;
  }
  for (unsigned y = 0; y < pixels.height; y++)
    std::memcpy(static_cast<uint8_t*>(target) + size_t(y) * info.stride,
                pixels.rgba.data() + size_t(y) * pixels.width * 4, size_t(pixels.width) * 4);
  AndroidBitmap_unlockPixels(env, bitmap);
  return bitmap;
}

}  // namespace

// The reason portraits can't be drawn (missing or damaged RFLRes01.arc), or null.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativeUnavailableReason(JNIEnv* env, jobject, jstring faces) {
  const auto reason = UnavailableReason(ToString(env, faces));
  return reason ? env->NewStringUTF(reason->c_str()) : nullptr;
}

// A head portrait cropped to the drawn pixels. Throws IllegalStateException with the reason.
extern "C" JNIEXPORT jobject JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePortrait(
    JNIEnv* env, jobject, jstring faces, jbyteArray mii, jint maxSize) {
  try {
    const auto pixels = RenderPortrait(ToString(env, faces), ToBytes(env, mii), unsigned(std::max(0, maxSize)));
    return ToBitmap(env, pixels);
  } catch (const std::exception& error) {
    Throw(env, error.what());
  } catch (...) {
    Throw(env, "The Mii portrait couldn't be drawn.");
  }
  return nullptr;
}

// One editor tile in the Mii's current colours; null for "none" tiles.
extern "C" JNIEXPORT jobject JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativeFeatureTile(
    JNIEnv* env, jobject, jstring faces, jint field, jint value, jbyteArray mii, jint maxSize) {
  try {
    if (field < 0 || field >= jint(AppearanceFields.size()) || value < 0) throw std::invalid_argument("Invalid Mii feature.");
    const auto pixels = RenderFeatureTile(ToString(env, faces), unsigned(field), unsigned(value),
                                          ToBytes(env, mii), unsigned(std::max(0, maxSize)));
    return pixels ? ToBitmap(env, *pixels) : nullptr;
  } catch (const std::exception& error) {
    Throw(env, error.what());
  } catch (...) {
    Throw(env, "The Mii feature couldn't be drawn.");
  }
  return nullptr;
}

// The inputs a field's tiles depend on (part of the tile cache key).
extern "C" JNIEXPORT jstring JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativeTileInputs(JNIEnv* env, jobject, jint field, jbyteArray mii) {
  try {
    return env->NewStringUTF(TileInputs(unsigned(std::max(0, field)), Appearance::Decode(ToBytes(env, mii))).c_str());
  } catch (const std::exception& error) {
    Throw(env, error.what());
  }
  return nullptr;
}

// A preview scene for kartpad_mii_preview_gl.cpp, owned by the caller until installed or released.
extern "C" JNIEXPORT jlong JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativeBuildScene(
    JNIEnv* env, jobject, jstring faces, jstring bodies, jbyteArray mii) {
  try {
    return reinterpret_cast<jlong>(BuildScene(ToString(env, faces), ToString(env, bodies), ToBytes(env, mii)).release());
  } catch (const std::exception& error) {
    Throw(env, error.what());
  } catch (...) {
    Throw(env, "The Mii preview couldn't be built.");
  }
  return 0;
}

// False when MiiBody.szs is missing or unusable and the scene is the head alone.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativeSceneHasBody(JNIEnv*, jobject, jlong scene) {
  const auto* value = reinterpret_cast<const PreviewScene*>(scene);
  return value && std::any_of(value->parts.begin(), value->parts.end(), [](const auto& part) { return part.bodyPart; });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativeReleaseScene(JNIEnv*, jobject, jlong scene) {
  delete reinterpret_cast<PreviewScene*>(scene);
}
