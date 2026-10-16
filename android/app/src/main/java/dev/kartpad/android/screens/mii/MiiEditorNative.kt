package dev.kartpad.android.screens.mii

/**
 * The Mii editor's tables and record edits (kartpad_mii_editor_jni.cpp, from the headers the Apple
 * editor uses): fields and ranges, Mii Channel tile order, each category's colour, switch, toggle and
 * adjustments, look-alikes, birthdays, the build and names. Records are 74 bytes; any other size
 * throws IllegalArgumentException. Any thread.
 */
internal object MiiEditorNative {
    class Field(val name: String, val minimum: Int, val maximum: Int)
    class Mode(val field: Int, val title: String)
    class Adjustment(val field: Int, val title: String, val less: String, val more: String)

    // Fields by index (appearance.h AppearanceFields).
    const val GENDER = 0
    const val MONTH = 1
    const val DAY = 2
    const val FAVORITE_COLOR = 3
    const val FAVORITE = 4
    const val HEIGHT = 5
    const val WEIGHT = 6
    const val FACE_SHAPE = 7
    const val SKIN = 8
    const val FACIAL_FEATURE = 9
    const val MINGLE_OFF = 10
    const val HAIR_TYPE = 11
    const val HAIR_COLOR = 12
    const val HAIR_FLIP = 13
    const val EYE_TYPE = 14
    const val EYEBROW_TYPE = 20
    const val MUSTACHE = 37
    const val BEARD = 38
    const val MOLE = 42
    const val NICKNAME = 2
    const val CREATOR = 54

    val fields: List<Field> by lazy {
        val names = nativeFieldNames()
        val limits = nativeFieldLimits()
        names.indices.map { Field(names[it], limits[it * 2], limits[it * 2 + 1]) }
    }
    val categories: List<String> by lazy { nativeCategories().toList() }
    /** Each category's feature (0 for Profile and Body). */
    val primaryFeatures: IntArray by lazy { nativePrimaryFeatures() }
    private val ids = HashMap<Int, IntArray>()

    /** A field's tiles in Mii Channel order, 12 to a page. */
    fun featureIds(field: Int): IntArray = synchronized(ids) { ids.getOrPut(field) { nativeFeatureIds(field) } }
    fun featurePage(field: Int, value: Int) = nativeFeaturePage(field, value)
    /** Every field as stored, or as the editor shows it (clamped to its range). */
    fun values(record: ByteArray, clamped: Boolean): IntArray = nativeValues(record, clamped)
    /** The record with one field changed, or null when the value is out of the field's range. */
    fun with(record: ByteArray, field: Int, value: Int): ByteArray? = record.copyOf().takeIf { nativeSet(it, field, value) }
    fun inRange(record: ByteArray): ByteArray = nativeInRange(record)
    /** The category's colour field, or -1. */
    fun colorField(category: Int) = nativeColorField(category)
    fun modes(category: Int): List<Mode> {
        val fields = nativeModeFields(category)
        val titles = nativeModeTitles(category)
        return fields.indices.map { Mode(fields[it], titles[it]) }
    }
    /** Flip hair or Mole, or -1. */
    fun toggleField(category: Int) = nativeToggleField(category)
    fun toggleTitle(category: Int): String = nativeToggleTitle(category)
    fun adjustments(category: Int, record: ByteArray): List<Adjustment> {
        val fields = nativeAdjustmentFields(category, record)
        val titles = nativeAdjustmentTitles(category, record)
        return fields.indices.map { Adjustment(fields[it], titles[it * 3], titles[it * 3 + 1], titles[it * 3 + 2]) }
    }
    fun lookAlike(base: ByteArray, gender: Int, seed: Int): ByteArray = nativeLookAlike(base, gender, seed)
    fun birthdayDays(month: Int) = nativeBirthdayDays(month)
    fun buildName(record: ByteArray): String = nativeBuildName(record)
    fun name(record: ByteArray, offset: Int): String = nativeName(record, offset)
    /** The record with a name stored (trimmed by the caller), or null when it can't be. */
    fun withName(record: ByteArray, offset: Int, name: String): ByteArray? = record.copyOf().takeIf { nativeSetName(it, offset, name) }
    /** Why the record can't be exported (or stored over previous), or null. */
    fun problem(record: ByteArray, previous: ByteArray? = null): String? = nativeValidate(record, previous)
    /** A colour chip's colour, 0xRRGGBB. */
    fun color(field: Int, value: Int) = nativeColor(field, value)

    private external fun nativeFieldLimits(): IntArray
    private external fun nativeFieldNames(): Array<String>
    private external fun nativeValues(record: ByteArray, clamped: Boolean): IntArray
    private external fun nativeSet(record: ByteArray, field: Int, value: Int): Boolean
    private external fun nativeInRange(record: ByteArray): ByteArray
    private external fun nativeFeatureIds(field: Int): IntArray
    private external fun nativeFeaturePage(field: Int, value: Int): Int
    private external fun nativePrimaryFeatures(): IntArray
    private external fun nativeCategories(): Array<String>
    private external fun nativeColorField(category: Int): Int
    private external fun nativeModeFields(category: Int): IntArray
    private external fun nativeModeTitles(category: Int): Array<String>
    private external fun nativeToggleField(category: Int): Int
    private external fun nativeToggleTitle(category: Int): String
    private external fun nativeAdjustmentFields(category: Int, record: ByteArray): IntArray
    private external fun nativeAdjustmentTitles(category: Int, record: ByteArray): Array<String>
    private external fun nativeLookAlike(base: ByteArray, gender: Int, seed: Int): ByteArray
    private external fun nativeBirthdayDays(month: Int): Int
    private external fun nativeBuildName(record: ByteArray): String
    private external fun nativeName(record: ByteArray, offset: Int): String
    private external fun nativeSetName(record: ByteArray, offset: Int, name: String): Boolean
    private external fun nativeValidate(record: ByteArray, previous: ByteArray?): String?
    private external fun nativeColor(field: Int, value: Int): Int
}
