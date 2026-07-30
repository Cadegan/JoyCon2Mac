#include "JoyConDecoder.h"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {

std::vector<uint8_t> makeStickPacket(JoyConSide side, int rawX, int rawY) {
    std::vector<uint8_t> packet(64, 0);
    size_t offset = side == JoyConSide::Left ? 10 : 13;
    packet[offset] = static_cast<uint8_t>(rawX & 0xFF);
    packet[offset + 1] = static_cast<uint8_t>(
        ((rawX >> 8) & 0x0F) | ((rawY & 0x0F) << 4));
    packet[offset + 2] = static_cast<uint8_t>((rawY >> 4) & 0xFF);
    return packet;
}

void sample(JoyConSide side, int rawX, int rawY, int count) {
    const auto packet = makeStickPacket(side, rawX, rawY);
    for (int i = 0; i < count; ++i) {
        DecodeJoystick(packet, side, JoyConOrientation::Upright);
    }
}

bool expect(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAILED: " << message << '\n';
        return false;
    }
    return true;
}

} // namespace

int main() {
    bool ok = true;

    BeginStickCalibration();
    sample(JoyConSide::Left, 2048, 2048, 30);
    sample(JoyConSide::Right, 2048, 2048, 30);
    ok &= expect(IsStickCalibrationComplete(JoyConSide::Left),
                 "left stick should calibrate at nominal center");
    ok &= expect(IsStickCalibrationComplete(JoyConSide::Right),
                 "right stick should calibrate at nominal center");

    // Once calibrated, a stable held position must never become the new
    // center unless the user explicitly starts another calibration.
    sample(JoyConSide::Left, 1800, 2048, 120);
    const auto neutralPacket = makeStickPacket(JoyConSide::Left, 2048, 2048);
    const StickData neutral = DecodeJoystick(
        neutralPacket, JoyConSide::Left, JoyConOrientation::Upright);
    ok &= expect(neutral.x == 0 && neutral.y == 0,
                 "holding a displaced stick must not move the saved center");

    // An explicit calibration ignores a held stick outside the strict center
    // window, then completes once the stick returns to neutral.
    BeginStickCalibration();
    sample(JoyConSide::Left, 1800, 2048, 120);
    ok &= expect(IsStickCalibrationInProgress(JoyConSide::Left),
                 "held left stick must leave calibration waiting");
    ok &= expect(GetStickCalibrationSampleCount(JoyConSide::Left) == 0,
                 "held left stick must not contribute calibration samples");
    sample(JoyConSide::Left, 2050, 2046, 30);
    ok &= expect(IsStickCalibrationComplete(JoyConSide::Left),
                 "left stick should complete after returning to neutral");

    // Cancelling a recalibration keeps the last usable center.
    BeginStickCalibration();
    sample(JoyConSide::Left, 1800, 2048, 5);
    CancelStickCalibration();
    const StickData afterCancel = DecodeJoystick(
        makeStickPacket(JoyConSide::Left, 2050, 2046),
        JoyConSide::Left,
        JoyConOrientation::Upright);
    ok &= expect(afterCancel.x == 0 && afterCancel.y == 0,
                 "cancelling must preserve the previous calibrated center");

    // Every explicit run uses the nominal center window rather than the
    // previously learned center. Otherwise two valid candidates at opposite
    // edges of the window could never correct one another.
    BeginStickCalibration();
    sample(JoyConSide::Left, 2208, 2048, 30);
    ok &= expect(IsStickCalibrationComplete(JoyConSide::Left),
                 "upper edge of nominal window should calibrate");
    BeginStickCalibration();
    sample(JoyConSide::Left, 1888, 2048, 30);
    ok &= expect(IsStickCalibrationComplete(JoyConSide::Left),
                 "recalibration should use nominal rather than saved center");

    if (!ok) {
        return 1;
    }

    std::cout << "JoyConDecoder calibration tests passed\n";
    return 0;
}
