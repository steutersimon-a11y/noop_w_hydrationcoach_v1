import Foundation

/// Opt-in personal coaching, separate from the existing sex/effort goal when coaching is off.
/// iOS phase 1 only: these are reminder preferences, not physiological hydration measurements.
public struct HydrationCoachSettings: Codable, Equatable {
    public static let storageKey = "noop.hydrationCoach.settings"
    public var enabled: Bool
    public var personalGoalML: Int
    public var servingML: Int
    public var startMinute: Int
    public var endMinute: Int
    public var intervalMinutes: Int

    public init(enabled: Bool = false, personalGoalML: Int = 3_000, servingML: Int = 250,
                startMinute: Int = 450, endMinute: Int = 1_290, intervalMinutes: Int = 75) {
        self.enabled = enabled
        self.personalGoalML = personalGoalML
        self.servingML = servingML
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.intervalMinutes = intervalMinutes
    }

    /// Same-day waking windows; invalid persisted values fail closed rather than scheduling a flood.
    public var isValid: Bool {
        (250...10_000).contains(personalGoalML) && (50...1_000).contains(servingML) &&
        (0..<1_440).contains(startMinute) && (1..<1_440).contains(endMinute) &&
        startMinute < endMinute && (15...240).contains(intervalMinutes)
    }
}

public struct HydrationCoachReminder: Identifiable, Codable, Equatable {
    public let id: String
    public let dayKey: String
    public let scheduledAt: Date
    public let expiresAt: Date
}

/// Wall-clock cadence in the supplied local calendar, never fixed 86,400-second day arithmetic.
public enum HydrationCoachSchedule {
    public static let acceptanceSeconds: TimeInterval = 120

    /// A bounded rolling fallback; today's completed goal must not suppress tomorrow's new day.
    public static func notificationReminders(at now: Date, settings: HydrationCoachSettings,
                                              totalML: Double, workoutActive: Bool,
                                              calendar: Calendar = .current, limit: Int = 32) -> [HydrationCoachReminder] {
        guard settings.enabled, settings.isValid, !workoutActive, totalML.isFinite, totalML >= 0 else { return [] }
        var result = totalML < Double(settings.personalGoalML)
            ? reminders(on: now, settings: settings, calendar: calendar) : []
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            result += reminders(on: tomorrow, settings: settings, calendar: calendar)
        }
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        return Array(result.filter { $0.scheduledAt > now && $0.scheduledAt <= horizon }
            .sorted { $0.scheduledAt < $1.scheduledAt }.prefix(max(0, min(32, limit))))
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func reminders(on date: Date, settings: HydrationCoachSettings,
                                 calendar: Calendar = .current) -> [HydrationCoachReminder] {
        guard settings.enabled, settings.isValid else { return [] }
        let day = dayKey(for: date, calendar: calendar)
        func localTime(_ minute: Int, boundary: Bool = false) -> Date? {
            guard let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60,
                                           second: 0, of: date, matchingPolicy: boundary ? .nextTime : .strict,
                                           repeatedTimePolicy: .first, direction: .forward),
                  dayKey(for: time, calendar: calendar) == day else { return nil }
            return time
        }
        // A missing spring-forward end boundary advances to the first valid time, rather than
        // discarding earlier valid reminders in the same waking window.
        guard let end = localTime(settings.endMinute, boundary: true) else { return [] }
        return stride(from: settings.startMinute, to: settings.endMinute,
                      by: settings.intervalMinutes).compactMap { minute in
            // A nonexistent spring-forward time is omitted. The repeated autumn time occurs once.
            guard let time = localTime(minute), time < end else { return nil }
            return HydrationCoachReminder(
                id: "hydration-coach.\(day).\(minute).\(calendar.timeZone.identifier)",
                dayKey: day, scheduledAt: time,
                expiresAt: min(time.addingTimeInterval(acceptanceSeconds), end))
        }
    }
}

public enum HydrationCoachTapDecision: Equatable {
    case ignored
    case duplicate
    case log(HydrationCoachReminder)
}

