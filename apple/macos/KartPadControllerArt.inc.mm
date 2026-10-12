// Live drawings of controllers for the Controllers and button-setup screens, in the Wii's glossy
// white plastic. Each kind has its own silhouette (an Xbox controller's chunky grips, a PlayStation
// controller's touchpad and low sticks, a Pro Controller's round grips, a GameCube controller's big
// A, a Joy-Con pair, a Wii Remote held sideways or upright with a Nunchuk, a keyboard) and lights in
// the player's colour as they press. Buttons are drawn by position with plain letters; no maker's
// logos or symbols. Everything is in a 200 × 124 unit box scaled to fit; small drawings drop letters
// and keep lines at least a point wide. Included by KartPadMacShell.mm after the overlay.

struct KPArtState {
  uint64_t buttons = 0;            // SDL gamepad buttons held (bits)
  float axes[SDL_GAMEPAD_AXIS_COUNT] = {};
  uint64_t highlight = 0;          // buttons to pulse (the ones bound to an action being set up)
  CGFloat pulse = 0;               // 0…1
  unsigned accent = 0x1b9ad5;      // the player's colour
};

// Where each button sits, in art units, and how the body is shaped.
enum class KPArtLayout { Offset, Symmetric, Nintendo, GameCube, JoyCon, WiiRemote, Keyboard };
static KPArtLayout KPArtLayoutFor(KPPadFamily family) {
  switch (family) {
    case KPFamilyPlayStation: return KPArtLayout::Symmetric;
    case KPFamilySwitch: return KPArtLayout::Nintendo;
    case KPFamilyGameCube: return KPArtLayout::GameCube;
    case KPFamilyJoyCon: return KPArtLayout::JoyCon;
    case KPFamilyWiiRemote: return KPArtLayout::WiiRemote;
    case KPFamilyKeyboard: return KPArtLayout::Keyboard;
    default: return KPArtLayout::Offset;
  }
}

// The plastic: shell, buttons at rest, recesses (stick wells) and the parts behind the shell
// (shoulders, triggers), for light and dark.
struct KPArtTones {
  unsigned bodyTop, bodyBottom, outline, partTop, partBottom, partLine, letter, wellTop, wellBottom, backTop, backBottom;
};
static const KPArtTones KPArtLightTones{0xffffff, 0xe1e7ea, 0x97a4ab, 0xffffff, 0xe0e6e9, 0xa3afb6, 0x556168,
                                        0xc5ced3, 0xe9eef0, 0xf4f6f7, 0xd3dade};
static const KPArtTones KPArtDarkTones{0x5f6970, 0x3b4349, 0x0a0c0e, 0x7a858c, 0x4f585e, 0x1c2023, 0xf1f4f6,
                                       0x1b1f22, 0x353b40, 0x535c62, 0x363d42};

// How to draw at this size: the player's state, the scale, light or dark.
struct KPArtCtx {
  CGContextRef c;
  const KPArtState &state;
  CGFloat s;     // points per art unit
  bool dark;
  bool small;    // a tray chip: silhouette and colour only
  bool big;      // button setup: every label and detail
  const KPArtTones &tone;
  // A line `base` units wide, but never thinner than `minPoints` on screen.
  CGFloat line(CGFloat base, CGFloat minPoints = 0.8) const { return std::max(base, minPoints / s); }
  // Letters only where they'll be readable.
  bool words(CGFloat size) const { return !small && size * s >= 4.4; }
  bool held(int button) const { return button >= 0 && ((state.buttons >> button) & 1); }
  bool marked(int button) const { return button >= 0 && ((state.highlight >> button) & 1); }
  float pull(int axis) const { return std::clamp(state.axes[axis], 0.f, 1.f); }
};

// Owns a path for the length of a block.
struct KPArtPath {
  CGPathRef p;
  KPArtPath(CGPathRef path) : p(path) {}
  ~KPArtPath() { CGPathRelease(p); }
  KPArtPath(const KPArtPath &) = delete;
  KPArtPath &operator=(const KPArtPath &) = delete;
  operator CGPathRef() const { return p; }
};

static unsigned KPArtMix(unsigned a, unsigned b, CGFloat t) {
  unsigned out = 0;
  for (int shift : {16, 8, 0})
    out |= (unsigned)std::lround(((a >> shift) & 255) * (1 - t) + ((b >> shift) & 255) * t) << shift;
  return out;
}
static CGFloat KPArtLuminance(unsigned rgb) {
  auto channel = [&](int shift) {
    const CGFloat v = ((rgb >> shift) & 255) / 255.0;
    return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}
// Letters on a lit part: dark on light colours (Player 3's yellow, Player 4's green), white on the rest.
static unsigned KPArtInkOn(unsigned fill) { return KPArtLuminance(fill) > 0.3 ? KPArtMix(fill, 0x000000, 0.8) : 0xffffff; }
// The player's number from their colour (-1 for the UI blue).
static int KPArtPlayer(unsigned accent) {
  for (int i = 0; i < 4; ++i)
    if (KPPlayerColors[i] == accent) return i;
  return -1;
}

// Shapes.
static CGPathRef KPArtCircle(CGPoint at, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(at.x - r, at.y - r, 2 * r, 2 * r), nullptr); }
static CGPathRef KPArtRound(CGRect r, CGFloat radius) {
  radius = std::min(radius, std::min(r.size.width, r.size.height) / 2 - 0.01);
  return CGPathCreateWithRoundedRect(r, radius, radius, nullptr);
}
// A closed polygon with each corner rounded by its own radius.
static CGPathRef KPArtPolygon(const CGPoint *v, int count, const CGFloat *radii) {
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathMoveToPoint(p, nullptr, (v[0].x + v[count - 1].x) / 2, (v[0].y + v[count - 1].y) / 2);
  for (int i = 0; i < count; ++i) {
    const CGPoint next = v[(i + 1) % count];
    CGPathAddArcToPoint(p, nullptr, v[i].x, v[i].y, (v[i].x + next.x) / 2, (v[i].y + next.y) / 2, radii[i]);
  }
  CGPathCloseSubpath(p);
  return p;
}
static CGPathRef KPArtOctagon(CGPoint at, CGFloat r) {
  CGPoint v[8];
  CGFloat radii[8];
  for (int i = 0; i < 8; ++i) {
    v[i] = CGPointMake(at.x + r * cos(M_PI / 8 + i * M_PI / 4), at.y + r * sin(M_PI / 8 + i * M_PI / 4));
    radii[i] = r * 0.18;
  }
  return KPArtPolygon(v, 8, radii);
}
// A body symmetric about x = axis: the right half from the top centre clockwise to the bottom
// centre as curves (control, control, end), mirrored for the left.
struct KPArtCurve { CGFloat c1x, c1y, c2x, c2y, x, y; };
static CGPathRef KPArtMirrored(CGPoint top, const KPArtCurve *curves, int count, CGFloat axis = 100) {
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathMoveToPoint(p, nullptr, top.x, top.y);
  for (int i = 0; i < count; ++i) CGPathAddCurveToPoint(p, nullptr, curves[i].c1x, curves[i].c1y, curves[i].c2x, curves[i].c2y, curves[i].x, curves[i].y);
  for (int i = count - 1; i >= 0; --i) {
    const CGPoint start = i ? CGPointMake(curves[i - 1].x, curves[i - 1].y) : top;
    CGPathAddCurveToPoint(p, nullptr, 2 * axis - curves[i].c2x, curves[i].c2y, 2 * axis - curves[i].c1x, curves[i].c1y,
                          2 * axis - start.x, start.y);
  }
  CGPathCloseSubpath(p);
  return p;
}

