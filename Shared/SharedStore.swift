import Foundation
import SwiftUI

extension Notification.Name {
    static let sharedStoreDidUpdate = Notification.Name("sharedStoreDidUpdate")
}

enum SharedKeys {
    static let aplGoal           = "aplGoal"
    static let minCals           = "minCals"
    static let avgCals           = "avgCals"
    static let goal              = "goal"
    static let goalCalories      = "goal_calories"
    static let goalSteps         = "goal_steps"
    static let todaysCals        = "todaysCals"
    static let todaysMinCalsGoal = "todaysMinCalsGoal"
    static let rollingDays       = "rollingDays"
    static let trackingMode      = "trackingMode"
    static let stoodThisHour     = "stoodThisHour"
    static let lastUpdated       = "lastUpdated"
    static let syncSource        = "syncSource"
}

struct SharedStore {
    static let defaults = UserDefaults(suiteName: "group.ch.enjor.health")!

    private static func goalKey(for mode: TrackingMode) -> String {
        mode == .steps ? SharedKeys.goalSteps : SharedKeys.goalCalories
    }

    static func currentGoal(for trackingMode: String) -> Int {
        let mode = TrackingMode(rawValue: trackingMode) ?? .calories
        let modeGoal = defaults.integer(forKey: goalKey(for: mode))
        if modeGoal > 0 {
            return modeGoal
        }

        let genericGoal = defaults.integer(forKey: SharedKeys.goal)
        if genericGoal > 0 {
            return genericGoal
        }

        return TrackingDefaults.goal(for: mode)
    }

    static func write(
        aplGoal: Int,
        minCals: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int,
        rollingDays: Int,
        trackingMode: String,
        stoodThisHour: Bool
    ) {
        let mode = TrackingMode(rawValue: trackingMode) ?? .calories

        defaults.set(aplGoal, forKey: SharedKeys.aplGoal)
        defaults.set(minCals, forKey: SharedKeys.minCals)
        defaults.set(avgCals, forKey: SharedKeys.avgCals)
        defaults.set(goal, forKey: SharedKeys.goal)
        defaults.set(goal, forKey: goalKey(for: mode))
        defaults.set(todaysCals, forKey: SharedKeys.todaysCals)
        defaults.set(todaysMinCalsGoal, forKey: SharedKeys.todaysMinCalsGoal)
        defaults.set(rollingDays, forKey: SharedKeys.rollingDays)
        defaults.set(trackingMode, forKey: SharedKeys.trackingMode)
        defaults.set(stoodThisHour, forKey: SharedKeys.stoodThisHour)
        defaults.set(Date(), forKey: SharedKeys.lastUpdated)
    }

    static func writeSettings(goal: Int, rollingDays: Int, trackingMode: String) {
        let mode = TrackingMode(rawValue: trackingMode) ?? .calories

        defaults.set(goal, forKey: SharedKeys.goal)
        defaults.set(goal, forKey: goalKey(for: mode))
        defaults.set(rollingDays, forKey: SharedKeys.rollingDays)
        defaults.set(trackingMode, forKey: SharedKeys.trackingMode)
        defaults.set(Date(), forKey: SharedKeys.lastUpdated)
    }

    static func apply(applicationContext: [String: Any]) {
        let keys = [
            SharedKeys.aplGoal,
            SharedKeys.minCals,
            SharedKeys.avgCals,
            SharedKeys.goal,
            SharedKeys.goalCalories,
            SharedKeys.goalSteps,
            SharedKeys.todaysCals,
            SharedKeys.todaysMinCalsGoal,
            SharedKeys.rollingDays,
            SharedKeys.trackingMode,
            SharedKeys.stoodThisHour
        ]

        for key in keys {
            if let value = applicationContext[key] {
                defaults.set(value, forKey: key)
            }
        }

        if let value = applicationContext[SharedKeys.lastUpdated] as? Date {
            defaults.set(value, forKey: SharedKeys.lastUpdated)
        } else {
            defaults.set(Date(), forKey: SharedKeys.lastUpdated)
        }
    }

