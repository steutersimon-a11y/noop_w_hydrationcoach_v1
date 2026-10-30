#if os(iOS)
import Combine
import Foundation
import HydrationCoach
import UIKit
import UserNotifications

/// One owner selects the WHOOP alarm: wake at night, hydration after an explicit morning dismissal.
/// Bluetooth callbacks can advance the routine in the background; a timer is only opportunistic.
@MainActor
final class HydrationCoachController: ObservableObject {
    @Published private(set) var settings: HydrationCoachSettings
    @Published private(set) var status = String(localized: "Hydration Coach is off.")
    @Published private(set) var notificationStatus = String(localized: "Notification permission has not been granted.")
    @Published private(set) var totalML: Double = 0
    @Published private(set) var nextAlarmDate: Date?
    @Published private(set) var nextAlarmIsHydration = false
    @Published private(set) var recommendedServingML: Double?
    @Published private(set) var alarmStatus = ""

    /// Wake settings have a single source: the existing NOOP Alarms screen, including weekday overrides.
    var wakeSettingsSummary: String {
        guard let model,
              let wake = model.resolvedNextCoachWake(after: Date(), calendar: Self.localCalendar) else {
            return String(localized: "Set and enable your wake alarm in Alarms.")
        }
        return wake.formatted(.dateTime.locale(AppLanguage.activeLocale).weekday(.abbreviated).hour().minute())
    }

    var managesSharedAlarm: Bool {
        guard let model else { return false }
        return settings.enabled && settings.isValid && defaults.bool(forKey: HydrationStore.enabledKey)
            && model.behavior.smartAlarmEnabled && model.ble.isWhoop4
    }

    var routineIsActive: Bool { activePlan(at: Date()) != nil }

    var canStartToday: Bool {
        guard managesSharedAlarm, !routineIsActive, let plan = todayPlan(at: Date()) else { return false }
        let now = Date()
        return now >= plan.wakeAt && now < plan.bedtimeAt
    }

    var canSnoozeNextReminder: Bool {
        guard routineIsActive, nextAlarmIsHydration, !workoutIsActive,
              let next = nextAlarmDate, let plan = activePlan(at: Date()) else { return false }
        return next.addingTimeInterval(15 * 60) < plan.bedtimeAt
    }

    private struct Activation: Codable, Equatable {
        let deviceID: String
        let dayKey: String
        let wakeAt: Date
        let activatedAt: Date
        let timeZoneIdentifier: String
    }

    private struct AlarmSelection: Codable, Equatable {
        let deviceID: String
        let date: Date
        let hydration: Bool
        let dayKey: String
    }

    private struct WakeExpectation: Codable, Equatable {
        let deviceID: String
        let wakeAt: Date
        let timeZoneIdentifier: String
    }

    private struct WakeFire: Codable, Equatable {
        let deviceID: String
        let wakeAt: Date
        let eventDate: Date
        let receivedAt: Date
    }

    private struct RuntimeState: Codable, Equatable {
        var activation: Activation?
        var lastProgram: AlarmSelection?
        var expectedWakes: [WakeExpectation] = []
        var wakeFire: WakeFire?
        var mirroredWakeIDs: [String] = []
        var reminderOverrides: ReminderOverrides?
    }

    private struct GestureContext: Equatable {
        let settings: HydrationCoachSettings
        let activation: Activation
        let generation: UInt64
        let deviceID: String
        let timeZoneIdentifier: String
    }

    private struct ScheduledDrink {
        let slot: HydrationRoutineSlot
        let date: Date
    }

    private struct SnoozedDrink: Codable, Equatable {
        let planID: String
        let slot: HydrationRoutineSlot
        let date: Date
    }

    private struct ReminderOverrides: Codable, Equatable {
        let planID: String
        var skippedSlotIDs: Set<String> = []
        var snoozedDrink: SnoozedDrink?
    }

    private static let stateKey = "noop.hydrationCoach.routineState.v2"
    private static let notificationPrefix = "hydration-coach."
    private static let wakeDismissalSeconds: TimeInterval = 15 * 60
    private static let eventFreshnessSeconds: TimeInterval = 15

