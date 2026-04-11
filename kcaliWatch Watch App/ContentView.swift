//
//  ContentView.swift
//  kcaliWatch Watch App
//
//  Created by René Jossen on 11.04.2026.
//

import SwiftUI
import Combine
import WatchConnectivity

struct ContentView: View {
    @State private var model = WatchWidgetVisualModel.load()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        WatchWidgetVisualView(model: model)
            .padding(6)
            .onAppear {
                WatchSyncListener.shared.activate()
                model = .load()
            }
            .onReceive(timer) { _ in model = .load() }
    }
}

private enum WatchSharedKeys {
    static let aplGoal = "aplGoal"
    static let avgCals = "avgCals"
    static let goal = "goal"
    static let todaysCals = "todaysCals"
    static let todaysMinCalsGoal = "todaysMinCalsGoal"
    static let trackingMode = "trackingMode"
}

private struct WatchWidgetVisualModel {
    let aplGoal: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
    let isSteps: Bool

    static func load() -> WatchWidgetVisualModel {
        let defaults = UserDefaults(suiteName: "group.ch.enjor.health")
        let mode = defaults?.string(forKey: WatchSharedKeys.trackingMode) ?? "calories"
        return WatchWidgetVisualModel(
            aplGoal: defaults?.integer(forKey: WatchSharedKeys.aplGoal) ?? 0,
            avgCals: defaults?.integer(forKey: WatchSharedKeys.avgCals) ?? 0,
            goal: defaults?.integer(forKey: WatchSharedKeys.goal) ?? 0,
            todaysCals: defaults?.integer(forKey: WatchSharedKeys.todaysCals) ?? 0,
            todaysMinCalsGoal: defaults?.integer(forKey: WatchSharedKeys.todaysMinCalsGoal) ?? 0,
            isSteps: mode == "steps"
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

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        if let v = applicationContext[WatchSharedKeys.aplGoal] as? Int { defaults?.set(v, forKey: WatchSharedKeys.aplGoal) }
        if let v = applicationContext[WatchSharedKeys.avgCals] as? Int { defaults?.set(v, forKey: WatchSharedKeys.avgCals) }
        if let v = applicationContext[WatchSharedKeys.goal] as? Int { defaults?.set(v, forKey: WatchSharedKeys.goal) }
        if let v = applicationContext[WatchSharedKeys.todaysCals] as? Int { defaults?.set(v, forKey: WatchSharedKeys.todaysCals) }
        if let v = applicationContext[WatchSharedKeys.todaysMinCalsGoal] as? Int { defaults?.set(v, forKey: WatchSharedKeys.todaysMinCalsGoal) }
        if let v = applicationContext[WatchSharedKeys.trackingMode] as? String { defaults?.set(v, forKey: WatchSharedKeys.trackingMode) }
    }
}

private struct WatchWidgetVisualView: View {
    let model: WatchWidgetVisualModel

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let anchor = ((geo.size.width + geo.size.height) / 2)
                let pAvg = CGFloat(model.avgCals) / CGFloat(max(model.goal, 1))
                let cGoal = anchor
                let cAvg = anchor * min(pAvg, 1.5)
                let target = max(model.todaysMinCalsGoal, 1)
                let progress = CGFloat(min(Double(model.todaysCals) / Double(target), 1.0))

                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.green)
                    .frame(width: cGoal, height: cGoal)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                Circle()
                    .fill((pAvg < 1.0 ? Color.orange : Color.green).opacity(0.5))
                    .frame(width: cAvg, height: cAvg)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                Circle()
                    .fill((model.isSteps ? Color.orange : Color.pink).opacity(0.5))
                    .frame(width: anchor * progress, height: anchor * progress)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

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
