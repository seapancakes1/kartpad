// Icons for KartPad's screens, drawn in code on a 40-unit grid in one ink, in the Mii editor's
// rounded line style. They're generic shapes (a house, a gamepad, a gear), never a console maker's
// logo. Included by KartPadMacShell.mm with the overlay.

// New glyphs go at the end: some code stores them as ints.
enum class KPUIGlyph {
  Home, Play, Swap, Mii, Pad, Gear, Power, Speaker, SpeakerOff, Window, FullScreen, Plus, Keyboard,
  Restart, Find, Move, Close, Chevron, Back, WiiRemote, Bluetooth, Check, Buttons, Battery, Disc, Order, Search, Ghost, Export,
  Phone, Download, Folder, Picture, Game, Advanced
};

static void KPGlyphPath(CGContextRef c, CGPathRef path, bool fill) {
  CGContextAddPath(c, path);
  if (fill) CGContextFillPath(c);
  else CGContextStrokePath(c);
}
static void KPGlyphRounded(CGContextRef c, CGRect r, CGFloat radius, bool fill) {
  CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, nullptr);
  KPGlyphPath(c, path, fill);
  CGPathRelease(path);
}
static void KPGlyphRing(CGContextRef c, CGFloat x, CGFloat y, CGFloat radius) {
  CGContextStrokeEllipseInRect(c, CGRectMake(x - radius, y - radius, radius * 2, radius * 2));
}
// An open arrowhead, drawn like the chevrons, with its tip at tip.
static void KPGlyphHead(CGContextRef c, CGPoint tip, CGFloat angle, CGFloat arm) {
  CGContextMoveToPoint(c, tip.x - arm * cos(angle - M_PI_4), tip.y - arm * sin(angle - M_PI_4));
  CGContextAddLineToPoint(c, tip.x, tip.y);
  CGContextAddLineToPoint(c, tip.x - arm * cos(angle + M_PI_4), tip.y - arm * sin(angle + M_PI_4));
  CGContextStrokePath(c);
}
static void KPGlyphArrow(CGContextRef c, CGPoint from, CGPoint to, CGFloat arm) {
  KPLine(c, from.x, from.y, to.x, to.y);
  KPGlyphHead(c, to, atan2(to.y - from.y, to.x - from.x), arm);
}

