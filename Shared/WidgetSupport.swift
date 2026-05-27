import Foundation
import SwiftUI
import WidgetKit
import HealthKit

private enum WidgetPalette {
    static let goalRing = Color.green
    static let averageLow = Color.orange
    static let averageHigh = Color.green
    static let todayFill = Color.pink
    static let standRing = Color.blue
    static let trackFill = Color.black.opacity(0.78)
    static let trackStroke = Color.white.opacity(0.18)
}

/// Shared widget timeline entry used by both the iOS widget target and the watch widget target.
struct KcaliEntry: TimelineEntry {
    let date: Date
    let aplGoal: Int
    let minCals: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
    let isSteps: Bool
    let standingHours: Int
    let standingGoal: Int
    let stoodThisHour: Bool
}

extension KcaliEntry {
    init(from shared: (aplGoal: Int, minCals: Int, avgCals: Int, goal: Int, todaysCals: Int, todaysMinCalsGoal: Int, rollingDays: Int, trackingMode: String, stoodThisHour: Bool)) {
        let trackingMode = TrackingMode(rawValue: shared.trackingMode) ?? .calories
        let resolvedGoal = max(shared.goal, TrackingDefaults.goal(for: trackingMode))

        self.init(
            date: Date(),
            aplGoal: shared.aplGoal,
            minCals: shared.minCals,
            avgCals: shared.avgCals,
            goal: resolvedGoal,
            todaysCals: shared.todaysCals,
            todaysMinCalsGoal: max(shared.todaysMinCalsGoal, 1),
            isSteps: trackingMode == .steps,
            standingHours: 0,
            standingGoal: 0,
            stoodThisHour: shared.stoodThisHour
        )
    }

    var minimumTarget: Int {
        if isSteps { return max(goal, 1) }
        return max(todaysMinCalsGoal, 1)
    }

    var progressFraction: CGFloat {
        CGFloat(min(Double(todaysCals) / Double(minimumTarget), 1.0))
    }

    var standingFraction: CGFloat {
        let target = standingGoal > 0 ? standingGoal : max(standingHours, 12)
        guard target > 0 else { return 0.0 }
        return CGFloat(min(Double(standingHours) / Double(target), 1.0))
    }

    var standingTarget: Int {
        standingGoal > 0 ? standingGoal : 12
    }

    var primaryTarget: Int {
        if !isSteps && aplGoal > todaysMinCalsGoal {
            return max(aplGoal, 1)
        }
        return minimumTarget
    }

    var unitLabel: String {
        isSteps ? "steps" : "kcal"
    }
}

/// Converts shared entry data into the generic ring model that multiple widget surfaces can draw.
func generateWidgetRings(from entry: KcaliEntry, usesStandHourGoalHighlight: Bool = true) -> [SharedRing] {
    generateRings(
        from: SharedRingInput(
            aplGoal: entry.aplGoal,
            avgCals: entry.avgCals,
            goal: entry.goal,
            todaysCals: entry.todaysCals,
            todaysMinCalsGoal: entry.todaysMinCalsGoal,
            isSteps: entry.isSteps,
            stoodThisHour: entry.stoodThisHour,
            usesStandHourGoalHighlight: usesStandHourGoalHighlight
        )
    )
}

/// Shared timeline provider used by both widget targets.
/// The provider still prefers App Group values as a fallback, but it now derives
/// live metrics through the same collector and math helpers used by the apps.
struct KcaliTimelineProvider: TimelineProvider {
    private let store = HKHealthStore()
    private let healthService = AppleHealthDataService()
    private static let refreshMinutes = 5
    private static let lookbackDays = 30

    func placeholder(in context: Context) -> KcaliEntry {
        KcaliEntry(from: SharedStore.read())
    }

