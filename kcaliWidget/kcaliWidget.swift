//
//  kcaliWidget.swift
//  kcaliWidget
//
//  Created by René Jossen on 22.10.2025.
//

import WidgetKit
import SwiftUI
import HealthKit


private typealias WidgetRing = SharedRing

private func generateRings(from entry: KcaliEntry, usesStandHourGoalHighlight: Bool = true) -> [WidgetRing] {
    generateRings(from: SharedRingInput(
        aplGoal: entry.aplGoal,
        avgCals: entry.avgCals,
        goal: entry.goal,
        todaysCals: entry.todaysCals,
        todaysMinCalsGoal: entry.todaysMinCalsGoal,
        isSteps: entry.isSteps,
        stoodThisHour: entry.stoodThisHour,
        usesStandHourGoalHighlight: usesStandHourGoalHighlight
    ))
}

private enum WidgetPalette {
    static let goalRing = Color.green
    static let averageLow = Color.orange
    static let averageHigh = Color.green
    static let todayFill = Color.pink
    static let standRing = Color.blue
    static let trackFill = Color.black.opacity(0.78)
    static let trackStroke = Color.white.opacity(0.18)
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    private let store = HKHealthStore()
    private static let refreshMinutes = 5
    private static let lookbackDays = 30

    func placeholder(in context: Context) -> KcaliEntry {
        KcaliEntry(from: SharedStore.read())
    }

    func getSnapshot(in context: Context, completion: @escaping (KcaliEntry) -> ()) {
        completion(KcaliEntry(from: SharedStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KcaliEntry>) -> ()) {
        Task {
            let entry = await fetchEntry()
            let next = Self.nextRefreshDate(after: Date())
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // MARK: - Shared values + live standing fetch

    private func fetchEntry() async -> KcaliEntry {
        let shared = SharedStore.read()
        let cached = cachedEntry(trackingMode: shared.trackingMode)
        let live = try? await fetchLiveMetrics(
            trackingMode: shared.trackingMode,
            sharedGoal: shared.goal,
            sharedAplGoal: shared.aplGoal
        )

        var standingProgress = (try? await fetchStandingProgressToday()) ?? (done: 0, goal: 0)
        let stoodThisHour = (try? await fetchCurrentHourStandingStatus()) ?? false
        if standingProgress.done == 0, standingProgress.goal == 0 {
            let doneFromSamples = (try? await fetchStandingHoursFromSamplesToday()) ?? 0
            if doneFromSamples > 0 {
                standingProgress = (done: doneFromSamples, goal: 12)
            }
        }

        let fallbackGoal = shared.trackingMode == "steps" ? max(shared.goal, 10_000) : max(shared.goal, 500)
        let liveGoal = live?.goal ?? fallbackGoal
        let liveAplGoal = live?.aplGoal ?? max(shared.aplGoal, liveGoal)
        let liveToday = live?.todaysValue ?? shared.todaysCals
        let liveAverage = live?.averageValue ?? shared.avgCals
        // Prefer the SharedStore value: it is the weighted minimum computed by the main app.
        // live?.minimumGoal is always equal to goal (not the smart weighted target), so it must not override.
        var liveMinimumGoal = shared.todaysMinCalsGoal > 0 ? shared.todaysMinCalsGoal : (live?.minimumGoal ?? max(liveGoal, 1))
        if liveMinimumGoal <= 0 {
            liveMinimumGoal = max(liveGoal, 1)
        }

        var entry = KcaliEntry(
            date: Date(),
            aplGoal: liveAplGoal,
            minCals: shared.minCals,
            avgCals: liveAverage,
            goal: liveGoal,
            todaysCals: liveToday,
            todaysMinCalsGoal: liveMinimumGoal,
            isSteps: shared.trackingMode == "steps",
            standingHours: standingProgress.done,
            standingGoal: standingProgress.goal,
            stoodThisHour: stoodThisHour
        )

        if isLikelyPlaceholder(entry), let cached {
            entry = cached
        }
        if !isLikelyPlaceholder(entry) {
            cache(entry: entry, trackingMode: shared.trackingMode)
        }
        return entry
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

    private struct LiveMetrics {
        let todaysValue: Int
        let averageValue: Int
        let goal: Int
        let aplGoal: Int
        let minimumGoal: Int
    }

    private func fetchLiveMetrics(trackingMode: String, sharedGoal: Int, sharedAplGoal: Int) async throws -> LiveMetrics {
        if trackingMode == "steps" {
            let stepMap = try await fetchStepsByDay(last: Self.lookbackDays)
            let series = normalizedSeries(from: stepMap)
            let todays = series.last ?? 0
            let average = average(for: series)
            let goal = max(sharedGoal, 10_000)
            return LiveMetrics(todaysValue: todays, averageValue: average, goal: goal, aplGoal: 0, minimumGoal: goal)
        }

        let calorieData = try await fetchCaloriesByDay(last: Self.lookbackDays)
        let series = normalizedSeries(from: calorieData.values)
        let todays = series.last ?? 0
        let average = average(for: series)
        let moveGoal = calorieData.moveGoal > 0 ? calorieData.moveGoal : max(max(sharedAplGoal, sharedGoal), 500)
        let minimum = max(max(sharedGoal, moveGoal), 1)
        return LiveMetrics(
            todaysValue: todays,
            averageValue: average,
            goal: minimum,
            aplGoal: moveGoal,
            minimumGoal: minimum
        )
    }

    private func fetchCaloriesByDay(last n: Int) async throws -> (values: [Date: Int], moveGoal: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -(n - 1), to: today)!

        var start = cal.dateComponents([.year, .month, .day], from: startDate)
        start.calendar = cal
        var end = cal.dateComponents([.year, .month, .day], from: today)
        end.calendar = cal

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error = error { return cont.resume(throwing: error) }
                var map: [Date: Int] = [:]
                var latestGoal = 0
                for summary in summaries ?? [] {
                    guard let date = cal.date(from: summary.dateComponents(for: cal)) else { continue }
                    map[cal.startOfDay(for: date)] = Int(summary.activeEnergyBurned.doubleValue(for: .kilocalorie()).rounded())
                    let goal = Int(summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()).rounded())
                    if goal > 0 { latestGoal = goal }
                }
                cont.resume(returning: (map, latestGoal))
            }
            store.execute(q)
        }
    }

