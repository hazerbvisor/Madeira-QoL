#!/usr/bin/env python3
"""Run the production touch-release logic against interrupted input sequences."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/ContentView.swift').read_text()
# Compile the real actions and cancellation methods with only UIKit output stubbed.
actions = source[source.index('enum ControlAction: Codable'):source.index('final class TouchControlsModel')]
methods = source[source.index('    private func stickKeys('):source.index('/// ml645 — the mapping panel.')]
methods = methods.rsplit('\n}', 1)[0].replace('private func', 'func')
fixture = r'''
import Foundation
struct TouchPadAction { static func supported(_ name: String) -> Bool { true } }
final class UIImpactFeedbackGenerator {
    enum Style { case light }
    init(style: Style) {}
    func impactOccurred() {}
}
enum MetalBackedView { static func toggleKeyboard() {} }
var edges: [String] = []
func winios_post_key(_ key: Int32, _ down: Int32) { edges.append("key:\(key):\(down)") }
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: Int32, _ wheel: Int32) { edges.append("mouse:\(flags)") }
'''
harness = r'''
final class Gesture {
    var control = TouchControl()
    var isDown = false
    var stickDir = -1
    var padVector = CGSize.zero
    var dragBase: CGPoint?
'''
tests = r'''
}
let gesture = Gesture()
// Remapping while pressed must release the original key, never the new binding.
gesture.control.action = .key(0x20)
gesture.isDown = true
gesture.releaseGesture(.key(0x57))
assert(edges == ["key:87:0"])
gesture.releaseGesture(.key(0x57))
assert(edges.count == 1)
// Cancel a held diagonal exactly once, including both directions.
edges.removeAll()
gesture.applyStick(1, [0x57, 0x44, 0x53, 0x41])
gesture.isDown = true
gesture.releaseGesture(.joystickWASD)
assert(Set(edges) == Set(["key:87:1", "key:68:1", "key:87:0", "key:68:0"]))
assert(edges.count == 4 && gesture.stickDir == -1 && !gesture.isDown)
gesture.releaseGesture(.joystickWASD)
assert(edges.count == 4)
for (action, flag): (ControlAction, Int32) in [(.mouseLeft, 4), (.mouseRight, 16)] {
    edges.removeAll(); gesture.isDown = true
    gesture.releaseGesture(action)
    assert(edges == ["mouse:\(flag)"])
}
// XInput touch lifetime belongs to TouchPadSurface; do not inject key/mouse events.
edges.removeAll(); gesture.isDown = true
gesture.padVector = CGSize(width: 1, height: 1)
gesture.releaseGesture(.pad("A"))
assert(edges.isEmpty && gesture.padVector == .zero && !gesture.isDown)
print("PASS: interrupted keys, diagonal sticks, mouse buttons, old remaps and idempotent cancellation")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'lifecycle.swift'
    path.write_text(fixture + actions + harness + methods + tests)
    subprocess.run([os.environ.get('SWIFT', 'swift'), str(path)], check=True)
print('check-input-lifecycle: PASS')