// Painting.
static void KPArtFill(CGContextRef c, CGPathRef p, unsigned hex, CGFloat alpha = 1) {
  KPSetInk(c, hex, alpha);
  CGContextAddPath(c, p);
  CGContextFillPath(c);
}
static void KPArtStroke(CGContextRef c, CGPathRef p, unsigned hex, CGFloat width, CGFloat alpha = 1) {
  KPSetInk(c, hex, alpha);
  CGContextSetLineWidth(c, width);
  CGContextAddPath(c, p);
  CGContextStrokePath(c);
}
// A vertical gradient across a box, between fractions `from` and `to` of its height, inside the
// current clip.
static void KPArtWash(CGContextRef c, CGRect box, unsigned top, unsigned bottom, CGFloat topAlpha = 1, CGFloat bottomAlpha = 1,
                      CGFloat from = 0, CGFloat to = 1) {
  auto f = [](unsigned hex, int shift) -> CGFloat { return ((hex >> shift) & 255) / 255.0; };
  const CGFloat colors[] = {f(top, 16), f(top, 8), f(top, 0), topAlpha, f(bottom, 16), f(bottom, 8), f(bottom, 0), bottomAlpha};
  static CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, nullptr, 2);
  CGContextDrawLinearGradient(c, gradient, CGPointMake(0, box.origin.y + box.size.height * from),
                              CGPointMake(0, box.origin.y + box.size.height * to),
                              kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
  CGGradientRelease(gradient);
}
// Three colours down a box, `middle` at fraction `at` of its height, inside the current clip.
static void KPArtWash3(CGContextRef c, CGRect box, unsigned top, unsigned middle, unsigned bottom, CGFloat at) {
  CGFloat colors[12];
  const unsigned hex[3] = {top, middle, bottom};
  for (int i = 0; i < 12; ++i) colors[i] = i % 4 == 3 ? 1 : ((hex[i / 4] >> (16 - 8 * (i % 4))) & 255) / 255.0;
  const CGFloat locations[3] = {0, at, 1};
  static CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, locations, 3);
  CGContextDrawLinearGradient(c, gradient, box.origin, CGPointMake(box.origin.x, CGRectGetMaxY(box)), 0);
  CGGradientRelease(gradient);
}
// The same, filling a path.
static void KPArtGradient(CGContextRef c, CGPathRef p, unsigned top, unsigned bottom, CGFloat topAlpha = 1,
                          CGFloat bottomAlpha = 1, CGFloat from = 0, CGFloat to = 1) {
  CGContextSaveGState(c);
  CGContextAddPath(c, p);
  CGContextClip(c);
  KPArtWash(c, CGPathGetBoundingBox(p), top, bottom, topAlpha, bottomAlpha, from, to);
  CGContextRestoreGState(c);
}
// A band just inside a shape's top edge, fading out down its sides (in steps, or at once when
// `steps` is 1): light on a raised part, shade in a recess. Drawn inside a clip to the shape.
static void KPArtRim(CGContextRef c, CGPathRef p, CGFloat width, unsigned hex, CGFloat alpha, int steps = 1) {
  const CGRect box = CGPathGetBoundingBox(p);
  for (int step = 0; step < steps; ++step) {
    const CGFloat reach = steps == 1 ? 0.45 : 0.56 * (step + 1) / steps;
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(box.origin.x - width, box.origin.y - width, box.size.width + 2 * width, box.size.height * reach + width));
    CGContextTranslateCTM(c, 0, width / 2);
    KPArtStroke(c, p, hex, width, alpha / steps);
    CGContextRestoreGState(c);
  }
}
// A surface: a gradient with a rim along its top, in one clip.
static void KPArtSurface(CGContextRef c, CGPathRef p, unsigned top, unsigned bottom, CGFloat rimWidth = 0, CGFloat rimAlpha = 0,
                         unsigned rim = 0xffffff) {
  CGContextSaveGState(c);
  CGContextAddPath(c, p);
  CGContextClip(c);
  KPArtWash(c, CGPathGetBoundingBox(p), top, bottom);
  if (rimAlpha > 0) KPArtRim(c, p, rimWidth, rim, rimAlpha);
  CGContextRestoreGState(c);
}
// A shadow under a shape, soft (widening translucent bands, so it scales with the drawing) or a
// plain contact shadow for small parts.
static void KPArtDrop(const KPArtCtx &a, CGPathRef p, CGFloat drop, CGFloat strength = 1, bool soft = true) {
  CGContextSaveGState(a.c);
  CGContextTranslateCTM(a.c, 0, drop);
  const CGFloat k = strength * (a.dark ? 2.4 : 1);
  if (soft) {
    // Bands round the edge rather than a fill, since the shape covers the middle.
    for (int i = 1; i <= 3; ++i) KPArtStroke(a.c, p, 0x000000, drop * 1.2 * i, 0.045 * k);
  } else {
    KPArtFill(a.c, p, 0x000000, 0.12 * k);
  }
  CGContextRestoreGState(a.c);
}
// The ring around a part being set up: a crisp line in the player's colour, a small gap off the
// part, with a soft glow that breathes with the pulse.
static void KPArtMark(const KPArtCtx &a, CGPathRef shape) {
  CGContextRef c = a.c;
  const CGFloat pulse = std::clamp(a.state.pulse, CGFloat(0), CGFloat(1));
  const CGFloat gap = a.line(1.1, 1.1) + 0.7 * pulse, ring = a.line(1.25, 1.4), glow = a.line(1.2, 1.1);
  const unsigned ink = !a.dark && KPArtLuminance(a.state.accent) > 0.3 ? KPArtMix(a.state.accent, 0x000000, 0.15) : a.state.accent;
  CGContextSaveGState(c);
  const CGFloat reach = 2 * (gap + ring + glow * 3);
  CGContextClipToRect(c, CGRectInset(CGPathGetBoundingBox(shape), -reach, -reach));
  CGContextBeginTransparencyLayer(c, nullptr);
  for (int i = 3; i >= 1; --i) KPArtStroke(c, shape, a.state.accent, 2 * (gap + ring + glow * i), 0.05 + 0.09 * pulse);
  KPArtStroke(c, shape, ink, 2 * (gap + ring));
  CGContextSetBlendMode(c, kCGBlendModeClear);
  KPArtStroke(c, shape, 0x000000, 2 * gap);
  KPArtFill(c, shape, 0x000000);
  CGContextEndTransparencyLayer(c);
  CGContextRestoreGState(c);
}
// Capitals centred on a point, in SF Pro Rounded.
static void KPArtLabel(NSString *text, CGPoint at, CGFloat size, unsigned ink, CGFloat weight = NSFontWeightBold) {
  KPMiiFont *font = KPStyleFont(size, weight);
  const CGSize box = KPTextSize(text, size, weight);
  KPTextWeight(text, CGRectMake(at.x - box.width / 2 - size, at.y + font.capHeight / 2 - font.ascender, box.width + 2 * size, box.height + 1),
               size, ink, weight);
}

// The shell: a soft shadow, white plastic shading to silver, a gloss over the top, shade inside the
// lower edge and a fine outline. Dark mode is graphite with a light rim so it stands off the card.
static void KPArtShell(const KPArtCtx &a, CGPathRef body, bool shadow = true) {
  CGContextRef c = a.c;
  if (shadow) KPArtDrop(a, body, 2);
  const CGRect box = CGPathGetBoundingBox(body);
  CGContextSaveGState(c);
  CGContextAddPath(c, body);
  CGContextClip(c);
  // White plastic shading to silver, with a gloss over the top part.
  KPArtWash3(c, box, KPArtMix(a.tone.bodyTop, 0xffffff, a.dark ? 0.12 : 0.8), KPArtMix(a.tone.bodyTop, a.tone.bodyBottom, 0.45),
             a.tone.bodyBottom, 0.45);
  // Shade inside the lower edge: the wider bands start lower down the sides, so it fades in.
  const CGFloat widths[3] = {6.0, 3.8, 1.8}, starts[3] = {0.72, 0.6, 0.48};
  for (int i = 0; i < 3; ++i) {
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(box.origin.x - 4, box.origin.y + box.size.height * starts[i], box.size.width + 8, box.size.height));
    CGContextTranslateCTM(c, 0, -a.line(widths[i]) / 2);
    KPArtStroke(c, body, 0x000000, a.line(widths[i]), a.dark ? 0.1 : 0.03);
    CGContextRestoreGState(c);
  }
  KPArtRim(c, body, a.line(2.0, 1.2), 0xffffff, a.dark ? 0.45 : 1, 3);
  CGContextRestoreGState(c);
  KPArtStroke(c, body, a.tone.outline, a.line(1.2, 1.0), a.dark ? 0.85 : 1);
}