    private func fetchStepsByDay(last n: Int) async throws -> [Date: Int] {
        let type = HKObjectType.quantityType(forIdentifier: .stepCount)!
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -(n - 1), to: today)!

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        let interval = DateComponents(day: 1)
        let anchorDate = cal.startOfDay(for: startDate)

        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                if let error = error { return cont.resume(throwing: error) }
                var values: [Date: Int] = [:]
                results?.enumerateStatistics(from: startDate, to: today) { stats, _ in
                    values[cal.startOfDay(for: stats.startDate)] = Int((stats.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0).rounded())
                }
                cont.resume(returning: values)
            }
            store.execute(query)
        }
    }

    private func normalizedSeries(from map: [Date: Int]) -> [Int] {
        map.keys.sorted().map { map[$0] ?? 0 }
    }

    private func average(for values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
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
            isSteps: trackingMode == "steps",
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
        let cal = Calendar.current
        let now = Date()
        var start = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))
        start.calendar = cal
        var end = cal.dateComponents([.year, .month, .day], from: now)
        end.calendar = cal
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error = error { return cont.resume(throwing: error) }
                guard let s = summaries?.first else { return cont.resume(returning: (0, 0)) }
                let done = Int(s.appleStandHours.doubleValue(for: HKUnit.count()).rounded())
                let goal = Int(s.appleStandHoursGoal.doubleValue(for: HKUnit.count()).rounded())
                cont.resume(returning: (done, goal))
            }
            store.execute(q)
        }
    }

    private func fetchCurrentHourStandingStatus() async throws -> Bool {
        let type = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        let cal = Calendar.current
        let now = Date()
        let start = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { return cont.resume(throwing: error) }
                let stood = (samples as? [HKCategorySample])?.contains {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                } ?? false
                cont.resume(returning: stood)
            }
            store.execute(q)
        }
    }

    private func fetchStandingHoursFromSamplesToday() async throws -> Int {
        let type = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { return cont.resume(throwing: error) }
                let stoodHours = (samples as? [HKCategorySample])?.filter {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                }.count ?? 0
                cont.resume(returning: stoodHours)
            }
            store.execute(q)
        }
    }
}

// MARK: - Entry

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

