//
//  ContentView.swift
//  kcaliWatch Watch App
//
//  Created by René Jossen on 11.04.2026.
//

import SwiftUI
import Combine
import WatchConnectivity
import WidgetKit
import HealthKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var healthBridge = WatchHealthBridge()
    @State private var model = WatchWidgetVisualModel.load()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        WatchWidgetVisualView(model: model)
            .padding(6)
            .onAppear {
                WatchSyncListener.shared.activate()
                model = .load(healthSnapshot: healthBridge.snapshot)
                WidgetCenter.shared.reloadAllTimelines()
                Task {
                    await healthBridge.refresh(force: true)
                    model = .load(healthSnapshot: healthBridge.snapshot)
                }
            }
            .onReceive(timer) { _ in
                Task {
                    await healthBridge.refresh()
                    model = .load(healthSnapshot: healthBridge.snapshot)
                }
            }
            .onChange(of: healthBridge.snapshot?.timestamp) { _, _ in
                model = .load(healthSnapshot: healthBridge.snapshot)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await healthBridge.refresh(force: true)
                    model = .load(healthSnapshot: healthBridge.snapshot)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
    }
}

private enum WatchSharedKeys {
    static let aplGoal = "aplGoal"
    static let avgCals = "avgCals"
    static let goal = "goal"
    static let todaysCals = "todaysCals"
    static let todaysMinCalsGoal = "todaysMinCalsGoal"
    static let trackingMode = "trackingMode"
    static let stoodThisHour = "stoodThisHour"
}

private struct WatchWidgetVisualModel {
    let aplGoal: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
    let isSteps: Bool
    let stoodThisHour: Bool
    
    var ringInput: SharedRingInput {
        SharedRingInput(
            aplGoal: aplGoal,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            isSteps: isSteps,
            stoodThisHour: stoodThisHour
        )
    }

    static func load(healthSnapshot: WatchHealthSnapshot? = nil) -> WatchWidgetVisualModel {
        let defaults = UserDefaults(suiteName: "group.ch.enjor.health")
        let mode = defaults?.string(forKey: WatchSharedKeys.trackingMode) ?? "calories"
        let isSteps = mode == "steps"
        var aplGoal = defaults?.integer(forKey: WatchSharedKeys.aplGoal) ?? 0
        var avgCals = defaults?.integer(forKey: WatchSharedKeys.avgCals) ?? 0
        var goal = defaults?.integer(forKey: WatchSharedKeys.goal) ?? 0
        var todaysCals = defaults?.integer(forKey: WatchSharedKeys.todaysCals) ?? 0
        var todaysMinCalsGoal = defaults?.integer(forKey: WatchSharedKeys.todaysMinCalsGoal) ?? 0
        var stoodThisHour = defaults?.bool(forKey: WatchSharedKeys.stoodThisHour) ?? false

        if let snapshot = healthSnapshot, !isSteps {
            aplGoal = max(aplGoal, snapshot.moveGoal)
            goal = max(goal, snapshot.moveGoal)
            todaysCals = snapshot.todaysCalories
            avgCals = snapshot.averageCalories
            if todaysMinCalsGoal <= 0 {
                todaysMinCalsGoal = max(goal, 1)
            }
            stoodThisHour = snapshot.stoodThisHour
        }

        return WatchWidgetVisualModel(
            aplGoal: aplGoal,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            isSteps: isSteps,
            stoodThisHour: stoodThisHour
        )
    }
}

struct WatchHealthSnapshot {
    let timestamp: Date
    let todaysCalories: Int
    let averageCalories: Int
    let moveGoal: Int
    let stoodThisHour: Bool
}

@MainActor
private final class WatchHealthBridge: ObservableObject {
    @Published private(set) var snapshot: WatchHealthSnapshot?

    private let store = HKHealthStore()
    private let standHourType = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
    private var hasRequestedAuthorization = false
    private var lastRefresh: Date = .distantPast

    func refresh(force: Bool = false) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        if !force, Date().timeIntervalSince(lastRefresh) < 5 * 60 { return }