// One button of any shape: raised silver at rest, lit with the player's colour while held, ringed
// while it's one being set up. Its label takes dark or light ink to suit the fill.
static void KPArtPart(const KPArtCtx &a, int button, CGPathRef shape, NSString *label = nil, CGFloat size = 0,
                      CGPoint at = CGPointZero) {
  CGContextRef c = a.c;
  const bool held = a.held(button);
  const unsigned accent = a.state.accent;
  if (a.marked(button)) KPArtMark(a, shape);
  if (!held) {
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, a.line(0.9, 0.6));
    KPArtFill(c, shape, 0x000000, a.dark ? 0.45 : 0.15);
    CGContextRestoreGState(c);
  }
  KPArtSurface(c, shape, held ? KPArtMix(accent, 0xffffff, 0.2) : a.tone.partTop, held ? KPArtMix(accent, 0x000000, 0.08) : a.tone.partBottom,
               a.line(1.0, 0.8), a.small ? 0 : held ? 0.45 : a.dark ? 0.3 : 0.9);
  KPArtStroke(c, shape, held ? KPArtMix(accent, 0x000000, 0.35) : a.tone.partLine, a.line(0.8, 0.75));
  if (label.length && a.words(size)) KPArtLabel(label, at, size, held ? KPArtInkOn(accent) : a.tone.letter);
}
static void KPArtButton(const KPArtCtx &a, int button, CGPoint at, CGFloat radius, NSString *label = nil) {
  KPArtPath shape = KPArtCircle(at, radius);
  KPArtPart(a, button, shape, label, radius * 1.12, at);
}
static void KPArtPill(const KPArtCtx &a, int button, CGRect r) {
  KPArtPath shape = KPArtRound(r, std::min(r.size.width, r.size.height) / 2);
  KPArtPart(a, button, shape);
}
// A − or + drawn as bars (readable smaller than text).
static void KPArtSign(const KPArtCtx &a, int button, CGPoint at, CGFloat size, bool plus) {
  if (a.small) return;
  KPSetInk(a.c, a.held(button) ? KPArtInkOn(a.state.accent) : a.tone.letter);
  const CGFloat w = std::max(size * 0.26, 0.9 / a.s);
  CGContextFillRect(a.c, CGRectMake(at.x - size / 2, at.y - w / 2, size, w));
  if (plus) CGContextFillRect(a.c, CGRectMake(at.x - w / 2, at.y - size / 2, w, size));
}
// A small arrowhead pointing up, right, down or left (0…3).
static void KPArtArrowhead(CGContextRef c, CGPoint at, CGFloat size, int direction, unsigned ink, CGFloat alpha) {
  const CGFloat angle = direction * M_PI_2;
  auto point = [&](CGFloat x, CGFloat y) { return CGPointMake(at.x + x * cos(angle) - y * sin(angle), at.y + x * sin(angle) + y * cos(angle)); };
  const CGPoint v[3] = {point(0, -size * 0.6), point(size * 0.62, size * 0.4), point(-size * 0.62, size * 0.4)};
  KPSetInk(c, ink, alpha);
  CGContextAddLines(c, v, 3);
  CGContextClosePath(c);
  CGContextFillPath(c);
}
// Four face buttons around a point, labelled by position (south, east, west, north).
static void KPArtFace(const KPArtCtx &a, CGPoint at, CGFloat spread, CGFloat radius, NSString *south, NSString *east,
                      NSString *west, NSString *north) {
  KPArtButton(a, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(at.x, at.y - spread), radius, north);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(at.x - spread, at.y), radius, west);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(at.x + spread, at.y), radius, east);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_SOUTH, CGPointMake(at.x, at.y + spread), radius, south);
}

// A stick: a recessed well (round, or the GameCube's octagon) and a cap that follows the stick,
// ringed in the player's colour as it leans and filled with it while clicked.
static void KPArtStick(const KPArtCtx &a, int click, int axisX, CGPoint at, CGFloat radius, bool octagon = false,
                       CGFloat capScale = 0.72) {
  CGContextRef c = a.c;
  const unsigned accent = a.state.accent;
  KPArtPath well = octagon ? KPArtOctagon(at, radius) : KPArtCircle(at, radius);
  if (a.marked(click)) KPArtMark(a, well);
  KPArtSurface(c, well, a.tone.wellTop, a.tone.wellBottom, a.line(2.2, 1.0), a.dark ? 0.4 : 0.16, 0x000000);
  KPArtStroke(c, well, a.tone.partLine, a.line(0.8, 0.75));
  const CGFloat x = std::clamp(a.state.axes[axisX], -1.f, 1.f), y = std::clamp(a.state.axes[axisX + 1], -1.f, 1.f);
  const CGFloat lean = std::min<CGFloat>(1, std::hypot(x, y));
  const CGFloat cap = radius * capScale;
  const CGPoint centre = CGPointMake(at.x + x * radius * 0.36, at.y + y * radius * 0.36);
  KPArtPath top = KPArtCircle(centre, cap), dish = KPArtCircle(centre, cap * 0.68);
  const bool held = a.held(click);
  CGContextSaveGState(c);
  CGContextTranslateCTM(c, 0, a.line(1.2, 0.6));
  KPArtFill(c, top, 0x000000, a.dark ? 0.5 : 0.2);
  CGContextRestoreGState(c);
  KPArtSurface(c, top, held ? KPArtMix(accent, 0xffffff, 0.2) : a.tone.partTop, held ? KPArtMix(accent, 0x000000, 0.08) : a.tone.partBottom,
               a.line(1.0, 0.8), a.small ? 0 : held ? 0.45 : a.dark ? 0.3 : 0.9);
  // The dish is concave: dark at the top, light at the bottom. Leaning only tints it faintly; the
  // full colour is for a click.
  unsigned dishTop = held ? KPArtMix(accent, 0x000000, 0.15) : a.tone.partBottom;
  unsigned dishBottom = held ? KPArtMix(accent, 0xffffff, 0.25) : a.tone.partTop;
  const bool leaning = !held && lean > 0.05;
  if (leaning) {
    dishTop = KPArtMix(dishTop, accent, 0.18 * lean);
    dishBottom = KPArtMix(dishBottom, accent, 0.12 * lean);
  }
  KPArtGradient(c, dish, dishTop, dishBottom);
  if (!a.small) KPArtStroke(c, dish, held ? KPArtMix(accent, 0x000000, 0.3) : a.tone.partLine, a.line(0.6, 0.5), 0.6);
  KPArtStroke(c, top, held ? KPArtMix(accent, 0x000000, 0.35) : a.tone.partLine, a.line(0.8, 0.75));
  // Leaning rings the cap in the player's colour, stronger the further it goes.
  if (leaning) KPArtStroke(c, top, accent, a.line(1.4, 1.1), 0.35 + 0.65 * lean);
}

