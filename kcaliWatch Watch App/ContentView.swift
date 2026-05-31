//
//  ContentView.swift
//  kcaliWatch Watch App
//
//  Created by Rene Jossen on 11.04.2026.
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
            .onReceive(NotificationCenter.default.publisher(for: .watchSyncContextDidUpdate)) { _ in
                Task {
                    await healthBridge.refresh(force: true)
                    model = .load(healthSnapshot: healthBridge.snapshot)
                }
            }
    }
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

    // The watch always starts from synced App Group values and upgrades to a direct
    // HealthKit-backed snapshot as soon as the shared collector finishes.
    static func load(healthSnapshot: WatchHealthSnapshot? = nil) -> WatchWidgetVisualModel {
        let shared = SharedStore.read()
        var trackingMode = TrackingMode(rawValue: shared.trackingMode) ?? .calories
        var aplGoal = shared.aplGoal
        var avgCals = shared.avgCals
        var goal = max(shared.goal, TrackingDefaults.goal(for: trackingMode))
        var todaysCals = shared.todaysCals
        var todaysMinCalsGoal = max(shared.todaysMinCalsGoal, 1)
        var stoodThisHour = shared.stoodThisHour

        if let healthSnapshot {
            trackingMode = healthSnapshot.trackingMode
            aplGoal = healthSnapshot.aplGoal
            avgCals = healthSnapshot.averageValue
            goal = healthSnapshot.goal
            todaysCals = healthSnapshot.todaysValue
            todaysMinCalsGoal = max(healthSnapshot.todaysMinimumGoal, 1)
            stoodThisHour = healthSnapshot.stoodThisHour
        }

        return WatchWidgetVisualModel(
            aplGoal: aplGoal,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            isSteps: trackingMode == .steps,
            stoodThisHour: stoodThisHour
        )
    }
}

struct WatchHealthSnapshot {
    let timestamp: Date
    let trackingMode: TrackingMode
    let goal: Int
    let aplGoal: Int
    let todaysValue: Int
    let averageValue: Int
    let todaysMinimumGoal: Int
    let stoodThisHour: Bool
}

@MainActor
private final class WatchHealthBridge: ObservableObject {
    @Published private(set) var snapshot: WatchHealthSnapshot?

    private let healthService = AppleHealthDataService()
    private var hasRequestedAuthorization = false
    private var lastRefresh: Date = .distantPast

    func refresh(force: Bool = false) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= 5 * 60 else { return }

        do {
            if !hasRequestedAuthorization {
                try await healthService.requestAuthorization()
                hasRequestedAuthorization = true
            }

            let shared = SharedStore.read()
            let trackingMode = TrackingMode(rawValue: shared.trackingMode) ?? .calories
            let resolvedGoal = max(shared.goal, TrackingDefaults.goal(for: trackingMode))
            let collection = try await healthService.fetchCollection(last: 30, mode: trackingMode)
            let metrics = TrackingMath.makeMetrics(
                from: collection,
                goal: resolvedGoal,
                rollingDays: shared.rollingDays,
                maxDays: 30
            )

            snapshot = WatchHealthSnapshot(
                timestamp: Date(),
                trackingMode: trackingMode,
                goal: resolvedGoal,
                aplGoal: metrics.appleMoveGoal,
                todaysValue: metrics.todaysValue,
                averageValue: metrics.weightedAverage,
                todaysMinimumGoal: metrics.requiredToday,
                stoodThisHour: metrics.stoodThisHour
            )

            lastRefresh = Date()
        } catch {
            // The watch intentionally keeps the last synced/shared values as a safe fallback.
        }
    }
}

private final class WatchSyncListener: NSObject, WCSessionDelegate {
    static let shared = WatchSyncListener()
    private let defaults = SharedStore.defaults

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

    // The app group is the handoff point for the watch app and watch widget.
    // We mirror every synced dashboard field so both can boot quickly from shared state.
    private func apply(applicationContext: [String: Any]) {
        if let value = applicationContext[SharedKeys.aplGoal] as? Int { defaults.set(value, forKey: SharedKeys.aplGoal) }
        if let value = applicationContext[SharedKeys.minCals] as? Int { defaults.set(value, forKey: SharedKeys.minCals) }
        if let value = applicationContext[SharedKeys.avgCals] as? Int { defaults.set(value, forKey: SharedKeys.avgCals) }
        if let value = applicationContext[SharedKeys.goal] as? Int { defaults.set(value, forKey: SharedKeys.goal) }
        if let value = applicationContext[SharedKeys.todaysCals] as? Int { defaults.set(value, forKey: SharedKeys.todaysCals) }
        if let value = applicationContext[SharedKeys.todaysMinCalsGoal] as? Int { defaults.set(value, forKey: SharedKeys.todaysMinCalsGoal) }
        if let value = applicationContext[SharedKeys.rollingDays] as? Int { defaults.set(value, forKey: SharedKeys.rollingDays) }
        if let value = applicationContext[SharedKeys.trackingMode] as? String { defaults.set(value, forKey: SharedKeys.trackingMode) }
        if let value = applicationContext[SharedKeys.stoodThisHour] as? Bool { defaults.set(value, forKey: SharedKeys.stoodThisHour) }

        WidgetCenter.shared.reloadAllTimelines()

        // Notify ContentView so it can re-fetch HealthKit with the updated settings.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .watchSyncContextDidUpdate, object: nil)
        }
    }
}

private struct WatchWidgetVisualView: View {
    let model: WatchWidgetVisualModel

    private var rings: [SharedRing] {
        generateRings(from: model.ringInput)
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let anchor = (geometry.size.width + geometry.size.height) / 2
                let target = model.ringInput.primaryTarget

                // The same shared ring generator drives the watch app and both widget targets.
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position

                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 2))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
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

private extension Notification.Name {
    static let watchSyncContextDidUpdate = Notification.Name("watchSyncContextDidUpdate")
}
