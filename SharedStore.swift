//
//  ShardStore.swift
//  pfHealth
//
//  Created by René Jossen on 06.10.2025.
//
import Foundation

enum SharedKeys {
    static let aplGoal           = "aplGoal"
    static let minCals           = "minCals"
    static let avgCals           = "avgCals"
    static let goal              = "goal"
    static let todaysCals        = "todaysCals"
    static let todaysMinCalsGoal = "todaysMinCalsGoal"
}

struct SharedStore {
    static let defaults = UserDefaults(suiteName: "group.ch.enjor.health")!

    static func write(
        aplGoal: Int,
        minCals: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int
    ) {
        
        defaults.set(aplGoal, forKey: SharedKeys.aplGoal)
        defaults.set(minCals, forKey: SharedKeys.minCals)
        defaults.set(avgCals, forKey: SharedKeys.avgCals)
        defaults.set(goal, forKey: SharedKeys.goal)
        defaults.set(todaysCals, forKey: SharedKeys.todaysCals)
        defaults.set(todaysMinCalsGoal, forKey: SharedKeys.todaysMinCalsGoal)
        
        
    }

    static func read() -> (
        aplGoal: Int,
        minCals: Int,
        avgCals: Int,
        goal: Int,
        todaysCals: Int,
        todaysMinCalsGoal: Int
    ) {
        return (
            defaults.integer(forKey: SharedKeys.aplGoal),
            defaults.integer(forKey: SharedKeys.minCals),
            defaults.integer(forKey: SharedKeys.avgCals),
            defaults.integer(forKey: SharedKeys.goal),
            defaults.integer(forKey: SharedKeys.todaysCals),
            defaults.integer(forKey: SharedKeys.todaysMinCalsGoal)
        )
    }
}
