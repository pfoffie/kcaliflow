//
//  kcaliWidget.swift
//  kcaliWidget
//
//  Created by René Jossen on 22.10.2025.
//

import WidgetKit
import SwiftUI
import HealthKit

// MARK: - Computation helpers (mirrors PFHealth logic)

private func autoHalfLife(daysCount N: Int, endRatio r: Double = 0.5) -> Double {
    guard N > 1, r > 0, r < 1 else { return 1 }
    return Double(N - 1) / log2(1.0 / r)
}

private func weightedAverageCals(halfLife: Double, days: [Int]) -> Int {
    let N = days.count
    guard N >= 2 else { return 0 }
    func w(_ i: Int) -> Double { pow(0.5, Double(i) / halfLife) }
    var wSum = 0.0, weighted = 0.0
    for i in 0..<N {
        let wi = w(i)
        wSum += wi
        weighted += wi * Double(days[i])
    }
    return Int(round(weighted / wSum))
}

private func requiredCalsToday(goal: Double, halfLife: Double, days: [Int]) -> Int {
    let N = days.count
    guard N >= 2 else { return 0 }
    func w(_ i: Int) -> Double { pow(0.5, Double(i) / halfLife) }
    var wSum = 0.0, pastWeighted = 0.0
    for i in 1..<N {
        let wi = w(i)
        wSum += wi
        pastWeighted += wi * Double(days[i])
    }
    let w0 = w(0)
    let x = (goal * (w0 + wSum) - pastWeighted) / w0
    return max(0, Int(round(x)))
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    private let store = HKHealthStore()

    func placeholder(in context: Context) -> KcaliEntry {
        KcaliEntry(from: SharedStore.read())
    }

    func getSnapshot(in context: Context, completion: @escaping (KcaliEntry) -> ()) {
        completion(KcaliEntry(from: SharedStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KcaliEntry>) -> ()) {
        Task {
            let entry = await fetchLiveEntry()
            let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // MARK: - Live HealthKit fetch

    private func fetchLiveEntry() async -> KcaliEntry {
        let shared = SharedStore.read()
        let isSteps = shared.trackingMode == "steps"
        do {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let maxDays = 30

            let dailyValues: [Date: Int]
            let aplGoal: Int
            if isSteps {
                dailyValues = try await fetchStepsByDay(last: maxDays)
                aplGoal = 0
            } else {
                let summaries = try await fetchActivitySummaries(last: maxDays)
                var map: [Date: Int] = [:]
                for (date, kcal) in summaries { map[cal.startOfDay(for: date)] = kcal }
                dailyValues = map
                aplGoal = try await fetchMoveGoal()
            }

            // Build chronological array (index 0 = oldest, last = today)
            var aplDays: [Int] = []
            for i in 0..<maxDays {
                let date = cal.date(byAdding: .day, value: -(maxDays - 1 - i), to: today)!
                aplDays.append(dailyValues[cal.startOfDay(for: date)] ?? 0)
            }

            let todaysCals = aplDays.last ?? 0
            let minCals = aplDays.dropLast().filter { $0 > 0 }.min() ?? 0
            let goal = shared.goal

            // Slice to rollingDays and reverse so index 0 = today (matches PFHealth)
            let days = Array(Array(aplDays.suffix(shared.rollingDays)).reversed())

            let h = autoHalfLife(daysCount: days.count, endRatio: 0.1)
            let avgCals = weightedAverageCals(halfLife: h, days: days)
            let todaysMinCalsGoal = requiredCalsToday(goal: Double(goal), halfLife: h, days: days)

            return KcaliEntry(date: Date(), aplGoal: aplGoal, minCals: minCals,
                              avgCals: avgCals, goal: goal,
                              todaysCals: todaysCals, todaysMinCalsGoal: todaysMinCalsGoal,
                              isSteps: isSteps)
        } catch {
            // Fall back to last values written by the main app
            return KcaliEntry(from: shared)
        }
    }

    private func fetchStepsByDay(last n: Int) async throws -> [Date: Int] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -(n - 1), to: today)!
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        let interval = DateComponents(day: 1)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: stepsType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: cal.startOfDay(for: startDate),
                intervalComponents: interval
            )
            q.initialResultsHandler = { _, results, error in
                if let error = error { return cont.resume(throwing: error) }
                var map: [Date: Int] = [:]
                results?.enumerateStatistics(from: startDate, to: today) { stats, _ in
                    let steps = stats.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0
                    map[cal.startOfDay(for: stats.startDate)] = Int(round(steps))
                }
                cont.resume(returning: map)
            }
            store.execute(q)
        }
    }

    private func fetchActivitySummaries(last n: Int) async throws -> [(date: Date, kcal: Int)] {
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
                let result: [(Date, Int)] = (summaries ?? []).compactMap { s in
                    guard let date = cal.date(from: s.dateComponents(for: cal)) else { return nil }
                    let kcal = s.activeEnergyBurned.doubleValue(for: .kilocalorie())
                    return (date, Int(round(kcal)))
                }.sorted { $0.0 < $1.0 }
                cont.resume(returning: result)
            }
            store.execute(q)
        }
    }

    private func fetchMoveGoal() async throws -> Int {
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
                guard let s = summaries?.first else { return cont.resume(returning: 0) }
                cont.resume(returning: Int(s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()).rounded()))
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
}

