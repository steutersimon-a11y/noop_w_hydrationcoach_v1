# Codex task — NOOP iOS Hydration Coach

## Accepted routine, revised 2026-10-30

Implement the accepted WHOOP 4.0 routine on this fork's iOS target. This revision supersedes
phase one's restriction against sharing the wake-alarm slot. The user explicitly authorizes
daytime use of the reversible firmware alarm and does not require a physical-device test
before delivery. Report automated checks accurately; never equate compilation with physical
motor or iOS background scheduling verification.

- Wake time, enabled weekdays and weekday overrides stay exclusively in NOOP's existing
  **Alarms** settings. Hydration reads that effective schedule and offers no wake editor.
- At the configured wake (for example 07:30), a double tap starts drinking mode without
  booking water. An explicit start-today action can start a new installation after today's
  wake has passed, also without crediting water.
- During drinking mode, a double tap logs the configured glass (default 250 ml), including
  between reminders. A second distinct double tap within approximately three seconds selects
  one bottle (default 500 ml total). Resolve the gesture before persisting one entry.
- Both bottle gesture receipts must commit atomically with that entry so live/offload replay,
  relaunch and corrections cannot manufacture another drink.
- Preserve the existing tracker, history, manual entry/edit/delete and HealthKit water import;
  imported water stays separate from the accumulating manual total. No parallel datastore.
- Defaults: optional/off, personal goal 3,000 ml, interval 60 minutes, bedtime 23:30.
  Goal, interval, glass, bottle and bedtime are editable. Preserve compatible saved preferences.
- First normal reminder follows one interval after the configured wake, for example 08:30.
  Calculate proportional cumulative targets and suppress slots covered by actual intake.
  Partial planning sections and rounding preserve the exact goal. Avoid large catch-up
  recommendations. Actual drinks remain loggable after the goal until bedtime.
- At bedtime, drinking-mode gesture ownership ends and the next native wake owns the slot.
  At goal completion, during workouts or with no future drinking slots, restore the wake early
  rather than relying on a bedtime timer running in the background.
- One coordinator selects wake/drinking alarms on settings changes, reconnect and foreground
  entry. Drinking executions must not trigger the normal morning wake-notification mirror.
  Select the following alarm independently of whether the wearer confirms a drink.
- Accept eligible live Bluetooth events while iOS is backgrounded. Foreground scene activity
  is not a prerequisite. Only finite background work may support gesture resolution and
  persistence; no indefinite keepalive or new background execution entitlement.
- A ready bonded WHOOP 4.0 channel is required to submit a coaching alarm. Native WHOOP 5
  behavior remains unchanged. No new opcodes, firmware changes or handshake modifications.
- Distinguish planned/requested and strap-reported alarms. A write is not delivery proof.
  Missing/stale event time, connection loss and database failures must not create success.
- Preserve Lift/workout gesture priority and normal actions outside drinking mode.
- Deliver the tested implementation in the existing PR, a real iPhone Release IPA, checksums
  and a fork-specific AltStore source. Simulator compilation alone is insufficient.

WHOOP 4.0 stores one absolute alarm instant. Following alarms still require Bluetooth and iOS
background event delivery. Document this boundary without imposing a device-test onboarding
flow. Preserve the existing independent iOS backup wake notification and its permission limits.

Withings integration and Android coaching remain outside this iOS task.
