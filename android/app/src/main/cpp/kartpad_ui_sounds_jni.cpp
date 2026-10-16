// HOME and Mii editor sounds: Mario Kart Wii menu cues (kartpad::mii::EditorSound) rendered from the
// player's imported files/sound/revo_kart.brsar. Nothing is cached on disk or shipped.
// Apple counterpart: apple/shared/KartPadMiiSounds.inc.mm.
#include <fcntl.h>
#include <jni.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "kartpad/audio/sound_archive.h"
#include "kartpad/mii/editor_sounds.h"

namespace {

// The archive is about 100 MB: map it, so only the pages these sounds read are loaded.
class MappedFile {
 public:
  explicit MappedFile(const std::string& path) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) throw std::runtime_error("Sound archive unavailable.");
    struct stat info {};
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0) {
      size_ = size_t(info.st_size);
      void* data = mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, fd, 0);
      data_ = data == MAP_FAILED ? nullptr : data;
    }
    close(fd);
    if (!data_) throw std::runtime_error("Sound archive unavailable.");
  }
  MappedFile(const MappedFile&) = delete;
  MappedFile& operator=(const MappedFile&) = delete;
  ~MappedFile() { munmap(data_, size_); }
  std::span<const uint8_t> Bytes() const { return {static_cast<const uint8_t*>(data_), size_}; }

 private:
  void* data_ = nullptr;
  size_t size_ = 0;
};

// One clip per EditorSound, 32 kHz interleaved stereo; empty for a sound that didn't render.
std::vector<std::vector<int16_t>> RenderEditorSounds(const std::string& path) {
  MappedFile file(path);
  kartpad::audio::SoundArchive sounds(file.Bytes());
  std::vector<std::vector<int16_t>> clips;
  for (const char* name : kartpad::mii::EditorSoundNames) {
    try {
      auto pcm = sounds.Render(name);
      clips.push_back(pcm.rate == 32000 ? std::move(pcm.samples) : std::vector<int16_t>{});
    } catch (const std::exception&) {
      clips.emplace_back();  // That one sound stays silent.
    }
  }
  return clips;
}

}  // namespace

// short[EditorSound::Count], null where a sound didn't render. Throws when the archive can't be read.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_screens_KartPadUISounds_nativeRender(JNIEnv* env, jobject, jstring path_string) {
  std::string path;
  if (const char* raw = path_string ? env->GetStringUTFChars(path_string, nullptr) : nullptr) {
    path = raw;
    env->ReleaseStringUTFChars(path_string, raw);
  }
  std::vector<std::vector<int16_t>> clips;
  try {
    clips = RenderEditorSounds(path);
  } catch (const std::exception& error) {
    if (jclass type = env->FindClass("java/lang/IllegalStateException")) env->ThrowNew(type, error.what());
    return nullptr;
  }
  jclass shorts = env->FindClass("[S");
  if (!shorts) return nullptr;
  jobjectArray result = env->NewObjectArray(jsize(clips.size()), shorts, nullptr);
  for (size_t i = 0; result && i < clips.size(); i++) {
    if (clips[i].empty()) continue;
    jshortArray clip = env->NewShortArray(jsize(clips[i].size()));
    if (!clip) return nullptr;
    env->SetShortArrayRegion(clip, 0, jsize(clips[i].size()), clips[i].data());
    env->SetObjectArrayElement(result, jsize(i), clip);
    env->DeleteLocalRef(clip);
  }
  return result;
}
