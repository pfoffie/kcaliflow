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

    // How much of the first glass bubble peeks in at the bottom to hint that the page scrolls.
    private let overlayPeek: CGFloat = 26

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 8) {
                        // Transparent spacer keeps the rings fully visible until the user scrolls
                        // the glass overlays up over them.
                        Color.clear
                            .frame(height: max(geo.size.height - overlayPeek, 0))

                        if model.remainingToTarget > 0 {
                            WatchRemainingBubble(
                                remaining: model.remainingToTarget,
                                isSteps: model.isSteps
                            )
                        }

                        WatchSettingsView(
                            goal: $settingsGoal,
                            rollingDays: $settingsRollingDays,
                            trackingMode: $settingsMode,
                            onSave: saveSettings
                        )
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
            .background {
                WatchWidgetVisualView(model: model)
                    .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "questionmark")
                    }
                    .accessibilityLabel(String(localized: "info_page_nav_title"))
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            WatchInfoView()
        }
        .onAppear {
            WatchSyncListener.shared.activate()
            reloadModel()
            reloadSettings()
            refreshIfStale()
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchSharedStoreDidUpdate)) { _ in
            reloadModel()
            reloadSettings()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            reloadModel()
            reloadSettings()
            refreshIfStale()
        }
    }

    private func reloadModel() {
        model = .load()
    }

    // Skip the HealthKit refresh when the shared data was updated within the last 5 minutes.
    private func refreshIfStale() {
        if let lastUpdated = SharedStore.readSnapshot().lastUpdated,
           Date().timeIntervalSince(lastUpdated) < 300 {
            return
        }
        refreshWithAuthorization()
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

    /// Step rings use the configured goal rather than the rolling minimum.
    var todayTarget: Int {
        if isSteps { return goal }
        return usesAppleMoveGoal ? aplGoal : todaysMinCalsGoal
    }

    var remainingToTarget: Int {
        max(todayTarget - todaysCals, 0)
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
            // The view fills the whole screen, so size the rings from the short side to keep
            // the goal circle fully visible.
            let anchor = min(geo.size.width, geo.size.height) * 0.9

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
                    }

                    Text("\(model.todaysCals) / \(model.todayTarget)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    Text("ø \(model.avgCals) / \(model.goal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: anchor * 0.8)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}

private struct WatchRemainingBubble: View {
    let remaining: Int
    let isSteps: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSteps ? "figure.walk" : "flame.fill")
                .font(.body)
                .foregroundStyle(isSteps ? Color.orange : Color.pink)

            Text(
                String(localized: isSteps ? "info_rest_steps" : "info_rest_kcal")
                    .replacingOccurrences(of: "{kcal}", with: "\(remaining)")
            )
            .font(.system(.headline, design: .rounded))
            .monospacedDigit()
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct WatchSettingsView: View {
    @Binding var goal: Int
    @Binding var rollingDays: Int
    @Binding var trackingMode: TrackingMode
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "info_page_settings_title"))
                .font(.headline)
                .padding(.leading, 4)

            // Segmented pickers are unavailable on watchOS, so the mode switch is a custom capsule control.
            HStack(spacing: 2) {
                modeButton(String(localized: "mode_calories"), mode: .calories)
                modeButton(String(localized: "mode_steps"), mode: .steps)
            }
            .padding(3)
            .background(Capsule().fill(.white.opacity(0.08)))
            .onChange(of: trackingMode) { _, newMode in
                goal = SharedStore.currentGoal(for: newMode.rawValue)
            }

            VStack(alignment: .leading, spacing: 2) {
                settingTitle(trackingMode == .steps ? "Step goal" : "Calorie goal")
                Stepper(value: $goal, in: 0...(trackingMode == .steps ? 50_000 : 5_000), step: trackingMode == .steps ? 500 : 5) {
                    valueLabel("\(goal)", unit: trackingMode == .steps ? "steps" : "kcal")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                settingTitle("Average over")
                Stepper(value: $rollingDays, in: 2...30) {
                    valueLabel("\(rollingDays)", unit: "days")
                }
            }

            Button(action: onSave) {
                Text("Save settings")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func settingTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func valueLabel(_ value: String, unit: LocalizedStringKey) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func modeButton(_ title: String, mode: TrackingMode) -> some View {
        let isSelected = trackingMode == mode
        return Button {
            trackingMode = mode
        } label: {
            Text(title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor.opacity(0.45))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
