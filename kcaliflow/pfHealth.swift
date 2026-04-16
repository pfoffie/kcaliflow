//
//  pfHealth.swift
//  kcaliflow
//
//  Created by René Jossen on 21.10.2025.
//

import Foundation
import Combine
import HealthKit
import WidgetKit
#if os(iOS)
import WatchConnectivity
#endif

enum TrackingMode: String {
    case calories, steps
}

struct Day: Identifiable {
    let id = UUID()
    let day: Int
    let cals: Int
}

private let goalKey = "goal_kcal" // legacy compatibility key
private let caloriesGoalKey = "goal_kcal_mode_calories"
private let stepsGoalKey = "goal_kcal_mode_steps"
private let daysKey = "average_days"
private let modeKey = "tracking_mode"

private let defaultCaloriesGoal = 500
private let defaultStepsGoal   = 10_000


class PFHealth: ObservableObject {
    private var energyObserverQuery: HKObserverQuery?
    private var stepsObserverQuery: HKObserverQuery?

    public let maxDays = 30; // this many days are the maximum to be set in the average
    public var aplGoal: Int = 500
    private var aplDays: [Day] = []
    
    public var minCals:Int = 0
    public var avgCals:Int = 0
    
    private let store = HKHealthStore()
    private let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let stepsType  = HKObjectType.quantityType(forIdentifier: .stepCount)!
    private let summaryType = HKObjectType.activitySummaryType()
    private let standHourType = HKObjectType.categoryType(forIdentifier: .appleStandHour)!
    #if os(iOS)
    private let watchSync = PhoneWatchSyncBridge()
    #endif

    @Published var trackingMode: TrackingMode = .calories {
        didSet {
            guard oldValue != trackingMode else { return }
            UserDefaults.standard.set(trackingMode.rawValue, forKey: modeKey)
            goal = persistedGoal(for: trackingMode)
            aplGoal = 0
            loadData()
        }
    }

    var unitLabel: String { trackingMode == .steps ? "Steps" : "kcal" }
    
    private var fetching:Int = 0
    private var pendingReload = false
    @Published var isLoading: Bool = true
    
    @Published var days: [Day] = []
    @Published var goal: Int = 500 {
        didSet {
            UserDefaults.standard.set(goal, forKey: goalKey)
            UserDefaults.standard.set(goal, forKey: goalStorageKey(for: trackingMode))
            recompute()
        }
    }
    @Published var todaysMinCalsGoal: Int = 0;
    @Published var rollingDays: Int = 7 {
        didSet {
            UserDefaults.standard.set(rollingDays, forKey: daysKey)
            
            self.days = Array(self.aplDays.suffix(self.rollingDays))
            
            recompute()
        }
    }
    @Published var average: Double = 0 // to be calculated
    
    
    
    var todaysCals: Int = 0
    
    
    init(type: String = "app") {
        if let stored = UserDefaults.standard.object(forKey: daysKey) as? Int {
            rollingDays = stored
        }

        if let storedMode = UserDefaults.standard.string(forKey: modeKey),
           let mode = TrackingMode(rawValue: storedMode) {
            trackingMode = mode
        }

        goal = persistedGoal(for: trackingMode)

        loadData()
        #if os(iOS)
        watchSync.activate()
        #endif
        
        if type == "widget" {
            mirrorFromSharedStore()
        }
    }

    private func goalStorageKey(for mode: TrackingMode) -> String {
        mode == .steps ? stepsGoalKey : caloriesGoalKey
    }

    private func defaultGoal(for mode: TrackingMode) -> Int {
        mode == .steps ? defaultStepsGoal : defaultCaloriesGoal
    }

    private func persistedGoal(for mode: TrackingMode) -> Int {
        let modeKey = goalStorageKey(for: mode)
        if let stored = UserDefaults.standard.object(forKey: modeKey) as? Int {
            return stored
        }

        // Migrate old single goal value to calories mode.
        if mode == .calories,
           let legacy = UserDefaults.standard.object(forKey: goalKey) as? Int {
            return legacy
        }

        return defaultGoal(for: mode)
    }
    