        do {
            if !hasRequestedAuthorization {
                try await requestAuthorization()
                hasRequestedAuthorization = true
            }
            let summaries = try await fetchActivitySummaries(last: 30)
            let stoodThisHour = (try? await fetchCurrentHourStandingStatus()) ?? false
            let values = summaries.map(\.kcal)
            let avg = values.isEmpty ? 0 : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
            let today = summaries.last?.kcal ?? 0
            let goal = summaries.last?.goal ?? 0
            snapshot = WatchHealthSnapshot(
                timestamp: Date(),
                todaysCalories: today,
                averageCalories: avg,
                moveGoal: goal,
                stoodThisHour: stoodThisHour
            )
            lastRefresh = Date()
        } catch {
            // Keep last snapshot and shared-store values.
        }
    }

    private func requestAuthorization() async throws {
        let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        let readTypes: Set<HKObjectType> = [activeEnergyType, HKObjectType.activitySummaryType(), standHourType]
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    private func fetchActivitySummaries(last n: Int) async throws -> [(date: Date, kcal: Int, goal: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -(n - 1), to: today)!

        var start = cal.dateComponents([.year, .month, .day], from: startDate)
        start.calendar = cal
        var end = cal.dateComponents([.year, .month, .day], from: today)
        end.calendar = cal

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error = error { return cont.resume(throwing: error) }
                let items: [(Date, Int, Int)] = (summaries ?? []).compactMap { summary in
                    guard let date = cal.date(from: summary.dateComponents(for: cal)) else { return nil }
                    let kcal = Int(summary.activeEnergyBurned.doubleValue(for: .kilocalorie()).rounded())
                    let goal = Int(summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()).rounded())
                    return (date, kcal, goal)
                }
                .sorted { $0.0 < $1.0 }
                cont.resume(returning: items)
            }
            store.execute(query)
        }
    }

    private func fetchCurrentHourStandingStatus() async throws -> Bool {
        let cal = Calendar.current
        let now = Date()
        let start = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: standHourType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { return cont.resume(throwing: error) }
                let stood = (samples as? [HKCategorySample])?.contains {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                } ?? false
                cont.resume(returning: stood)
            }
            store.execute(query)
        }
    }
}

private final class WatchSyncListener: NSObject, WCSessionDelegate {
    static let shared = WatchSyncListener()
    private let defaults = UserDefaults(suiteName: "group.ch.enjor.health")

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        apply(applicationContext: session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        apply(applicationContext: applicationContext)
    }

    private func apply(applicationContext: [String: Any]) {
        if let v = applicationContext[WatchSharedKeys.aplGoal] as? Int { defaults?.set(v, forKey: WatchSharedKeys.aplGoal) }
        if let v = applicationContext[WatchSharedKeys.avgCals] as? Int { defaults?.set(v, forKey: WatchSharedKeys.avgCals) }
        if let v = applicationContext[WatchSharedKeys.goal] as? Int { defaults?.set(v, forKey: WatchSharedKeys.goal) }
        if let v = applicationContext[WatchSharedKeys.todaysCals] as? Int { defaults?.set(v, forKey: WatchSharedKeys.todaysCals) }
        if let v = applicationContext[WatchSharedKeys.todaysMinCalsGoal] as? Int { defaults?.set(v, forKey: WatchSharedKeys.todaysMinCalsGoal) }
        if let v = applicationContext[WatchSharedKeys.trackingMode] as? String { defaults?.set(v, forKey: WatchSharedKeys.trackingMode) }
        if let v = applicationContext[WatchSharedKeys.stoodThisHour] as? Bool { defaults?.set(v, forKey: WatchSharedKeys.stoodThisHour) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private struct WatchWidgetVisualView: View {
    let model: WatchWidgetVisualModel
    
    private var rings: [SharedRing] {
        generateRings(from: model.ringInput)
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let anchor = ((geo.size.width + geo.size.height) / 2)
                let target = model.ringInput.primaryTarget
                
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

                VStack {
                    Text("\(model.todaysCals) / \(target)")
                    Text("ø \(model.avgCals) / \(model.goal)")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

#Preview {
    ContentView()
}
