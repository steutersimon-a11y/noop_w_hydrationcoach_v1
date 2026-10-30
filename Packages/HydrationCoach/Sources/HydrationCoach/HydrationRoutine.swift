import Foundation

public enum HydrationRoutineMode: String, Codable, Equatable {
    case night
    case wakeRinging
    case hydration
}

/// A recorded user action, never inferred from an elapsed alarm date or a reconnection.
public struct HydrationRoutineActivation: Codable, Equatable {
    public let dayKey: String
    public let wakeAt: Date
    public let dismissedAt: Date
    public let timeZoneIdentifier: String

    public init(wakeAt: Date, dismissedAt: Date, calendar: Calendar = .current) {
        self.dayKey = HydrationCoachSchedule.dayKey(for: wakeAt, calendar: calendar)
        self.wakeAt = wakeAt
        self.dismissedAt = dismissedAt
        self.timeZoneIdentifier = calendar.timeZone.identifier
    }

    public func matches(_ plan: HydrationRoutinePlan) -> Bool {
        dayKey == plan.dayKey && wakeAt == plan.wakeAt &&
        timeZoneIdentifier == plan.timeZoneIdentifier && dismissedAt >= wakeAt &&
        dismissedAt < plan.bedtimeAt
    }
}

public struct HydrationRoutineSlot: Identifiable, Codable, Equatable {
    public let id: String
    public let scheduledAt: Date
    public let recommendedML: Int
    public let cumulativeTargetML: Int
    public let isBedtimeBoundary: Bool
}

public struct HydrationRoutinePlan: Codable, Equatable {
    public let id: String
    public let dayKey: String
    public let wakeAt: Date
    public let bedtimeAt: Date
    public let timeZoneIdentifier: String
    public let goalML: Int
    public let maximumSuggestedML: Int
    /// Includes the final goal checkpoint at bedtime for exact proportional totals.
    /// That checkpoint is a display/accounting boundary, never a drinking alarm.
    public let checkpoints: [HydrationRoutineSlot]

    public var slots: [HydrationRoutineSlot] {
        checkpoints.filter { !$0.isBedtimeBoundary && $0.scheduledAt < bedtimeAt }
    }

    /// Strictly future slots only: activation, reconnect and late alarm delivery never catch up.
    /// Recorded water can suppress reminders, but never changes the actual recorded amount.
    public func nextSlot(after now: Date, totalML: Double,
                         notBefore activationDate: Date? = nil) -> HydrationRoutineSlot? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              activationDate?.timeIntervalSinceReferenceDate.isFinite != false,
              (250...10_000).contains(goalML), totalML.isFinite, totalML >= 0,
              totalML < Double(goalML), now < bedtimeAt else { return nil }
        let lowerBound = max(now, activationDate ?? now)
        return slots.first {
            $0.scheduledAt > lowerBound && Double($0.cumulativeTargetML) > totalML
        }
    }

    public func recommendedML(at now: Date, totalML: Double) -> Int {
        guard totalML.isFinite, totalML >= 0, totalML < Double(goalML),
              now >= wakeAt, now < bedtimeAt else { return 0 }
        let next = nextSlot(after: now, totalML: totalML)
        // An exact daily deficit is not an instruction to drink it all at once.
        // Skipped slots never enlarge a recommendation beyond its normal portion.
        return next.map {
            max(0, min($0.recommendedML, maximumSuggestedML,
                       Int(ceil(Double($0.cumulativeTargetML) - totalML))))
        } ?? 0
    }
}