// A D-pad cross; each arm lights on its own. `turn` quarter-turns it clockwise for a controller
// held sideways, so the arm that lights is the one under the player's thumb.
static void KPArtDpad(const KPArtCtx &a, CGPoint at, CGFloat size, int turn = 0) {
  CGContextRef c = a.c;
  const CGFloat h = size / 2, w = size * 0.17;
  const CGPoint v[12] = {{at.x - w, at.y - h}, {at.x + w, at.y - h}, {at.x + w, at.y - w}, {at.x + h, at.y - w},
                         {at.x + h, at.y + w}, {at.x + w, at.y + w}, {at.x + w, at.y + h}, {at.x - w, at.y + h},
                         {at.x - w, at.y + w}, {at.x - h, at.y + w}, {at.x - h, at.y - w}, {at.x - w, at.y - w}};
  const CGFloat o = w * 0.5, i = w * 0.35;
  const CGFloat radii[12] = {o, o, i, o, o, i, o, o, i, o, o, i};
  KPArtPath cross = KPArtPolygon(v, 12, radii);
  static const int buttons[4] = {SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_DPAD_DOWN,
                                 SDL_GAMEPAD_BUTTON_DPAD_LEFT};
  // Arms in screen order: up, right, down, left.
  const CGRect arms[4] = {CGRectMake(at.x - w, at.y - h, 2 * w, h - w * 0.4), CGRectMake(at.x + w * 0.4, at.y - w, h - w * 0.4, 2 * w),
                          CGRectMake(at.x - w, at.y + w * 0.4, 2 * w, h - w * 0.4), CGRectMake(at.x - h, at.y - w, h - w * 0.4, 2 * w)};
  int button[4];
  for (int arm = 0; arm < 4; ++arm) button[arm] = buttons[(arm - turn + 8) % 4];
  for (int arm = 0; arm < 4; ++arm)
    if (a.marked(button[arm])) {
      KPArtPath shape = KPArtRound(arms[arm], o);
      KPArtMark(a, shape);
    }
  CGContextSaveGState(c);
  CGContextTranslateCTM(c, 0, a.line(1.0, 0.6));
  KPArtFill(c, cross, 0x000000, a.dark ? 0.45 : 0.16);
  CGContextRestoreGState(c);
  CGContextSaveGState(c);
  CGContextAddPath(c, cross);
  CGContextClip(c);
  KPArtWash(c, CGPathGetBoundingBox(cross), a.tone.partTop, a.tone.partBottom);
  for (int arm = 0; arm < 4; ++arm)
    if (a.held(button[arm])) {
      CGContextSaveGState(c);
      CGContextClipToRect(c, arms[arm]);
      KPArtWash(c, arms[arm], KPArtMix(a.state.accent, 0xffffff, 0.2), KPArtMix(a.state.accent, 0x000000, 0.08));
      CGContextRestoreGState(c);
    }
  if (!a.small) KPArtRim(c, cross, a.line(1.0, 0.8), 0xffffff, a.dark ? 0.3 : 0.9);
  CGContextRestoreGState(c);
  if (!a.small) {
    // A dimple in the middle, and arrowheads on the big drawing.
    KPArtPath dimple = KPArtCircle(at, w * 0.55);
    KPArtGradient(c, dimple, a.tone.partBottom, a.tone.partTop);
    if (a.big)
      for (int arm = 0; arm < 4; ++arm) {
        const CGFloat d = h - w * 0.75;
        const CGPoint tip = CGPointMake(at.x + d * (arm == 1 ? 1 : arm == 3 ? -1 : 0), at.y + d * (arm == 2 ? 1 : arm == 0 ? -1 : 0));
        const bool held = a.held(button[arm]);
        KPArtArrowhead(c, tip, w * 0.55, arm, held ? KPArtInkOn(a.state.accent) : a.tone.letter, held ? 0.9 : 0.4);
      }
  }
  KPArtStroke(c, cross, a.tone.partLine, a.line(0.8, 0.75));
}

// The PlayStation controller's D-pad: four separate pads pointing in.
static void KPArtArrowPads(const KPArtCtx &a, CGPoint at, CGFloat size) {
  static const int buttons[4] = {SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_DPAD_DOWN,
                                 SDL_GAMEPAD_BUTTON_DPAD_LEFT};
  const CGFloat h = size / 2, w = size * 0.18, gap = size * 0.07;
  for (int arm = 0; arm < 4; ++arm) {
    const CGFloat angle = arm * M_PI_2;
    auto point = [&](CGFloat x, CGFloat y) { return CGPointMake(at.x + x * cos(angle) - y * sin(angle), at.y + x * sin(angle) + y * cos(angle)); };
    const CGPoint v[5] = {point(-w, -h), point(w, -h), point(w, -gap - w), point(0, -gap), point(-w, -gap - w)};
    const CGFloat radii[5] = {w * 0.45, w * 0.45, w * 0.3, w * 0.25, w * 0.3};
    KPArtPath shape = KPArtPolygon(v, 5, radii);
    KPArtPart(a, buttons[arm], shape);
    if (a.big) {
      const bool held = a.held(buttons[arm]);
      KPArtArrowhead(a.c, point(0, -h + w * 0.95), w * 0.55, arm, held ? KPArtInkOn(a.state.accent) : a.tone.letter, held ? 0.9 : 0.4);
    }
  }
}

// A trigger: an analog pad that fills from its base up as it's pulled. `show` is how much of it
// peeks out past whatever sits in front; its label changes ink where the fill passes under it.
static void KPArtTrigger(const KPArtCtx &a, int axis, CGRect r, CGFloat radius, CGFloat show, NSString *label,
                         CGFloat labelShift = 0) {
  CGContextRef c = a.c;
  KPArtPath shape = KPArtRound(r, radius);
  const unsigned accent = a.state.accent;
  KPArtDrop(a, shape, 1.2, 0.8, false);
  const float pull = a.pull(axis);
  const CGRect fill = CGRectMake(r.origin.x, r.origin.y + show * (1 - pull), r.size.width, r.size.height);
  CGContextSaveGState(c);
  CGContextAddPath(c, shape);
  CGContextClip(c);
  KPArtWash(c, r, a.tone.backTop, a.tone.backBottom, 1, 1, 0, show / r.size.height);
  if (pull > 0.01) {
    CGContextSaveGState(c);
    CGContextClipToRect(c, fill);
    KPArtWash(c, fill, KPArtMix(accent, 0xffffff, 0.15), KPArtMix(accent, 0x000000, 0.1));
    CGContextRestoreGState(c);
  }
  if (!a.small) KPArtRim(c, shape, a.line(1.0, 0.8), 0xffffff, a.dark ? 0.3 : 0.9);
  CGContextRestoreGState(c);
  KPArtStroke(c, shape, a.tone.partLine, a.line(0.8, 0.75));
  const CGFloat size = std::min<CGFloat>(6, show * 0.62);
  if (label.length && a.words(size) && (a.big || label.length == 1)) {
    const CGPoint at = CGPointMake(CGRectGetMidX(r) + labelShift, r.origin.y + show / 2 + 0.3);
    KPArtLabel(label, at, size, a.tone.letter);
    if (pull > 0.01) {
      CGContextSaveGState(c);
      CGContextClipToRect(c, fill);
      KPArtLabel(label, at, size, KPArtInkOn(accent));
      CGContextRestoreGState(c);
    }
  }
}

// Shoulder buttons with their triggers behind, peeking above the shell (drawn before it). The left
// pair is given and the right mirrors it, both tilted to follow the shoulders. `show` is how much
// of a shoulder button clears the shell.
static void KPArtShoulders(const KPArtCtx &a, CGRect bumper, CGRect trigger, CGFloat tilt, CGFloat show,
                           NSString *bumperLeft, NSString *bumperRight, NSString *triggerLeft, NSString *triggerRight,
                           bool leftBumper = true) {
  CGContextRef c = a.c;
  for (int side = 0; side < 2; ++side) {
    const CGRect b = side ? CGRectMake(200 - CGRectGetMaxX(bumper), bumper.origin.y, bumper.size.width, bumper.size.height) : bumper;
    const CGRect t = side ? CGRectMake(200 - CGRectGetMaxX(trigger), trigger.origin.y, trigger.size.width, trigger.size.height) : trigger;
    const int button = side ? SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER : SDL_GAMEPAD_BUTTON_LEFT_SHOULDER;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, CGRectGetMidX(b), CGRectGetMidY(b));
    CGContextRotateCTM(c, side ? -tilt : tilt);
    CGContextTranslateCTM(c, -CGRectGetMidX(b), -CGRectGetMidY(b));
    KPArtTrigger(a, side ? SDL_GAMEPAD_AXIS_RIGHT_TRIGGER : SDL_GAMEPAD_AXIS_LEFT_TRIGGER, t, std::min(t.size.width, t.size.height) * 0.45,
                 b.origin.y - t.origin.y, side ? triggerRight : triggerLeft);
    // The GameCube controller has Z on the right only; a left one (newer models' ZL) shows only while
    // it's pressed or being set up.
    if (side || leftBumper || a.held(button) || a.marked(button)) {
      KPArtPath shape = KPArtRound(b, b.size.height * 0.42);
      NSString *label = side ? bumperRight : bumperLeft;
      const CGFloat size = std::min<CGFloat>(6, show * 0.66);
      KPArtPart(a, button, shape, label, size, CGPointMake(CGRectGetMidX(b), b.origin.y + show / 2 + 0.4));
    }
    CGContextRestoreGState(c);
  }
}

