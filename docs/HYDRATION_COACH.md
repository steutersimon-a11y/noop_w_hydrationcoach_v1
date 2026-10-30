# iOS Hydration Coach

The optional WHOOP 4.0 coach shares NOOP's existing firmware alarm between waking and daytime
hydration. Wake time and weekday overrides remain in **Alarms**. Hydration contains the daily
goal, interval, glass/bottle sizes and bedtime, plus a link to the existing Alarms screen.

## Daily operation

1. The native wake alarm runs at its configured time. Its dismissal double tap starts drinking
   mode and never logs water. When installing after today's wake, the explicit start-today
   action can start the remainder of today's routine without claiming a wake or a drink.
2. The first drinking slot follows one interval after the configured wake: 07:30 with a
   60-minute interval means 08:30. Slots stay anchored to wake time rather than drifting on
   every reconnect or drink.
3. In drinking mode, a double tap records a glass between reminders too. Two distinct double
   taps within three seconds record one bottle in total. A short pause separates the gestures;
   four indistinguishably fast taps are not promised as two firmware events.
4. The app resolves the gesture before storing the entry. Its constituent tap receipts,
   editable entry and manual total commit together. Replaying either half of a bottle cannot
   add a glass, including after relaunch or correction. No tap means no water.
5. At bedtime, drinking-mode gesture ownership ends and the next wake owns the shared slot.
   Goal completion, workouts or exhaustion of future drinking slots select that wake early.
   Actual water remains loggable after reaching the goal until bedtime. Lift/workout gestures
   retain priority; normal configured actions resume outside drinking mode.

Defaults are off, 3,000 ml, 250 ml glass, 500 ml bottle, 60-minute interval and 23:30 bedtime.
Compatible saved preferences are retained. The next drinking reminder can be skipped or moved
15 minutes later; these choices survive a same-day reconnect or relaunch. Ordinary manual entry,
correction and history remain
available. Imported HealthKit water contributes to progress and reminder suppression but is
never folded into the accumulating manual-water row.

## Proportional planning

Planning targets follow elapsed time between the native wake and bedtime. At 3,000 ml over
07:30–23:30, 60 minutes represents 187.5 ml and 80 minutes 250 ml. Cumulative rounding preserves
the exact full-day goal. A partial final section receives its proportional share; the terminal
bedtime checkpoint is for the target calculation, not a wrist alarm at the quiet boundary.

Gestures always record actual container sizes; a 250 ml glass never silently becomes a smaller
recommended portion. Ahead-of-plan intake suppresses covered slots and goal completion stops
drinking alarms. Recommendations are bounded by a normal section and configured container
size, so late activation cannot produce a giant catch-up dose. Arbitrary remaining quantities
can be recorded with the existing manual controls.

## Firmware alarm and iOS

The supported WHOOP 4.0 path stores one absolute alarm instant, not an independently verified
list or recurring timetable. Coaching uses the existing reversible arm API. A single coordinator
owns settings/reconnect/foreground reconciliation so the native daily re-arm cannot silently
overwrite a daytime slot. Drinking executions do not produce morning wake notifications.

A stored firmware alarm can fire while the phone is locked or NOOP is suspended. Programming
the following alarm requires Bluetooth event delivery and a new write from the phone. The next
alarm is chosen independently of a water confirmation. Timers are opportunistic reconciliation;
iOS local notifications cannot perform arbitrary Bluetooth writes. Finite background work for
an incoming gesture and database commit is not an all-day keepalive.

Disconnection, force-quitting or OS scheduling can interrupt the chain. While a drinking alarm
occupies the slot, the next morning's wake is not additionally stored there. Native independent
iOS backup wake notifications remain governed by Alarms settings and permissions; Focus and
silent mode can suppress them.

The UI distinguishes a planned/requested alarm from matching current-link readback. Neither a
write nor a readback proves physical motor delivery. Stale/missing event time cannot manufacture
a drink. Restarting does not reconstruct water from missed alarms; genuine persisted activation
is scoped to the same valid day, native wake, time zone and device.

A saved drink's confirmation uses only the existing bounded haptic pattern and is attempted on
the same still-ready connection after persistence. It never runs, clears or replaces the future
alarm. The repository records WHOOP 4.0 bare-pattern reliability limitations. Physical haptics
and a complete locked-phone day have not been measured by this cloud build.

## Installation and validation

The iOS sideload workflow builds a device Release IPA, strips the watch app, retains the widget,
anonymizes builder paths and adds replaceable ad-hoc capability signatures. AltStore Classic
or SideStore supplies Apple-ID signing. Successful commits publish an isolated
`hydration-coach-<commit>` prerelease containing the IPA, SHA256SUMS and
`altstore-hydration-source.json`. Feed version, size and platform come from the actual archive.

Keep the widget enabled when signing. The bundle identifier is preserved, so back up NOOP data
before replacing an installation. AltStore Classic requires a reachable AltServer to install
and renew, over the same Wi-Fi network or USB.

Automated package tests cover planning, rounding, gesture aggregation, wake exclusion, day/DST
boundaries and adaptive suppression. GRDB tests cover atomic alias receipts, replay, rollback,
imports, after-goal logging and correction/reopen. Apple CI builds macOS and iOS and runs app
tests for live alarm metadata, CRC boundaries, callback ordering and the native wake resolver.
Device Release packaging checks capability signatures, archive integrity and feed metadata.
These checks do not constitute physical strap validation. Installation and feature activation
have no mandatory device-test step.