    private static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        return calendar
    }

    private weak var model: AppModel?
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private var runtime: RuntimeState
    private var lastSavedRuntime: RuntimeState?
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var eligibleSince: Date
    private var lastAttempt: (selection: AlarmSelection, date: Date)?
    private var didManageSlot = false
    private var gestureAggregator = HydrationTapAggregator()
    private var gestureContext: GestureContext?
    private var gestureFlushTask: Task<Void, Never>?
    private var commitTail: Task<Void, Never>?
    private var pendingCommits = 0
    private var alarmHandoffPending = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var notificationSignature: String?
    private var notificationTask: Task<Void, Never>?
    private var notificationRevision = 0
    private var desiredNotifications: [HydrationCoachReminder]?
    private var outcome: (text: String, until: Date)?

    init(model: AppModel, defaults: UserDefaults = .standard,
         center: UNUserNotificationCenter = .current(), now: Date = Date()) {
        self.model = model
        self.defaults = defaults
        self.center = center
        self.eligibleSince = now
        if let data = defaults.data(forKey: HydrationCoachSettings.storageKey),
           let saved = try? JSONDecoder().decode(HydrationCoachSettings.self, from: data), saved.isValid {
            settings = saved
        } else {
            settings = HydrationCoachSettings()
        }
        if let data = defaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(RuntimeState.self, from: data) {
            runtime = state
            lastSavedRuntime = state
        } else {
            runtime = RuntimeState()
        }

        model.live.$connected.dropFirst().sink { [weak self] connected in
            guard let self else { return }
            self.invalidateGestures(at: Date())
            self.lastAttempt = nil
            if !connected { self.alarmStatus = String(localized: "Waiting for a ready WHOOP 4.0 connection.") }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.live.$bonded.dropFirst().sink { [weak self] bonded in
            guard let self else { return }
            if !bonded { self.invalidateGestures(at: Date()); self.lastAttempt = nil }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.live.$encryptedBond.dropFirst().sink { [weak self] encrypted in
            guard let self else { return }
            if !encrypted { self.invalidateGestures(at: Date()); self.lastAttempt = nil }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.live.$alarmReportedEpoch.dropFirst().sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &subscriptions)
        model.$activeWorkout.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.invalidateGestures(at: Date())
            self.clearReminderOverrides()
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.repo.$hydrationSeq.dropFirst().sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.invalidateGestures(at: Date())
                self.clearReminderOverrides()
                self.lastAttempt = nil
                self.notificationSignature = nil
                self.requestRefresh()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                if !self.defaults.bool(forKey: HydrationStore.enabledKey) {
                    self.invalidateGestures(at: Date())
                }
                self.requestRefresh()
            }.store(in: &subscriptions)
        // This can run during an allowed background wake. It is never the guarantee of an alarm:
        // the selected next date has already been handed to the strap's own alarm register.
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        timer.tolerance = 2
        self.timer = timer
        requestRefresh()
    }

    func updateSettings(_ value: HydrationCoachSettings) {
        guard value.isValid else { status = String(localized: "Invalid reminder settings."); return }
        guard value != settings else { return }
        let newlyEnabled = value.enabled && !settings.enabled
        invalidateGestures(at: Date())
        clearReminderOverrides()
        outcome = nil
        settings = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: HydrationCoachSettings.storageKey) }
        if value.enabled { defaults.set(true, forKey: HydrationStore.enabledKey) }
        else { runtime.activation = nil; runtime.wakeFire = nil; saveRuntime() }
        model?.repo.noteHydrationChanged()
        notificationSignature = nil
        // Includes the normal wake backup notifications and restores the existing wake on opt-out.
        model?.applySmartAlarm()
        requestRefresh()
        if newlyEnabled {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.center.requestAuthorization(options: [.alert, .sound])
                guard self.settings.enabled else { return }
                self.requestRefresh()
            }
        }
    }

    /// Locking/backgrounding does not revoke an explicit wake receipt or a live drink gesture.
    func setSceneActive(_ active: Bool) {
        requestRefresh()
    }

    func workoutContextChanged() {
        invalidateGestures(at: Date())
        clearReminderOverrides()
        requestRefresh()
    }

    /// Postpone one planned water cue, never the wake alarm or the bedtime boundary.
    func snoozeNextReminder() {
        let now = Date()
        guard !workoutIsActive, let plan = activePlan(at: now), nextAlarmIsHydration,
              let current = scheduledDrinks(in: plan, at: now).first,
              current.date == nextAlarmDate else { return }
        let postponed = current.date.addingTimeInterval(15 * 60)
        guard postponed < plan.bedtimeAt else { return }
        prepareOverrides(for: plan)
        skipDrinkDate(current.date, in: plan)
        runtime.reminderOverrides?.snoozedDrink = SnoozedDrink(planID: plan.id, slot: current.slot, date: postponed)
        saveRuntime()
        requestRefresh()
    }

    func skipNextReminder() {
        let now = Date()
        guard !workoutIsActive, let plan = activePlan(at: now), nextAlarmIsHydration,
              let current = scheduledDrinks(in: plan, at: now).first,
              current.date == nextAlarmDate else { return }
        prepareOverrides(for: plan)
        skipDrinkDate(current.date, in: plan)
        requestRefresh()
    }

    /// Return true when the shared routine, rather than the legacy wake-only path, selects the slot.
    @discardableResult
    func coordinateAlarm() -> Bool {
        if !managesSharedAlarm {
            didManageSlot = false
            if runtime.activation != nil || runtime.wakeFire != nil {
                runtime.activation = nil
                runtime.wakeFire = nil
                saveRuntime()
            }
            invalidateGestures(at: Date())
            lastAttempt = nil
            nextAlarmDate = nil
            nextAlarmIsHydration = false
            recommendedServingML = nil
            requestRefresh()
            return false
        }
        didManageSlot = true
        requestRefresh()
        return true
    }

    /// Explicit start supports installing/enabling the coach after today's wake; it never logs water.
    func startToday() {
        let now = Date()
        guard canStartToday, let model, let plan = todayPlan(at: now) else { return }
        activate(plan: plan, at: now, deviceID: model.ble.deviceId)
        requestRefresh()
    }

    /// A firmware fire chooses the next register value independently of a drink confirmation.
    /// Unknown/stale fires are consumed while this coordinator owns the slot, without inventing water.
    @discardableResult
    func alarmFired(eventDate: Date?) -> Bool {
        guard managesSharedAlarm, let model else { return false }
        let now = Date()
        guard let eventDate, isFresh(eventDate, receivedAt: now) else {
            requestRefresh()
            return true
        }
        let device = model.ble.deviceId
        guard model.live.lastSmartAlarmEventDeviceID == device else {
            requestRefresh()
            return true
        }
        let candidate = matchingWake(eventDate: eventDate, deviceID: device, now: now)
        if let candidate {
            runtime.wakeFire = WakeFire(deviceID: device, wakeAt: candidate.wakeAt,
                                       eventDate: eventDate, receivedAt: now)
            let fireID = "\(device).\(Int(candidate.wakeAt.timeIntervalSince1970))"
            if !runtime.mirroredWakeIDs.contains(fireID) {
                runtime.mirroredWakeIDs.append(fireID)
                runtime.mirroredWakeIDs = Array(runtime.mirroredWakeIDs.suffix(14))
                AppModel.postSmartAlarm()
            }
        }
        // Secure the next wake synchronously before FrameRouter starts any history offload.
        // The bounded background handoff can then replace it with the next water slot after a
        // successful total read. A busy database never strands the register on an expired cue.
        lastAttempt = nil
        selectNextWake(at: now)
        saveRuntime()
        alarmHandoffPending = true
        beginBackgroundWork()
        requestRefresh()
        return true
    }

    /// Wake dismissal is consumed first. During an activated day, all fresh drink gestures are owned.
    func handleDoubleTap(eventDate: Date?) -> Bool {
        guard managesSharedAlarm, let model else { return false }
        let now = Date()
        let device = model.ble.deviceId
        if let eventDate, isFresh(eventDate, receivedAt: now),
           eventDate >= Date(timeIntervalSince1970: floor(eligibleSince.timeIntervalSince1970)),
           let wake = matchingWake(eventDate: eventDate, deviceID: device, now: now),
           let plan = todayPlan(at: now), plan.wakeAt == wake.wakeAt,
           runtime.activation?.wakeAt != wake.wakeAt {
            activate(plan: plan, at: eventDate, deviceID: device)
            outcome = (String(localized: "Wake alarm stopped. Hydration tracking is active."), now.addingTimeInterval(8))
            requestRefresh()
            return true
        }
        guard !workoutIsActive, let plan = activePlan(at: now),
              let activation = runtime.activation else { return false }
        // The daytime mode reserves this gesture even if its timestamp/link is unusable. Falling
        // through would unexpectedly run a user's unrelated action while trying to record water.
        guard model.ble.canSendHydrationCoachHaptic,
              let eventDate, isFresh(eventDate, receivedAt: now),
              eventDate >= plan.wakeAt, eventDate < plan.bedtimeAt,
              eventDate > activation.activatedAt,
              eventDate >= Date(timeIntervalSince1970: floor(eligibleSince.timeIntervalSince1970)) else { return true }
        var context = GestureContext(settings: settings, activation: activation,
                                     generation: sessionGeneration, deviceID: device,
                                     timeZoneIdentifier: Self.localCalendar.timeZone.identifier)
        if let previous = gestureContext, previous != context {
            invalidateGestures(at: now)
            context = GestureContext(settings: settings, activation: activation,
                                     generation: sessionGeneration, deviceID: device,
                                     timeZoneIdentifier: Self.localCalendar.timeZone.identifier)
        }
        gestureContext = context
        let eventID = "\(device).\(Int(eventDate.timeIntervalSince1970))"
        beginBackgroundWork()
        let entries = gestureAggregator.receive(eventID: eventID, eventDate: eventDate,
                                                 receivedAt: now, settings: settings)
        for entry in entries { commit(entry, context: context) }
        scheduleGestureFlush()
        return true
    }

    private var workoutIsActive: Bool {
        model?.activeWorkout != nil || model?.strapDoubleTapOverride != nil
    }

    private func todayPlan(at now: Date) -> HydrationRoutinePlan? {
        guard let model else { return nil }
        return HydrationRoutinePlanner.plan(wakeAt: model.resolvedCoachWake(on: now, calendar: Self.localCalendar),
                                           settings: settings, calendar: Self.localCalendar)
    }

    private func activePlan(at now: Date) -> HydrationRoutinePlan? {
        guard managesSharedAlarm, let model, let activation = runtime.activation,
              let plan = todayPlan(at: now), activation.deviceID == model.ble.deviceId,
              activation.dayKey == plan.dayKey, activation.wakeAt == plan.wakeAt,
              activation.timeZoneIdentifier == Self.localCalendar.timeZone.identifier,
              now >= activation.activatedAt, now >= plan.wakeAt, now < plan.bedtimeAt else { return nil }
        return plan
    }

    private func activate(plan: HydrationRoutinePlan, at date: Date, deviceID: String) {
        invalidateGestures(at: Date())
        clearReminderOverrides()
        runtime.activation = Activation(deviceID: deviceID, dayKey: plan.dayKey, wakeAt: plan.wakeAt,
                                        activatedAt: date, timeZoneIdentifier: Self.localCalendar.timeZone.identifier)
        runtime.wakeFire = nil
        saveRuntime()
    }

    private func matchingWake(eventDate: Date, deviceID: String, now: Date) -> WakeExpectation? {
        guard let plan = todayPlan(at: now), eventDate >= plan.wakeAt,
              eventDate < min(plan.bedtimeAt, plan.wakeAt.addingTimeInterval(Self.wakeDismissalSeconds)) else { return nil }
        let expected = runtime.expectedWakes.first {
            $0.deviceID == deviceID && $0.wakeAt == plan.wakeAt
                && $0.timeZoneIdentifier == Self.localCalendar.timeZone.identifier
        }
        if let expected { return expected }
        if let fired = runtime.wakeFire, fired.deviceID == deviceID, fired.wakeAt == plan.wakeAt,
           eventDate >= fired.eventDate, now.timeIntervalSince(fired.receivedAt) <= Self.wakeDismissalSeconds {
            return WakeExpectation(deviceID: deviceID, wakeAt: plan.wakeAt,
                                   timeZoneIdentifier: Self.localCalendar.timeZone.identifier)
        }
        return nil
    }

    private func isFresh(_ eventDate: Date, receivedAt now: Date) -> Bool {
        eventDate.timeIntervalSince1970 > 0 && eventDate <= now
            && now.timeIntervalSince(eventDate) <= Self.eventFreshnessSeconds
    }

    private func saveRuntime() {
        guard runtime != lastSavedRuntime else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(runtime) else { return }
        defaults.set(data, forKey: Self.stateKey)
        lastSavedRuntime = runtime
    }

    private func clearReminderOverrides() {
        guard runtime.reminderOverrides != nil else { return }
        runtime.reminderOverrides = nil
        saveRuntime()
    }

    private func prepareOverrides(for plan: HydrationRoutinePlan) {
        if runtime.reminderOverrides?.planID != plan.id {
            runtime.reminderOverrides = ReminderOverrides(planID: plan.id)
            saveRuntime()
        }
    }

    private func skipDrinkDate(_ date: Date, in plan: HydrationRoutinePlan) {
        guard var overrides = runtime.reminderOverrides, overrides.planID == plan.id else { return }
        for slot in plan.slots where slot.scheduledAt == date { overrides.skippedSlotIDs.insert(slot.id) }
        if let snoozed = overrides.snoozedDrink, snoozed.date == date {
            overrides.skippedSlotIDs.insert(snoozed.slot.id)
            overrides.snoozedDrink = nil
        }
        runtime.reminderOverrides = overrides
        saveRuntime()
    }

    private func scheduledDrinks(in plan: HydrationRoutinePlan, at now: Date) -> [ScheduledDrink] {
        guard totalML < Double(settings.personalGoalML) else { return [] }
        let overrides = runtime.reminderOverrides?.planID == plan.id ? runtime.reminderOverrides : nil
        let skipped = overrides?.skippedSlotIDs ?? []
        var candidates = plan.slots.filter {
            $0.scheduledAt > now && Double($0.cumulativeTargetML) > totalML && !skipped.contains($0.id)
        }.map { ScheduledDrink(slot: $0, date: $0.scheduledAt) }
        if let snoozed = overrides?.snoozedDrink, snoozed.planID == plan.id,
           snoozed.date > now, snoozed.date < plan.bedtimeAt,
           Double(snoozed.slot.cumulativeTargetML) > totalML {
            candidates.append(ScheduledDrink(slot: snoozed.slot, date: snoozed.date))
        }
        // At a collision one signal represents both checkpoints; prefer the later cumulative target.
        candidates.sort {
            $0.date == $1.date ? $0.slot.cumulativeTargetML > $1.slot.cumulativeTargetML : $0.date < $1.date
        }
        var dates = Set<Date>()
        return candidates.filter { dates.insert($0.date).inserted }
    }

    private func invalidateGestures(at now: Date) {
        sessionGeneration &+= 1
        eligibleSince = now
        gestureAggregator.invalidate()
        gestureContext = nil
        gestureFlushTask?.cancel()
        gestureFlushTask = nil
        endBackgroundWorkIfIdle()
    }

    private func scheduleGestureFlush() {
        gestureFlushTask?.cancel()
        guard let deadline = gestureAggregator.nextDeadline else {
            gestureFlushTask = nil
            gestureContext = nil
            endBackgroundWorkIfIdle()
            return
        }
        let delay = max(0, deadline.timeIntervalSinceNow)
        gestureFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if let entry = self.gestureAggregator.flush(at: Date()), let context = self.gestureContext {
                self.commit(entry, context: context)
            }
            self.scheduleGestureFlush()
        }
    }

    private func contextIsCurrent(_ context: GestureContext, at now: Date) -> Bool {
        guard let model, managesSharedAlarm, !workoutIsActive,
              settings == context.settings, sessionGeneration == context.generation,
              model.ble.deviceId == context.deviceID,
              runtime.activation == context.activation,
              context.timeZoneIdentifier == Self.localCalendar.timeZone.identifier,
              model.ble.canSendHydrationCoachHaptic,
              activePlan(at: now) != nil else { return false }
        return true
    }

    private func commit(_ entry: HydrationGestureEntry, context: GestureContext) {
        pendingCommits += 1
        beginBackgroundWork()
        let previous = commitTail
        commitTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.pendingCommits -= 1
                self.endBackgroundWorkIfIdle()
                self.requestRefresh()
            }
            let now = Date()
            let calendar = Self.localCalendar
            let day = HydrationCoachSchedule.dayKey(for: entry.eventDate, calendar: calendar)
            guard self.contextIsCurrent(context, at: now),
                  day == HydrationCoachSchedule.dayKey(for: now, calendar: calendar),
                  now.timeIntervalSince(entry.receivedAt) <= 30,
                  entry.eventDates.allSatisfy({ HydrationCoachSchedule.dayKey(for: $0, calendar: calendar) == day }) else { return }
            guard let model = self.model else { return }
            let receipts = entry.eventIDs.map { "hydration-gesture.\(day).\($0)" }
            guard let receipt = receipts.first else { return }
            self.status = String(localized: "Saving your drink…")
            do {
                let committed = try await HydrationCoachCommit.perform(
                    persist: {
                        try await model.repo.logHydrationGesture(receiptID: receipt,
                            additionalReceiptIDs: Array(receipts.dropFirst()), amountMl: entry.volumeML,
                            day: day, at: entry.eventDate)
                    },
                    canConfirm: { self.contextIsCurrent(context, at: Date()) },
                    confirm: { _ = model.ble.buzzHydrationCoach() })
                if committed { self.outcome = (String(localized: "Drink saved."), Date().addingTimeInterval(8)) }
            } catch {
                self.outcome = (String(localized: "Drink could not be saved. Log it manually."),
                                Date().addingTimeInterval(15))
            }
        }
    }

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Hydration drink") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.alarmHandoffPending = false
                self.refreshGeneration += 1
                self.refreshTask?.cancel()
                self.invalidateGestures(at: Date())
                self.endBackgroundWork()
            }
        }
    }

    private func endBackgroundWorkIfIdle() {
        if gestureAggregator.nextDeadline == nil && pendingCommits == 0 && !alarmHandoffPending { endBackgroundWork() }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func requestRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(generation: generation)
        }
    }

    private func refresh(generation: Int) async {
        guard let model else { return }
        defer {
            if generation == refreshGeneration {
                alarmHandoffPending = false
                endBackgroundWorkIfIdle()
            }
        }
        var now = Date()
        let calendar = Self.localCalendar
        if runtime.activation != nil && activePlan(at: now) == nil {
            runtime.activation = nil
            invalidateGestures(at: now)
            clearReminderOverrides()
            saveRuntime()
        }
        guard managesSharedAlarm else {
            let restoreWake = didManageSlot
            didManageSlot = false
            nextAlarmDate = nil
            nextAlarmIsHydration = false
            alarmStatus = ""
            queueNotifications([])
            recommendedServingML = nil
            if !settings.enabled { status = String(localized: "Hydration Coach is off.") }
            else if !defaults.bool(forKey: HydrationStore.enabledKey) { status = String(localized: "Hydration tracking is off.") }
            else if !model.behavior.smartAlarmEnabled { status = String(localized: "Set and enable your wake alarm in Alarms.") }
            else { status = String(localized: "Waiting for a ready WHOOP 4.0 connection.") }
            if restoreWake { model.applySmartAlarm() }
            return
        }
        didManageSlot = true
        let day = HydrationCoachSchedule.dayKey(for: now, calendar: calendar)
        guard let store = await model.repo.storeHandle() else {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            selectNextWake(at: Date())
            status = String(localized: "Hydration data is unavailable.")
            queueNotifications([])
            return
        }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        do {
            let manual = try await store.metricSeries(deviceId: HydrationStore.sourceId,
                key: HydrationStore.key, from: day, to: day)
            let imported = try await store.metricSeries(deviceId: HydrationStore.sourceId,
                key: HydrationStore.importedKey, from: day, to: day)
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            let value = (manual.first?.value ?? 0) + (imported.first?.value ?? 0)
            guard value.isFinite, value >= 0 else {
                selectNextWake(at: Date())
                status = String(localized: "Hydration data is unavailable.")
                queueNotifications([])
                return
            }
            totalML = value
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            selectNextWake(at: Date())
            status = String(localized: "Hydration data is unavailable.")
            queueNotifications([])
            return
        }
        now = Date()
        guard day == HydrationCoachSchedule.dayKey(for: now, calendar: Self.localCalendar), managesSharedAlarm else {
            requestRefresh()
            return
        }
        if let plan = activePlan(at: now), let activation = runtime.activation {
            if workoutIsActive || totalML >= Double(settings.personalGoalML) {
                clearReminderOverrides()
            } else {
                prepareOverrides(for: plan)
            }
            if !workoutIsActive,
               let drink = scheduledDrinks(in: plan, at: now).first,
               drink.date > activation.activatedAt {
                recommendedServingML = Double(max(0, min(drink.slot.recommendedML,
                    plan.maximumSuggestedML, Int(ceil(Double(drink.slot.cumulativeTargetML) - totalML)))))
                select(AlarmSelection(deviceID: model.ble.deviceId, date: drink.date,
                                      hydration: true, dayKey: plan.dayKey), at: now)
            } else {
                recommendedServingML = nil
                selectNextWake(at: now)
            }
            if workoutIsActive { status = String(localized: "Hydration reminders are paused for your workout.") }
            else if totalML >= Double(settings.personalGoalML) {
                status = String(localized: "Hydration tracking is active. Daily goal reached.")
            } else { status = String(localized: "Double tap to log a glass. Double tap twice to log a bottle.") }
            let reminders = workoutIsActive ? [] : scheduledDrinks(in: plan, at: now).prefix(32).map {
                HydrationCoachReminder(id: $0.slot.id, dayKey: plan.dayKey, scheduledAt: $0.date,
                                       expiresAt: min($0.date.addingTimeInterval(120), plan.bedtimeAt))
            }
            queueNotifications(Array(reminders))
        } else {
            recommendedServingML = nil
            selectNextWake(at: now)
            if model.resolvedCoachWake(on: now, calendar: Self.localCalendar) != nil,
               todayPlan(at: now) == nil {
                status = String(localized: "Invalid reminder settings.")
            } else {
                status = String(localized: "Waiting for your wake alarm. Start today if you are already awake.")
            }
            queueNotifications([])
        }
        if let outcome, outcome.until > now { status = outcome.text }
        if pendingCommits > 0 || gestureAggregator.nextDeadline != nil { status = String(localized: "Saving your drink…") }
    }

    private func selectNextWake(at now: Date) {
        guard let model, let next = model.resolvedNextCoachWake(after: now, calendar: Self.localCalendar) else {
            nextAlarmDate = nil
            nextAlarmIsHydration = false
            alarmStatus = String(localized: "Set and enable your wake alarm in Alarms.")
            return
        }
        select(AlarmSelection(deviceID: model.ble.deviceId, date: next, hydration: false,
                              dayKey: HydrationCoachSchedule.dayKey(for: next, calendar: Self.localCalendar)), at: now)
    }

    private func select(_ selection: AlarmSelection, at now: Date) {
        guard let model, managesSharedAlarm, selection.deviceID == model.ble.deviceId,
              selection.date > now else { return }
        nextAlarmDate = selection.date
        nextAlarmIsHydration = selection.hydration
        guard model.ble.canSendHydrationCoachHaptic else {
            lastAttempt = nil
            alarmStatus = String(localized: "Waiting for a ready WHOOP 4.0 connection.")
            return
        }
        let epoch = Int(selection.date.timeIntervalSince1970)
        let observed = model.live.alarmReportedEpoch
        let attributed = model.live.alarmReportedDeviceID == selection.deviceID
        let freshReadback = model.live.alarmReportedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 300 } == true
        let reportsSelected = attributed && freshReadback && observed == epoch
        if reportsSelected {
            alarmStatus = String(localized: "WHOOP reports the selected alarm time.")
        } else if attributed && freshReadback && observed != nil {
            alarmStatus = String(localized: "WHOOP reports a different alarm time. NOOP will retry.")
        } else {
            alarmStatus = String(localized: "Next alarm requested. Waiting for strap readback.")
        }
        // A new selection or connection is written immediately. Unrecognised/mismatching readback
        // stays explicit and retries at a bounded rate, rather than claiming the write was delivery.
        let sameAttempt = lastAttempt?.selection == selection
        let retryDue = lastAttempt.map { now.timeIntervalSince($0.date) >= 60 } ?? true
        guard !sameAttempt || (!reportsSelected && retryDue) else { return }
        guard model.ble.armHydrationCoachAlarm(at: selection.date) else { return }
        lastAttempt = (selection, now)
        runtime.lastProgram = selection
        if !selection.hydration {
            let expected = WakeExpectation(deviceID: selection.deviceID, wakeAt: selection.date,
                                           timeZoneIdentifier: Self.localCalendar.timeZone.identifier)
            runtime.expectedWakes.removeAll {
                $0.wakeAt < now.addingTimeInterval(-Self.wakeDismissalSeconds)
                    || ($0.deviceID == expected.deviceID && $0.wakeAt == expected.wakeAt)
            }
            runtime.expectedWakes.append(expected)
            runtime.expectedWakes = Array(runtime.expectedWakes.suffix(10))
        }
        saveRuntime()
    }

    /// Serialize hydration notification replacements; the existing wake backup remains independent.
    private func queueNotifications(_ reminders: [HydrationCoachReminder]) {
        let signature = reminders.map { "\($0.id)@\($0.scheduledAt.timeIntervalSince1970)" }.joined(separator: "|")
        if notificationTask == nil, notificationSignature == signature { return }
        if desiredNotifications == reminders { return }
        notificationRevision += 1
        desiredNotifications = reminders
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self else { return }
            while let next = self.desiredNotifications {
                self.desiredNotifications = nil
                let revision = self.notificationRevision
                await self.replaceNotifications(next, revision: revision)
            }
            self.notificationTask = nil
        }
    }

    private func replaceNotifications(_ reminders: [HydrationCoachReminder], revision: Int) async {
        let authorization = await center.notificationSettings()
        guard revision == notificationRevision else { return }
        let authorized = authorization.authorizationStatus == .authorized
            || authorization.authorizationStatus == .provisional
            || authorization.authorizationStatus == .ephemeral
        let allowed = authorized && authorization.alertSetting == .enabled
        let desired = allowed ? reminders : []
        let signature = desired.map { "\($0.id)@\($0.scheduledAt.timeIntervalSince1970)" }.joined(separator: "|")
        notificationStatus = allowed
            ? (desired.isEmpty ? "" : String(localized: "Notifications are scheduled for up to the next 24 hours."))
            : String(localized: "Notifications are off in iOS Settings.")
        guard notificationSignature != signature else { return }
        let pending = await center.pendingNotificationRequests()
        guard revision == notificationRevision else { return }
        notificationSignature = nil
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)
            .filter { $0.hasPrefix(Self.notificationPrefix) })
        do {
            for reminder in desired {
                guard revision == notificationRevision else { return }
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Time for water")
                content.body = String(localized: "Open NOOP to log a drink. A notification never logs water automatically.")
                content.sound = .default
                content.threadIdentifier = "hydration-coach"
                var components = Self.localCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                                 from: reminder.scheduledAt)
                components.calendar = Self.localCalendar
                components.timeZone = Self.localCalendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
            guard revision == notificationRevision else { return }
            notificationSignature = signature
        } catch {
            notificationSignature = nil
            notificationStatus = String(localized: "Notifications could not be scheduled.")
        }
    }
}
#endif
