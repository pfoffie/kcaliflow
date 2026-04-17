//
//  kcaliWidget.swift
//  kcaliWidget
//
//  Created by René Jossen on 22.10.2025.
//

import WidgetKit
import SwiftUI
import HealthKit


private typealias WidgetRing = SharedRing

private func generateRings(from entry: KcaliEntry) -> [WidgetRing] {
    generateRings(from: SharedRingInput(
        aplGoal: entry.aplGoal,
        avgCals: entry.avgCals,
        goal: entry.goal,
        todaysCals: entry.todaysCals,
        todaysMinCalsGoal: entry.todaysMinCalsGoal,
        isSteps: entry.isSteps
    ))
}

private enum WidgetPalette {
    static let goalRing = Color.green
    static let averageLow = Color.orange
    static let averageHigh = Color.green
    static let todayFill = Color.pink
    static let standRing = Color.blue
    static let trackFill = Color.black.opacity(0.78)
    static let trackStroke = Color.white.opacity(0.18)
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    private let store = HKHealthStore()

    func placeholder(in context: Context) -> KcaliEntry {
        KcaliEntry(from: SharedStore.read())
    }

    func getSnapshot(in context: Context, completion: @escaping (KcaliEntry) -> ()) {
        completion(KcaliEntry(from: SharedStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KcaliEntry>) -> ()) {
        Task {
            let entry = await fetchEntry()
            let calendar = Calendar.current
            let now = Date()
            let nextRefreshMinute = 5 - (calendar.component(.minute, from: now) % 5)
            let roundedNow = calendar.date(bySetting: .second, value: 0, of: now) ?? now
            let next = calendar.date(byAdding: .minute, value: max(nextRefreshMinute, 1), to: roundedNow) ?? now.addingTimeInterval(5 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // MARK: - Shared values + live standing fetch

    private func fetchEntry() async -> KcaliEntry {
        let shared = SharedStore.read()
        var standingProgress = (try? await fetchStandingProgressToday()) ?? (done: 0, goal: 0)
        let stoodThisHour = (try? await fetchCurrentHourStandingStatus()) ?? false
        if standingProgress.done == 0, standingProgress.goal == 0 {
            let doneFromSamples = (try? await fetchStandingHoursFromSamplesToday()) ?? 0
            if doneFromSamples > 0 {
                standingProgress = (done: doneFromSamples, goal: 12)
            }
        }
        return KcaliEntry(
            date: Date(),
            aplGoal: shared.aplGoal,
            minCals: shared.minCals,
            avgCals: shared.avgCals,
            goal: shared.goal,
            todaysCals: shared.todaysCals,
            todaysMinCalsGoal: shared.todaysMinCalsGoal,
            isSteps: shared.trackingMode == "steps",
            standingHours: standingProgress.done,
            standingGoal: standingProgress.goal,
            stoodThisHour: stoodThisHour
        )
    }

    private func fetchStandingProgressToday() async throws -> (done: Int, goal: Int) {
        let cal = Calendar.current
        let now = Date()
        var start = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))
        start.calendar = cal
        var end = cal.dateComponents([.year, .month, .day], from: now)
        end.calendar = cal
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error = error { return cont.resume(throwing: error) }
                guard let s = summaries?.first else { return cont.resume(returning: (0, 0)) }
                let done = Int(s.appleStandHours.doubleValue(for: HKUnit.count()).rounded())
                let goal = Int(s.appleStandHoursGoal.doubleValue(for: HKUnit.count()).rounded())
                cont.resume(returning: (done, goal))
            }
            store.execute(q)
        }
    }

    private func fetchCurrentHourStandingStatus() async throws -> Bool {
        let type = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        let cal = Calendar.current
        let now = Date()
        let start = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { return cont.resume(throwing: error) }
                let stood = (samples as? [HKCategorySample])?.contains {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                } ?? false
                cont.resume(returning: stood)
            }
            store.execute(q)
        }
    }

    private func fetchStandingHoursFromSamplesToday() async throws -> Int {
        let type = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { return cont.resume(throwing: error) }
                let stoodHours = (samples as? [HKCategorySample])?.filter {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                }.count ?? 0
                cont.resume(returning: stoodHours)
            }
            store.execute(q)
        }
    }
}

