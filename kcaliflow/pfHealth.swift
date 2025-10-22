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

struct Day: Identifiable {
    let id = UUID()
    let day: Int
    let cals: Int
}

private let goalKey = "goal_kcal"
private let daysKey = "average_days"


class PFHealth: ObservableObject {
    private var energyObserverQuery: HKObserverQuery?
    
    public let maxDays = 30; // this many days are the maximum to be set in the average
    public var aplGoal: Int = 500
    private var aplDays: [Day] = []
    
    public var minCals:Int = 0
    public var avgCals:Int = 0
    
    private let store = HKHealthStore()
    private let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let summaryType = HKObjectType.activitySummaryType()
    
    private var fetching:Int = 0
    
    @Published var days: [Day] = []
    @Published var goal: Int = 500 {
        didSet {
            UserDefaults.standard.set(goal, forKey: goalKey)
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
        
        loadData()
        
        if let stored = UserDefaults.standard.object(forKey: goalKey) as? Int {
            goal = stored
        }
        
        if type == "widget" {
            mirrorFromSharedStore()
        }
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
    }
    
    func requestAuthorization() async throws {
        // Prüfen, ob HealthKit verfügbar ist
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }
        
        // Welche Daten wollen wir lesen
        let toRead: Set = [energyType, summaryType]
        
        // Anfrage an HealthKit (nur Lesen)
        try await store.requestAuthorization(toShare: [], read: toRead)
        startObservingEnergy()
    }
    
    func fetchDailyEnergy(last n: Int) async throws -> [(date: Date, kcal: Int)] {
        let cal = Calendar.current
        let end = Date()
        let startOfToday = cal.startOfDay(for: end)
        let start = cal.date(byAdding: .day, value: -(n-1), to: startOfToday)!
        let interval = DateComponents(day: 1)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: energyType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startOfToday,
                intervalComponents: interval
            )
            q.initialResultsHandler = { _, results, error in
                if let error = error { return cont.resume(throwing: error) }
                var out: [(Date, Int)] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let val = stat.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    out.append((stat.startDate, Int(round(val))))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }
    
    @MainActor
    func loadFromHealthKit() async {
        fetching = 1
        do {
            NSLog("loadFromHealthKit")
            try await requestAuthorization()
            let rows = try await fetchDailyEnergy(last: maxDays)
            
            aplDays.removeAll()
            self.aplDays = rows.enumerated().map { idx, r in
                Day(day: maxDays - idx - 1, cals: r.kcal)
            }
            self.todaysCals = self.aplDays.last?.cals ?? 0
            self.minCals = self.aplDays.dropLast().map(\.cals).min() ?? 0
            
            let goal = try await fetchMoveGoal()
            self.aplGoal = Int(goal)
            
            self.days = Array(self.aplDays.suffix(self.rollingDays))
            
            recompute()
        } catch {
            NSLog("HealthKit error: \(error)")
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
        energyObserverQuery = HKObserverQuery(sampleType: energyType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }
            if(self?.fetching == 0){
                Task {
                    await self?.loadFromHealthKit()
                    completion() // wichtig! sonst keine weiteren Updates
                }
            }
        }

        if let q = energyObserverQuery {
            store.execute(q)
        }

        // Option: Hintergrundzustellung aktivieren
        store.enableBackgroundDelivery(for: energyType, frequency: .immediate) { success, error in
            if !success {
                print("Background delivery error: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }
    
    
    
    // widget things
    
    private func mirrorToWidget() {
        NSLog("mirrorToWidget")
        SharedStore.write(
            aplGoal: aplGoal,
            minCals: minCals,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal
        )
        print(SharedStore.read())
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    func mirrorFromSharedStore() {
        let r = SharedStore.read();
        self.aplGoal =      r.aplGoal
        self.minCals =      r.minCals
        self.avgCals =      r.avgCals
        self.goal =         r.goal
        self.todaysCals =   r.todaysCals
    }
}