/// Shares the existing Smart Alarm wake date without owning another wake-time preference.
public enum HydrationRoutinePlanner {
    public static func plan(wakeAt: Date?, settings: HydrationCoachSettings,
                            calendar: Calendar = .current) -> HydrationRoutinePlan? {
        guard settings.enabled, settings.isValid, let wakeAt,
              wakeAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let dayKey = HydrationCoachSchedule.dayKey(for: wakeAt, calendar: calendar)
        let bedtime: Date?
        if settings.endMinute == 0 {
            bedtime = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: wakeAt))
        } else {
            bedtime = calendar.date(bySettingHour: settings.endMinute / 60,
                                     minute: settings.endMinute % 60, second: 0, of: wakeAt,
                                     matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                     direction: .forward)
        }
        guard let bedtime, bedtime > wakeAt,
              settings.endMinute == 0 ||
                HydrationCoachSchedule.dayKey(for: bedtime, calendar: calendar) == dayKey else { return nil }
        let duration = bedtime.timeIntervalSince(wakeAt)
        guard duration.isFinite, duration > 0 else { return nil }
        let zone = calendar.timeZone.identifier
        let wakeStamp = String(wakeAt.timeIntervalSince1970.bitPattern, radix: 16)
        let planID = "hydration-routine.\(dayKey).\(zone).\(wakeStamp).\(settings.endMinute).\(settings.intervalMinutes).\(settings.personalGoalML)"
        let interval = TimeInterval(settings.intervalMinutes * 60)
        var dates: [Date] = []
        var offset = interval
        while offset < duration {
            dates.append(wakeAt.addingTimeInterval(offset))
            offset += interval
        }
        dates.append(bedtime)
        var previousTarget = 0
        let checkpoints = dates.map { date -> HydrationRoutineSlot in
            let final = date == bedtime
            let target = final ? settings.personalGoalML :
                Int((Double(settings.personalGoalML) * date.timeIntervalSince(wakeAt) / duration).rounded())
            defer { previousTarget = target }
            return HydrationRoutineSlot(
                id: "\(planID).\(String(date.timeIntervalSince1970.bitPattern, radix: 16))",
                scheduledAt: date, recommendedML: target - previousTarget,
                cumulativeTargetML: target, isBedtimeBoundary: final)
        }
        return HydrationRoutinePlan(id: planID, dayKey: dayKey, wakeAt: wakeAt,
                                    bedtimeAt: bedtime, timeZoneIdentifier: zone,
                                    goalML: settings.personalGoalML,
                                    maximumSuggestedML: max(settings.servingML, settings.bottleML),
                                    checkpoints: checkpoints)
    }

    public static func mode(at now: Date, plan: HydrationRoutinePlan?,
                            activation: HydrationRoutineActivation?) -> HydrationRoutineMode {
        guard let plan, now >= plan.wakeAt, now < plan.bedtimeAt else { return .night }
        guard let activation, activation.matches(plan), activation.dismissedAt <= now else { return .wakeRinging }
        return .hydration
    }
}

public struct HydrationGestureEntry: Equatable {
    public let id: String
    public let eventDate: Date
    public let receivedAt: Date
    public let volumeML: Int
    public let gestureCount: Int
    public let eventIDs: [String]
    public let eventDates: [Date]
}

/// Groups two distinct double-tap events before committing one actual container amount.
/// The adapter owns day/mode/workout/channel gating and persists every event ID atomically.
public struct HydrationTapAggregator {
    public static let classificationSeconds: TimeInterval = 3

    private struct Pending {
        let id: String
        let eventDate: Date
        let receivedAt: Date
        let glassML: Int
        let bottleML: Int
        var deadline: Date { receivedAt.addingTimeInterval(HydrationTapAggregator.classificationSeconds) }
    }

    private var pending: Pending?
    private var seenIDs: Set<String> = []
    public init() {}
    public var nextDeadline: Date? { pending?.deadline }

    public mutating func invalidate() { pending = nil }

    public mutating func flush(at now: Date) -> HydrationGestureEntry? {
        guard let pending, now >= pending.deadline else { return nil }
        self.pending = nil
        return entry(for: pending)
    }

    public mutating func receive(eventID: String, eventDate: Date?, receivedAt now: Date,
                                 settings: HydrationCoachSettings) -> [HydrationGestureEntry] {
        guard settings.enabled, settings.isValid, !eventID.isEmpty, let eventDate,
              eventDate.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, eventDate <= now,
              !seenIDs.contains(eventID) else { return [] }
        if let pending, now < pending.receivedAt || eventDate < pending.eventDate { return [] }
        seenIDs.insert(eventID)
        // Half-open window: at the deadline a timer and a second event produce the
        // same two-glass result regardless of callback ordering.
        if let pending, now < pending.deadline,
           eventDate.timeIntervalSince(pending.eventDate) < Self.classificationSeconds {
            self.pending = nil
            return [HydrationGestureEntry(id: pending.id, eventDate: pending.eventDate,
                receivedAt: pending.receivedAt, volumeML: pending.bottleML, gestureCount: 2,
                eventIDs: [pending.id, eventID], eventDates: [pending.eventDate, eventDate])]
        }
        var result: [HydrationGestureEntry] = []
        if let pending { result.append(entry(for: pending)) }
        pending = Pending(id: eventID, eventDate: eventDate, receivedAt: now,
                          glassML: settings.servingML, bottleML: settings.bottleML)
        return result
    }

    private func entry(for pending: Pending) -> HydrationGestureEntry {
        HydrationGestureEntry(id: pending.id, eventDate: pending.eventDate,
            receivedAt: pending.receivedAt, volumeML: pending.glassML, gestureCount: 1,
            eventIDs: [pending.id], eventDates: [pending.eventDate])
    }
}
