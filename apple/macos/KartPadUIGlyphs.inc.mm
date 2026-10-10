// Icons for KartPad's screens, drawn in code on a 40-unit grid in one ink, in the Mii editor's
// rounded line style. They're generic shapes (a house, a gamepad, a gear), never a console maker's
// logo. Included by KartPadMacShell.mm with the overlay.

enum class KPUIGlyph {
  Home, Play, Swap, Mii, Pad, Gear, Power, Speaker, SpeakerOff, Window, FullScreen, Plus, Keyboard,
  Restart, Find, Move, Close, Chevron, Back, WiiRemote, Bluetooth, Check, Buttons, Battery
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
      // Two arrows passing each other: switch games.
      KPArrow(c, CGPointMake(6, 13), CGPointMake(33, 13), 3.4);
      KPArrow(c, CGPointMake(34, 27), CGPointMake(7, 27), 3.4);
      break;
    }
    case KPUIGlyph::Mii: {
      // A round head on shoulders.
      CGContextFillEllipseInRect(c, CGRectMake(12, 3, 16, 17));
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathMoveToPoint(p, nullptr, 5, 37);
      CGPathAddCurveToPoint(p, nullptr, 5, 26, 12, 22, 20, 22);
      CGPathAddCurveToPoint(p, nullptr, 28, 22, 35, 26, 35, 37);
      CGPathCloseSubpath(p);
      KPGlyphPath(c, p, true);
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
      CGContextSetLineWidth(c, 3);
      for (int i = 0; i < 8; ++i) {
        const CGFloat a = i * M_PI / 4;
        KPLine(c, 20 + 11 * cos(a), 20 + 11 * sin(a), 20 + 16.5 * cos(a), 20 + 16.5 * sin(a));
      }
      CGContextSetLineWidth(c, 3.4);
      CGContextStrokeEllipseInRect(c, CGRectMake(8.5, 8.5, 23, 23));
      CGContextStrokeEllipseInRect(c, CGRectMake(15, 15, 10, 10));
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
      CGPathMoveToPoint(p, nullptr, 5, 15);
      CGPathAddLineToPoint(p, nullptr, 12, 15);
      CGPathAddLineToPoint(p, nullptr, 21, 7);
      CGPathAddLineToPoint(p, nullptr, 21, 33);
      CGPathAddLineToPoint(p, nullptr, 12, 25);
      CGPathAddLineToPoint(p, nullptr, 5, 25);
      CGPathCloseSubpath(p);
      KPGlyphPath(c, p, true);
      CGPathRelease(p);
      if (glyph == KPUIGlyph::SpeakerOff) {
        KPLine(c, 27, 14, 36, 26);
        KPLine(c, 36, 14, 27, 26);
      } else {
        if (level > 0.05) {
          CGContextAddArc(c, 21, 20, 7, -0.8, 0.8, 0);
          CGContextStrokePath(c);
        }
        if (level > 0.5) {
          CGContextAddArc(c, 21, 20, 13, -0.85, 0.85, 0);
          CGContextStrokePath(c);
        }
      }
      break;
    }
    case KPUIGlyph::Window: {
      CGContextSetLineWidth(c, 3);
      KPGlyphRounded(c, CGRectMake(5, 8, 30, 24), 4, false);
      KPLine(c, 5, 14, 35, 14);
      break;
    }
    case KPUIGlyph::FullScreen: {
      CGContextSetLineWidth(c, 3.4);
      for (int x : {0, 1})
        for (int y : {0, 1}) {
          const CGFloat cx = x ? 34 : 6, cy = y ? 33 : 7, sx = x ? -1 : 1, sy = y ? -1 : 1;
          CGContextMoveToPoint(c, cx, cy + sy * 9);
          CGContextAddLineToPoint(c, cx, cy);
          CGContextAddLineToPoint(c, cx + sx * 9, cy);
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
      CGContextSetLineWidth(c, 3);
      KPGlyphRounded(c, CGRectMake(3, 10, 34, 21), 4, false);
      for (int row = 0; row < 2; ++row)
        for (int col = 0; col < 5; ++col)
          CGContextFillRect(c, CGRectMake(8 + col * 5.6, 14.5 + row * 5, 3, 3));
      CGContextFillRect(c, CGRectMake(12, 25, 16, 2.6));
      break;
    }
    case KPUIGlyph::Restart: {
      CGContextAddArc(c, 20, 21, 12.5, -M_PI * 0.15, M_PI * 1.55, 0);
      CGContextStrokePath(c);
      KPArrowHead(c, CGPointMake(20 + 12.5 * cos(-M_PI * 0.15), 21 + 12.5 * sin(-M_PI * 0.15)), M_PI * 0.42, 9);
      break;
    }
    case KPUIGlyph::Find: {
      // Ripples out from a dot: "this one is me".
      CGContextFillEllipseInRect(c, CGRectMake(16, 16, 8, 8));
      CGContextSetLineWidth(c, 3);
      CGContextAddArc(c, 20, 20, 10, -0.9, 0.9, 0);
      CGContextStrokePath(c);
      CGContextAddArc(c, 20, 20, 10, M_PI - 0.9, M_PI + 0.9, 0);
      CGContextStrokePath(c);
      CGContextAddArc(c, 20, 20, 17, -0.75, 0.75, 0);
      CGContextStrokePath(c);
      CGContextAddArc(c, 20, 20, 17, M_PI - 0.75, M_PI + 0.75, 0);
      CGContextStrokePath(c);
      break;
    }
    case KPUIGlyph::Move: {
      KPArrow(c, CGPointMake(20, 20), CGPointMake(4, 20), 3.2);
      KPArrow(c, CGPointMake(20, 20), CGPointMake(36, 20), 3.2);
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
      CGContextSetLineWidth(c, 3);
      KPGlyphRounded(c, CGRectMake(13, 2, 14, 36), 5, false);
      CGContextFillEllipseInRect(c, CGRectMake(17.5, 8, 5, 5));
      CGContextFillRect(c, CGRectMake(18.5, 16, 3, 7));
      CGContextFillRect(c, CGRectMake(16.5, 18, 7, 3));
      CGContextFillEllipseInRect(c, CGRectMake(18, 28, 4, 4));
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
      CGContextSetLineWidth(c, 2.6);
      KPGlyphRounded(c, CGRectMake(3, 12, 31, 16), 3.5, false);
      CGContextFillRect(c, CGRectMake(34.5, 17, 3, 6));
      const CGFloat fill = std::clamp(level, CGFloat(0), CGFloat(1));
      if (fill > 0) KPGlyphRounded(c, CGRectMake(6, 15, 25 * fill, 10), 1.6, true);
      break;
    }
  }
  CGContextRestoreGState(c);
}
static void KPDrawGlyphIndex(CGContextRef c, int glyph, CGRect rect, unsigned ink) {
  KPDrawGlyph(c, static_cast<KPUIGlyph>(glyph), rect, ink);
}
