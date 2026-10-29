# iOS Hydration Coach: support boundary and device validation

The phase-one coach is an opt-in addition to the existing Hydration tracker on this fork's iOS target. It uses the existing manual-water total, editable entries, history and Apple Health imported-water total. It does not infer that the wearer drank water from a timer, a notification, an alarm dismissal or a disconnection.

## WHOOP 4.0 alarm boundary

The checked-in WHOOP 4.0 `WhoopCommand.setAlarmPayload` is the captured revision-one alarm body: revision byte, UTC epoch, subseconds and haptic mode. It does not expose an independently verified alarm ID. `BLEManager.armStrapAlarm` is already the waking Smart Alarm's single arm/readback path. Neither that payload nor the existing readback establishes that a second independent hydration alarm can coexist with the wake alarm.

Consequently, hydration must not call `armStrapAlarm`, `disableStrapAlarm`, `SET_ALARM_TIME`, `DISABLE_ALARM` or `RUN_ALARM`. It must not temporarily replace and later restore the wake alarm. The existing explicit “Buzz strap” helper also sends `RUN_ALARM`, so that helper is not the hydration cue path. The coach uses only the existing reversible haptic-pattern command when a WHOOP 4.0 command channel is available. No new opcodes, guessed alarm IDs, firmware changes or connection-handshake changes are required.

Submitting a BLE write establishes an attempt, not delivery or a physical motor response. A connected-state flag alone is insufficient: the actual connected peripheral, discovered command characteristic, selected WHOOP 4.0 family and completed bond must permit the command. A disconnected or unready strap must never be described as having received a reminder.

`BLEManager.canSendHydrationCoachHaptic` checks that transport and genuine per-connection bond. `buzzHydrationCoach()` rechecks it and sends only `RUN_HAPTICS_PATTERN`; its Boolean result means submission was attempted, never that the wearer felt a buzz. `LiveState.lastDoubleTapEventDate` exposes the decoded event's own time synchronously inside the existing double-tap callback. A missing or nonpositive event time clears that metadata, so hydration fails closed while ordinary gesture actions keep their existing behavior.

The bounded hydration write requests a CoreBluetooth acknowledgment (`.withResponse`) to reduce the existing busy-link/background write-loss risk. That acknowledgment still does not verify the physical motor. The repository documents a WHOOP 4.0 Siri-path report where a bare haptic-pattern command was ignored; the explicit “Buzz strap” helper adds `RUN_ALARM` as its fallback. Hydration deliberately has no such fallback because preserving the waking alarm takes priority. Its actual motor behavior must be verified on a real WHOOP 4.0 before claiming reliable wrist reminders.

## iOS fallback

Local iOS notifications provide the reminder fallback when permission is granted, using a rolling set of at most 32 scheduled coach notifications. Their presentation is controlled by iOS and the wearer's notification/Focus settings. Scheduling a notification does not establish presentation, wake the app to run an arbitrary BLE timer, or establish that a strap haptic fired.

The `bluetooth-central` background mode and CoreBluetooth state restoration already configured by the application allow supported BLE background events. They do not guarantee continuous process execution. As described in `docs/IOS.md`, iOS can suspend the process between BLE events; a repeating app timer cannot promise reliable all-day wrist reminders. Force-quitting, Bluetooth loss, a locked phone, OS scheduling and an unavailable command channel may prevent a wrist cue or timely tap delivery. Reopening or reconnecting must not manufacture credit for missed reminders.

This phase therefore enables coach haptic attempts and tap acceptance only while NOOP's iOS scene is active in the foreground. Backgrounding or locking the phone closes the coach window; local notifications remain the fallback. Returning to the foreground, reconnecting or restarting does not re-open a missed slot. The rolling notification set covers at most the next 24 hours and is refreshed while the app runs; it is not an unlimited independent schedule. Reaching today's goal removes today's pending coach notifications when NOOP observes the new total, while a future local day starts with a fresh goal.

The coach must not claim that a double tap dismissing an autonomous strap alarm will reach NOOP while the phone is locked. Receiving the decoded `DOUBLE_TAP` event and dismissing a firmware alarm are distinct observations. Autonomous multi-alarm operation remains unsupported until the relevant firmware behavior is independently established on real WHOOP 4.0 hardware.

## Gesture and persistence contract

