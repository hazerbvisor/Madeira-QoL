#!/usr/bin/env python3
"""Exercise production deadline and profile migration on a Linux/macOS host."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    c = work / 'deadline.c'
    c.write_text(r'''
#include "FrameDeadline.h"
#include <assert.h>
int main(void) {
    MadeiraFrameDeadline s = {0};
    assert(madeira_frame_deadline(&s, 100, 30) == 100);
    assert(madeira_frame_deadline(&s, 110, 30) == 130);
    assert(madeira_frame_deadline(&s, 163, 30) == 163);
    assert(s.next == 190); // late frame does not add its lateness to the schedule
    assert(madeira_frame_deadline(&s, 1000, 30) == 1000);
    assert(s.next == 1030); // long stall cannot bank catch-up credit
    assert(madeira_frame_deadline(&s, 1005, 10) == 1005);
    assert(madeira_frame_deadline(&s, 1006, 0) == 1006);
    assert(s.next == 0); // unlimited mode clears the limiter
    for (uint64_t p = 8333333; p < 34000000; p += 1000000) {
        s = (MadeiraFrameDeadline){0};
        uint64_t t = 1000000000;
        assert(madeira_frame_deadline(&s, t, p) == t);
        for (int i = 1; i < 10000; i++) {
            assert(madeira_frame_deadline(&s, t + (uint64_t)i*p - 100, p) == t + (uint64_t)i*p);
        }
    }
}
''')
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-I', str(root / 'app/Madeira'), str(c), '-o', str(work / 'deadline')], check=True)
    subprocess.run([str(work / 'deadline')], check=True)
    swift = work / 'main.swift'
    swift.write_text(r'''
import Foundation
let decoder = JSONDecoder()
let encoder = JSONEncoder()
let defaults = try decoder.decode(PerformanceProfile.self, from: Data("{}".utf8))
assert(defaults == PerformanceProfile())
let future = try decoder.decode(PerformanceProfile.self, from: Data("""
{"fxMode":"future","fpsCap":999,"mouseSensitivity":-4,"minimumScale":0.1,"maximumScale":2,"renderScale":9,"interpolation":"future"}
""".utf8))
assert(future.fxMode == .off && future.fpsCap == nil && future.interpolation == .off)
assert(future.renderScale == 1 && future.minimumScale == 0.5 && future.maximumScale == 1)
assert(future.mouseSensitivity == 0.1)
for cap in PerformanceProfile.fpsCaps {
    var p = PerformanceProfile(); p.fpsCap = cap; p.fxMode = .balanced; p.renderScale = 0.72
    let restored = try decoder.decode(PerformanceProfile.self, from: encoder.encode(p))
    assert(restored == p)
    let size = p.internalResolution(outputWidth: 1280, outputHeight: 960)
    assert(size.width == 922 && size.height == 691)
}
var malformed = PerformanceProfile(); malformed.renderScale = .infinity; malformed.mouseSensitivity = .nan
malformed.normalize()
assert(malformed.renderScale == 1 && malformed.mouseSensitivity == nil)
malformed.maximumScale = 0.7; malformed.renderScale = .nan; malformed.normalize()
assert(malformed.renderScale == 0.7)
var auto = PerformanceProfile(); auto.automaticPerformance = true; auto.fpsCap = 60
auto.lastAutoFPS = 30; auto.fxMode = .auto; auto.nextLaunchScale = 0.67
auto.lastAutoDecision = "Conservative next-launch advice"
let savedAuto = try decoder.decode(PerformanceProfile.self, from: encoder.encode(auto))
assert(savedAuto == auto && savedAuto.initialFPSCap == 30)
let nextSize = savedAuto.internalResolution(outputWidth: 1280, outputHeight: 960)
assert(nextSize.width == 858 && nextSize.height == 643)
auto.automaticPerformance = false
assert(auto.initialFPSCap == 60 && auto.requestedRenderScale == 1)
let huge = auto.internalResolution(outputWidth: Int.max, outputHeight: Int.max)
assert(huge.width == Int.max && huge.height == Int.max)
// An absent upgrade field must leave a legacy library profile unchanged.
struct LegacyEnvelope: Codable { var fpsMode: Int; var performanceUpgrade: PerformanceProfile? }
let legacy = try decoder.decode(LegacyEnvelope.self, from: Data("{\"fpsMode\":3}".utf8))
assert(legacy.fpsMode == 3 && legacy.performanceUpgrade == nil)
print("Profile migration, invalid values and persistence passed")
''')
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(root / 'app/Madeira/PerformancePolicy.swift'),
                    str(swift), '-o', str(work / 'policy')], check=True)
    subprocess.run([str(work / 'policy')], check=True)
print('Frame pacing: absolute deadline, stall recovery, cap transitions and 10,000-frame drift checks passed')
