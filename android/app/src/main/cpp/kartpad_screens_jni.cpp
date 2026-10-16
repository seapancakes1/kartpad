#include <jni.h>

#include <algorithm>
#include <cstring>

#include "kartpad/android/host_screens.hpp"

// dev.kartpad.android.screens.KartPadHostScreens: KartPad's screens reach the game thread's side
// (runtime/src/android/host_screens.cpp, or host_screens_fixture.cpp in the fixture app).
namespace screens = kartpad::android::screens;

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeSetOpen(JNIEnv*, jobject, jboolean open) {
  screens::SetScreensOpen(open == JNI_TRUE);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeHoldState(JNIEnv*, jobject) {
  return static_cast<jint>(screens::CurrentHoldState());
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeGameState(JNIEnv*, jobject) {
  return screens::GameState();
}

// Fills a direct buffer with kPadRecordBytes per pad; returns how many.
extern "C" JNIEXPORT jint JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeReadPads(JNIEnv* env, jobject, jobject buffer) {
  auto* bytes = static_cast<uint8_t*>(env->GetDirectBufferAddress(buffer));
  const jlong capacity = env->GetDirectBufferCapacity(buffer);
  if (bytes == nullptr || capacity < static_cast<jlong>(screens::kPadRecordBytes)) return 0;
  screens::PadRecord pads[screens::kMaxPads];
  const std::size_t fit = std::min<std::size_t>(screens::kMaxPads,
                                                static_cast<std::size_t>(capacity) / screens::kPadRecordBytes);
  const std::size_t count = screens::ReadPads(pads, fit);
  std::memcpy(bytes, pads, count * screens::kPadRecordBytes);
  return static_cast<jint>(count);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeEventFd(JNIEnv*, jobject) {
  return screens::EventFd();
}

// Pairs of (kind, arg).
extern "C" JNIEXPORT jintArray JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeTakeEvents(JNIEnv* env, jobject) {
  const auto events = screens::TakeEvents();
  jintArray out = env->NewIntArray(static_cast<jsize>(events.size() * 2));
  if (out == nullptr) return nullptr;
  for (std::size_t index = 0; index < events.size(); ++index) {
    const jint pair[2] = {static_cast<jint>(events[index].kind), events[index].arg};
    env->SetIntArrayRegion(out, static_cast<jsize>(index * 2), 2, pair);
  }
  return out;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeRumble(
    JNIEnv*, jobject, jint instance, jint low, jint high, jint millis) {
  screens::Rumble(static_cast<uint32_t>(instance), static_cast<uint16_t>(std::clamp(low, 0, 0xffff)),
                  static_cast<uint16_t>(std::clamp(high, 0, 0xffff)),
                  static_cast<uint32_t>(std::max(millis, 0)));
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeSetLight(JNIEnv*, jobject, jint instance, jint rgb) {
  screens::SetLight(static_cast<uint32_t>(instance), static_cast<uint8_t>(rgb >> 16),
                    static_cast<uint8_t>(rgb >> 8), static_cast<uint8_t>(rgb));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeAssign(JNIEnv*, jobject, jint instance, jint player) {
  if (player < 0) return JNI_FALSE;
  return screens::Assign(static_cast<uint32_t>(instance), static_cast<uint32_t>(player)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeClearPlayer(JNIEnv*, jobject, jint player) {
  if (player < 0) return JNI_FALSE;
  return screens::ClearPlayer(static_cast<uint32_t>(player)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_KartPadHostScreens_nativeQaPress(JNIEnv*, jobject, jint button, jboolean down) {
  screens::QaPress(button, down == JNI_TRUE);
}
