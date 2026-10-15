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
    @State private var settingsGoal = 500
    @State private var settingsRollingDays = 7
    @State private var settingsMode = TrackingMode.calories
    @State private var showInfo = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                WatchWidgetVisualView(model: model)
                    .frame(height: 175)

                WatchSettingsView(
                    goal: $settingsGoal,
                    rollingDays: $settingsRollingDays,
                    trackingMode: $settingsMode,
                    onSave: saveSettings
                )
            }
            .padding(6)
            .onAppear {
                WatchSyncListener.shared.activate()
                reloadModel()
                refreshWithAuthorization()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchSharedStoreDidUpdate)) { _ in
                reloadModel()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                reloadModel()
                refreshWithAuthorization()
            }
    }

    private func reloadModel() {
        model = .load()
    }

    private func reloadSettings() {
        let shared = SharedStore.read()
        settingsGoal = shared.goal
        settingsRollingDays = shared.rollingDays
        settingsMode = TrackingMode(rawValue: shared.trackingMode) ?? .calories
    }

    private func saveSettings() {
        let goal = max(settingsGoal, 0)
        SharedStore.writeSettings(
            goal: goal,
            rollingDays: settingsRollingDays,
            trackingMode: settingsMode.rawValue
        )
        WatchSyncListener.shared.pushSettings(
            goal: goal,
            rollingDays: settingsRollingDays,
            trackingMode: settingsMode.rawValue
        )
        reloadModel()
        refreshFromHealthKit()
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

            guard let collection = try? await healthService.fetchCollection(last: 30, mode: trackingMode) else { return }

            let metrics = TrackingMath.makeMetrics(
                from: collection,
                goal: resolvedGoal,
                rollingDays: shared.rollingDays,
                maxDays: 30
            )

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

    func pushSettings(goal: Int, rollingDays: Int, trackingMode: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext([
                SharedKeys.goal: goal,
                SharedKeys.goalCalories: trackingMode == TrackingMode.calories.rawValue ? goal : SharedStore.defaults.integer(forKey: SharedKeys.goalCalories),
                SharedKeys.goalSteps: trackingMode == TrackingMode.steps.rawValue ? goal : SharedStore.defaults.integer(forKey: SharedKeys.goalSteps),
                SharedKeys.rollingDays: rollingDays,
                SharedKeys.trackingMode: trackingMode,
                SharedKeys.lastUpdated: Date()
            ])
        } catch {
            NSLog("Watch settings sync failed: \(error.localizedDescription)")
        }
    }

    private func apply(applicationContext: [String: Any]) {
        guard !applicationContext.isEmpty else { return }

        SharedStore.apply(applicationContext: applicationContext)

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

private struct WatchSettingsView: View {
    @Binding var goal: Int
    @Binding var rollingDays: Int
    @Binding var trackingMode: TrackingMode
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.headline)

            Picker("Mode", selection: $trackingMode) {
                Text("Calories").tag(TrackingMode.calories)
                Text("Steps").tag(TrackingMode.steps)
            }
            .pickerStyle(.segmented)
                .onChange(of: trackingMode) { _, newMode in
                    goal = SharedStore.currentGoal(for: newMode.rawValue)
                }

            Stepper(value: $goal, in: 0...(trackingMode == .steps ? 50_000 : 5_000), step: trackingMode == .steps ? 500 : 5) {
                HStack {
                    Text(trackingMode == .steps ? "Step goal" : "Calorie goal")
                    Spacer()
                    Text("\(goal)")
                        .monospacedDigit()
                }
            }

            Stepper(value: $rollingDays, in: 2...30) {
                HStack {
                    Text("Average over")
                    Spacer()
                    Text("\(rollingDays) days")
                        .monospacedDigit()
                }
            }

            Button("Save settings", action: onSave)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct WatchInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    explanation(
                        title: String(localized: "info_page_concept_title"),
                        body: String(localized: "info_page_concept_body")
                    )
                    explanation(
                        title: String(localized: "info_page_min_title"),
                        body: String(localized: "info_page_min_body")
                    )
                    explanation(
                        title: String(localized: "info_page_settings_title"),
                        body: String(localized: "info_page_settings_body")
                    )
                    explanation(
                        title: String(localized: "info_page_version_title"),
                        body: AppVersionInfo.current.displayText
                    )
                }
                .padding()
            }
            .navigationTitle(String(localized: "info_page_nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "button_done")) { dismiss() }
                }
            }
        }
    }

    private func explanation(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}
