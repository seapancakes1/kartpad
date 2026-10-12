// AppKit method names the Mac screens use, renamed to the kp_ methods of KartPadAppKitShim.h, so
// none of them can override a method UIKit keeps for itself. Included by KartPadScreens.mm after
// the shim's implementation and before the Mac screens; it stays in force for the iOS glue after
// them, which therefore writes these names with AppKit's meaning too.
#pragma once
#define needsDisplay kp_needsDisplay
#define alphaValue kp_alphaValue
#define animator kp_animator
#define wantsLayer kp_wantsLayer
#define layerContentsRedrawPolicy kp_layerContentsRedrawPolicy
#define isFlipped kp_isFlipped
#define acceptsFirstResponder kp_acceptsFirstResponder
#define mouseDown kp_mouseDown
#define mouseUp kp_mouseUp
#define mouseDragged kp_mouseDragged
#define mouseMoved kp_mouseMoved
#define mouseEntered kp_mouseEntered
#define mouseExited kp_mouseExited
#define rightMouseDown kp_rightMouseDown
#define scrollWheel kp_scrollWheel
#define keyDown kp_keyDown
#define updateTrackingAreas kp_updateTrackingAreas
#define addTrackingArea kp_addTrackingArea
#define removeTrackingArea kp_removeTrackingArea
#define viewDidChangeEffectiveAppearance kp_viewDidChangeEffectiveAppearance
#define viewDidMoveToWindow kp_viewDidMoveToWindow
#define convertRect kp_convertRect
#define setFrameOrigin kp_setFrameOrigin
#define setFrameSize kp_setFrameSize
#define convertSizeToBacking kp_convertSizeToBacking
#define accessibilityPerformPress kp_accessibilityPerformPress
#define isAccessibilityEnabled kp_isAccessibilityEnabled
#define accessibilityRole kp_accessibilityRole

#define visible kp_visible