// Xbox: a chunky body with deep grips and a heavy lower half, the left stick high and the right one
// low, a round guide button high in the middle with two small buttons below it and share under those.
static void KPArtXbox(const KPArtCtx &a) {
  static const KPArtCurve right[] = {{116, 25, 131, 20, 145, 21}, {160, 22, 172, 26, 177, 34}, {184, 45, 187, 59, 188, 74},
                                     {190, 88, 189, 100, 183, 107}, {177, 114, 167, 117, 157, 116}, {147, 115, 140, 109, 135, 104},
                                     {127, 100, 113, 100, 100, 100}};
  KPArtShoulders(a, CGRectMake(30, 13, 46, 17), CGRectMake(36, 2, 34, 21), -0.1, 8.5, @"LB", @"RB", @"LT", @"RT");
  KPArtPath body = KPArtMirrored(CGPointMake(100, 25), right, 7);
  KPArtShell(a, body);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(55, 50), 13.5);
  KPArtDpad(a, CGPointMake(80, 80), 24);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(121, 80), 13);
  KPArtFace(a, CGPointMake(146, 50), 12.5, 7.2, @"A", @"B", @"X", @"Y");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(100, 34), 6.8);
  if (!a.small) {
    KPArtPath ring = KPArtCircle(CGPointMake(100, 34), 4.2);
    KPArtStroke(a.c, ring, a.held(SDL_GAMEPAD_BUTTON_GUIDE) ? KPArtInkOn(a.state.accent) : a.tone.partLine, a.line(0.7, 0.5), 0.6);
  }
  KPArtButton(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(87, 50), 3.8);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(113, 50), 3.8);
  KPArtPill(a, SDL_GAMEPAD_BUTTON_MISC1, CGRectMake(96.5, 57.5, 7, 4));
}

// PlayStation: long grips, a wide touchpad across the top with the light bar glowing in the
// player's colour beside it, four separate D-pad pads, and both sticks low in the middle.
static void KPArtPlayStation(const KPArtCtx &a) {
  CGContextRef c = a.c;
  static const KPArtCurve right[] = {{118, 27, 132, 23, 147, 24}, {163, 25, 176, 28, 182, 37}, {191, 54, 198, 82, 197, 101},
                                     {196, 113, 189, 119, 180, 118}, {169, 117, 158, 106.5, 152, 98}, {144, 93.5, 120, 93, 100, 93}};
  KPArtShoulders(a, CGRectMake(28, 15, 46, 17), CGRectMake(33, 2, 36, 22), -0.08, 8.5, @"L1", @"R1", @"L2", @"R2");
  KPArtPath body = KPArtMirrored(CGPointMake(100, 27), right, 6);
  KPArtShell(a, body);
  const CGRect pad = CGRectMake(75, 29, 50, 28);
  for (CGFloat x : {pad.origin.x - 4.6, CGRectGetMaxX(pad) + 2.2}) {
    KPArtPath bar = KPArtRound(CGRectMake(x, pad.origin.y + 3, 2.4, pad.size.height - 7), 1.2);
    KPArtStroke(c, bar, a.state.accent, a.line(2.4, 1.2), a.dark ? 0.35 : 0.22);
    KPArtFill(c, bar, KPArtMix(a.state.accent, 0xffffff, a.dark ? 0.1 : 0.15));
  }
  KPArtPath touchpad = KPArtRound(pad, 6);
  KPArtPart(a, SDL_GAMEPAD_BUTTON_TOUCHPAD, touchpad);
  KPArtPill(a, SDL_GAMEPAD_BUTTON_BACK, CGRectMake(64, 28, 4.6, 8.5));
  KPArtPill(a, SDL_GAMEPAD_BUTTON_START, CGRectMake(131.4, 28, 4.6, 8.5));
  KPArtArrowPads(a, CGPointMake(50, 51), 28);
  KPArtFace(a, CGPointMake(150, 51), 12.5, 7.2, nil, nil, nil, nil);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(76, 78), 12.5);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(124, 78), 12.5);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(100, 73), 4.6);
  KPArtPill(a, SDL_GAMEPAD_BUTTON_MISC1, CGRectMake(96.5, 81.5, 7, 3.2));
}

// Pro Controller: wide, with round grips splayed outward, offset sticks, − and + up top with
// capture and home below.
static void KPArtPro(const KPArtCtx &a) {
  static const KPArtCurve right[] = {{120, 28, 136, 26, 150, 27}, {166, 28, 177, 31, 181, 38}, {186, 46, 188, 55, 190, 64},
                                     {192, 77, 198, 90, 197, 101}, {196, 114, 186, 120, 176, 118}, {164, 116, 155, 108.5, 149, 100},
                                     {142, 90, 121, 86, 100, 86}};
  KPArtShoulders(a, CGRectMake(28, 17, 48, 17), CGRectMake(34, 4, 36, 22), -0.06, 9.5, @"L", @"R", @"ZL", @"ZR");
  KPArtPath body = KPArtMirrored(CGPointMake(100, 28), right, 7);
  KPArtShell(a, body);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(52, 51), 13);
  KPArtDpad(a, CGPointMake(79, 72), 22);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(121, 72), 12);
  KPArtFace(a, CGPointMake(149, 51), 12, 7, @"B", @"A", @"Y", @"X");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(85, 38), 3.6);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(85, 38), 3.5, false);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(115, 38), 3.6);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(115, 38), 3.5, true);
  KPArtPath capture = KPArtRound(CGRectMake(85, 47, 7, 7), 1.9);
  KPArtPart(a, SDL_GAMEPAD_BUTTON_MISC1, capture);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(111.5, 50.5), 4.2);
  if (!a.small) {
    KPArtPath dot = KPArtCircle(CGPointMake(88.5, 50.5), 1.8), ring = KPArtCircle(CGPointMake(111.5, 50.5), 2.3);
    KPArtStroke(a.c, dot, a.held(SDL_GAMEPAD_BUTTON_MISC1) ? KPArtInkOn(a.state.accent) : a.tone.partLine, a.line(0.6, 0.5), 0.8);
    KPArtStroke(a.c, ring, a.held(SDL_GAMEPAD_BUTTON_GUIDE) ? KPArtInkOn(a.state.accent) : a.tone.partLine, a.line(0.6, 0.5), 0.8);
  }
}

// Any other controller: a smaller, plain friendly pad with round ends, a D-pad, four face buttons,
// two small sticks and small shoulder buttons.
static void KPArtGeneric(const KPArtCtx &a) {
  static const KPArtCurve right[] = {{118, 37, 132, 35, 146, 36}, {166, 37, 180, 50, 180, 68}, {180, 87, 168, 100, 153, 100},
                                     {134, 100, 118, 94, 100, 94}};
  KPArtShoulders(a, CGRectMake(38, 29, 36, 13), CGRectMake(43, 21, 26, 14), -0.06, 7, @"LB", @"RB", @"LT", @"RT");
  KPArtPath body = KPArtMirrored(CGPointMake(100, 37), right, 4);
  KPArtShell(a, body);
  KPArtDpad(a, CGPointMake(54, 67), 23);
  KPArtFace(a, CGPointMake(146, 67), 11, 6.4, @"A", @"B", @"X", @"Y");
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(85, 83), 8.5);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(115, 83), 8.5);
  KPArtPill(a, SDL_GAMEPAD_BUTTON_BACK, CGRectMake(85, 53, 9, 4));
  KPArtPill(a, SDL_GAMEPAD_BUTTON_START, CGRectMake(106, 53, 9, 4));
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(100, 66), 4);
}

// A GameCube kidney button: a short thick arc around A.
static void KPArtKidney(const KPArtCtx &a, int button, CGPoint around, CGFloat radius, CGFloat from, CGFloat to, CGFloat width,
                        NSString *label) {
  CGMutablePathRef arc = CGPathCreateMutable();
  CGPathAddArc(arc, nullptr, around.x, around.y, radius, from, to, false);
  KPArtPath shape = CGPathCreateCopyByStrokingPath(arc, nullptr, width, kCGLineCapRound, kCGLineJoinRound, 0);
  CGPathRelease(arc);
  const CGFloat mid = (from + to) / 2;
  KPArtPart(a, button, shape, label, width * 0.78, CGPointMake(around.x + radius * cos(mid), around.y + radius * sin(mid)));
}