    func loadData() {
        Task {
            await loadFromHealthKit()
       }
    }
    
    func dummyData() {
        days.append(Day(day: 0, cals: todaysCals))
        days.append(Day(day: 0, cals: 700))
        for day in 1...rollingDays-1 {
            days.append(Day(day: day, cals: Int.random(in: 400...475) ))
        }
    }
    
    func requiredCalsToday(goal: Double, halfLife: Double, days: [Day]) -> Int {
        let N = min(days.count, rollingDays)
        if(N < 2) { return 0 }
        
        func w(_ i: Int) -> Double { pow(0.5, Double(i)/halfLife) }

        var wSum = 0.0
        var pastWeighted = 0.0

        for i in 1..<N {                 // nur Vergangenheit
            let wi = w(i)
            wSum += wi
            pastWeighted += wi * Double(days[i].cals)
        }
        let w0 = w(0)                     // Gewicht heute
        let totalW = w0 + wSum
        let x = (goal * totalW - pastWeighted) / w0

        return max(0, Int(round(x)))      // clamp auf >= 0
    }
    
    func weightedAverageCals(halfLife: Double, days: [Day]) -> Int {
        let N = min(days.count, rollingDays)
        if(N < 2) { return 0 }
        
        func w(_ i: Int) -> Double { pow(0.5, Double(i)/halfLife) }
        
        var wSum = 0.0
        var pastWeighted = 0.0
        
        // complete average including today
        for i in 0..<N {
            let wi = w(i)
            wSum += wi
            pastWeighted += wi * Double(days[i].cals)
        }
        
        let totalW = wSum
        let x = pastWeighted / totalW
        
        return Int(round(x))
    }
    
    func autoHalfLife(daysCount N: Int, endRatio r: Double = 0.5) -> Double {
        guard N > 1, r > 0, r < 1 else { return 1 }
        return Double(N - 1) / (log2(1.0 / r))
    }
    
    private func recompute() {
        fetching = 0
        let h = autoHalfLife(daysCount: days.count, endRatio: 0.1)
        todaysMinCalsGoal = requiredCalsToday(goal: Double(goal), halfLife: h, days: days.reversed())
        
        //avgCals = days.map(\.cals).reduce(0, +) / self.rollingDays
        avgCals = weightedAverageCals(halfLife: h, days: days.reversed())
        
        mirrorToWidget()

        if pendingReload {
            pendingReload = false
            Task { await loadFromHealthKit() }
        }
    }
    
    func requestAuthorization() async throws {
        // Prüfen, ob HealthKit verfügbar ist
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }
        
        // Welche Daten wollen wir lesen
        let toRead: Set<HKObjectType> = [energyType, stepsType, summaryType, standHourType]
        