// MARK: - Entry

struct KcaliEntry: TimelineEntry {
    let date: Date
    let aplGoal: Int
    let minCals: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
    let isSteps: Bool
    let standingHours: Int
    let standingGoal: Int
    let stoodThisHour: Bool
}

private extension KcaliEntry {
    init(from r: (aplGoal: Int, minCals: Int, avgCals: Int, goal: Int, todaysCals: Int, todaysMinCalsGoal: Int, rollingDays: Int, trackingMode: String)) {
        self.init(date: Date(), aplGoal: r.aplGoal, minCals: r.minCals,
                  avgCals: r.avgCals, goal: r.goal,
                  todaysCals: r.todaysCals, todaysMinCalsGoal: r.todaysMinCalsGoal,
                  isSteps: r.trackingMode == "steps",
                  standingHours: 0,
                  standingGoal: 0,
                  stoodThisHour: false)
    }

    var minimumTarget: Int {
        if isSteps { return max(goal, 1) }
        return max(todaysMinCalsGoal, 1)
    }

    var progressFraction: CGFloat {
        CGFloat(min(Double(todaysCals) / Double(minimumTarget), 1.0))
    }

    var standingFraction: CGFloat {
        let target = standingGoal > 0 ? standingGoal : max(standingHours, 12)
        guard target > 0 else { return 0.0 }
        return CGFloat(min(Double(standingHours) / Double(target), 1.0))
    }

    var standingTarget: Int {
        standingGoal > 0 ? standingGoal : 12
    }

    var primaryTarget: Int {
        if !isSteps && aplGoal > todaysMinCalsGoal {
            return max(aplGoal, 1)
        }
        return minimumTarget
    }

    var unitLabel: String {
        isSteps ? "steps" : "kcal"
    }
}

// MARK: - View (refactored)

struct kcaliWidgetEntryView: View {
    var entry: Provider.Entry
    
