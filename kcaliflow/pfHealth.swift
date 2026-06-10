//
//  pfHealth.swift
//  kcaliflow
//
//  Created by Rene Jossen on 21.10.2025.
//

import Foundation
import Combine
import HealthKit
import WidgetKit
#if os(iOS)
import WatchConnectivity
#endif

private let goalKey = "goal_kcal" // legacy compatibility key
private let caloriesGoalKey = "goal_kcal_mode_calories"
private let stepsGoalKey = "goal_kcal_mode_steps"
private let daysKey = "average_days"
private let modeKey = "tracking_mode"

final class PFHealth: ObservableObject {
    private var energyObserverQuery: HKObserverQuery?
    private var stepsObserverQuery: HKObserverQuery?
    private var standHourObserverQuery: HKObserverQuery?

    public let maxDays = 30
    public var aplGoal: Int = TrackingDefaults.goal(for: .calories)
    private var aplDays: [Day] = []

    public var minCals: Int = 0
    public var avgCals: Int = 0

    // The shared service owns every HealthKit read path so iPhone and Watch stay aligned.
    private let healthService = AppleHealthDataService()
    private let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount)!
    private let standHourType = HKObjectType.categoryType(forIdentifier: .appleStandHour)!

    #if os(iOS)
    private let watchSync = PhoneWatchSyncBridge()
    #endif

    @Published var trackingMode: TrackingMode = .calories {
        didSet {
            guard oldValue != trackingMode else { return }

            UserDefaults.standard.set(trackingMode.rawValue, forKey: modeKey)
            goal = persistedGoal(for: trackingMode)
            aplGoal = trackingMode == .steps ? 0 : aplGoal
            loadData()
        }
    }

    var unitLabel: String {
        trackingMode == .steps ? "Steps" : "kcal"
    }

    private var fetching: Int = 0
    private var pendingReload = false
    @Published var isLoading: Bool = true

    @Published var days: [Day] = []
    @Published var goal: Int = TrackingDefaults.goal(for: .calories) {
        didSet {
            UserDefaults.standard.set(goal, forKey: goalKey)
            UserDefaults.standard.set(goal, forKey: goalStorageKey(for: trackingMode))
            recompute()
        }
    }
    @Published var todaysMinCalsGoal: Int = 0
    @Published var rollingDays: Int = 7 {
        didSet {
            UserDefaults.standard.set(rollingDays, forKey: daysKey)
            recompute()
        }
    }
    @Published var average: Double = 0

    var todaysCals: Int = 0
    var stoodThisHour: Bool = false

    init(type: String = "app") {
        if let storedRollingDays = UserDefaults.standard.object(forKey: daysKey) as? Int {
            rollingDays = storedRollingDays
        }

        if let storedMode = UserDefaults.standard.string(forKey: modeKey),
           let mode = TrackingMode(rawValue: storedMode) {
            trackingMode = mode
        }

        goal = persistedGoal(for: trackingMode)

        #if os(iOS)
        watchSync.activate()
        #endif

        if type == "widget" {
            mirrorFromSharedStore()
        } else {
            loadData()
        }
    }

    private func goalStorageKey(for mode: TrackingMode) -> String {
        mode == .steps ? stepsGoalKey : caloriesGoalKey
    }

    private func persistedGoal(for mode: TrackingMode) -> Int {
        let storageKey = goalStorageKey(for: mode)
        if let stored = UserDefaults.standard.object(forKey: storageKey) as? Int {
            return stored
        }

        // Keep the old single-goal setting alive for users upgrading from older builds.
        if mode == .calories,
           let legacyGoal = UserDefaults.standard.object(forKey: goalKey) as? Int {
            return legacyGoal
        }

        return TrackingDefaults.goal(for: mode)
    }

    func loadData() {
        Task {
            await loadFromHealthKit()
        }
    }

    private func recompute() {
        fetching = 0

        // Re-run the shared math locally whenever the user changes goal or averaging days.
        let metrics = TrackingMath.makeMetrics(
            from: aplDays,
            goal: goal,
            rollingDays: rollingDays,
            appleMoveGoal: aplGoal,
            stoodThisHour: stoodThisHour
        )

        days = metrics.visibleDays
        todaysCals = metrics.todaysValue
        minCals = metrics.minimumHistoricalValue
        avgCals = metrics.weightedAverage
        average = Double(metrics.weightedAverage)
        todaysMinCalsGoal = metrics.requiredToday

        mirrorToWidget()

        if pendingReload {
            pendingReload = false
            Task { await loadFromHealthKit() }
        }
    }

    func requestAuthorization() async throws {
        try await healthService.requestAuthorization()
        startObservingEnergy()
        startObservingSteps()
        startObservingStandHours()
    }

    @MainActor
    func loadFromHealthKit() async {
        guard fetching == 0 else {
            pendingReload = true
            return
        }

        fetching = 1

        do {
            NSLog("loadFromHealthKit mode=\(trackingMode.rawValue)")

            let collection = try await healthService.fetchCollection(last: maxDays, mode: trackingMode)
            let metrics = TrackingMath.makeMetrics(
                from: collection,
                goal: goal,
                rollingDays: rollingDays,
                maxDays: maxDays
            )

            aplGoal = metrics.appleMoveGoal
            aplDays = metrics.allDays
            stoodThisHour = metrics.stoodThisHour
            isLoading = false

            recompute()
        } catch {
            NSLog("HealthKit error: \(error)")
            fetching = 0
            isLoading = false
        }
    }

    func startObservingEnergy() {
        guard energyObserverQuery == nil else { return }

        energyObserverQuery = HKObserverQuery(sampleType: energyType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }

            guard let self else {
                completion()
                return
            }

            if self.fetching == 0 {
                Task {
                    await self.loadFromHealthKit()
                    completion()
                }
            } else {
                completion()
            }
        }

        if let query = energyObserverQuery {
            healthObserverStore.execute(query)
        }
        healthObserverStore.enableBackgroundDelivery(for: energyType, frequency: .immediate) { _, _ in }
    }

    func startObservingSteps() {
        guard stepsObserverQuery == nil else { return }

        stepsObserverQuery = HKObserverQuery(sampleType: stepsType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }

            guard let self else {
                completion()
                return
            }

            guard self.trackingMode == .steps else {
                completion()
                return
            }

            if self.fetching == 0 {
                Task {
                    await self.loadFromHealthKit()
                    completion()
                }
            } else {
                completion()
            }
        }

        if let query = stepsObserverQuery {
            healthObserverStore.execute(query)
        }
        healthObserverStore.enableBackgroundDelivery(for: stepsType, frequency: .immediate) { _, _ in }
    }

    func startObservingStandHours() {
        guard standHourObserverQuery == nil else { return }

        standHourObserverQuery = HKObserverQuery(sampleType: standHourType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }

            guard let self else {
                completion()
                return
            }

            if self.fetching == 0 {
                Task {
                    await self.loadFromHealthKit()
                    completion()
                }
            } else {
                completion()
            }
        }

        if let query = standHourObserverQuery {
            healthObserverStore.execute(query)
        }
        healthObserverStore.enableBackgroundDelivery(for: standHourType, frequency: .immediate) { _, _ in }
    }

    // This separate store keeps the observer lifecycle explicit and mirrors the old behavior.
    private let healthObserverStore = HKHealthStore()

    private func mirrorToWidget() {
        SharedStore.write(
            aplGoal: aplGoal,
            minCals: minCals,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            rollingDays: rollingDays,
            trackingMode: trackingMode.rawValue,
            stoodThisHour: stoodThisHour
        )

        #if os(iOS)
        watchSync.push(
            aplGoal: aplGoal,
            minCals: minCals,
            avgCals: avgCals,
            goal: goal,
            todaysCals: todaysCals,
            todaysMinCalsGoal: todaysMinCalsGoal,
            rollingDays: rollingDays,
            trackingMode: trackingMode.rawValue,
            stoodThisHour: stoodThisHour
        )
        #endif

        WidgetCenter.shared.reloadAllTimelines()
    }

    func mirrorFromSharedStore() {
        let shared = SharedStore.read()
        aplGoal = shared.aplGoal
        minCals = shared.minCals
        avgCals = shared.avgCals
        goal = shared.goal
        todaysCals = shared.todaysCals
        todaysMinCalsGoal = shared.todaysMinCalsGoal
        stoodThisHour = shared.stoodThisHour

        if let mode = TrackingMode(rawValue: shared.trackingMode) {
            trackingMode = mode
        }
    }
}

#if os(iOS)
private final class PhoneWatchSyncBridge: NSObject, WCSessionDelegate {
    private let session = WCSession.isSupported() ? WCSession.default : nil

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // The iPhone mirrors the already-computed dashboard values so the watch can render
    // useful fallback content even before its direct HealthKit refresh finishes.
    func push(
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
        guard let session else { return }

        let payload: [String: Any] = [
            SharedKeys.aplGoal: aplGoal,
            SharedKeys.minCals: minCals,
            SharedKeys.avgCals: avgCals,
            SharedKeys.goal: goal,
            SharedKeys.todaysCals: todaysCals,
            SharedKeys.todaysMinCalsGoal: todaysMinCalsGoal,
            SharedKeys.rollingDays: rollingDays,
            SharedKeys.trackingMode: trackingMode,
            SharedKeys.stoodThisHour: stoodThisHour,
            SharedKeys.lastUpdated: Date()
        ]

        try? session.updateApplicationContext(payload)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
