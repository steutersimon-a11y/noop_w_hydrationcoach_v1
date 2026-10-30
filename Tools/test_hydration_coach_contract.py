"""Guard confirmation haptics and the single shared-alarm owner without CoreBluetooth.

The accepted routine uses the firmware alarm for wake and drinking. Confirming a saved
drink must still never execute or overwrite that future alarm.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def declaration_body(path, signature):
    source = (ROOT / path).read_text(encoding="utf-8")
    declaration = source.index(signature)
    opening = source.index("{", declaration)
    depth = 1
    cursor = opening + 1
    while cursor < len(source) and depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    if depth:
        raise AssertionError("Hydration cue declaration has no complete body")
    return source[opening + 1 : cursor - 1]


class HydrationCoachAlarmBoundaryTests(unittest.TestCase):
    def test_saved_drink_confirmation_never_mutates_or_runs_the_future_alarm(self):
        body = declaration_body("Strand/BLE/BLEManager.swift", "func buzzHydrationCoach() -> Bool")
        commands = re.findall(r"\bsend\s*\(\s*\.([A-Za-z_]\w*)", body)
        self.assertEqual(
            commands,
            ["runHapticsPattern"],
            "Confirming a drink may send only the reversible pattern, never arm/disarm/run the next alarm",
        )
        self.assertNotRegex(
            body,
            r"\b(?:armStrapAlarm|disableStrapAlarm|buzzStrapOnce|sendSetClockBothForms)\s*\(",
            "The explicit buzz helper sends RUN_ALARM and cannot be the hydration fallback",
        )

    def test_shared_alarm_uses_the_existing_bond_gated_alarm_api(self):
        body = declaration_body("Strand/BLE/BLEManager.swift", "func armHydrationCoachAlarm(at date: Date) -> Bool")
        self.assertLess(body.index("canSendHydrationCoachHaptic"), body.index("armStrapAlarm(at:"))
        self.assertNotRegex(body, r"\bsend\s*\(", "The shared owner must reuse the existing alarm framing")

    def test_single_alarm_owner_precedes_legacy_rearm_and_gesture_debounce(self):
        alarm = declaration_body("Strand/App/AppModel.swift", "func applySmartAlarm()")
        self.assertLess(alarm.index("hydrationCoach.coordinateAlarm()"), alarm.index("ble.armStrapAlarm"))
        tap = declaration_body("Strand/App/AppModel.swift", "private func handleDoubleTap()")
        self.assertLess(tap.index("hydrationCoach.handleDoubleTap"), tap.index("guard since > 1.2"))


if __name__ == "__main__":
    unittest.main()