        // Anfrage an HealthKit (nur Lesen)
        try await store.requestAuthorization(toShare: [], read: toRead)
        startObservingEnergy()
        startObservingSteps()
    }
    
    func fetchActivitySummaries(last n: Int) async throws -> [(date: Date, kcal: Int)] {
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
    
    @MainActor
    func loadFromHealthKit() async {
        guard fetching == 0 else {
            pendingReload = true
            return
        }
        fetching = 1
        do {
            NSLog("loadFromHealthKit mode=\(trackingMode.rawValue)")
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())

            let dailyValues: [Date: Int]
            if trackingMode == .steps {
                dailyValues = try await fetchStepsByDay(last: maxDays)
                aplGoal = 0
            } else {
                let summaries = try await fetchActivitySummaries(last: maxDays)
                var map: [Date: Int] = [:]
                for (date, kcal) in summaries { map[cal.startOfDay(for: date)] = kcal }
                dailyValues = map
                let goal = try await fetchMoveGoal()
                self.aplGoal = Int(goal)
            }

            aplDays.removeAll()
            for i in 0..<maxDays {
                let date = cal.date(byAdding: .day, value: -(maxDays - 1 - i), to: today)!
                let value = dailyValues[cal.startOfDay(for: date)] ?? 0
                aplDays.append(Day(day: maxDays - i - 1, cals: value))
            }

            self.todaysCals = self.aplDays.last?.cals ?? 0
            self.minCals = self.aplDays.dropLast().map(\.cals).min() ?? 0

            self.days = Array(self.aplDays.suffix(self.rollingDays))
            
            recompute()
        } catch {
            NSLog("HealthKit error: \(error)")
            fetching = 0
        }
        isLoading = false
    }

    func fetchStepsByDay(last n: Int) async throws -> [Date: Int] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -(n - 1), to: today)!

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        let anchorDate = cal.startOfDay(for: startDate)
        let interval = DateComponents(day: 1)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: stepsType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
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
    
    func fetchMoveGoal() async throws -> Int {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)

        var start = cal.dateComponents([.year, .month, .day], from: startOfDay)
        start.calendar = cal

        var end = cal.dateComponents([.year, .month, .day], from: now)
        end.calendar = cal

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error = error { return cont.resume(throwing: error) }
                guard let s = summaries?.first else { return cont.resume(returning: 0) }
                let goal = s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
                cont.resume(returning: Int(goal.rounded()))
            }
            store.execute(q)
        }
    }
    
    func startObservingEnergy() {
        guard energyObserverQuery == nil else { return }
        energyObserverQuery = HKObserverQuery(sampleType: energyType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }
            if self?.fetching == 0 {
                Task {
                    await self?.loadFromHealthKit()
                    completion()
                }
            } else {
                completion()
            }
        }

        if let q = energyObserverQuery {
            store.execute(q)
        }
        store.enableBackgroundDelivery(for: energyType, frequency: .immediate) { _, _ in }
    }

    func startObservingSteps() {
        guard stepsObserverQuery == nil else { return }
        stepsObserverQuery = HKObserverQuery(sampleType: stepsType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }
            guard self?.trackingMode == .steps else {
                completion()
                return
            }
            if self?.fetching == 0 {
                Task {
                    await self?.loadFromHealthKit()
                    completion()
                }
            } else {
                completion()
            }
        }
        if let q = stepsObserverQuery {
            store.execute(q)
        }
        store.enableBackgroundDelivery(for: stepsType, frequency: .immediate) { _, _ in }
    }
    
    
    
    // widget things
    
    private func mirrorToWidget() {
        SharedStore.write(
            aplGoal: aplGoal,
            minCals: minCals,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            rollingDays: rollingDays,
            trackingMode: trackingMode.rawValue
        )
        #if os(iOS)
        watchSync.push(
            aplGoal: aplGoal,
            minCals: minCals,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            rollingDays: rollingDays,
            trackingMode: trackingMode.rawValue
        )
        #endif
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    func mirrorFromSharedStore() {
        let r = SharedStore.read()
        self.aplGoal =      r.aplGoal
        self.minCals =      r.minCals
        self.avgCals =      r.avgCals
        self.goal =         r.goal
        self.todaysCals =   r.todaysCals
        if let mode = TrackingMode(rawValue: r.trackingMode) {
            self.trackingMode = mode
        }
    }
}

#if os(iOS)
private final class PhoneWatchSyncBridge: NSObject, WCSessionDelegate {
    private let session = WCSession.isSupported() ? WCSession.default : nil

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func push(aplGoal: Int, minCals: Int, avgCals: Int, goal: Int, todaysCals: Int, todaysMinCalsGoal: Int, rollingDays: Int, trackingMode: String) {
        guard let session else { return }
        let payload: [String: Any] = [
            "aplGoal": aplGoal,
            "minCals": minCals,
            "avgCals": avgCals,
            "goal": goal,
            "todaysCals": todaysCals,
            "todaysMinCalsGoal": todaysMinCalsGoal,
            "rollingDays": rollingDays,
            "trackingMode": trackingMode
        ]
        try? session.updateApplicationContext(payload)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
