// -[KPControllersScreen listen] on iPhone and iPad: each controller's confirm, back and Start, from
// the roster's view of it (refreshed by the screen's tick just before). Included inside the method
// (apple/macos/KartPadControllersScreen.inc.mm), with its now, presses and first.
for (KPPadDevice *device in KPControllerRoster.shared.devices) {
  if (device.controller == nil) continue;
  const KPPadFace face = KPPadFaceButtons(device.gamepad);
  const uint64_t held = device.buttons;
  const unsigned down = ((held >> face.a) & 1 ? KPPressConfirm : 0) | ((held >> face.b) & 1 ? KPPressBack : 0) |
                        ((held >> SDL_GAMEPAD_BUTTON_START) & 1 ? KPPressStart : 0);
  now[@(device.joystick)] = @(down);
  NSNumber *was = self.held[@(device.joystick)];
  if (first || was == nil) continue;  // already down when listening began, or just connected
  const unsigned pressed = down & ~was.unsignedIntValue;
  if (pressed) [presses addObject:@[@(device.joystick), @(pressed)]];
}