- Outside an active hydration acceptance window, retain the user's configured double-tap action.
- A Lift Log gesture claim has priority. Do not send hydration cues or claim water during a running workout; do not alter the user's gesture preference.
- Accept water only for a real, integrity-checked double-tap event with usable event time, an active stable reminder ID, the same local calendar day, an unexpired 120-second window and no persisted acknowledgment. The router's existing live/offload deduplication is an additional guard rather than the sole accounting guard.
- One accepted reminder creates one existing Hydration entry. A replay, repeated tap, reopened process, reconnect, expired window, prior-day event or missing event time must not create another credit. No tap means zero automatic credit.
- Persist the water and the reminder acknowledgment before attempting the confirmation buzz. A failed write must not produce a successful-credit signal. Correcting or deleting the existing hydration entry must not turn a replay into a new drink.
- Manual water and imported Apple Health water both contribute to daily progress and goal completion. Import remains replacement-based and separate from the accumulating manual row; coach logging must not fold imported water into the manual total.

The canonical manual total remains the existing Hydration `metricSeries` row in the same SQLite database. Editable entry metadata and the stable reminder receipt are namespaced bookkeeping in that database's existing cursor storage; a coach credit commits those records and its manual total in one transaction. Existing per-day entry JSON is lazily migrated, with UserDefaults retained only as a compatibility mirror. The receipt survives manual edit/delete and reopen: correcting water does not re-arm a reminder acknowledgment. No second hydration database or schema migration is introduced. Daily history advances with calendar-day arithmetic rather than assuming every local day lasts 86,400 seconds.

The coach rechecks manual plus imported water against the personal goal in the write transaction, so a concurrent manual entry or HealthKit import cannot leave it acting on a stale progress value. Confirmation also requires the original foreground/connection session; reconnecting before a pending write completes cannot queue an old confirmation. Additional taps within a settled window are consumed without another drink or an unrelated configured gesture. After expiry the configured gesture resumes.

Scheduling uses Gregorian local day keys matching the existing tracker, refreshing the time zone on each read. Nonexistent spring-forward reminder slots are omitted, a repeated autumn slot occurs once, and a nonexistent waking-window end advances to the next valid local time. Strap event times have whole-second precision: a tap timestamp earlier than the actual cue attempt fails closed, including an immediate same-second tap whose truncated timestamp precedes the attempt. Manual logging remains available in that case.

## Required physical-device checks

These are outstanding device checks, not results established by package tests, Simulator builds or CI. Record the iPhone model/iOS version, WHOOP 4.0 firmware, app commit, notification settings and observed outcome for each check. Keep a separate wake alarm for safety during testing.

1. Arm the existing waking Smart Alarm, then enable the coach, edit its schedule, receive several available haptic cues and disable the coach. Inspect the command log: hydration must send no firmware arm, disarm or run-alarm command. Confirm the original wake still fires at its configured time.
2. With the app foregrounded and the strap bonded, observe an actual reminder haptic. Double tap once within the acceptance window. Verify one persisted serving in the existing entry list and daily history, then the confirmation haptic. Do not tap at the next reminder: verify zero credit.
3. Repeat with the screen locked and with the application backgrounded long enough to suspend. Confirm the foreground-only coach window closes and coach taps do not log water. Record local notification presentation separately from any unrelated strap event or waking alarm. Returning to NOOP must wait for a new eligible slot, rather than replay a missed reminder. Do not report this fallback as reliable independent wrist reminders.
4. Trigger a sync/offload immediately after a real accepted tap. Replay the banked event and reconnect. Verify that the reminder ID is acknowledged once and the day total does not increase again. Restart the app while a window is pending and verify that an old event cannot be credited.
5. Disconnect or turn Bluetooth off before a reminder, between cue and tap, and during persistence/confirmation. Verify no invented delivery, no speculative water and no queued confirmation buzz after reconnect.
6. Start a Lift Log and a regular tracked workout. Verify their existing gestures and haptics retain priority and hydration neither interrupts the session nor credits a workout gesture. End the session and verify normal configured gesture behavior returns outside hydration windows.
7. Check local midnight, travel/time-zone changes and daylight-saving transitions, including a skipped or repeated wall-clock time. Confirm the configured waking interval and daily goal use the wearer's local calendar day and do not produce duplicate reminders or prior-day credit.
8. Deny notification permission, enable Focus and disable alerts individually. Confirm the UI reports the available fallback honestly, no notification interaction automatically logs water, and manual entry/correction remains available. Import dietary water through HealthKit twice and confirm idempotent totals and goal-based reminder suppression.

## Validation scope

Pure scheduling, acceptance, replay and persistence tests can establish the accounting invariants without a strap. Apple app compilation still requires the `Strand` macOS build and the `NOOPiOS` iOS build from `app-build.yml`; Linux Swift package tests do not compile these targets. CoreBluetooth and the physical haptic motor are unavailable in the iOS Simulator. This phase does not add Android coach behavior or Withings Body Scan integration.