// GameCube: round handles, the stick in an octagon high on the left, a small D-pad below, a big A
// with B low to its left and X and Y curving round it, the C-stick, big L and R triggers and Z.
static void KPArtGameCube(const KPArtCtx &a) {
  static const KPArtCurve right[] = {{114, 37, 126, 25, 141, 24}, {164, 22, 184, 30, 187, 47}, {190, 62, 193, 78, 190, 90},
                                     {187, 104, 178, 117, 165, 116}, {153, 115, 148, 108, 147, 100}, {144, 93, 122, 89, 100, 89}};
  KPArtShoulders(a, CGRectMake(40, 15, 30, 13), CGRectMake(24, 3, 50, 27), -0.2, 7, @"ZL", @"Z", @"L", @"R", false);
  KPArtPath body = KPArtMirrored(CGPointMake(100, 37), right, 6);
  KPArtShell(a, body);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(49, 52), 15, true);
  KPArtDpad(a, CGPointMake(72, 80), 17);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(131, 80.5), 9.2, true, 0.6);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(100, 56), 3.8);
  const CGPoint centre = CGPointMake(152, 51);
  KPArtKidney(a, SDL_GAMEPAD_BUTTON_EAST, centre, 20, -0.95, 0.35, 8.4, @"X");
  KPArtKidney(a, SDL_GAMEPAD_BUTTON_NORTH, centre, 20, -2.7, -1.75, 8.4, @"Y");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(133.5, 62), 6.2, @"B");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_SOUTH, centre, 11.5, @"A");
}

// The Joy-Con shoulders: bands hugging each half's outer top corner (centre `corner`, radius 21),
// the trigger (ZL, ZR) behind the button (L, R).
static void KPArtJoyConShoulders(const KPArtCtx &a) {
  CGContextRef c = a.c;
  const CGPoint corner = CGPointMake(67, 36.5);
  const CGFloat bumper = 24.6, trigger = 31, shown = 28.2;
  for (int side = 0; side < 2; ++side) {
    const CGAffineTransform flip = side ? CGAffineTransformMake(-1, 0, 0, 1, 200, 0) : CGAffineTransformIdentity;
    auto band = [&](CGFloat radius, CGFloat from, CGFloat width) {
      CGMutablePathRef spine = CGPathCreateMutable();
      CGPathAddArc(spine, &flip, corner.x, corner.y, radius, from, 1.5 * M_PI, false);
      CGPathAddLineToPoint(spine, &flip, 80, corner.y - radius);
      CGPathRef shape = CGPathCreateCopyByStrokingPath(spine, nullptr, width, kCGLineCapRound, kCGLineJoinRound, 0);
      CGPathRelease(spine);
      return shape;
    };
    auto at = [&](CGFloat radius) {
      const CGPoint p = CGPointMake(corner.x + radius * cos(1.27 * M_PI), corner.y + radius * sin(1.27 * M_PI));
      return CGPointApplyAffineTransform(p, flip);
    };
    // The trigger fills outward from the shell as it's pulled.
    KPArtPath back = band(trigger, 1.13 * M_PI, 6.8);
    const float pull = a.pull(side ? SDL_GAMEPAD_AXIS_RIGHT_TRIGGER : SDL_GAMEPAD_AXIS_LEFT_TRIGGER);
    const CGFloat reach = shown + (trigger + 3.4 - shown) * pull;
    const CGRect level = CGRectMake(corner.x - reach, corner.y - reach, 2 * reach + 40, 2 * reach);
    KPArtPath fill = CGPathCreateWithRoundedRect(level, reach - 0.01, reach - 0.01, &flip);
    KPArtDrop(a, back, 1.2, 0.8, false);
    CGContextSaveGState(c);
    CGContextAddPath(c, back);
    CGContextClip(c);
    KPArtWash(c, CGPathGetBoundingBox(back), a.tone.backTop, a.tone.backBottom);
    if (pull > 0.01) KPArtGradient(c, fill, KPArtMix(a.state.accent, 0xffffff, 0.15), KPArtMix(a.state.accent, 0x000000, 0.1));
    if (!a.small) KPArtRim(c, back, a.line(1.0, 0.8), 0xffffff, a.dark ? 0.3 : 0.9);
    CGContextRestoreGState(c);
    KPArtStroke(c, back, a.tone.partLine, a.line(0.8, 0.75));
    NSString *name = side ? @"ZR" : @"ZL";
    if (a.big) {
      const CGPoint p = CGPointApplyAffineTransform(CGPointMake(76, corner.y - (shown + trigger + 3.4) / 2), flip);
      KPArtLabel(name, p, 4.6, a.tone.letter);
      if (pull > 0.01) {
        CGContextSaveGState(c);
        CGContextAddPath(c, fill);
        CGContextClip(c);
        KPArtLabel(name, p, 4.6, KPArtInkOn(a.state.accent));
        CGContextRestoreGState(c);
      }
    }
    KPArtPath front = band(bumper, 1.1 * M_PI, 7.2);
    KPArtPart(a, side ? SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER : SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, front, !a.big ? nil : side ? @"R" : @"L",
              5.4, at((21 + bumper + 3.6) / 2));
  }
}
// Joy-Con pair: two halves, each flat along its rail and rounded outside; the left with its stick
// above four direction buttons, the right with its face buttons above the stick.
static void KPArtJoyCon(const KPArtCtx &a) {
  CGContextRef c = a.c;
  KPArtJoyConShoulders(a);
  for (int side = 0; side < 2; ++side) {
    const CGFloat inner = side ? 106 : 94, outer = side ? 154 : 46;
    const CGPoint v[4] = {{inner, 15.5}, {outer, 15.5}, {outer, 117}, {inner, 117}};
    const CGFloat radii[4] = {2.5, 21, 21, 2.5};
    KPArtPath half = KPArtPolygon(v, 4, radii);
    KPArtShell(a, half);
    // The rail, a darker strip down the inside edge.
    CGContextSaveGState(c);
    CGContextAddPath(c, half);
    CGContextClip(c);
    KPArtPath rail = CGPathCreateWithRect(CGRectMake(side ? inner : inner - 3.2, 15.5, 3.2, 101.5), nullptr);
    KPArtGradient(c, rail, a.dark ? 0x2b3136 : 0xd3dade, a.dark ? 0x23282c : 0xc2cbd0);
    CGContextRestoreGState(c);
    KPArtStroke(c, half, a.tone.outline, a.line(1.2, 1.0), a.dark ? 0.85 : 1);
  }
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(69, 42), 12.5);
  static const int arrows[4] = {SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_DPAD_DOWN,
                                SDL_GAMEPAD_BUTTON_DPAD_LEFT};
  for (int arm = 0; arm < 4; ++arm) {
    const CGPoint at = CGPointMake(69 + 10.5 * (arm == 1 ? 1 : arm == 3 ? -1 : 0), 81 + 10.5 * (arm == 2 ? 1 : arm == 0 ? -1 : 0));
    KPArtButton(a, arrows[arm], at, 5.4);
    if (!a.small) KPArtArrowhead(c, at, 3.2, arm, a.held(arrows[arm]) ? KPArtInkOn(a.state.accent) : a.tone.letter, 0.55);
  }
  KPArtFace(a, CGPointMake(131, 42), 10.5, 5.6, @"B", @"A", @"Y", @"X");
  KPArtStick(a, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_AXIS_RIGHTX, CGPointMake(131, 81), 12.5);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(85, 23.5), 3.3);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(85, 23.5), 3.4, false);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(115, 23.5), 3.3);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(115, 23.5), 3.4, true);
  KPArtPath capture = KPArtRound(CGRectMake(80, 99, 7, 7), 1.8);
  KPArtPart(a, SDL_GAMEPAD_BUTTON_MISC1, capture);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(117, 102.5), 4.2);
}