private extension KcaliEntry {
    init(from r: (aplGoal: Int, minCals: Int, avgCals: Int, goal: Int, todaysCals: Int, todaysMinCalsGoal: Int, rollingDays: Int, trackingMode: String)) {
        self.init(date: Date(), aplGoal: r.aplGoal, minCals: r.minCals,
                  avgCals: r.avgCals, goal: r.goal,
                  todaysCals: r.todaysCals, todaysMinCalsGoal: r.todaysMinCalsGoal,
                  isSteps: r.trackingMode == "steps")
    }
}

// MARK: - View

struct kcaliWidgetEntryView : View {
    var entry: Provider.Entry
    var body: some View {
        
        ZStack {
            GeometryReader { geo in
                let anchor = ((geo.size.width + geo.size.height) / 2)
                
                let p_avgCals = CGFloat(entry.avgCals) / CGFloat(entry.goal)
                
                let c_goal = anchor
                let c_avgCals = anchor * p_avgCals
                
                
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.green)
                    .frame(width: c_goal, height: c_goal)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                if(p_avgCals < 1.0){
                    Circle()
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: c_avgCals, height: c_avgCals)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }else{
                    Circle()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: c_avgCals, height: c_avgCals)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    if(entry.aplGoal > entry.todaysMinCalsGoal){
                        
                        let p_todaysCals = CGFloat(entry.todaysCals) / CGFloat(entry.aplGoal)
                        if(p_todaysCals < 1.0){
                            
                            let c_todayCals = anchor * p_todaysCals
                            
                            
                            Circle()
                                .fill(Color.white)
                                .frame(width: c_todayCals, height: c_todayCals)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            Circle()
                                .fill(Color.pink.opacity(0.5))
                                .frame(width: c_todayCals, height: c_todayCals)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            
                            
                            Circle()
                                .stroke(style: StrokeStyle(lineWidth: 2))
                                .foregroundStyle(Color.red)
                                .frame(width: c_goal, height: c_goal)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    }
                }
                
                if(entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps){
                    VStack {
                        Text("")
                        Text("\(entry.todaysCals) / \(entry.aplGoal)")
                        
                        Text("ø \(entry.avgCals) / \(entry.goal)")
                            .font(.caption2)
                        Text(" ")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    
                }else{
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

struct kcaliWidget: Widget {
    let kind: String = "kcaliWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                kcaliWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                kcaliWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("kcaliflow")
        .description(
            String(localized: "info_widget_description")
        )
    }
}

#Preview(as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry(date: .now,
               aplGoal: 555,
               minCals: 666,
               avgCals: 999,
               goal: 888,
               todaysCals: 666,
               todaysMinCalsGoal: 555,
               isSteps: false)
}
