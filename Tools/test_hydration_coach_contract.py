"""Guard the hydration cue's firmware-alarm boundary without a CoreBluetooth runtime.

This source contract protects the specific shared-register risk documented in CODEX_TASK.md.
Motor delivery and the original waking alarm still require the physical-device checklist.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def hydration_haptic_body():
    source = (ROOT / "Strand/BLE/BLEManager.swift").read_text(encoding="utf-8")
    declaration = source.index("func buzzHydrationCoach() -> Bool")
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
    def test_hydration_haptic_never_mutates_or_runs_the_firmware_alarm(self):
        body = hydration_haptic_body()
        commands = re.findall(r"\bsend\s*\(\s*\.([A-Za-z_]\w*)", body)
        self.assertEqual(
            commands,
            ["runHapticsPattern"],
            "Hydration may send only the reversible pattern, never arm/disarm/run the wake alarm",
        )
        self.assertNotRegex(
            body,
            r"\b(?:armStrapAlarm|disableStrapAlarm|buzzStrapOnce|sendSetClockBothForms)\s*\(",
            "The explicit buzz helper sends RUN_ALARM and cannot be the hydration fallback",
        )


if __name__ == "__main__":
    unittest.main()