    private var rings: [WidgetRing] {
        generateRings(from: entry)
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geo in
                let anchor = (geo.size.width + geo.size.height) / 2
                
                // Alle Ringe iterativ zeichnen
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
                
                // Text-Overlay
                if entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps {
                    VStack {
                        Text("")
                        Text("\(entry.todaysCals) / \(entry.aplGoal)")
                        
                        Text("ø \(entry.avgCals) / \(entry.goal)")
                            .font(.caption2)
                        Text(" ")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack {
                        Text("\(entry.todaysCals) / \(entry.todaysMinCalsGoal)")
                        
                        Text("ø \(entry.avgCals) / \(entry.goal)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}

// MARK: - Watch Views (können jetzt dieselbe Ring-Logik nutzen)

private struct WatchCircularComplicationView: View {
    let entry: KcaliEntry
    
    private var rings: [WidgetRing] {
        generateRings(from: entry)
    }

    var body: some View {
        GeometryReader { geo in
            let anchor = (geo.size.width + geo.size.height) / 2.6
            
            // Alle Ringe iterativ zeichnen
            ForEach(rings) { ring in
                let diameter = anchor * ring.position
                
                if ring.type == .line {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 1))
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
            
            
            if entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps {
                let rest:Int = entry.aplGoal - entry.todaysCals
                if(rest > 0){
                    VStack {
                        Text("").font(.caption2)
                        Text("\(rest)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            } else {
                let rest:Int = entry.todaysMinCalsGoal - entry.todaysCals
                if(rest > 0){
                    VStack {
                        Text("\(rest)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            
            if entry.stoodThisHour {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3))
                    .foregroundStyle(WidgetPalette.standRing.opacity(0.5))
            }else{
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3))
                    .foregroundStyle(WidgetPalette.trackStroke)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchRectangularComplicationView: View {
    let entry: KcaliEntry
    
    private var rings: [WidgetRing] {
        generateRings(from: entry)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                GeometryReader { geo in
                    let innerWidth = max(geo.size.width*0.7, 0)
                    
                    
                    ForEach(rings) { ring in
                        let diameter = innerWidth * ring.position
                        
                        if ring.type == .line {
                            Rectangle()
                                .fill(ring.color)
                                .frame(width: 2)
                                .position(x: diameter, y: geo.size.height/2)
                        } else {
                            Rectangle()
                                .fill(ring.color)
                                .frame(width: diameter)
                        }
                    }
                }
                .clipShape(Capsule())
                
                Capsule()
                    .stroke(WidgetPalette.trackFill.opacity(0.5), lineWidth: 10)
                Capsule()
                    .stroke(WidgetPalette.trackFill, lineWidth: 6)
                
                if entry.stoodThisHour {
                    Capsule()
                        .stroke(WidgetPalette.standRing, lineWidth: 2)
                } else {
                    Capsule()
                        .stroke(WidgetPalette.trackStroke, lineWidth: 2)
                }

            }
            .frame(height: 30)
           
            if entry.aplGoal > entry.todaysMinCalsGoal && !entry.isSteps {
                HStack {
                    Text("")
                    Text("\(entry.todaysCals) / \(entry.aplGoal)")
                    Text("ø \(entry.avgCals) / \(entry.goal)")
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack {
                    Text("\(entry.todaysCals) / \(entry.todaysMinCalsGoal)")
                    Text("ø \(entry.avgCals) / \(entry.goal)")
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

struct kcaliWidget: Widget {
    let kind: String = "kcaliWidget"

    var body: some WidgetConfiguration {
        #if os(watchOS)
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            WidgetRootView(entry: entry)
        }
        .configurationDisplayName("kcaliflow")
        .description(
            String(localized: "info_widget_description")
        )
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
        #else
        if #available(iOSApplicationExtension 16.0, *) {
            StaticConfiguration(kind: kind, provider: Provider()) { entry in
                WidgetRootView(entry: entry)
            }
            .configurationDisplayName("kcaliflow")
            .description(
                String(localized: "info_widget_description")
            )
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        } else {
            StaticConfiguration(kind: kind, provider: Provider()) { entry in
                WidgetRootView(entry: entry)
            }
            .configurationDisplayName("kcaliflow")
            .description(
                String(localized: "info_widget_description")
            )
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        }
        #endif
    }
}

private struct WidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KcaliEntry

    var body: some View {
        if #available(iOSApplicationExtension 16.0, *) {
            if #available(iOSApplicationExtension 17.0, watchOS 10.0, *) {
                switch family {
                case .accessoryCircular:
                    WatchCircularComplicationView(entry: entry)
                        .containerBackground(for: .widget) { Color.clear }
                case .accessoryRectangular:
                    WatchRectangularComplicationView(entry: entry)
                        .containerBackground(for: .widget) { Color.clear }
                default:
                    kcaliWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                }
            } else {
                switch family {
                case .accessoryCircular:
                    WatchCircularComplicationView(entry: entry)
                case .accessoryRectangular:
                    WatchRectangularComplicationView(entry: entry)
                default:
                    kcaliWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        } else {
            kcaliWidgetEntryView(entry: entry)
                .padding()
                .background()
        }
    }
}

#if os(iOS)
#Preview(as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry(date: .now,
               aplGoal: 999,
               minCals: 666,
               avgCals: 888,
               goal: 888,
               todaysCals: 165,
               todaysMinCalsGoal: 100,
               isSteps: false,
               standingHours: 8,
               standingGoal: 12,
               stoodThisHour: true)
}
#endif

#if os(watchOS)
#Preview(as: .accessoryCircular) {
    kcaliWidget()
} timeline: {
    KcaliEntry(date: .now,
       aplGoal: 90,
       minCals: 666,
       avgCals: 888,
       goal: 888,
       todaysCals: 165,
       todaysMinCalsGoal: 100,
       isSteps: false,
       standingHours: 8,
       standingGoal: 12,
       stoodThisHour: true)
}

#Preview(as: .accessoryRectangular) {
    kcaliWidget()
} timeline: {
    KcaliEntry(date: .now,
               aplGoal: 90,
               minCals: 666,
               avgCals: 888,
               goal: 888,
               todaysCals: 1200,
               todaysMinCalsGoal: 666,
               isSteps: false,
               standingHours: 8,
               standingGoal: 12,
               stoodThisHour: true)
}
#endif
