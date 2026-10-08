import Foundation
import HealthKit

/// The two tracking modes that the apps, widgets, and watch surfaces can display.
/// Keeping this enum in shared code ensures every target speaks the same language.
enum TrackingMode: String {
    case calories
    case steps
}

/// Shared goal defaults used whenever the user has not stored a custom target yet.
enum TrackingDefaults {
    static func goal(for mode: TrackingMode) -> Int {
        mode == .steps ? 10_000 : 500
    }
}

/// A single chart-ready day/value pair.
/// `day == 0` always represents today, `1` yesterday, and so on.
struct Day: Identifiable {
    let id = UUID()
    let day: Int
    let cals: Int
    let hasData: Bool
}

/// Raw HealthKit values before kcaliflow applies its weighted-average logic.
struct AppleHealthCollection {
    let mode: TrackingMode
    let dailyValues: [Date: Int]
    let appleMoveGoal: Int
    let stoodThisHour: Bool

    /// Builds a complete, gap-free day list so all callers work with the same shape.
    func makeDays(last maxDays: Int, calendar: Calendar = .current, referenceDate: Date = Date()) -> [Day] {
        let today = calendar.startOfDay(for: referenceDate)

        return (0..<maxDays).map { index in
            let date = calendar.date(byAdding: .day, value: -(maxDays - 1 - index), to: today) ?? today
            let normalizedDate = calendar.startOfDay(for: date)
            let offsetFromToday = maxDays - index - 1

            let cals = dailyValues[normalizedDate]
            return Day(
                day: offsetFromToday,
                cals: cals ?? 0,
                hasData: cals != nil
            )
        }
    }
}

/// Derived values that drive the app and watch UI.
struct TrackingMetrics {
    let allDays: [Day]
    let visibleDays: [Day]
    let todaysValue: Int
    let minimumHistoricalValue: Int
    let weightedAverage: Int
    let requiredToday: Int
    let appleMoveGoal: Int
    let stoodThisHour: Bool
}

/// Shared business math so the iPhone app and watch app calculate the same numbers
/// from the same HealthKit series.
enum TrackingMath {
    static func makeMetrics(
        from collection: AppleHealthCollection,
        goal: Int,
        rollingDays: Int,
        maxDays: Int
    ) -> TrackingMetrics {
        makeMetrics(
            from: collection.makeDays(last: maxDays),
            goal: goal,
            rollingDays: rollingDays,
            appleMoveGoal: collection.appleMoveGoal,
            stoodThisHour: collection.stoodThisHour
        )
    }

    static func makeMetrics(
        from allDays: [Day],
        goal: Int,
        rollingDays: Int,
        appleMoveGoal: Int,
        stoodThisHour: Bool
    ) -> TrackingMetrics {
        let dataDays = allDays.filter(\.hasData)
        let computationDays = dataDays.isEmpty ? allDays : dataDays
        let safeRollingDays = max(1, min(rollingDays, computationDays.count))
        let visibleDays = Array(computationDays.suffix(safeRollingDays))
        let calculationDays = Array(visibleDays.reversed())
        let halfLife = autoHalfLife(daysCount: visibleDays.count, endRatio: 0.1)

        return TrackingMetrics(
            allDays: allDays,
            visibleDays: visibleDays,
            todaysValue: allDays.last?.cals ?? 0,
            minimumHistoricalValue: computationDays.dropLast().map(\.cals).min() ?? 0,
            weightedAverage: weightedAverage(halfLife: halfLife, days: calculationDays),
            requiredToday: requiredToday(goal: Double(goal), halfLife: halfLife, days: calculationDays),
            appleMoveGoal: appleMoveGoal,
            stoodThisHour: stoodThisHour
        )
    }

    /// Calculates how much activity is still needed today to keep the rolling target.
    static func requiredToday(goal: Double, halfLife: Double, days: [Day]) -> Int {
        let dayCount = days.count
        guard dayCount >= 2 else { return 0 }

        func weight(_ index: Int) -> Double {
            pow(0.5, Double(index) / halfLife)
        }

        var pastWeightedValue = 0.0
        var pastWeightSum = 0.0

        for index in 1..<dayCount {
            let currentWeight = weight(index)
            pastWeightSum += currentWeight
            pastWeightedValue += currentWeight * Double(days[index].cals)
        }

        let todayWeight = weight(0)
        let totalWeight = todayWeight + pastWeightSum
        let requiredValue = (goal * totalWeight - pastWeightedValue) / todayWeight

        return max(0, Int(round(requiredValue)))
    }