    func getSnapshot(in context: Context, completion: @escaping (KcaliEntry) -> Void) {
        completion(KcaliEntry(from: SharedStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KcaliEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let nextRefreshDate = Self.nextRefreshDate(after: Date())
            completion(Timeline(entries: [entry], policy: .after(nextRefreshDate)))
        }
    }

    private func fetchEntry() async -> KcaliEntry {
        let shared = SharedStore.read()
        let trackingMode = TrackingMode(rawValue: shared.trackingMode) ?? .calories
        let cached = cachedEntry(trackingMode: shared.trackingMode)
        let live = try? await buildLiveEntry(shared: shared, trackingMode: trackingMode)
        var entry = live ?? KcaliEntry(from: shared)

        if isLikelyPlaceholder(entry), let cached {
            entry = cached
        }

        if !isLikelyPlaceholder(entry) {
            cache(entry: entry, trackingMode: shared.trackingMode)
        }

        return entry
    }

    private func buildLiveEntry(
        shared: (aplGoal: Int, minCals: Int, avgCals: Int, goal: Int, todaysCals: Int, todaysMinCalsGoal: Int, rollingDays: Int, trackingMode: String, stoodThisHour: Bool),
        trackingMode: TrackingMode
    ) async throws -> KcaliEntry {
        let resolvedGoal = max(shared.goal, TrackingDefaults.goal(for: trackingMode))
        let collection = try await healthService.fetchCollection(last: Self.lookbackDays, mode: trackingMode)
        let metrics = TrackingMath.makeMetrics(
            from: collection,
            goal: resolvedGoal,
            rollingDays: shared.rollingDays,
            maxDays: Self.lookbackDays
        )

        var standingProgress = (try? await fetchStandingProgressToday()) ?? (done: 0, goal: 0)
        if standingProgress.done == 0, standingProgress.goal == 0 {
            let sampledStandingHours = (try? await fetchStandingHoursFromSamplesToday()) ?? 0
            if sampledStandingHours > 0 {
                standingProgress = (done: sampledStandingHours, goal: 12)
            }
        }

        return KcaliEntry(
            date: Date(),
            aplGoal: metrics.appleMoveGoal,
            minCals: metrics.minimumHistoricalValue,
            avgCals: metrics.weightedAverage,
            goal: resolvedGoal,
            todaysCals: metrics.todaysValue,
            todaysMinCalsGoal: max(metrics.requiredToday, 1),
            isSteps: trackingMode == .steps,
            standingHours: standingProgress.done,
            standingGoal: standingProgress.goal,
            stoodThisHour: metrics.stoodThisHour
        )
    }

    private static func nextRefreshDate(after now: Date) -> Date {
        let calendar = Calendar.current
        let rounded = calendar.date(bySetting: .second, value: 0, of: now) ?? now
        let minute = calendar.component(.minute, from: rounded)
        let remainder = minute % refreshMinutes
        let deltaMinutes = remainder == 0 ? refreshMinutes : refreshMinutes - remainder

        return calendar.date(byAdding: .minute, value: deltaMinutes, to: rounded)
            ?? rounded.addingTimeInterval(Double(refreshMinutes) * 60)
    }

    private func cache(entry: KcaliEntry, trackingMode: String) {
        let defaults = SharedStore.defaults
        let prefix = "widget_cache_\(trackingMode)_"

        defaults.set(entry.date, forKey: "\(prefix)date")
        defaults.set(entry.aplGoal, forKey: "\(prefix)aplGoal")
        defaults.set(entry.minCals, forKey: "\(prefix)minCals")
        defaults.set(entry.avgCals, forKey: "\(prefix)avgCals")
        defaults.set(entry.goal, forKey: "\(prefix)goal")
        defaults.set(entry.todaysCals, forKey: "\(prefix)todaysCals")
        defaults.set(entry.todaysMinCalsGoal, forKey: "\(prefix)todaysMinCalsGoal")
        defaults.set(entry.standingHours, forKey: "\(prefix)standingHours")
        defaults.set(entry.standingGoal, forKey: "\(prefix)standingGoal")
        defaults.set(entry.stoodThisHour, forKey: "\(prefix)stoodThisHour")
    }

    private func cachedEntry(trackingMode: String) -> KcaliEntry? {
        let defaults = SharedStore.defaults
        let prefix = "widget_cache_\(trackingMode)_"

        guard let date = defaults.object(forKey: "\(prefix)date") as? Date else { return nil }

        return KcaliEntry(
            date: date,
            aplGoal: defaults.integer(forKey: "\(prefix)aplGoal"),
            minCals: defaults.integer(forKey: "\(prefix)minCals"),
            avgCals: defaults.integer(forKey: "\(prefix)avgCals"),
            goal: defaults.integer(forKey: "\(prefix)goal"),
            todaysCals: defaults.integer(forKey: "\(prefix)todaysCals"),
            todaysMinCalsGoal: defaults.integer(forKey: "\(prefix)todaysMinCalsGoal"),
            isSteps: trackingMode == TrackingMode.steps.rawValue,
            standingHours: defaults.integer(forKey: "\(prefix)standingHours"),
            standingGoal: defaults.integer(forKey: "\(prefix)standingGoal"),
            stoodThisHour: defaults.bool(forKey: "\(prefix)stoodThisHour")
        )
    }

    private func isLikelyPlaceholder(_ entry: KcaliEntry) -> Bool {
        let emptyProgress = entry.todaysCals == 0 && entry.avgCals == 0
        let missingTargets = entry.todaysMinCalsGoal <= 0 || entry.goal <= 0
        let knownFallbackShape = !entry.isSteps && entry.aplGoal == 500 && entry.goal == 500 && entry.todaysCals == 0
        return (emptyProgress && missingTargets) || knownFallbackShape
    }

    private func fetchStandingProgressToday() async throws -> (done: Int, goal: Int) {
        let calendar = Calendar.current
        let now = Date()

        var start = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: now))
        start.calendar = calendar
        var end = calendar.dateComponents([.year, .month, .day], from: now)
        end.calendar = calendar

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error {
                    return continuation.resume(throwing: error)
                }