// The Wii Remote's four player lights; the player's own lit in their colour, or all four softly
// while it isn't playing.
static void KPArtLights(const KPArtCtx &a, CGPoint first, CGPoint step, CGSize size) {
  const int player = KPArtPlayer(a.state.accent);
  for (int i = 0; i < 4; ++i) {
    const CGRect r = CGRectMake(first.x + step.x * i - size.width / 2, first.y + step.y * i - size.height / 2, size.width, size.height);
    KPArtPath led = KPArtRound(r, std::min(size.width, size.height) / 2);
    const bool lit = player < 0 || player == i;
    const unsigned ink = player < 0 ? 0x5ccbf3 : a.state.accent;
    if (lit) KPArtStroke(a.c, led, ink, a.line(2.2, 1.0), 0.3);
    KPArtFill(a.c, led, lit ? ink : a.dark ? 0x2a3035 : 0xcfd7db);
    KPArtStroke(a.c, led, lit ? KPArtMix(ink, 0x000000, 0.3) : a.tone.partLine, a.line(0.5, 0.4), 0.7);
  }
}
// Speaker holes: a little ring of dots.
static void KPArtSpeaker(const KPArtCtx &a, CGPoint at, CGFloat r) {
  if (a.small) return;
  KPSetInk(a.c, a.dark ? 0x1d2124 : 0x9aa6ad, 0.8);
  CGContextFillEllipseInRect(a.c, CGRectMake(at.x - 0.75, at.y - 0.75, 1.5, 1.5));
  for (int i = 0; i < 6; ++i)
    CGContextFillEllipseInRect(a.c, CGRectMake(at.x + r * cos(i * M_PI / 3) - 0.7, at.y + r * sin(i * M_PI / 3) - 0.7, 1.4, 1.4));
}
// The dark window over the pointer's sensor at one end.
static void KPArtWindow(const KPArtCtx &a, CGPathRef body, CGRect r) {
  CGContextSaveGState(a.c);
  CGContextAddPath(a.c, body);
  CGContextClip(a.c);
  KPArtPath window = CGPathCreateWithRect(r, nullptr);
  KPArtGradient(a.c, window, a.dark ? 0x2a3035 : 0x6b767d, a.dark ? 0x15181b : 0x3d464c);
  KPArtGradient(a.c, window, 0xffffff, 0xffffff, a.dark ? 0.14 : 0.35, 0, 0, 0.55);
  CGContextRestoreGState(a.c);
}

// Wii Remote held sideways, as for racing: the pointer end on the left, the D-pad under the left
// thumb, A, − HOME + in a column, 1 and 2 on the right, the player lights at the far end, B peeking
// out underneath and the wrist strap. SDL names the D-pad as for the remote held upright (pointer
// end up) and doesn't turn it for sideways play, so the cross is turned a quarter: the arm under the
// player's thumb that SDL calls left points down here, up points left, and so on.
static void KPArtWiiRemote(const KPArtCtx &a) {
  CGContextRef c = a.c;
  const CGRect face = CGRectMake(4, 25, 192, 56);
  const CGFloat y = CGRectGetMidY(face);
  if (!a.small) {
    CGMutablePathRef strap = CGPathCreateMutable();
    CGPathMoveToPoint(strap, nullptr, 186, 84);
    CGPathAddCurveToPoint(strap, nullptr, 182, 99, 173, 114, 182, 118);
    CGPathAddCurveToPoint(strap, nullptr, 191, 122, 197, 104, 192, 84);
    KPArtStroke(c, strap, a.tone.outline, a.line(2.6, 1.6), a.dark ? 0.9 : 0.8);
    KPArtStroke(c, strap, a.dark ? 0x6a747b : 0xdfe5e8, a.line(1.4, 0.8));
    CGPathRelease(strap);
    KPArtPath lock = KPArtRound(CGRectMake(181.2, 98, 7, 6), 2);
    KPArtPart(a, -1, lock);
  }
  KPArtPath b = KPArtRound(CGRectMake(66, 78, 28, 23), 8);
  KPArtPart(a, SDL_GAMEPAD_BUTTON_SOUTH, b, a.big ? @"B" : nil, 5.6, CGPointMake(80, 95.6));
  // The remote's side, under its face, gives it depth.
  KPArtPath side = KPArtRound(CGRectOffset(face, 0, 7), 19), top = KPArtRound(face, 19);
  KPArtDrop(a, side, 2);
  KPArtGradient(c, side, a.dark ? 0x3d454b : 0xdde3e6, a.dark ? 0x2a3035 : 0xc4cdd2);
  KPArtStroke(c, side, a.tone.outline, a.line(1.2, 1.0), a.dark ? 0.85 : 1);
  KPArtShell(a, top, false);
  KPArtWindow(a, top, CGRectMake(face.origin.x, face.origin.y, 9, face.size.height));
  KPArtStroke(c, top, a.tone.outline, a.line(1.2, 1.0), a.dark ? 0.85 : 1);
  KPArtButton(a, -1, CGPointMake(24, y + 16), 3);
  KPArtDpad(a, CGPointMake(45, y), 33, 3);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(83, y), 11, @"A");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(110, y - 14.5), 4);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(110, y - 14.5), 3.8, true);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(110, y), 4.8);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(110, y + 14.5), 4);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(110, y + 14.5), 3.8, false);
  KPArtSpeaker(a, CGPointMake(127, y), 3.4);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(147, y), 8.2, @"1");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(168.5, y), 8.2, @"2");
  KPArtLights(a, CGPointMake(185.5, y + 12.6), CGPointMake(0, -8.4), CGSizeMake(3.2, 4.6));
}

// Wii Remote upright with a Nunchuk on its cord: the Nunchuk's egg shape with its stick, C and Z
// peeking over the top; the remote beside it as it's held for pointing, its D-pad as SDL names it.
static void KPArtNunchukPair(const KPArtCtx &a) {
  CGContextRef c = a.c;
  const CGFloat x = 138;
  CGMutablePathRef cord = CGPathCreateMutable();
  CGPathMoveToPoint(cord, nullptr, 70, 108);
  CGPathAddCurveToPoint(cord, nullptr, 70, 124, x - 4, 124, x, 113);
  KPArtStroke(c, cord, a.tone.outline, a.line(2.8, 1.6), a.dark ? 0.9 : 0.8);
  KPArtStroke(c, cord, a.dark ? 0x6a747b : 0xe3e8eb, a.line(1.5, 0.8));
  CGPathRelease(cord);
  // Nunchuk.
  KPArtTrigger(a, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, CGRectMake(48, 12.5, 44, 18), 8, 9, @"Z", 13);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, CGPointMake(70, 12), 5.2, @"C");
  static const KPArtCurve egg[] = {{88, 21.5, 98, 35, 97, 50}, {96, 65, 86, 78, 82, 94}, {79, 105, 76, 110, 70, 110}};
  KPArtPath nunchuk = KPArtMirrored(CGPointMake(70, 21.5), egg, 3, 70);
  KPArtShell(a, nunchuk);
  KPArtStick(a, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_AXIS_LEFTX, CGPointMake(70, 49.5), 14.5);
  // Remote, with B on its back peeking out the side.
  KPArtPath b = KPArtRound(CGRectMake(150, 46, 11, 17), 4.5);
  KPArtPart(a, SDL_GAMEPAD_BUTTON_SOUTH, b);
  const CGRect face = CGRectMake(x - 17, 5, 34, 109);
  KPArtPath remote = KPArtRound(face, 13);
  KPArtShell(a, remote);
  KPArtWindow(a, remote, CGRectMake(face.origin.x, face.origin.y, face.size.width, 8));
  KPArtStroke(c, remote, a.tone.outline, a.line(1.2, 1.0), a.dark ? 0.85 : 1);
  KPArtButton(a, -1, CGPointMake(x - 9, 17.5), 2.4);
  KPArtDpad(a, CGPointMake(x, 31), 22);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_EAST, CGPointMake(x, 53.5), 8.4, @"A");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(x - 9.5, 72), 3);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_BACK, CGPointMake(x - 9.5, 72), 3, false);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_GUIDE, CGPointMake(x, 72), 3.6);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(x + 9.5, 72), 3);
  KPArtSign(a, SDL_GAMEPAD_BUTTON_START, CGPointMake(x + 9.5, 72), 3, true);
  KPArtSpeaker(a, CGPointMake(x, 81), 2.6);
  KPArtButton(a, SDL_GAMEPAD_BUTTON_WEST, CGPointMake(x, 91), 5.4, @"1");
  KPArtButton(a, SDL_GAMEPAD_BUTTON_NORTH, CGPointMake(x, 102.5), 5.4, @"2");
  KPArtLights(a, CGPointMake(x - 7.5, 109.5), CGPointMake(5, 0), CGSizeMake(3, 1.8));
}