// level is 0…1 for Speaker and Battery.
static void KPDrawGlyph(CGContextRef c, KPUIGlyph glyph, CGRect rect, unsigned ink, CGFloat level = 1) {
  CGContextSaveGState(c);
  CGContextTranslateCTM(c, rect.origin.x, rect.origin.y);
  CGContextScaleCTM(c, rect.size.width / 40, rect.size.height / 40);
  KPSetInk(c, ink);
  CGContextSetLineWidth(c, 3.4);
  CGContextSetLineCap(c, kCGLineCapRound);
  CGContextSetLineJoin(c, kCGLineJoinRound);
  switch (glyph) {
    case KPUIGlyph::Home: {
      // A house with a door: the HOME button's mark.
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 4, 20);
      CGPathAddLineToPoint(p, nullptr, 20, 5);
      CGPathAddLineToPoint(p, nullptr, 36, 20);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      CGMutablePathRef body = CGPathCreateMutable();
      CGPathMoveToPoint(body, nullptr, 9, 17);
      CGPathAddLineToPoint(body, nullptr, 9, 35);
      CGPathAddLineToPoint(body, nullptr, 17, 35);
      CGPathAddLineToPoint(body, nullptr, 17, 25);
      CGPathAddLineToPoint(body, nullptr, 23, 25);
      CGPathAddLineToPoint(body, nullptr, 23, 35);
      CGPathAddLineToPoint(body, nullptr, 31, 35);
      CGPathAddLineToPoint(body, nullptr, 31, 17);
      KPGlyphPath(c, body, false);
      CGPathRelease(body);
      break;
    }
    case KPUIGlyph::Play: {
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 13, 7);
      CGPathAddLineToPoint(p, nullptr, 33, 20);
      CGPathAddLineToPoint(p, nullptr, 13, 33);
      CGPathCloseSubpath(p);
      CGContextAddPath(c, p);
      CGContextSetLineWidth(c, 4);
      CGContextDrawPath(c, kCGPathFillStroke);
      CGPathRelease(p);
      break;
    }
    case KPUIGlyph::Swap: {
      // Two arrows passing each other: change one thing for another.
      CGContextSetLineWidth(c, 4);
      KPGlyphArrow(c, CGPointMake(6, 12.5), CGPointMake(32, 12.5), 7.5);
      KPGlyphArrow(c, CGPointMake(34, 27.5), CGPointMake(8, 27.5), 7.5);
      break;
    }
    case KPUIGlyph::Mii: {
      // A round head on shoulders.
      CGContextFillEllipseInRect(c, CGRectMake(12, 3, 16, 17));
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 6, 36);
      CGPathAddCurveToPoint(p, nullptr, 6, 26.8, 12.6, 23, 20, 23);
      CGPathAddCurveToPoint(p, nullptr, 27.4, 23, 34, 26.8, 34, 36);
      CGPathCloseSubpath(p);
      CGContextAddPath(c, p);
      CGContextSetLineWidth(c, 2);
      CGContextDrawPath(c, kCGPathFillStroke);
      CGPathRelease(p);
      break;
    }
    case KPUIGlyph::Pad: {
      // A two-grip gamepad with a D-pad and two face buttons.
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 11, 11);
      CGPathAddLineToPoint(p, nullptr, 29, 11);
      CGPathAddCurveToPoint(p, nullptr, 35, 11, 37, 16, 38, 22);
      CGPathAddCurveToPoint(p, nullptr, 39.5, 30, 37, 33, 34, 33);
      CGPathAddCurveToPoint(p, nullptr, 31, 33, 29, 29, 26, 26);
      CGPathAddLineToPoint(p, nullptr, 14, 26);
      CGPathAddCurveToPoint(p, nullptr, 11, 29, 9, 33, 6, 33);
      CGPathAddCurveToPoint(p, nullptr, 3, 33, 0.5, 30, 2, 22);
      CGPathAddCurveToPoint(p, nullptr, 3, 16, 5, 11, 11, 11);
      CGPathCloseSubpath(p);
      CGContextSetLineWidth(c, 3);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      CGContextSetLineWidth(c, 2.6);
      KPLine(c, 8, 18.5, 14, 18.5);
      KPLine(c, 11, 15.5, 11, 21.5);
      CGContextFillEllipseInRect(c, CGRectMake(26.5, 14, 4, 4));
      CGContextFillEllipseInRect(c, CGRectMake(30.5, 18.5, 4, 4));
      break;
    }
    case KPUIGlyph::Gear: {
      // Six chunky teeth round a hole: Settings.
      CGMutablePathRef p = CGPathCreateMutable();
      const CGFloat step = M_PI / 3;
      for (int i = 0; i < 6; ++i) {
        const CGFloat a = -M_PI_2 + i * step;
        CGPathAddArc(p, nullptr, 20, 20, 12, a - step / 2, a - 0.29, false);
        CGPathAddArc(p, nullptr, 20, 20, 17, a - 0.19, a + 0.19, false);
        CGPathAddArc(p, nullptr, 20, 20, 12, a + 0.29, a + step / 2, false);
      }
      CGPathCloseSubpath(p);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      KPGlyphRing(c, 20, 20, 4.6);
      break;
    }
    case KPUIGlyph::Power: {
      CGContextAddArc(c, 20, 21, 13, -M_PI_2 + 0.75, -M_PI_2 - 0.75 + 2 * M_PI, 0);
      CGContextStrokePath(c);
      KPLine(c, 20, 4, 20, 19);
      break;
    }
    case KPUIGlyph::Speaker:
    case KPUIGlyph::SpeakerOff: {
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 5, 15.5);
      CGPathAddLineToPoint(p, nullptr, 11.5, 15.5);
      CGPathAddLineToPoint(p, nullptr, 19.5, 8.5);
      CGPathAddLineToPoint(p, nullptr, 19.5, 31.5);
      CGPathAddLineToPoint(p, nullptr, 11.5, 24.5);
      CGPathAddLineToPoint(p, nullptr, 5, 24.5);
      CGPathCloseSubpath(p);
      CGContextAddPath(c, p);
      CGContextSetLineWidth(c, 2.4);
      CGContextDrawPath(c, kCGPathFillStroke);
      CGPathRelease(p);
      CGContextSetLineWidth(c, 3.4);
      if (glyph == KPUIGlyph::SpeakerOff) {
        KPLine(c, 25.5, 15, 35.5, 25);
        KPLine(c, 35.5, 15, 25.5, 25);
      } else {
        if (level > 0.05) {
          CGContextAddArc(c, 20, 20, 7, -0.8, 0.8, 0);
          CGContextStrokePath(c);
        }
        if (level > 0.5) {
          CGContextAddArc(c, 20, 20, 13, -0.85, 0.85, 0);
          CGContextStrokePath(c);
        }
      }
      break;
    }
    case KPUIGlyph::Window: {
      // A window with a solid title bar.
      CGContextSetLineWidth(c, 3.2);
      CGPathRef frame = CGPathCreateWithRoundedRect(CGRectMake(5, 8, 30, 24), 5, 5, nullptr);
      CGContextSaveGState(c);
      CGContextAddPath(c, frame);
      CGContextClip(c);
      CGContextFillRect(c, CGRectMake(5, 8, 30, 7));
      CGContextRestoreGState(c);
      KPGlyphPath(c, frame, false);
      CGPathRelease(frame);
      break;
    }
    case KPUIGlyph::FullScreen: {
      // Four rounded corners pointing out.
      for (int x : {0, 1})
        for (int y : {0, 1}) {
          const CGFloat cx = x ? 34 : 6, cy = y ? 33 : 7, sx = x ? -1 : 1, sy = y ? -1 : 1;
          CGContextMoveToPoint(c, cx, cy + sy * 9.5);
          CGContextAddArcToPoint(c, cx, cy, cx + sx * 9.5, cy, 4);
          CGContextAddLineToPoint(c, cx + sx * 9.5, cy);
          CGContextStrokePath(c);
        }
      break;
    }
    case KPUIGlyph::Plus: {
      CGContextSetLineWidth(c, 4.2);
      KPLine(c, 20, 7, 20, 33);
      KPLine(c, 7, 20, 33, 20);
      break;
    }
    case KPUIGlyph::Keyboard: {
      // Two rows of round keys over a space bar.
      CGContextSetLineWidth(c, 3.2);
      KPGlyphRounded(c, CGRectMake(3.5, 9, 33, 22), 5, false);
      for (int row = 0; row < 2; ++row)
        for (int col = 0; col < 4; ++col)
          CGContextFillEllipseInRect(c, CGRectMake(9.2 + col * 6, 13.2 + row * 5.2, 3.6, 3.6));
      CGContextSetLineWidth(c, 3);
      KPLine(c, 14, 25.8, 26, 25.8);
      break;
    }
    case KPUIGlyph::Restart: {
      // A clockwise circle arrow, open at the top right.
      CGContextSetLineWidth(c, 3.6);
      CGContextAddArc(c, 20, 21.3, 12.5, -M_PI / 5, M_PI * 1.5, 0);
      CGContextStrokePath(c);
      KPGlyphHead(c, CGPointMake(20.8, 8.8), 0.06, 7);
      break;
    }
    case KPUIGlyph::Find: {
      // A remote with its light on, buzzing: "this one is me".
      CGContextSetLineWidth(c, 3.2);
      KPGlyphRounded(c, CGRectMake(14, 7, 12, 26), 5, false);
      CGContextFillEllipseInRect(c, CGRectMake(18.1, 11.1, 3.8, 3.8));
      CGContextSetLineWidth(c, 3);
      for (CGFloat side : {0.0, M_PI}) {
        CGContextAddArc(c, 20, 20, 12.8, side - 0.48, side + 0.48, 0);
        CGContextStrokePath(c);
        CGContextAddArc(c, 20, 20, 18, side - 0.42, side + 0.42, 0);
        CGContextStrokePath(c);
      }
      break;
    }
    case KPUIGlyph::Move: {
      // Arrows out four ways.
      CGContextSetLineWidth(c, 3.6);
      KPLine(c, 20, 5.5, 20, 34.5);
      KPLine(c, 5.5, 20, 34.5, 20);
      for (int i = 0; i < 4; ++i) {
        const CGFloat a = i * M_PI_2;
        KPGlyphHead(c, CGPointMake(20 + 15 * cos(a), 20 + 15 * sin(a)), a, 5.5);
      }
      break;
    }
    case KPUIGlyph::Close: {
      CGContextSetLineWidth(c, 4);
      KPLine(c, 10, 10, 30, 30);
      KPLine(c, 30, 10, 10, 30);
      break;
    }
    case KPUIGlyph::Chevron: {
      CGContextSetLineWidth(c, 4.2);
      CGContextMoveToPoint(c, 15, 8);
      CGContextAddLineToPoint(c, 27, 20);
      CGContextAddLineToPoint(c, 15, 32);
      CGContextStrokePath(c);
      break;
    }
    case KPUIGlyph::Back: {
      CGContextSetLineWidth(c, 4.2);
      CGContextMoveToPoint(c, 25, 8);
      CGContextAddLineToPoint(c, 13, 20);
      CGContextAddLineToPoint(c, 25, 32);
      CGContextStrokePath(c);
      break;
    }
    case KPUIGlyph::WiiRemote: {
      // A remote held upright: D-pad, A, then 1 and 2.
      CGContextSetLineWidth(c, 3.2);
      KPGlyphRounded(c, CGRectMake(13.5, 2.5, 13, 35), 6, false);
      CGContextSetLineWidth(c, 2.6);
      KPLine(c, 17, 10.5, 23, 10.5);
      KPLine(c, 20, 7.5, 20, 13.5);
      CGContextFillEllipseInRect(c, CGRectMake(17.4, 17.4, 5.2, 5.2));
      CGContextFillEllipseInRect(c, CGRectMake(18.4, 26, 3.2, 3.2));
      CGContextFillEllipseInRect(c, CGRectMake(18.4, 31, 3.2, 3.2));
      break;
    }
    case KPUIGlyph::Bluetooth: {
      CGContextSetLineWidth(c, 3.2);
      CGContextMoveToPoint(c, 12, 13);
      CGContextAddLineToPoint(c, 28, 27);
      CGContextAddLineToPoint(c, 20, 34);
      CGContextAddLineToPoint(c, 20, 6);
      CGContextAddLineToPoint(c, 28, 13);
      CGContextAddLineToPoint(c, 12, 27);
      CGContextStrokePath(c);
      break;
    }
    case KPUIGlyph::Check: {
      CGContextSetLineWidth(c, 4.5);
      CGContextMoveToPoint(c, 8, 21);
      CGContextAddLineToPoint(c, 17, 30);
      CGContextAddLineToPoint(c, 32, 11);
      CGContextStrokePath(c);
      break;
    }
    case KPUIGlyph::Buttons: {
      // Four face buttons in a diamond: "set up buttons".
      for (CGPoint p : {CGPointMake(20, 9), CGPointMake(31, 20), CGPointMake(20, 31), CGPointMake(9, 20)})
        CGContextStrokeEllipseInRect(c, CGRectMake(p.x - 5, p.y - 5, 10, 10));
      CGContextFillEllipseInRect(c, CGRectMake(15, 26, 10, 10));
      break;
    }
    case KPUIGlyph::Battery: {
      CGContextSetLineWidth(c, 3);
      KPGlyphRounded(c, CGRectMake(3, 11.5, 31, 17), 5, false);
      KPGlyphRounded(c, CGRectMake(35, 16, 3.2, 8), 1.6, true);
      const CGFloat fill = std::clamp(level, CGFloat(0), CGFloat(1)) * 24;
      if (fill > 0) KPGlyphRounded(c, CGRectMake(6.5, 15, fill, 10), std::min(CGFloat(2), fill / 2), true);
      break;
    }
    case KPUIGlyph::Disc: {
      // A game disc in front of another: switch game. The back one stops short of the front one.
      CGContextAddArc(c, 24, 16, 11.5, 4.025, 6.971, 0);
      CGContextStrokePath(c);
      KPGlyphRing(c, 16, 24, 11.5);
      CGContextSetLineWidth(c, 3.2);
      KPGlyphRing(c, 16, 24, 3.3);
      break;
    }
    case KPUIGlyph::Order: {
      // A numbered list: players take their places in turn.
      CGContextSetLineWidth(c, 3);
      CGContextMoveToPoint(c, 4.5, 8.1);
      CGContextAddLineToPoint(c, 8.5, 4.5);
      CGContextAddLineToPoint(c, 8.5, 15);
      CGContextStrokePath(c);
      CGContextFillEllipseInRect(c, CGRectMake(6, 18.5, 5, 5));
      CGContextFillEllipseInRect(c, CGRectMake(6, 29.5, 5, 5));
      CGContextSetLineWidth(c, 3.4);
      KPLine(c, 16, 9.5, 35, 9.5);
      KPLine(c, 16, 21, 35, 21);
      KPLine(c, 16, 32, 35, 32);
      break;
    }
    case KPUIGlyph::Ghost: {
      // A ghost with a wavy hem: Time Trial ghosts.
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 8, 34);
      CGPathAddLineToPoint(p, nullptr, 8, 19);
      CGPathAddArc(p, nullptr, 20, 19, 12, M_PI, 0, false);
      CGPathAddLineToPoint(p, nullptr, 32, 34);
      CGPathAddLineToPoint(p, nullptr, 28, 30.5);
      CGPathAddLineToPoint(p, nullptr, 24, 34);
      CGPathAddLineToPoint(p, nullptr, 20, 30.5);
      CGPathAddLineToPoint(p, nullptr, 16, 34);
      CGPathAddLineToPoint(p, nullptr, 12, 30.5);
      CGPathCloseSubpath(p);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      CGContextFillEllipseInRect(c, CGRectMake(12.6, 15.5, 5, 6));
      CGContextFillEllipseInRect(c, CGRectMake(22.4, 15.5, 5, 6));
      break;
    }
    case KPUIGlyph::Export: {
      // An arrow out of a tray: save a copy somewhere else.
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 8, 22);
      CGPathAddLineToPoint(p, nullptr, 8, 34);
      CGPathAddLineToPoint(p, nullptr, 32, 34);
      CGPathAddLineToPoint(p, nullptr, 32, 22);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      KPGlyphArrow(c, CGPointMake(20, 27), CGPointMake(20, 5), 7);
      break;
    }
    case KPUIGlyph::Search: {
      // A magnifying glass: look for something.
      CGContextSetLineWidth(c, 3.6);
      KPGlyphRing(c, 17.5, 17.5, 10);
      CGContextSetLineWidth(c, 4.4);
      KPLine(c, 25.2, 25.2, 33, 33);
      break;
    }
    case KPUIGlyph::Phone: {
      // A phone held upright: wider than a remote, with a notch and a home bar.
      CGContextSetLineWidth(c, 3.2);
      KPGlyphRounded(c, CGRectMake(10.5, 3.5, 19, 33), 5, false);
      KPGlyphRounded(c, CGRectMake(16.5, 7, 7, 2.6), 1.3, true);
      CGContextSetLineWidth(c, 2.8);
      KPLine(c, 16.5, 31.5, 23.5, 31.5);
      break;
    }
    case KPUIGlyph::Download: {
      // An arrow down into a tray: bring a copy here. Export's opposite.
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 8, 22);
      CGPathAddLineToPoint(p, nullptr, 8, 34);
      CGPathAddLineToPoint(p, nullptr, 32, 34);
      CGPathAddLineToPoint(p, nullptr, 32, 22);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      KPGlyphArrow(c, CGPointMake(20, 5), CGPointMake(20, 27), 7);
      break;
    }
    case KPUIGlyph::Folder: {
      // A folder with a tab: choose a folder or a file.
      CGContextSetLineWidth(c, 3.2);
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 4, 20);
      CGPathAddArcToPoint(p, nullptr, 4, 8, 15, 8, 3);
      CGPathAddLineToPoint(p, nullptr, 15, 8);
      CGPathAddLineToPoint(p, nullptr, 19, 12);
      CGPathAddArcToPoint(p, nullptr, 36, 12, 36, 33, 3);
      CGPathAddArcToPoint(p, nullptr, 36, 33, 4, 33, 3);
      CGPathAddArcToPoint(p, nullptr, 4, 33, 4, 8, 3);
      CGPathCloseSubpath(p);
      KPGlyphPath(c, p, false);
      CGPathRelease(p);
      KPLine(c, 4, 18, 36, 18);
      break;
    }
    case KPUIGlyph::Picture: {
      // A landscape photo: hills and a sun in a frame.
      CGContextSetLineWidth(c, 3.2);
      CGPathRef frame = CGPathCreateWithRoundedRect(CGRectMake(4, 7, 32, 26), 5, 5, nullptr);
      CGContextSaveGState(c);
      CGContextAddPath(c, frame);
      CGContextClip(c);
      CGMutablePathRef hills = CGPathCreateMutable();
      CGPathMoveToPoint(hills, nullptr, 4, 33);
      CGPathAddLineToPoint(hills, nullptr, 4, 30);
      CGPathAddLineToPoint(hills, nullptr, 15, 19);
      CGPathAddLineToPoint(hills, nullptr, 22.5, 26.5);
      CGPathAddLineToPoint(hills, nullptr, 27, 22);
      CGPathAddLineToPoint(hills, nullptr, 36, 31);
      CGPathAddLineToPoint(hills, nullptr, 36, 33);
      CGPathCloseSubpath(hills);
      KPGlyphPath(c, hills, true);
      CGPathRelease(hills);
      CGContextRestoreGState(c);
      KPGlyphPath(c, frame, false);
      CGPathRelease(frame);
      CGContextFillEllipseInRect(c, CGRectMake(24, 11.5, 6, 6));
      break;
    }
    case KPUIGlyph::Game: {
      // A steering wheel: the game's own settings.
      KPGlyphRing(c, 20, 20, 15);
      KPLine(c, 5.5, 19, 34.5, 19);
      KPLine(c, 20, 21, 20, 34.5);
      CGContextFillEllipseInRect(c, CGRectMake(14.5, 14, 11, 11));
      break;
    }
    case KPUIGlyph::Advanced: {
      // Three sliders set at different points: fine-tuning.
      CGContextSetLineWidth(c, 3);
      const CGFloat knobs[3][2] = {{12, 9}, {27, 20}, {17, 31}};
      for (const auto &k : knobs) {
        const CGFloat x = k[0], y = k[1];
        KPLine(c, 4.5, y, x - 5.5, y);
        KPLine(c, x + 5.5, y, 35.5, y);
        KPGlyphRing(c, x, y, 3.8);
      }
      break;
    }
  }
  CGContextRestoreGState(c);
}
static void KPDrawGlyphIndex(CGContextRef c, int glyph, CGRect rect, unsigned ink) {
  KPDrawGlyph(c, static_cast<KPUIGlyph>(glyph), rect, ink);
}