                guard let summary = summaries?.first else {
                    return continuation.resume(returning: (0, 0))
                }

                let done = Int(summary.appleStandHours.doubleValue(for: HKUnit.count()).rounded())
                let goal = Int(summary.appleStandHoursGoal.doubleValue(for: HKUnit.count()).rounded())
                continuation.resume(returning: (done, goal))
            }

            store.execute(query)
        }
    }

    /// Fallback: count stand-hour category samples for today when the
    /// activity-summary query returns nothing (e.g. watchOS extension).
    private func fetchStandingHoursFromSamplesToday() async throws -> Int {
        let type = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    return continuation.resume(throwing: error)
                }

                let stoodHours = (samples as? [HKCategorySample])?.filter {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                }.count ?? 0

                continuation.resume(returning: stoodHours)
            }

            store.execute(query)
        }
    }
}

// MARK: - Preview Sample Data

#if DEBUG
extension KcaliEntry {
    // -------------------------------------------------------------------------
    // These sample entries are used exclusively in Xcode's canvas previews.
    // They are compiled out of release builds via the #if DEBUG guard above.
    // -------------------------------------------------------------------------

    /// A realistic *calories* entry that places today's burn at ~84 % of the
    /// daily target, with a healthy rolling average and 7/12 standing hours.
    static var previewCalories: KcaliEntry {
        KcaliEntry(
            date: .now,
            aplGoal: 520,          // Apple Move goal in active kcal
            minCals: 1_200,        // historical minimum (lowest active day in window)
            avgCals: 1_800,        // weighted rolling average
            goal: 1_600,           // user-defined daily calorie target
            todaysCals: 1_350,     // calories burned so far today
            todaysMinCalsGoal: 1_400, // today's derived minimum calorie target
            isSteps: false,
            standingHours: 7,
            standingGoal: 12,
            stoodThisHour: true    // the current hour counts as a stood hour
        )
    }

    /// Like `previewCalories` but with the goal met — useful to preview the
    /// "complete" state (filled rings, no remaining count label).
    static var previewCaloriesComplete: KcaliEntry {
        KcaliEntry(
            date: .now,
            aplGoal: 520,
            minCals: 1_200,
            avgCals: 1_800,
            goal: 1_600,
            todaysCals: 1_750,     // over target → completion state
            todaysMinCalsGoal: 1_400,
            isSteps: false,
            standingHours: 12,
            standingGoal: 12,
            stoodThisHour: true
        )
    }

    /// A realistic *steps* entry at roughly 65 % of a 10 000-step goal.
    static var previewSteps: KcaliEntry {
        KcaliEntry(
            date: .now,
            aplGoal: 0,            // aplGoal is not relevant in steps mode
            minCals: 4_000,        // historical minimum (lowest step count in window)
            avgCals: 7_800,        // weighted rolling step average
            goal: 10_000,          // user-defined daily step target
            todaysCals: 6_500,     // steps logged so far today
            todaysMinCalsGoal: 10_000,
            isSteps: true,
            standingHours: 5,
            standingGoal: 12,
            stoodThisHour: false
        )
    }
}
#endif
