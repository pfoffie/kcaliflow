import Foundation
import SwiftUI

enum SharedKeys {
    static let aplGoal           = "aplGoal"
    static let minCals           = "minCals"
    static let avgCals           = "avgCals"
    static let goal              = "goal"
    static let todaysCals        = "todaysCals"
    static let todaysMinCalsGoal = "todaysMinCalsGoal"
    static let rollingDays       = "rollingDays"
    static let trackingMode      = "trackingMode"
}

struct SharedStore {
    static let defaults = UserDefaults(suiteName: "group.ch.enjor.health")!

    static func write(
        aplGoal: Int,
        minCals: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int,
        rollingDays: Int,
        trackingMode: String
    ) {
        defaults.set(aplGoal, forKey: SharedKeys.aplGoal)
        defaults.set(minCals, forKey: SharedKeys.minCals)
        defaults.set(avgCals, forKey: SharedKeys.avgCals)
        defaults.set(goal, forKey: SharedKeys.goal)
        defaults.set(todaysCals, forKey: SharedKeys.todaysCals)
        defaults.set(todaysMinCalsGoal, forKey: SharedKeys.todaysMinCalsGoal)
        defaults.set(rollingDays, forKey: SharedKeys.rollingDays)
        defaults.set(trackingMode, forKey: SharedKeys.trackingMode)
    }

    static func read() -> (
        aplGoal: Int,
        minCals: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int,
        rollingDays: Int,
        trackingMode: String
    ) {
        let storedRollingDays = defaults.integer(forKey: SharedKeys.rollingDays)
        return (
            defaults.integer(forKey: SharedKeys.aplGoal),
            defaults.integer(forKey: SharedKeys.minCals),
            defaults.integer(forKey: SharedKeys.avgCals),
            defaults.integer(forKey: SharedKeys.goal),
            defaults.integer(forKey: SharedKeys.todaysCals),
            defaults.integer(forKey: SharedKeys.todaysMinCalsGoal),
            storedRollingDays > 0 ? storedRollingDays : 7,
            defaults.string(forKey: SharedKeys.trackingMode) ?? "calories"
        )
    }
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
}

private enum SharedRingPalette {
    static let goalRing = Color.green
    static let todayCalories = Color.pink
    static let todaySteps = Color.orange
}

func generateRings(from input: SharedRingInput) -> [SharedRing] {
    var rings: [SharedRing] = []
    
    var goalRingPos = 1.0
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
        color: SharedRingPalette.goalRing,
        type: .line
    ))

    return rings
}
