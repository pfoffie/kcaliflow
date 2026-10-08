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

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchWidgetVisualModel.load()

    var body: some View {
        WatchWidgetVisualView(model: model)
            .padding(6)
            .onAppear {
                WatchSyncListener.shared.activate()
                let shared = SharedStore.readSnapshot()
                if shared.lastUpdated != nil && Date().timeIntervalSince(shared.lastUpdated!) < 300 {
                    reloadModel()
                    return
                }
                refreshWithAuthorization()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchSharedStoreDidUpdate)) { _ in
                reloadModel()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                let shared = SharedStore.readSnapshot()
                if shared.lastUpdated != nil && Date().timeIntervalSince(shared.lastUpdated!) < 300 {
                    reloadModel()
                    return
                }
                refreshWithAuthorization()
            }
    }

    private func reloadModel() {
        model = .load()
    }

    private func refreshWithAuthorization() {
        Task {
            do {
                try await AppleHealthDataService().requestAuthorization()
                refreshFromHealthKit()
            } catch {
                reloadModel()
            }
        }
    }

    private func refreshFromHealthKit() {
        Task {
            let shared = SharedStore.read()
            let trackingMode = TrackingMode(rawValue: shared.trackingMode) ?? .calories
            let healthService = AppleHealthDataService()

            guard let todayValue = try? await healthService.fetchTodayValue(mode: trackingMode) else {
                await MainActor.run { reloadModel() }
                return
            }

            SharedStore.write(
                aplGoal: shared.aplGoal,
                minCals: shared.minCals,
                avgCals: shared.avgCals,
                goal: shared.goal,
                todaysCals: todayValue,
                todaysMinCalsGoal: shared.todaysMinCalsGoal,
                rollingDays: shared.rollingDays,
                trackingMode: shared.trackingMode,
                stoodThisHour: shared.stoodThisHour
            )

            await MainActor.run {
                reloadModel()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

private extension Notification.Name {
    static let watchSharedStoreDidUpdate = Notification.Name("watchSharedStoreDidUpdate")
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

    var usesAppleMoveGoal: Bool {
        !isSteps && aplGoal > todaysMinCalsGoal
    }

    static func load() -> WatchWidgetVisualModel {
        WatchWidgetVisualModel(snapshot: SharedStore.readSnapshot())
    }

    init(snapshot: SharedSnapshot) {
        aplGoal = snapshot.aplGoal
        avgCals = snapshot.avgCals
        goal = snapshot.goal
        todaysCals = snapshot.todaysCals
        todaysMinCalsGoal = snapshot.todaysMinCalsGoal
        isSteps = snapshot.isSteps
        stoodThisHour = snapshot.stoodThisHour
    }
}

private final class WatchSyncListener: NSObject, WCSessionDelegate {
    static let shared = WatchSyncListener()

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
        guard !applicationContext.isEmpty else { return }

        if let v = applicationContext[SharedKeys.goal] as? Int { SharedStore.defaults.set(v, forKey: SharedKeys.goal) }
        if let v = applicationContext[SharedKeys.goalCalories] as? Int { SharedStore.defaults.set(v, forKey: SharedKeys.goalCalories) }
        if let v = applicationContext[SharedKeys.goalSteps] as? Int { SharedStore.defaults.set(v, forKey: SharedKeys.goalSteps) }
        if let v = applicationContext[SharedKeys.rollingDays] as? Int { SharedStore.defaults.set(v, forKey: SharedKeys.rollingDays) }
        if let v = applicationContext[SharedKeys.trackingMode] as? String { SharedStore.defaults.set(v, forKey: SharedKeys.trackingMode) }
        if let v = applicationContext[SharedKeys.lastUpdated] as? Date {
            SharedStore.defaults.set(v, forKey: SharedKeys.lastUpdated)
        } else {
            SharedStore.defaults.set(Date(), forKey: SharedKeys.lastUpdated)
        }

        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
            NotificationCenter.default.post(name: .watchSharedStoreDidUpdate, object: nil)
        }
    }
}

private struct WatchWidgetVisualView: View {
    let model: WatchWidgetVisualModel

    private var rings: [SharedRing] {
        generateRings(from: model.ringInput)
    }

    var body: some View {
        GeometryReader { geo in
            let anchor = (geo.size.width + geo.size.height) / 2

            ZStack {
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

                VStack(spacing: 2) {
                    if model.usesAppleMoveGoal {
                        Text("")
                            .font(.caption2)

                        Text("\(model.todaysCals) / \(model.aplGoal)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    } else {
                        Text("\(model.todaysCals) / \(model.todaysMinCalsGoal)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }

                    Text("ø \(model.avgCals) / \(model.goal)")
                        .font(.caption2)
                }
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

#Preview {
    ContentView()
}
