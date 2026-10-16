package dev.kartpad.android.screens.mii

import android.graphics.Bitmap

/**
 * Mii portraits, editor tiles and the 3D preview, drawn natively from the imported game files
 * (kartpad_mii_render_jni.cpp and kartpad_mii_preview_gl.cpp in the game's libmain.so). Builds
 * without the game runtime have none of it; [available] is false there.
 */
internal object MiiNative {
    /** Rendering failures throw IllegalStateException with a readable reason. */
    val available: Boolean by lazy {
        runCatching { nativeTileInputs(0, ByteArray(MII_SIZE)); true }.getOrElse { it !is UnsatisfiedLinkError }
    }

    const val MII_SIZE = 74

    // Any thread. Calls share one decoded archive and run one at a time.
    external fun nativeUnavailableReason(faces: String): String?
    external fun nativePortrait(faces: String, mii: ByteArray, maxSize: Int): Bitmap?
    /** Null for a "none" tile (no glasses, mustache or beard). */
    external fun nativeFeatureTile(faces: String, field: Int, value: Int, mii: ByteArray, maxSize: Int): Bitmap?
    external fun nativeTileInputs(field: Int, mii: ByteArray): String
    /** A scene handle, owned by the caller until passed to [nativePreviewSetScene] or released. */
    external fun nativeBuildScene(faces: String, bodies: String, mii: ByteArray): Long
    external fun nativeSceneHasBody(scene: Long): Boolean
    external fun nativeReleaseScene(scene: Long)

    // The preview's GL thread only, with its context current.
    external fun nativePreviewCreate(): Long
    external fun nativePreviewDestroy(renderer: Long)
    /** Takes ownership of [scene] (0 clears the preview); true when a scene is now shown. */
    external fun nativePreviewSetScene(renderer: Long, scene: Long): Boolean
    external fun nativePreviewConfigure(
        renderer: Long,
        animated: Boolean,
        reduceMotion: Boolean,
        visible: Boolean,
        fullBody: Boolean,
        background: Int,
    )
    external fun nativePreviewTurn(renderer: Long, radians: Float)
    external fun nativePreviewFaceFront(renderer: Long, ease: Boolean)
    external fun nativePreviewReact(renderer: Long)
    external fun nativePreviewYaw(renderer: Long): Float
    external fun nativePreviewSetYaw(renderer: Long, yaw: Float)
    external fun nativePreviewDraw(renderer: Long, width: Int, height: Int)
}
