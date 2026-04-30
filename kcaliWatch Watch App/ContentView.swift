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
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        WatchWidgetVisualView(model: model)
            .padding(6)
            .onAppear {
                WatchSyncListener.shared.activate()
                model = .load()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .onReceive(timer) { _ in model = .load() }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                model = .load()
                WidgetCenter.shared.reloadAllTimelines()
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

    static func load() -> WatchWidgetVisualModel {
        let defaults = UserDefaults(suiteName: "group.ch.enjor.health")
        let mode = defaults?.string(forKey: WatchSharedKeys.trackingMode) ?? "calories"
        return WatchWidgetVisualModel(
            aplGoal: defaults?.integer(forKey: WatchSharedKeys.aplGoal) ?? 0,
            avgCals: defaults?.integer(forKey: WatchSharedKeys.avgCals) ?? 0,
            goal: defaults?.integer(forKey: WatchSharedKeys.goal) ?? 0,
            todaysCals: defaults?.integer(forKey: WatchSharedKeys.todaysCals) ?? 0,
            todaysMinCalsGoal: defaults?.integer(forKey: WatchSharedKeys.todaysMinCalsGoal) ?? 0,
            isSteps: mode == "steps",
            stoodThisHour: defaults?.bool(forKey: WatchSharedKeys.stoodThisHour) ?? false
        )
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