private extension KcaliEntry {
    init(from r: (aplGoal: Int, minCals: Int, avgCals: Int, goal: Int, todaysCals: Int, todaysMinCalsGoal: Int, rollingDays: Int, trackingMode: String, stoodThisHour: Bool)) {
        self.init(date: Date(), aplGoal: r.aplGoal, minCals: r.minCals,
                  avgCals: r.avgCals, goal: r.goal,
                  todaysCals: r.todaysCals, todaysMinCalsGoal: r.todaysMinCalsGoal,
                  isSteps: r.trackingMode == "steps",
                  standingHours: 0,
                  standingGoal: 0,
                  stoodThisHour: r.stoodThisHour)
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

// MARK: - View (refactored)

struct kcaliWidgetEntryView: View {
    var entry: Provider.Entry
    
    private var rings: [WidgetRing] {
        generateRings(from: entry)
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geo in
                let anchor = (geo.size.width + geo.size.height) / 2
                
                // Alle Ringe iterativ zeichnen
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position
                    
                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 2))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
                
                // Text-Overlay
                if entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps {
                    VStack {
                        Text("")
                        Text("\(entry.todaysCals) / \(entry.aplGoal)")
                        
                        Text("ø \(entry.avgCals) / \(entry.goal)")
                            .font(.caption2)
                        Text(" ")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack {
                        Text("\(entry.todaysCals) / \(entry.todaysMinCalsGoal)")
                        
                        Text("ø \(entry.avgCals) / \(entry.goal)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}

// MARK: - Watch Views (können jetzt dieselbe Ring-Logik nutzen)

private struct WatchCircularComplicationView: View {
    let entry: KcaliEntry
    
    private var rings: [WidgetRing] {
        generateRings(from: entry, usesStandHourGoalHighlight: false)
    }

    var body: some View {
        GeometryReader { geo in
            let anchor = (geo.size.width + geo.size.height) / 2.6
            
            // Alle Ringe iterativ zeichnen
            ForEach(rings) { ring in
                let diameter = anchor * ring.position
                
                if ring.type == .line {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(ring.color)
                        .frame(width: diameter, height: diameter)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    Circle()
                        .fill(ring.color)
                        .frame(width: diameter, height: diameter)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            
            
            if entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps {
                let rest:Int = entry.aplGoal - entry.todaysCals
                if(rest > 0){
                    VStack {
                        Text("").font(.caption2)
                        Text("\(rest)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            } else {
                let rest:Int = entry.todaysMinCalsGoal - entry.todaysCals
                if(rest > 0){
                    VStack {
                        Text("\(rest)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            
            if entry.stoodThisHour {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3))
                    .foregroundStyle(WidgetPalette.standRing.opacity(0.5))
            }else{
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3))
                    .foregroundStyle(WidgetPalette.trackStroke)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchRectangularComplicationView: View {
    let entry: KcaliEntry
    
    private var rings: [WidgetRing] {
        generateRings(from: entry, usesStandHourGoalHighlight: false)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                GeometryReader { geo in
                    let innerWidth = max(geo.size.width*0.7, 0)
                    
                    
                    ForEach(rings) { ring in
                        let diameter = innerWidth * ring.position
                        
                        if ring.type == .line {
                            Rectangle()
                                .fill(ring.color)
                                .frame(width: 2)
                                .position(x: diameter, y: geo.size.height/2)
                        } else {
                            Rectangle()
                                .fill(ring.color)
                                .frame(width: diameter)
                        }
                    }
                }
                .clipShape(Capsule())
                
                Capsule()
                    .stroke(WidgetPalette.trackFill.opacity(0.5), lineWidth: 10)
                Capsule()
                    .stroke(WidgetPalette.trackFill, lineWidth: 6)
                
                if entry.stoodThisHour {
                    Capsule()
                        .stroke(WidgetPalette.standRing, lineWidth: 2)
                } else {
                    Capsule()
                        .stroke(WidgetPalette.trackStroke, lineWidth: 2)
                }

            }
            .frame(height: 30)
           
            if entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps {
                HStack {
                    Text("")
                    Text("\(entry.todaysCals) / \(entry.aplGoal)")
                    Text("ø \(entry.avgCals) / \(entry.goal)")
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack {
                    Text("\(entry.todaysCals) / \(entry.todaysMinCalsGoal)")
                    Text("ø \(entry.avgCals) / \(entry.goal)")
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

private struct WatchSmallPillComplicationView: View {
    let entry: KcaliEntry

    private var rings: [WidgetRing] {
        generateRings(from: entry, usesStandHourGoalHighlight: false)
    }

    private var usesAppleTarget: Bool {
        entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps
    }

    private var remaining: Int {
        (usesAppleTarget ? entry.aplGoal : entry.todaysMinCalsGoal) - entry.todaysCals
    }

    var body: some View {
        GeometryReader { geo in
            let anchor = (geo.size.width + geo.size.height) / 2.6

            ZStack {
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position

                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                    }
                }

                if remaining > 0 {
                    if usesAppleTarget {
                        VStack(spacing: 0) {
                            Text("")
                                .font(.caption2)
                            Text("\(remaining)")
                                .font(.caption2)
                        }
                    } else {
                        Text("\(remaining)")
                            .font(.caption2)
                    }
                }

                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3))
                    .foregroundStyle(entry.stoodThisHour ? WidgetPalette.standRing.opacity(0.5) : WidgetPalette.trackStroke)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchInlineComplicationView: View {
    let entry: KcaliEntry

    var body: some View {
        let aaplIcon = entry.aplGoal > entry.todaysMinCalsGoal ? "" : ""
        if(entry.todaysCals < entry.primaryTarget) {
            let icon = entry.stoodThisHour ? "◉" : "◎"
            
            Text("\(icon) \(entry.primaryTarget - entry.todaysCals) \(aaplIcon)")
        }else{
            let icon = entry.stoodThisHour ? "●" : "◉"
            Text(icon)
        }
            
    }
}

struct kcaliWidget: Widget {
    let kind: String = "kcaliWidget"

    var body: some WidgetConfiguration {
        #if os(watchOS)
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            WidgetRootView(entry: entry)
        }
        .configurationDisplayName("kcaliflow")
        .description(
            String(localized: "info_widget_description")
        )
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
        #else
        if #available(iOSApplicationExtension 16.0, *) {
            StaticConfiguration(kind: kind, provider: Provider()) { entry in
                WidgetRootView(entry: entry)
            }
            .configurationDisplayName("kcaliflow")
            .description(
                String(localized: "info_widget_description")
            )
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        } else {
            StaticConfiguration(kind: kind, provider: Provider()) { entry in
                WidgetRootView(entry: entry)
            }
            .configurationDisplayName("kcaliflow")
            .description(
                String(localized: "info_widget_description")
            )
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        }
        #endif
    }
}

private struct WidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KcaliEntry

    var body: some View {
        if #available(iOSApplicationExtension 16.0, *) {
            if #available(iOSApplicationExtension 17.0, watchOS 10.0, *) {
                switch family {
                case .accessoryCircular:
                    WatchCircularComplicationView(entry: entry)
                        .containerBackground(for: .widget) { Color.clear }
                #if os(watchOS)
                case .accessoryCorner:
                    WatchSmallPillComplicationView(entry: entry)
                        .containerBackground(for: .widget) { Color.clear }
                #endif
                case .accessoryInline:
                    WatchInlineComplicationView(entry: entry)
                        .containerBackground(for: .widget) { Color.clear }
                case .accessoryRectangular:
                    WatchRectangularComplicationView(entry: entry)
                        .containerBackground(for: .widget) { Color.clear }
                default:
                    kcaliWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                }
            } else {
                switch family {
                case .accessoryCircular:
                    WatchCircularComplicationView(entry: entry)
                #if os(watchOS)
                case .accessoryCorner:
                    WatchSmallPillComplicationView(entry: entry)
                #endif
                case .accessoryInline:
                    WatchInlineComplicationView(entry: entry)
                case .accessoryRectangular:
                    WatchRectangularComplicationView(entry: entry)
                default:
                    kcaliWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        } else {
            kcaliWidgetEntryView(entry: entry)
                .padding()
                .background()
        }
    }
}

#if os(iOS)
#Preview(as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry(date: .now,
               aplGoal: 222,
               minCals: 666,
               avgCals: 1088,
               goal: 888,
               todaysCals: 265,
               todaysMinCalsGoal: 400,
               isSteps: false,
               standingHours: 8,
               standingGoal: 12,
               stoodThisHour: true)
}
#endif

// #if os(watchOS)
// #Preview(as: .accessoryCircular) {
//     kcaliWidget()
// } timeline: {
//     KcaliEntry(date: .now,
//        aplGoal: 90,
//        minCals: 666,
//        avgCals: 888,
//        goal: 888,
//        todaysCals: 65,
//        todaysMinCalsGoal: 100,
//        isSteps: false,
//        standingHours: 8,
//        standingGoal: 12,
//        stoodThisHour: true)
// }

// #Preview(as: .accessoryRectangular) {
//     kcaliWidget()
// } timeline: {
//     KcaliEntry(date: .now,
//                aplGoal: 90,
//                minCals: 666,
//                avgCals: 888,
//                goal: 888,
//                todaysCals: 1200,
//                todaysMinCalsGoal: 666,
//                isSteps: false,
//                standingHours: 8,
//                standingGoal: 12,
//                stoodThisHour: true)
// }

// #Preview(as: .accessoryCorner) {
//     kcaliWidget()
// } timeline: {
//     KcaliEntry(date: .now,
//                aplGoal: 90,
//                minCals: 666,
//                avgCals: 888,
//                goal: 888,
//                todaysCals: 200,
//                todaysMinCalsGoal: 666,
//                isSteps: false,
//                standingHours: 8,
//                standingGoal: 12,
//                stoodThisHour: true)
// }

// #Preview(as: .accessoryInline) {
//     kcaliWidget()
// } timeline: {
//     KcaliEntry(date: .now,
//        aplGoal: 200,
//        minCals: 666,
//        avgCals: 888,
//        goal: 888,
//        todaysCals: 205,
//        todaysMinCalsGoal: 100,
//        isSteps: false,
//        standingHours: 8,
//        standingGoal: 12,
//        stoodThisHour: true)
// }
// #endif