    /// Uses exponential decay so recent days matter more than older ones.
    static func weightedAverage(halfLife: Double, days: [Day]) -> Int {
        let dayCount = days.count
        guard dayCount >= 2 else { return 0 }

        func weight(_ index: Int) -> Double {
            pow(0.5, Double(index) / halfLife)
        }

        var weightedTotal = 0.0
        var weightSum = 0.0

        for index in 0..<dayCount {
            let currentWeight = weight(index)
            weightSum += currentWeight
            weightedTotal += currentWeight * Double(days[index].cals)
        }

        guard weightSum > 0 else { return 0 }
        return Int(round(weightedTotal / weightSum))
    }

    /// Adjusts the decay curve automatically to the visible number of days.
    static func autoHalfLife(daysCount: Int, endRatio: Double = 0.5) -> Double {
        guard daysCount > 1, endRatio > 0, endRatio < 1 else { return 1 }
        return Double(daysCount - 1) / log2(1.0 / endRatio)
    }
}

/// Centralized HealthKit reader shared by the iPhone app and watch app.
/// All platform-specific view models now call through this single implementation.
final class AppleHealthDataService {
    private let store = HKHealthStore()
    private let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount)!
    private let summaryType = HKObjectType.activitySummaryType()
    private let standHourType = HKObjectType.categoryType(forIdentifier: .appleStandHour)!

    /// Requests the full read set that all kcaliflow surfaces depend on.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }

        let readTypes: Set<HKObjectType> = [energyType, stepsType, summaryType, standHourType]
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Fetches the raw series for the selected mode plus the standing status that the UI highlights.
    func fetchCollection(last days: Int, mode: TrackingMode) async throws -> AppleHealthCollection {
        async let stoodThisHour = fetchCurrentHourStandingStatus()

        switch mode {
        case .steps:
            let dailyValues = try await fetchStepsByDay(last: days)
            return AppleHealthCollection(
                mode: mode,
                dailyValues: dailyValues,
                appleMoveGoal: 0,
                stoodThisHour: try await stoodThisHour
            )

        case .calories:
            async let moveGoal = fetchMoveGoal()
            let summaries = try await fetchActivitySummaries(last: days)
            let normalizedValues = Dictionary(
                uniqueKeysWithValues: summaries.map { (Calendar.current.startOfDay(for: $0.date), $0.kcal) }
            )

            return AppleHealthCollection(
                mode: mode,
                dailyValues: normalizedValues,
                appleMoveGoal: try await moveGoal,
                stoodThisHour: try await stoodThisHour
            )
        }
    }

    func fetchTodayValue(mode: TrackingMode) async throws -> Int {
        let today = Calendar.current.startOfDay(for: Date())

        switch mode {
        case .steps:
            let dailyValues = try await fetchStepsByDay(last: 1)
            return dailyValues[today] ?? 0

        case .calories:
            let summaries = try await fetchActivitySummaries(last: 1)
            let normalizedValues = Dictionary(
                uniqueKeysWithValues: summaries.map { (Calendar.current.startOfDay(for: $0.date), $0.kcal) }
            )
            return normalizedValues[today] ?? 0
        }
    }

    private func fetchActivitySummaries(last days: Int) async throws -> [(date: Date, kcal: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        var start = calendar.dateComponents([.year, .month, .day], from: startDate)
        start.calendar = calendar
        var end = calendar.dateComponents([.year, .month, .day], from: today)
        end.calendar = calendar

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error {
                    return continuation.resume(throwing: error)
                }

                let items: [(Date, Int)] = (summaries ?? [])
                    .compactMap { summary in
                        guard let date = calendar.date(from: summary.dateComponents(for: calendar)) else {
                            return nil
                        }

                        let kcal = summary.activeEnergyBurned.doubleValue(for: .kilocalorie())
                        return (date, Int(round(kcal)))
                    }
                    .sorted { $0.0 < $1.0 }

                continuation.resume(returning: items)
            }

            store.execute(query)
        }
    }

    private func fetchStepsByDay(last days: Int) async throws -> [Date: Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        let anchorDate = calendar.startOfDay(for: startDate)
        let interval = DateComponents(day: 1)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepsType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    return continuation.resume(throwing: error)
                }

                var values: [Date: Int] = [:]
                results?.enumerateStatistics(from: startDate, to: today) { stats, _ in
                    let steps = stats.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0
                    values[calendar.startOfDay(for: stats.startDate)] = Int(round(steps))
                }

                continuation.resume(returning: values)
            }

            store.execute(query)
        }
    }

    private func fetchMoveGoal() async throws -> Int {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)

        var start = calendar.dateComponents([.year, .month, .day], from: startOfDay)
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
                    return continuation.resume(returning: 0)
                }

                let goal = summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
                continuation.resume(returning: Int(goal.rounded()))
            }

            store.execute(query)
        }
    }

    private func fetchCurrentHourStandingStatus() async throws -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: standHourType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    return continuation.resume(throwing: error)
                }

                let stoodThisHour = (samples as? [HKCategorySample])?.contains {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                } ?? false

                continuation.resume(returning: stoodThisHour)
            }

            store.execute(query)
        }
    }
}