// A small keyboard with the keys the game uses lit as they're pressed; the rest stay quiet.
static void KPArtKeyboard(const KPArtCtx &a) {
  CGContextRef c = a.c;
  int keyCount = 0;
  const bool *keys = SDL_GetKeyboardState(&keyCount);
  auto down = [&](SDL_Scancode code) { return (int)code < keyCount && keys[code]; };
  KPArtPath plate = KPArtRound(CGRectMake(4, 20, 192, 86), 11);
  KPArtShell(a, plate);
  struct Key { SDL_Scancode code; CGFloat x, y, w; const char *label; bool game; };
  const CGFloat p = 16, k = 14;  // key pitch and size
  auto col = [&](CGFloat n, CGFloat indent) { return 10 + indent + n * p; };
  const Key keyset[] = {
    {SDL_SCANCODE_Q, col(0, 0), 28, k, "Q", true}, {SDL_SCANCODE_W, col(1, 0), 28, k, "W", true},
    {SDL_SCANCODE_E, col(2, 0), 28, k, "E", true}, {SDL_SCANCODE_R, col(3, 0), 28, k, "R", false},
    {SDL_SCANCODE_T, col(4, 0), 28, k, "T", false}, {SDL_SCANCODE_Y, col(5, 0), 28, k, "Y", false},
    {SDL_SCANCODE_U, col(6, 0), 28, k, "U", true}, {SDL_SCANCODE_I, col(7, 0), 28, k, "I", true},
    {SDL_SCANCODE_O, col(8, 0), 28, k, "O", false}, {SDL_SCANCODE_P, col(9, 0), 28, k, "P", false},
    {SDL_SCANCODE_BACKSPACE, col(10, 0), 28, 20, "⌫", true},
    {SDL_SCANCODE_A, col(0, 4), 44, k, "A", true}, {SDL_SCANCODE_S, col(1, 4), 44, k, "S", true},
    {SDL_SCANCODE_D, col(2, 4), 44, k, "D", true}, {SDL_SCANCODE_F, col(3, 4), 44, k, "F", false},
    {SDL_SCANCODE_G, col(4, 4), 44, k, "G", false}, {SDL_SCANCODE_H, col(5, 4), 44, k, "H", false},
    {SDL_SCANCODE_J, col(6, 4), 44, k, "J", true}, {SDL_SCANCODE_K, col(7, 4), 44, k, "K", true},
    {SDL_SCANCODE_L, col(8, 4), 44, k, "L", true}, {SDL_SCANCODE_RETURN, col(9, 4), 44, 26, "⏎", true},
    {SDL_SCANCODE_LSHIFT, col(0, 0), 60, 22, "⇧", true}, {SDL_SCANCODE_Z, col(0, 24), 60, k, "Z", false},
    {SDL_SCANCODE_X, col(1, 24), 60, k, "X", false}, {SDL_SCANCODE_C, col(2, 24), 60, k, "C", false},
    {SDL_SCANCODE_V, col(3, 24), 60, k, "V", false}, {SDL_SCANCODE_B, col(4, 24), 60, k, "B", false},
    {SDL_SCANCODE_N, col(5, 24), 60, k, "N", false}, {SDL_SCANCODE_M, col(6, 24), 60, k, "M", true},
    {SDL_SCANCODE_UP, col(9, 4), 60, k, "↑", true},
    {SDL_SCANCODE_LCTRL, col(0, 0), 76, k, "⌃", true}, {SDL_SCANCODE_LALT, col(1, 0), 76, k, "⌥", true},
    {SDL_SCANCODE_LGUI, col(2, 0), 76, k, "⌘", false}, {SDL_SCANCODE_SPACE, col(3, 0), 76, 5 * p - 2, "", true},
    {SDL_SCANCODE_LEFT, col(8, 4), 76, k, "←", true}, {SDL_SCANCODE_DOWN, col(9, 4), 76, k, "↓", true},
    {SDL_SCANCODE_RIGHT, col(10, 4), 76, k, "→", true},
  };
  for (const Key &key : keyset) {
    const CGRect r = CGRectMake(key.x, key.y, key.w, k);
    const bool held = down(key.code);
    KPArtPath cap = KPArtRound(r, 3);
    if (!held) {
      CGContextSaveGState(c);
      CGContextTranslateCTM(c, 0, a.line(0.9, 0.6));
      KPArtFill(c, cap, 0x000000, a.dark ? 0.45 : 0.14);
      CGContextRestoreGState(c);
    }
    const unsigned top = held ? KPArtMix(a.state.accent, 0xffffff, 0.2) : key.game ? a.tone.partTop : a.dark ? 0x4a535a : 0xf1f4f5;
    const unsigned bottom = held ? KPArtMix(a.state.accent, 0x000000, 0.08) : key.game ? a.tone.partBottom : a.dark ? 0x3c444a : 0xe4e9ec;
    KPArtSurface(c, cap, top, bottom, a.line(1.0, 0.8), a.small ? 0 : held ? 0.45 : a.dark ? 0.25 : 0.9);
    KPArtStroke(c, cap, held ? KPArtMix(a.state.accent, 0x000000, 0.35) : key.game ? a.tone.partLine : KPArtMix(a.tone.partLine, a.tone.bodyBottom, 0.45),
                a.line(0.8, 0.6));
    if (key.label[0] && a.words(7.5))
      KPArtLabel(@(key.label), CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)), 7.5,
                 held ? KPArtInkOn(a.state.accent) : key.game ? a.tone.letter : KPArtMix(a.tone.letter, a.tone.partBottom, 0.6));
  }
}

static void KPDrawControllerArt(CGContextRef c, CGRect r, KPPadFamily family, const KPArtState &state, NSString *systemName = nil) {
  const CGFloat s = std::min(r.size.width / 200, r.size.height / 124);
  if (!(s > 0)) return;
  // A phone: the handset with the controller page on it (KartPadPhoneControllers.inc.mm).
  if (family == KPFamilyPhone) {
    KPDrawPhoneArt(c, CGRectInset(r, r.size.width * 0.03, r.size.height * 0.14), state.accent);
    return;
  }
  const bool dark = KPP == &KPDarkPalette;
  CGContextSaveGState(c);
  CGContextTranslateCTM(c, r.origin.x + (r.size.width - 200 * s) / 2, r.origin.y + (r.size.height - 124 * s) / 2);
  CGContextScaleCTM(c, s, s);
  CGContextSetLineJoin(c, kCGLineJoinRound);
  CGContextSetLineCap(c, kCGLineCapRound);
  const KPArtCtx a{c, state, s, dark, s < 0.6, s >= 1.6, dark ? KPArtDarkTones : KPArtLightTones};
  switch (KPArtLayoutFor(family)) {
    case KPArtLayout::Keyboard: KPArtKeyboard(a); break;
    case KPArtLayout::WiiRemote:
      if ([systemName containsString:@"Nunchuk"]) KPArtNunchukPair(a);
      else KPArtWiiRemote(a);
      break;
    case KPArtLayout::JoyCon: KPArtJoyCon(a); break;
    case KPArtLayout::GameCube: KPArtGameCube(a); break;
    case KPArtLayout::Symmetric: KPArtPlayStation(a); break;
    case KPArtLayout::Nintendo: KPArtPro(a); break;
    case KPArtLayout::Offset:
      if (family == KPFamilyGeneric) KPArtGeneric(a);
      else KPArtXbox(a);
      break;
  }
  CGContextRestoreGState(c);
}

static KPArtState KPArtStateFor(KPPadDevice *device, unsigned accent) {
  KPArtState state;
  state.accent = accent;
  if (device == nil) return state;
  if (!device.isKeyboard) {
    state.buttons = device.buttons;
    for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; ++axis) state.axes[axis] = device->axes[axis];
  }
  return state;
}

// The small icon for a kind of controller, where there's no room for its drawing (toasts, HOME).
static KPUIGlyph KPFamilyGlyph(KPPadFamily family) {
  switch (family) {
    case KPFamilyKeyboard: return KPUIGlyph::Keyboard;
    case KPFamilyWiiRemote: return KPUIGlyph::WiiRemote;
    case KPFamilyPhone: return KPUIGlyph::Phone;
    default: return KPUIGlyph::Pad;
  }
}
