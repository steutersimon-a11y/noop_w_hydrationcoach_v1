# Codex task — NOOP iOS Hydration Coach

Implement on this fork's iOS target for WHOOP 4.0. Preserve the original app and the project's clean-room, local-only principles. Read AGENTS.md, docs/CONTRIBUTING.md, and docs/IOS.md first.

## Desired behavior
- Optional Hydration Coach: default personal target 3,000 ml/day, default serving 250 ml.
- Default schedule 07:30–21:30, every 75 minutes (editable). Pause outside waking window and when goal is reached.
- WHOOP haptic reminders. When the user **double taps during an active reminder window**, credit exactly 250 ml once. If they don't double tap, credit zero.
- Confirmation buzz only after a successfully persisted log, and only if a strap command is possible.
- Preserve all existing double-tap actions outside that window; avoid interference with workouts.
- Add settings, daily progress, history and manual correction using the **existing** Hydration tracker and HealthKit import. Do not create a second parallel hydration datastore.
- Settings should be explicitly opt-in. Never assume a strap notification was delivered if disconnected.

## Existing code to inspect
- Strand/Data/HydrationStore.swift
- Strand/Screens/HydrationView.swift
- Packages/StrandAnalytics/Sources/StrandAnalytics/HydrationGoal.swift
- Strand/App/AppModel.swift (live.onDoubleTap / handleDoubleTap)
- Strand/BLE/BLEManager.swift (armStrapAlarm, haptics)
- StrandTests/FrameRouterDoubleTapDedupTests.swift
- StrandiOS/App/ and project.yml

## Critical hardware / iOS constraints
Do **not** promise reliable all-day independent reminders without verifying if WHOOP 4.0 actually supports multiple firmware alarm IDs, whether the Smart Alarm would be overwritten, and whether a double-tap after an autonomous alarm reaches the app with the screen locked. If unsupported, implement an honest fallback with local iOS notifications and available BLE haptics; clearly label the limitations. The alarm used for waking must not be overwritten. Receiving a double tap is distinct from dismissing a strap alarm.

Deduplicate double-tap events across BLE live and replay and guard reminder acceptance by stable reminder ID, local date, expiry window, and persisted acknowledgment. No speculative credit after disconnect/restart.

## Validation
Add unit tests for no tap => 0, one tap => one credit, replay => not twice, outside window, timer bounds, goal completion, local calendar day and DST, reopen/reconnect behavior, conflicting double-tap actions, and preserving the wake alarm. Use XcodeGen's project.yml rather than editing generated Strand.xcodeproj. Run Swift tests and available iOS build CI. Open a PR with tested implementation and document every outstanding device-test requirement.

This is phase 1 only. Withings Body Scan integration is a separate future feature.