/// Ephemeral acceptance state. A notification or a restored/reconnected process never opens a window.
/// The caller persists `.log` through the existing tracker and confirms only a newly committed receipt.
public struct HydrationCoachSession {
    private struct Window {
        let reminder: HydrationCoachReminder
        let openedAt: Date
        let settings: HydrationCoachSettings
    }
    private var eligibleSince: Date
    private var attemptedIDs: Set<String> = []
    private var active: Window?
    private var pending: Window?
    private var settled: Window?
    public private(set) var generation: UInt64 = 0

    public init(now: Date) { eligibleSince = now }
    public var activeReminder: HydrationCoachReminder? { active?.reminder }
    public var isCommitting: Bool { pending != nil }

    public mutating func invalidate(at date: Date) {
        generation &+= 1
        active = nil
        pending = nil
        settled = nil
        eligibleSince = date
    }

    public mutating func expire(at now: Date) {
        if let active, now >= active.reminder.expiresAt { self.active = nil }
        if let settled, now >= settled.reminder.expiresAt { self.settled = nil }
    }

    public func candidate(at now: Date, settings: HydrationCoachSettings, totalML: Double,
                          workoutActive: Bool, calendar: Calendar = .current) -> HydrationCoachReminder? {
        guard settings.enabled, settings.isValid, totalML.isFinite, totalML >= 0,
              totalML < Double(settings.personalGoalML), !workoutActive, pending == nil else { return nil }
        return HydrationCoachSchedule.reminders(on: now, settings: settings, calendar: calendar).first {
            $0.scheduledAt >= eligibleSince && $0.scheduledAt <= now && now < $0.expiresAt &&
            !attemptedIDs.contains($0.id)
        }
    }

    /// `didAttemptHaptic` means a ready command channel accepted a write attempt, never delivery proof.
    @discardableResult
    public mutating func open(_ reminder: HydrationCoachReminder, at now: Date,
                              settings: HydrationCoachSettings, didAttemptHaptic: Bool,
                              totalML: Double, workoutActive: Bool,
                              calendar: Calendar = .current) -> Bool {
        guard candidate(at: now, settings: settings, totalML: totalML,
                        workoutActive: workoutActive, calendar: calendar) == reminder else { return false }
        attemptedIDs.insert(reminder.id)
        active = nil
        settled = nil
        guard didAttemptHaptic else { return false }
        active = Window(reminder: reminder, openedAt: now, settings: settings)
        return true
    }

    public mutating func prepareTap(eventDate: Date?, receivedAt now: Date,
                                    settings: HydrationCoachSettings, totalML: Double,
                                    workoutActive: Bool, connected: Bool,
                                    calendar: Calendar = .current) -> HydrationCoachTapDecision {
        guard settings.enabled, settings.isValid, connected, !workoutActive,
              totalML.isFinite, totalML >= 0, totalML < Double(settings.personalGoalML) else {
            active = nil
            return .ignored
        }
        guard let eventDate, let window = active ?? pending ?? settled,
              window.settings == settings,
              HydrationCoachSchedule.dayKey(for: now, calendar: calendar) == window.reminder.dayKey,
              HydrationCoachSchedule.reminders(on: now, settings: settings, calendar: calendar)
                .contains(where: { $0.id == window.reminder.id }),
              now >= window.openedAt, now < window.reminder.expiresAt,
              eventDate >= window.openedAt, eventDate <= now,
              eventDate < window.reminder.expiresAt else { return .ignored }
        if pending != nil || settled != nil { return .duplicate }
        active = nil
        pending = window
        return .log(window.reminder)
    }

    /// Both success and failure close this window. Failed writes require an explicit manual retry.
    public mutating func finish(reminderID: String, committed: Bool) {
        guard pending?.reminder.id == reminderID else { return }
        // Retain gesture ownership until expiry even after a successful or failed write. A second
        // tap during this reminder must not unexpectedly run the user's normal double-tap action.
        settled = pending
        pending = nil
    }
}

/// The post-transaction confirmation boundary, shared by the iOS adapter and headless tests.
public enum HydrationCoachCommit {
    @MainActor
    @discardableResult
    public static func perform(persist: () async throws -> Bool, canConfirm: () -> Bool,
                               confirm: () -> Void) async throws -> Bool {
        let newlyCommitted = try await persist()
        if newlyCommitted && canConfirm() { confirm() }
        return newlyCommitted
    }
}
