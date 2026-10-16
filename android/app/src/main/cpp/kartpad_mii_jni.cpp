#include <jni.h>

#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "kartpad/mii/mii_database.h"
#include "kartpad/mii/player_identity.h"

namespace {

std::vector<uint8_t> CopyBytes(JNIEnv* env, jbyteArray array) {
  if (array == nullptr) return {};
  const jsize size = env->GetArrayLength(array);
  std::vector<uint8_t> bytes(static_cast<std::size_t>(size));
  if (size != 0) {
    env->GetByteArrayRegion(array, 0, size,
                            reinterpret_cast<jbyte*>(bytes.data()));
  }
  return bytes;
}

void Throw(JNIEnv* env, const char* type, const std::string& message) {
  if (jclass exception = env->FindClass(type); exception != nullptr) {
    env->ThrowNew(exception, message.c_str());
  }
}

jbyteArray ToByteArray(JNIEnv* env, const std::vector<uint8_t>& bytes) {
  jbyteArray result = env->NewByteArray(static_cast<jsize>(bytes.size()));
  if (result != nullptr && !bytes.empty()) {
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(bytes.size()),
                            reinterpret_cast<const jbyte*>(bytes.data()));
  }
  return result;
}

jstring ToJavaString(JNIEnv* env, std::string_view utf8) {
  std::u16string utf16;
  for (std::size_t index = 0; index < utf8.size();) {
    const uint8_t first = static_cast<uint8_t>(utf8[index++]);
    uint32_t code_point = 0xfffdu;
    std::size_t continuations = 0;
    if (first < 0x80u) {
      code_point = first;
    } else if ((first & 0xe0u) == 0xc0u) {
      code_point = first & 0x1fu;
      continuations = 1;
    } else if ((first & 0xf0u) == 0xe0u) {
      code_point = first & 0x0fu;
      continuations = 2;
    } else if ((first & 0xf8u) == 0xf0u) {
      code_point = first & 0x07u;
      continuations = 3;
    }
    bool valid = index + continuations <= utf8.size();
    for (std::size_t count = 0; valid && count < continuations; ++count) {
      const uint8_t next = static_cast<uint8_t>(utf8[index++]);
      valid = (next & 0xc0u) == 0x80u;
      code_point = (code_point << 6) | (next & 0x3fu);
    }
    if (!valid || code_point > 0x10ffffu ||
        (code_point >= 0xd800u && code_point <= 0xdfffu)) {
      code_point = 0xfffdu;
    }
    if (code_point <= 0xffffu) {
      utf16.push_back(static_cast<char16_t>(code_point));
    } else {
      code_point -= 0x10000u;
      utf16.push_back(static_cast<char16_t>(0xd800u + (code_point >> 10)));
      utf16.push_back(static_cast<char16_t>(0xdc00u + (code_point & 0x3ffu)));
    }
  }
  return env->NewString(reinterpret_cast<const jchar*>(utf16.data()),
                        static_cast<jsize>(utf16.size()));
}

}  // namespace

extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_KartPadIdentityStorage_nativeRecords(
    JNIEnv* env, jobject, jbyteArray data_array, jboolean mii) {
  const auto data = CopyBytes(env, data_array);
  const auto valid = mii ? kartpad::mii::ValidateDatabase(data) : kartpad::mii::ValidateRksys(data);
  if (!valid) { Throw(env, "java/lang/IllegalArgumentException", valid.message); return nullptr; }
  std::vector<std::string> fields;
  auto append = [&](size_t slot, const std::string& name, const auto& id) {
    std::string hex;
    for (uint8_t byte : id) { hex += "0123456789abcdef"[byte >> 4]; hex += "0123456789abcdef"[byte & 15]; }
    fields.insert(fields.end(), {std::to_string(slot), name, hex});
  };
  if (mii) for (const auto& record : kartpad::mii::ListMiis(data))
    append(record.slot, record.name, kartpad::mii::MiiCreateId(data, record.slot));
  else for (const auto& record : kartpad::mii::ListLicenses(data)) append(record.slot, record.name, record.createId);
  auto result = env->NewObjectArray(fields.size(), env->FindClass("java/lang/String"), nullptr);
  if (!result) return nullptr;
  for (size_t i = 0; i < fields.size(); ++i) {
    jstring value = ToJavaString(env, fields[i]);
    env->SetObjectArrayElement(result, i, value);
    env->DeleteLocalRef(value);
  }
  return result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_kartpad_android_KartPadIdentityStorage_nativeEdit(
    JNIEnv* env, jobject, jbyteArray data_array, jint operation, jint slot,
    jstring id_string, jbyteArray name_array) {
  auto data = CopyBytes(env, data_array);
  const auto name = CopyBytes(env, name_array);
  if (!id_string || env->ExceptionCheck()) return nullptr;
  const char* raw = env->GetStringUTFChars(id_string, nullptr);
  if (!raw) return nullptr;
  std::string hex(raw);
  env->ReleaseStringUTFChars(id_string, raw);
  std::array<uint8_t, kartpad::mii::kCreateIdByteSize> id{};
  if (hex.size() != id.size() * 2 || hex.find_first_not_of("0123456789abcdef") != std::string::npos) {
    Throw(env, "java/lang/IllegalArgumentException", "Invalid identity token."); return nullptr;
  }
  for (size_t i = 0; i < id.size(); ++i) id[i] = std::stoul(hex.substr(i * 2, 2), nullptr, 16);
  kartpad::mii::DatabaseResult result{false, "Invalid identity operation."};
  if (operation == 0) result = kartpad::mii::RenameLicense(data, slot, id, name);
  else if (operation == 1) result = kartpad::mii::DeleteLicense(data, slot, id);
  else if (operation == 2) {
    result = kartpad::mii::ValidateDatabase(data);
    if (result && kartpad::mii::MiiCreateId(data, slot) != id)
      result = {false, "The selected Mii changed before it could be renamed."};
    if (result) result = kartpad::mii::RenameMii(data, slot, name);
  } else if (operation == 3) {
    size_t updated = 0;
    result = kartpad::mii::RenameMatchingLicenses(data, id, name, updated);
  }
  if (operation == 4 && name.size() > kartpad::mii::kCreateIdByteSize) {
    // Payload: selected Mii create ID followed by its UTF-16BE name.
    std::array<uint8_t, kartpad::mii::kCreateIdByteSize> selected{};
    std::copy_n(name.begin(), selected.size(), selected.begin());
    result = kartpad::mii::SetLicenseMii(data, slot, id, selected,
        std::span<const uint8_t>(name).subspan(selected.size()));
  }
  if (!result) { Throw(env, "java/lang/IllegalArgumentException", result.message); return nullptr; }
  return ToByteArray(env, data);
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_KartPadActivity_nativeListMiis(
    JNIEnv* env, jobject, jbyteArray database_array) {
  const auto database = CopyBytes(env, database_array);
  if (env->ExceptionCheck()) return nullptr;
  if (const auto valid = kartpad::mii::ValidateDatabase(database); !valid) {
    Throw(env, "java/lang/IllegalArgumentException", valid.message);
    return nullptr;
  }
  const auto records = kartpad::mii::ListMiis(database);
  jclass string_class = env->FindClass("java/lang/String");
  if (string_class == nullptr) return nullptr;
  jobjectArray result = env->NewObjectArray(
      static_cast<jsize>(records.size() * 3), string_class, nullptr);
  if (result == nullptr) return nullptr;
  std::size_t index = 0;
  for (const auto& record : records) {
    const std::string slot = std::to_string(record.slot);
    const std::string creator = record.creatorName.empty()
        ? "Unknown" : record.creatorName;
    const std::string name = record.name.empty() ? "Unnamed Mii" : record.name;
    for (const std::string* value : {&slot, &name, &creator}) {
      jstring text = ToJavaString(env, *value);
      if (text == nullptr) return nullptr;
      env->SetObjectArrayElement(result, static_cast<jsize>(index++), text);
      env->DeleteLocalRef(text);
    }
  }
  return result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_kartpad_android_KartPadActivity_nativeImportMii(
    JNIEnv* env, jobject, jbyteArray database_array, jbyteArray mii_array) {
  auto database = CopyBytes(env, database_array);
  const auto mii = CopyBytes(env, mii_array);
  if (env->ExceptionCheck()) return nullptr;
  const auto result = kartpad::mii::ImportMii(database, mii);
  if (!result) {
    Throw(env, "java/lang/IllegalArgumentException", result.message);
    return nullptr;
  }
  return ToByteArray(env, database);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_kartpad_android_KartPadActivity_nativeRemoveMii(
    JNIEnv* env, jobject, jbyteArray database_array, jint slot) {
  auto database = CopyBytes(env, database_array);
  if (env->ExceptionCheck()) return nullptr;
  const auto result = kartpad::mii::RemoveMii(
      database, static_cast<std::size_t>(slot));
  if (!result) {
    Throw(env, "java/lang/IllegalArgumentException", result.message);
    return nullptr;
  }
  return ToByteArray(env, database);
}

#include "nand_settings.h"
extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_kartpad_android_KartPadIdentityStorage_nativeConsoleSettings(JNIEnv* env, jobject, jstring value) {
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (!chars) return nullptr;
  const std::string serial(chars);
  env->ReleaseStringUTFChars(value, chars);
  const auto bytes = RuntimeNandSettings::EncodeNew(serial);
  if (!bytes) {
    Throw(env, "java/lang/IllegalArgumentException", "Invalid previous console serial");
    return nullptr;
  }
  return ToByteArray(env, std::vector<uint8_t>(bytes->begin(), bytes->end()));
}

// Mii change queue (KartPadMiiChanges): every Mii and license change waits for the next launch.
#include "kartpad/mii/pending_changes.h"

namespace {

namespace mii = kartpad::mii;

std::optional<std::vector<uint8_t>> OptionalBytes(JNIEnv* env, jbyteArray array) {
  if (array == nullptr) return std::nullopt;
  return CopyBytes(env, array);
}

// The database, then one entry per save profile; null is a file that does not exist.
mii::GameFiles ReadFiles(JNIEnv* env, jbyteArray database, jobjectArray saves) {
  mii::GameFiles files;
  files.database = OptionalBytes(env, database);
  const jsize count = saves == nullptr ? 0 : env->GetArrayLength(saves);
  for (jsize index = 0; index < count && index < jsize(mii::kSaveProfileCount); ++index) {
    auto save = static_cast<jbyteArray>(env->GetObjectArrayElement(saves, index));
    files.saves[index] = OptionalBytes(env, save);
    if (save != nullptr) env->DeleteLocalRef(save);
  }
  return files;
}

std::string Hex(std::span<const uint8_t> bytes) {
  std::string hex;
  for (uint8_t byte : bytes) {
    hex += "0123456789abcdef"[byte >> 4];
    hex += "0123456789abcdef"[byte & 15];
  }
  return hex;
}

// An Object[] filled in order; each element's local reference is released once stored.
struct Elements {
  JNIEnv* env;
  jobjectArray array;
  jsize next = 0;
  jclass integer = env->FindClass("java/lang/Integer");
  jmethodID valueOf = integer == nullptr ? nullptr
      : env->GetStaticMethodID(integer, "valueOf", "(I)Ljava/lang/Integer;");

  Elements(JNIEnv* e, std::size_t count, const char* type = "java/lang/Object") : env(e) {
    jclass element = env->FindClass(type);
    array = element == nullptr ? nullptr : env->NewObjectArray(jsize(count), element, nullptr);
    if (element != nullptr) env->DeleteLocalRef(element);
  }
  ~Elements() { if (integer != nullptr) env->DeleteLocalRef(integer); }
  bool ok() const { return array != nullptr && valueOf != nullptr && !env->ExceptionCheck(); }
  void Put(jobject value) {
    if (array != nullptr) env->SetObjectArrayElement(array, next, value);
    ++next;
    if (value != nullptr) env->DeleteLocalRef(value);
  }
  void Int(long value) {
    Put(valueOf == nullptr ? nullptr : env->CallStaticObjectMethod(integer, valueOf, jint(value)));
  }
  void Text(std::string_view text) { Put(ToJavaString(env, text)); }
  void Bytes(std::span<const uint8_t> bytes) {
    Put(ToByteArray(env, std::vector<uint8_t>(bytes.begin(), bytes.end())));
  }
};

// What the Kotlin side reads after a replay or an append (KartPadMiiChanges.Native):
// [0] why the queue can't be read or no longer fits, [1] the change that failed or -1, [2] the
// new queue (append), [3] the database and saves the queue changes (null where unchanged),
// [4] Miis (slot, create ID, name, creator, favorite color, record), [5] licenses (profile,
// slot, name, create ID, pending operation, Mii slot or -1, profile title), [6] the queue's
// descriptions, [7] a save that can't be read, [8] why the Miis can't be listed.
struct Upcoming {
  std::string error;
  long failedChange = -1;
  std::optional<std::vector<uint8_t>> queue;
  const mii::GameFiles* live = nullptr;
  const mii::ReplayState* state = nullptr;
  std::vector<std::string> descriptions;
};

jobjectArray ToJava(JNIEnv* env, const Upcoming& upcoming) {
  Elements result(env, 9);
  if (!result.ok()) return nullptr;
  result.Put(upcoming.error.empty() ? nullptr : ToJavaString(env, upcoming.error));
  result.Int(upcoming.failedChange);
  result.Put(upcoming.queue ? ToByteArray(env, *upcoming.queue) : nullptr);

  Elements files(env, 1 + mii::kSaveProfileCount, "[B");
  const auto changed = [&](const auto& after, const auto& before) {
    files.Put(after && after != before ? ToByteArray(env, *after) : nullptr);
  };
  if (upcoming.state != nullptr && upcoming.live != nullptr) {
    changed(upcoming.state->files.database, upcoming.live->database);
    for (std::size_t profile = 0; profile < mii::kSaveProfileCount; ++profile)
      changed(upcoming.state->files.saves[profile], upcoming.live->saves[profile]);
  }
  result.Put(files.array);

  std::vector<mii::MiiRecord> records;
  std::string databaseProblem;
  std::string saveProblem;
  std::vector<mii::UpcomingLicense> licenses;
  if (upcoming.state != nullptr) {
    const auto& database = upcoming.state->files.database;
    if (const auto valid = mii::CheckPendingDatabase(upcoming.state->files); valid)
      records = mii::ListMiis(*database);
    else
      databaseProblem = valid.message;
    if (const auto saves = mii::CheckUpcomingSaves(*upcoming.state); !saves) saveProblem = saves.message;
    licenses = mii::ListUpcomingLicenses(*upcoming.state);
  }
  Elements miis(env, records.size() * 6);
  for (const auto& record : records) {
    const auto& database = *upcoming.state->files.database;
    miis.Int(long(record.slot));
    miis.Text(Hex(mii::MiiCreateId(database, record.slot)));
    miis.Text(record.name.empty() ? "Unnamed Mii" : record.name);
    miis.Text(record.creatorName.empty() ? "Unknown" : record.creatorName);
    miis.Int(record.favoriteColor);
    miis.Bytes(std::span(database).subspan(mii::kMiiBlockOffset + record.slot * mii::kMiiBlockSize,
                                           mii::kMiiBlockSize));
  }
  result.Put(miis.array);
  Elements listed(env, licenses.size() * 7);
  for (const auto& license : licenses) {
    listed.Int(long(license.profile));
    listed.Int(long(license.slot));
    listed.Text(license.name.empty() ? "Unnamed" : license.name);
    listed.Text(Hex(license.createId));
    listed.Int(license.pendingOperation ? long(*license.pendingOperation) : 0);
    listed.Int(license.miiSlot ? long(*license.miiSlot) : -1);
    listed.Text(mii::kSaveProfileTitles[std::size_t(license.profile)]);
  }
  result.Put(listed.array);
  Elements descriptions(env, upcoming.descriptions.size(), "java/lang/String");
  for (const auto& description : upcoming.descriptions) descriptions.Text(description);
  result.Put(descriptions.array);
  result.Put(saveProblem.empty() ? nullptr : ToJavaString(env, saveProblem));
  result.Put(databaseProblem.empty() ? nullptr : ToJavaString(env, databaseProblem));
  return env->ExceptionCheck() ? nullptr : result.array;
}

std::vector<std::string> Descriptions(const std::vector<mii::PendingChange>& queue) {
  std::vector<std::string> descriptions;
  for (const auto& change : queue) descriptions.push_back(change.description);
  return descriptions;
}

// Kinds the Kotlin side sends (KartPadMiiChanges): an editor save (slot -1 for a new Mii), an
// import, a removal, a Mii rename, then a license rename, deletion and relink.
std::optional<mii::PendingChange> BuildChange(
    jint kind, jint profile, jint slot, const std::vector<uint8_t>& createId, jint miiSlot,
    const std::vector<uint8_t>& miiCreateId, const std::optional<std::vector<uint8_t>>& record,
    const std::optional<std::vector<uint8_t>>& expected, const std::vector<uint8_t>& name,
    std::string& error) {
  const auto block = [&](const std::optional<std::vector<uint8_t>>& bytes, mii::MiiBlockBytes& out) {
    if (!bytes || bytes->size() != out.size()) return false;
    std::copy(bytes->begin(), bytes->end(), out.begin());
    return true;
  };
  const auto identity = [](const std::vector<uint8_t>& bytes, mii::CreateIdBytes& out) {
    if (bytes.size() != out.size()) return false;
    std::copy(bytes.begin(), bytes.end(), out.begin());
    return true;
  };
  mii::MiiBlockBytes miiBytes{}, expectedBytes{};
  mii::CreateIdBytes id{}, selected{};
  if (kind == 1 || kind == 2) {
    if (!block(record, miiBytes)) { error = "A Mii file must contain exactly 74 bytes."; return std::nullopt; }
    if (kind == 2) return mii::ImportMiiChange(miiBytes);
    if (slot < 0) return mii::NewMiiChange(miiBytes);
    if (slot >= jint(mii::kMaximumMiiSlots) || !block(expected, expectedBytes)) {
      error = "Invalid Mii selection.";
      return std::nullopt;
    }
    return mii::EditMiiChange(std::size_t(slot), expectedBytes, miiBytes);
  }
  if (kind == 3 || kind == 4) {
    if (slot < 0 || slot >= jint(mii::kMaximumMiiSlots) || !identity(createId, id)) {
      error = "The selected Mii changed. Reopen Miis and choose it again.";
      return std::nullopt;
    }
    return kind == 3 ? mii::RemoveMiiChange(std::size_t(slot), id)
                     : mii::RenameMiiChange(std::size_t(slot), id, name);
  }
  if (kind < 5 || kind > 7) { error = "A pending Mii change is invalid."; return std::nullopt; }
  if (profile < 0 || profile >= jint(mii::kSaveProfileCount) || slot < 0 ||
      slot >= jint(mii::kRksysLicenseCount)) {
    error = "The selected license location is invalid.";
    return std::nullopt;
  }
  if (!identity(createId, id)) { error = "The selected license identity is invalid."; return std::nullopt; }
  const auto location = static_cast<mii::SaveProfile>(profile);
  if (kind == 5) return mii::LicenseRenameChange(location, std::size_t(slot), id, name);
  if (kind == 6) return mii::LicenseDeleteChange(location, std::size_t(slot), id);
  if (miiSlot < 0 || miiSlot >= jint(mii::kMaximumMiiSlots) || !identity(miiCreateId, selected)) {
    error = "The selected Mii changed. Reopen Miis and choose it again.";
    return std::nullopt;
  }
  return mii::LicenseMiiChange(location, std::size_t(slot), id, std::size_t(miiSlot), selected);
}

constexpr char kUnreadableQueue[] = "The pending Mii changes can’t be read.";

}  // namespace

// The live files with the queue replayed over them.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_KartPadMiiChanges_nativeReplay(
    JNIEnv* env, jobject, jbyteArray database, jobjectArray saves, jbyteArray queue_array) {
  try {
    const auto live = ReadFiles(env, database, saves);
    const auto queueBytes = OptionalBytes(env, queue_array);
    if (env->ExceptionCheck()) return nullptr;
    Upcoming upcoming;
    upcoming.live = &live;
    const auto queue = queueBytes ? mii::ParseQueue(*queueBytes)
                                  : std::optional(std::vector<mii::PendingChange>{});
    if (!queue) {
      upcoming.error = kUnreadableQueue;
      return ToJava(env, upcoming);
    }
    upcoming.descriptions = Descriptions(*queue);
    const auto replayed = mii::Replay(live, *queue);
    if (!replayed) {
      upcoming.error = replayed.message;
      upcoming.failedChange = long(replayed.failedChange);
      return ToJava(env, upcoming);
    }
    upcoming.state = &replayed.state;
    return ToJava(env, upcoming);
  } catch (const std::exception& failure) {
    Throw(env, "java/lang/IllegalStateException", failure.what());
    return nullptr;
  }
}

// Checks one change against the replayed queue; on success [2] is the queue with it added.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_KartPadMiiChanges_nativeAppend(
    JNIEnv* env, jobject, jbyteArray database, jobjectArray saves, jbyteArray queue_array,
    jint kind, jint profile, jint slot, jbyteArray create_id, jint mii_slot,
    jbyteArray mii_create_id, jbyteArray record, jbyteArray expected, jbyteArray name) {
  try {
    const auto live = ReadFiles(env, database, saves);
    const auto queueBytes = OptionalBytes(env, queue_array);
    const auto createId = CopyBytes(env, create_id);
    const auto miiCreateId = CopyBytes(env, mii_create_id);
    const auto recordBytes = OptionalBytes(env, record);
    const auto expectedBytes = OptionalBytes(env, expected);
    const auto nameBytes = CopyBytes(env, name);
    if (env->ExceptionCheck()) return nullptr;
    Upcoming upcoming;
    upcoming.live = &live;
    auto queue = queueBytes ? mii::ParseQueue(*queueBytes)
                            : std::optional(std::vector<mii::PendingChange>{});
    if (!queue) {
      upcoming.error = kUnreadableQueue;
      return ToJava(env, upcoming);
    }
    auto replayed = mii::Replay(live, *queue);
    if (!replayed) {
      upcoming.error = replayed.message;
      upcoming.failedChange = long(replayed.failedChange);
      return ToJava(env, upcoming);
    }
    auto change = BuildChange(kind, profile, slot, createId, mii_slot, miiCreateId, recordBytes,
                              expectedBytes, nameBytes, upcoming.error);
    if (change) {
      if (const auto appended = mii::Append(replayed.state, *queue, std::move(*change)); !appended)
        upcoming.error = appended.message;
    }
    if (!upcoming.error.empty()) return ToJava(env, upcoming);
    upcoming.queue = mii::SerializeQueue(*queue);
    upcoming.descriptions = Descriptions(*queue);
    upcoming.state = &replayed.state;
    return ToJava(env, upcoming);
  } catch (const std::exception& failure) {
    Throw(env, "java/lang/IllegalStateException", failure.what());
    return nullptr;
  }
}

// The banner text of each waiting change, or null when the queue can't be read.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_KartPadMiiChanges_nativeDescribe(
    JNIEnv* env, jobject, jbyteArray queue_array) {
  const auto bytes = CopyBytes(env, queue_array);
  if (env->ExceptionCheck()) return nullptr;
  const auto queue = mii::ParseQueue(bytes);
  if (!queue) return nullptr;
  Elements descriptions(env, queue->size(), "java/lang/String");
  for (const auto& change : *queue) descriptions.Text(change.description);
  return env->ExceptionCheck() ? nullptr : descriptions.array;
}

// A new Mii with a unique ID and this console's ID (from its MAC), or with source a duplicate
// of that Mii: every appearance byte kept, fields out of range brought in range. Returns
// [record, null] or [null, why].
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_kartpad_android_KartPadMiiChanges_nativeNewMii(
    JNIEnv* env, jobject, jbyteArray database_array, jlong seconds, jbyteArray mac_array,
    jbyteArray source_array) {
  const auto database = CopyBytes(env, database_array);
  const auto mac = CopyBytes(env, mac_array);
  const auto source = OptionalBytes(env, source_array);
  if (env->ExceptionCheck()) return nullptr;
  Elements result(env, 2);
  if (!result.ok()) return nullptr;
  std::string error;
  try {
    if (mac.size() != 6) throw std::invalid_argument("This console’s identity can’t be read.");
    auto created = mii::NewAppearance(database, uint32_t((int64_t(seconds) - 1136073600) / 4));
    std::array<uint8_t, 6> address{};
    std::copy(mac.begin(), mac.end(), address.begin());
    const auto console = mii::CreateDefaultMii(address);
    std::copy_n(console.begin() + 0x1C, 4, created.bytes.begin() + 0x1C);
    if (source) {
      // The copy takes a fresh Mii ID and this console's ID (0x18-0x1F) so the database accepts
      // it as a separate Mii.
      auto copy = mii::Appearance::Decode(*source).InRange();
      std::copy_n(created.bytes.begin() + 0x18, 8, copy.bytes.begin() + 0x18);
      created = copy;
    }
    result.Bytes(created.bytes);
    result.Put(nullptr);
  } catch (const std::exception& failure) {
    result.Put(nullptr);
    result.Text(failure.what());
  }
  return env->ExceptionCheck() ? nullptr : result.array;
}
