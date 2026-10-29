#if os(iOS)
import Combine
import Foundation
import HydrationCoach
import UIKit
import UserNotifications

/// Foreground-only strap reminders with an independent, bounded local-notification fallback.
/// A successful BLE write attempt opens the tap window; notification delivery never does.
@MainActor
final class HydrationCoachController: ObservableObject {
    @Published private(set) var settings: HydrationCoachSettings
    @Published private(set) var status = String(localized: "Hydration Coach is off.")
    @Published private(set) var notificationStatus = String(localized: "Notification permission has not been granted.")
    @Published private(set) var totalML: Double = 0

    var activeReminder: HydrationCoachReminder? { session.activeReminder }

    private static let notificationPrefix = "hydration-coach."
    /// Match the existing hydration tracker's ISO day keys while following the device time zone.
    private static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        return calendar
    }
    private weak var model: AppModel?
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private var session: HydrationCoachSession
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var sceneIsActive = false
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
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
        self.session = HydrationCoachSession(now: now)
        if let data = defaults.data(forKey: HydrationCoachSettings.storageKey),
           let saved = try? JSONDecoder().decode(HydrationCoachSettings.self, from: data), saved.isValid {
            settings = saved
        } else {
            settings = HydrationCoachSettings()
        }

        model.live.$connected.dropFirst().sink { [weak self] connected in
            guard let self else { return }
            if !connected { self.session.invalidate(at: Date()) }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.live.$bonded.dropFirst().sink { [weak self] bonded in
            guard let self else { return }
            if !bonded { self.session.invalidate(at: Date()) }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.live.$encryptedBond.dropFirst().sink { [weak self] encrypted in
            guard let self else { return }
            if !encrypted { self.session.invalidate(at: Date()) }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.$activeWorkout.dropFirst().sink { [weak self] workout in
            guard let self else { return }
            if workout != nil { self.session.invalidate(at: Date()) }
            self.requestRefresh()
        }.store(in: &subscriptions)
        model.repo.$hydrationSeq.dropFirst().sink { [weak self] _ in
            self?.requestRefresh()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.session.invalidate(at: Date())
                self.notificationSignature = nil
                self.requestRefresh()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.defaults.bool(forKey: HydrationStore.enabledKey) {
                    self.session.invalidate(at: Date())
                }
                self.requestRefresh()
            }.store(in: &subscriptions)
        requestRefresh()
    }

    /// The settings toggle is the only path that requests notification authorization.
    func updateSettings(_ value: HydrationCoachSettings) {
        guard value.isValid else {
            status = String(localized: "Invalid reminder settings.")
            return
        }
        guard value != settings else { return }
        let newlyEnabled = value.enabled && !settings.enabled
        session.invalidate(at: Date())
        outcome = nil
        settings = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: HydrationCoachSettings.storageKey)
        }
        if value.enabled { defaults.set(true, forKey: HydrationStore.enabledKey) }
        model?.repo.noteHydrationChanged()
        notificationSignature = nil
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

    /// Never restore a former tap window on foreground entry, reconnect or cold launch.
    func setSceneActive(_ active: Bool) {
        guard sceneIsActive != active else { return }
        sceneIsActive = active
        session.invalidate(at: Date())
        timer?.invalidate()
        timer = nil
        if active {
            let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.requestRefresh() }
            }
            timer.tolerance = 2
            self.timer = timer
        }
        notificationSignature = nil
        requestRefresh()
    }

    /// Called when Lift Log claims/releases the gesture, without changing its existing priority.
    func workoutContextChanged() {
        session.invalidate(at: Date())
        requestRefresh()
    }

    /// Returns true only when the hydration window owns this event (including duplicate taps).
    func handleDoubleTap(eventDate: Date?) -> Bool {
        guard let model, sceneIsActive, defaults.bool(forKey: HydrationStore.enabledKey) else { return false }
        let now = Date()
        let decision = session.prepareTap(
            eventDate: eventDate, receivedAt: now, settings: settings, totalML: totalML,
            workoutActive: workoutIsActive, connected: model.ble.canSendHydrationCoachHaptic,
            calendar: Self.localCalendar)
        switch decision {
        case .ignored:
            return false
        case .duplicate:
            return true
        case .log(let reminder):
            let snapshot = settings
            let sessionGeneration = session.generation
            status = String(localized: "Saving your drink…")
            Task { [weak self, weak model] in
                guard let self else { return }
                guard let model, self.sceneIsActive, self.settings == snapshot,
                      self.session.generation == sessionGeneration,
                      Date() < reminder.expiresAt,
                      !self.workoutIsActive, model.ble.canSendHydrationCoachHaptic,
                      HydrationCoachSchedule.dayKey(for: Date(), calendar: Self.localCalendar) == reminder.dayKey else {
                    self.session.finish(reminderID: reminder.id, committed: false)
                    self.requestRefresh()
                    return
                }
                do {
                    let committed = try await HydrationCoachCommit.perform(
                        persist: {
                            try await model.repo.logHydrationReminder(
                                reminderID: reminder.id, amountMl: snapshot.servingML,
                                goalML: snapshot.personalGoalML, day: reminder.dayKey, at: now)
                        },
                        canConfirm: {
                            self.sceneIsActive && self.settings == snapshot && self.settings.enabled
                                && self.session.generation == sessionGeneration
                                && Date() < reminder.expiresAt
                                && HydrationCoachSchedule.dayKey(for: Date(), calendar: Self.localCalendar) == reminder.dayKey
                                && self.defaults.bool(forKey: HydrationStore.enabledKey)
                                && !self.workoutIsActive && model.ble.canSendHydrationCoachHaptic
                        },
                        confirm: { _ = model.ble.buzzHydrationCoach() })
                    self.session.finish(reminderID: reminder.id, committed: committed)
                    if committed {
                        self.outcome = (String(localized: "Drink saved."), Date().addingTimeInterval(8))
                    }
                } catch {
                    self.session.finish(reminderID: reminder.id, committed: false)
                    self.outcome = (String(localized: "Drink could not be saved. Log it manually."),
                                    Date().addingTimeInterval(15))
                }
                self.requestRefresh()
            }
            return true
        }
    }

    private var workoutIsActive: Bool {
        model?.activeWorkout != nil || model?.strapDoubleTapOverride != nil
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
        let now = Date()
        session.expire(at: now)
        let calendar = Self.localCalendar
        let day = HydrationCoachSchedule.dayKey(for: now, calendar: calendar)
        guard settings.enabled, settings.isValid, defaults.bool(forKey: HydrationStore.enabledKey) else {
            session.invalidate(at: now)
            status = settings.enabled ? String(localized: "Hydration tracking is off.")
                : String(localized: "Hydration Coach is off.")
            queueNotifications([])
            return
        }
        // A failed database read must never look like an empty day and trigger another drink cue.
        guard let store = await model.repo.storeHandle() else {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            session.invalidate(at: Date())
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
            totalML = (manual.first?.value ?? 0) + (imported.first?.value ?? 0)
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            session.invalidate(at: now)
            status = String(localized: "Hydration data is unavailable.")
            queueNotifications([])
            return
        }
        guard day == HydrationCoachSchedule.dayKey(for: Date(), calendar: Self.localCalendar) else {
            session.invalidate(at: Date())
            requestRefresh()
            return
        }
        let workout = workoutIsActive
        if workout || (totalML >= Double(settings.personalGoalML) && !session.isCommitting) {
            // The just-committed final serving may publish progress before its confirmation
            // continuation resumes. Reaching the goal alone must not invalidate that receipt.
            session.invalidate(at: now)
        }
        if !sceneIsActive {
            status = String(localized: "Open NOOP for live strap reminders.")
        } else if workout {
            status = String(localized: "Hydration Coach pauses during workouts.")
        } else if totalML >= Double(settings.personalGoalML) {
            status = String(localized: "Daily hydration goal reached.")
        } else if !model.ble.canSendHydrationCoachHaptic {
            session.invalidate(at: now)
            status = String(localized: "Waiting for a ready WHOOP 4.0 connection.")
        } else {
            let cueTime = Date()
            if let reminder = session.candidate(at: cueTime, settings: settings,
                totalML: totalML, workoutActive: workout, calendar: calendar) {
                let attempted = model.ble.buzzHydrationCoach()
                _ = session.open(reminder, at: cueTime, settings: settings, didAttemptHaptic: attempted,
                    totalML: totalML, workoutActive: workout, calendar: calendar)
            }
            status = session.activeReminder.map { $0.expiresAt > cueTime } == true
                ? String(localized: "Double tap now to log your serving.")
                : String(localized: "Waiting for the next scheduled reminder.")
        }
        if let outcome, outcome.until > now { status = outcome.text }
        if session.isCommitting { status = String(localized: "Saving your drink…") }
        let notifications = HydrationCoachSchedule.notificationReminders(
            at: Date(), settings: settings, totalML: totalML,
            workoutActive: workout, calendar: calendar)
        queueNotifications(notifications)
    }

    /// Serialize notification writes: an old asynchronous add must finish before a newer disable
    /// removes it. Cancelling the refresh task alone cannot cancel an OS notification add.
    private func queueNotifications(_ reminders: [HydrationCoachReminder]) {
        let signature = reminders.map(\.id).joined(separator: "|")
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

    /// Owns only hydration notification IDs, leaving wake alarms and every other notification alone.
    private func replaceNotifications(_ reminders: [HydrationCoachReminder], revision: Int) async {
        let authorization = await center.notificationSettings()
        guard revision == notificationRevision else { return }
        let authorized = authorization.authorizationStatus == .authorized
            || authorization.authorizationStatus == .provisional
            || authorization.authorizationStatus == .ephemeral
        let allowed = authorized && authorization.alertSetting == .enabled
        let desired = allowed ? reminders : []
        let signature = desired.map(\.id).joined(separator: "|")
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
