//
//  ShardStore.swift
//  pfHealth
//
//  Created by René Jossen on 06.10.2025.
//
import Foundation

enum SharedKeys {
    static let goal = "goal_kcal"
    static let todaysCals = "todays_cals"
    static let avgCals = "avg_cals"
    static let todaysMin = "todays_min"
    static let lastUpdate = "last_update"
}

struct SharedStore {
    static let defaults = UserDefaults(suiteName: "group.ch.enjor.health")!

    static func write(goal: Int, todays: Int, minToday: Int, average: Int) {
        defaults.set(goal, forKey: SharedKeys.goal)
        defaults.set(todays, forKey: SharedKeys.todaysCals)
        defaults.set(average, forKey: SharedKeys.avgCals)
        defaults.set(minToday, forKey: SharedKeys.todaysMin)
        defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.lastUpdate)
    }

    static func read() -> (goal: Int, todays: Int, minToday: Int, average: Int, last: Date?) {
        let g = defaults.integer(forKey: SharedKeys.goal)
        let t = defaults.integer(forKey: SharedKeys.todaysCals)
        let a = defaults.integer(forKey: SharedKeys.avgCals)
        let m = defaults.integer(forKey: SharedKeys.todaysMin)
        let ts = defaults.double(forKey: SharedKeys.lastUpdate)
        return (g, t, m, a, ts > 0 ? Date(timeIntervalSince1970: ts) : nil)
    }
}
