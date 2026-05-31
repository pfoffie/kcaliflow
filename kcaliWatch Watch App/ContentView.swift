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
    @State private var syncedSettings = SharedStore.readTrackingSettings()
    @State private var showSettingsPanel = false
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        WatchWidgetVisualView(model: model)
            .padding(6)
            .overlay(alignment: .topTrailing) {
                Button {
                    syncedSettings = SharedStore.readTrackingSettings()
                    showSettingsPanel = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
            .onAppear {
                WatchSyncListener.shared.activate()
                syncedSettings = SharedStore.readTrackingSettings()
                model = .load(healthSnapshot: healthBridge.snapshot)
                WidgetCenter.shared.reloadAllTimelines()

                Task {
                    await healthBridge.refresh(force: true)
                    model = .load(healthSnapshot: healthBridge.snapshot)
                    syncedSettings = SharedStore.readTrackingSettings()
                }
            }
            .onReceive(timer) { _ in
                Task {
                    await healthBridge.refresh()
                    model = .load(healthSnapshot: healthBridge.snapshot)
                    syncedSettings = SharedStore.readTrackingSettings()
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
                    syncedSettings = SharedStore.readTrackingSettings()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchSyncContextDidUpdate)) { _ in
                syncedSettings = SharedStore.readTrackingSettings()
                Task {
                    await healthBridge.refresh(force: true)
                    model = .load(healthSnapshot: healthBridge.snapshot)
                    syncedSettings = SharedStore.readTrackingSettings()
                }
            }
            .sheet(isPresented: $showSettingsPanel) {
                WatchSettingsPanel(settings: syncedSettings)
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
        let settings = SharedStore.readTrackingSettings()
        let trackingMode = settings.trackingMode
        var aplGoal = shared.aplGoal
        var avgCals = shared.avgCals
        let goal = settings.goal
        var todaysCals = shared.todaysCals
        var todaysMinCalsGoal = max(shared.todaysMinCalsGoal, 1)
        var stoodThisHour = shared.stoodThisHour

        if let healthSnapshot,
           healthSnapshot.trackingMode == trackingMode,
           healthSnapshot.goal == goal {
            aplGoal = healthSnapshot.aplGoal
            avgCals = healthSnapshot.averageValue
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

            let settings = SharedStore.readTrackingSettings()
            let trackingMode = settings.trackingMode
            let collection = try await healthService.fetchCollection(last: 30, mode: trackingMode)
            let metrics = TrackingMath.makeMetrics(
                from: collection,
                goal: settings.goal,
                rollingDays: settings.rollingDays,
                maxDays: 30
            )

            snapshot = WatchHealthSnapshot(
                timestamp: Date(),
                trackingMode: trackingMode,
                goal: settings.goal,
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

private struct WatchSettingsPanel: View {
    @Environment(\.dismiss) private var dismiss
    let settings: SharedTrackingSettings

    var body: some View {
        NavigationStack {
            List {
                settingsRow(
                    label: String(localized: "setting_tracking_mode"),
                    value: String(localized: settings.trackingMode == .steps ? "mode_steps" : "mode_calories")
                )

                settingsRow(
                    label: String(localized: settings.trackingMode == .steps ? "setting_goal_steps" : "setting_goal_kcal"),
                    value: "\(settings.goal)"
                )

                Text(
                    String(localized: "setting_avg_days")
                        .replacingOccurrences(of: "{days}", with: "\(settings.rollingDays)")
                )
                .foregroundStyle(.secondary)

                Text("watch_settings_synced_note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(String(localized: "info_page_settings_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "button_done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func settingsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
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