    static func read() -> (
        aplGoal: Int,
        minCals: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int,
        rollingDays: Int,
        trackingMode: String,
        stoodThisHour: Bool,
        lastUpdated: Date?
    ) {
        let trackingMode = defaults.string(forKey: SharedKeys.trackingMode) ?? "calories"
        let mode = TrackingMode(rawValue: trackingMode) ?? .calories
        let storedRollingDays = defaults.integer(forKey: SharedKeys.rollingDays)
        let resolvedGoal = currentGoal(for: trackingMode)

        return (
            defaults.integer(forKey: SharedKeys.aplGoal),
            defaults.integer(forKey: SharedKeys.minCals),
            defaults.integer(forKey: SharedKeys.avgCals),
            resolvedGoal > 0 ? resolvedGoal : TrackingDefaults.goal(for: mode),
            defaults.integer(forKey: SharedKeys.todaysCals),
            defaults.integer(forKey: SharedKeys.todaysMinCalsGoal),
            storedRollingDays > 0 ? storedRollingDays : 7,
            trackingMode,
            defaults.bool(forKey: SharedKeys.stoodThisHour),
            defaults.object(forKey: SharedKeys.lastUpdated) as? Date
        )
    }

    static func readSnapshot() -> SharedSnapshot {
        let values = read()
        return SharedSnapshot(
            aplGoal: values.aplGoal,
            minCals: values.minCals,
            avgCals: values.avgCals,
            goal: values.goal,
            todaysCals: values.todaysCals,
            todaysMinCalsGoal: values.todaysMinCalsGoal,
            rollingDays: values.rollingDays,
            trackingMode: values.trackingMode,
            stoodThisHour: values.stoodThisHour,
            lastUpdated: values.lastUpdated
        )
    }
}

struct SharedSnapshot {
    let aplGoal: Int
    let minCals: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
    let rollingDays: Int
    let trackingMode: String
    let stoodThisHour: Bool
    let lastUpdated: Date?

    var isSteps: Bool { trackingMode == "steps" }
    var usesAppleMoveGoal: Bool { !isSteps && aplGoal > todaysMinCalsGoal }
}

enum SharedRingType: String, Codable {
    case solid
    case line
}

struct SharedRing: Identifiable {
    let id = UUID()
    let position: CGFloat
    var color: Color
    let type: SharedRingType
}

struct SharedRingInput {
    let aplGoal: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
    let isSteps: Bool
    let stoodThisHour: Bool
    let usesStandHourGoalHighlight: Bool

    var minimumTarget: Int {
        if isSteps { return max(goal, 1) }
        return max(todaysMinCalsGoal, 1)
    }

    var primaryTarget: Int {
        if !isSteps && aplGoal > todaysMinCalsGoal {
            return max(aplGoal, 1)
        }
        return minimumTarget
    }

    init(
        aplGoal: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int,
        isSteps: Bool,
        stoodThisHour: Bool = false,
        usesStandHourGoalHighlight: Bool = true
    ) {
        self.aplGoal = aplGoal
        self.avgCals = avgCals
        self.goal = goal
        self.todaysCals = todaysCals
        self.todaysMinCalsGoal = todaysMinCalsGoal
        self.isSteps = isSteps
        self.stoodThisHour = stoodThisHour
        self.usesStandHourGoalHighlight = usesStandHourGoalHighlight
    }
}

private enum SharedRingPalette {
    static let goalRing = Color.green
    static let todayCalories = Color.pink
    static let todaySteps = Color.orange
    static let standRing = Color.blue
}

func generateRings(from input: SharedRingInput) -> [SharedRing] {
    var rings: [SharedRing] = []
    
    var goalRingPos = 1.0
    let goalRingColor = (input.usesStandHourGoalHighlight && input.stoodThisHour)
        ? SharedRingPalette.standRing
        : SharedRingPalette.goalRing
    let nowRingPos = CGFloat(input.todaysCals) / CGFloat(max(input.primaryTarget, 1))
    let todayBaseColor = input.isSteps ? SharedRingPalette.todaySteps : SharedRingPalette.todayCalories
    var nowRing = SharedRing(
        position: nowRingPos,
        color: todayBaseColor,
        type: .solid
    )
    
    if nowRingPos >= 1 {
        nowRing.color = SharedRingPalette.goalRing.opacity(0.3)
        if nowRingPos >= 1.65{
            goalRingPos = 1.0 * (1.65 / nowRingPos)
        }
    } else {
        let avgRingPos = CGFloat(input.avgCals) / CGFloat(max(input.goal, 1))
        var avgRing = SharedRing(
            position: avgRingPos,
            color: todayBaseColor.opacity(0.3),
            type: .solid
        )
        if avgRingPos >= 1 {
            avgRing.color = SharedRingPalette.goalRing.opacity(0.3)
        }
        rings.append(avgRing)
    }

    rings.append(nowRing)
    rings.append(SharedRing(
        position: goalRingPos,
        color: goalRingColor,
        type: .line
    ))

    return rings
}
