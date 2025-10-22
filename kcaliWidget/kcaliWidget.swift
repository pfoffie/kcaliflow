//
//  kcaliWidget.swift
//  kcaliWidget
//
//  Created by René Jossen on 22.10.2025.
//

import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> KcaliEntry {
        KcaliEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (KcaliEntry) -> ()) {
        let entry = KcaliEntry(date: Date())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        var entries: [KcaliEntry] = []

        let currentDate = Date()
        entries.append(KcaliEntry(date: currentDate))
        
        /*
        for i in 0...10 {
            entries.append(KcaliEntry(date: Calendar.current.date(byAdding: .second, value: i * 10, to: currentDate)!))
        }
        */
           
        let timeline = Timeline(entries: entries, policy: .atEnd)
        completion(timeline)
    }

//    func relevances() async -> WidgetRelevances<Void> {
//        // Generate a list containing the contexts this widget is relevant in.
//    }
}

struct KcaliEntry: TimelineEntry {
    let date: Date
}

struct kcaliWidgetEntryView : View {
    var entry: Provider.Entry
    var body: some View {
        let r = SharedStore.read()
        // Current Time HH:MM:SS
        
        ZStack {
            GeometryReader { geo in
                let anchor = ((geo.size.width + geo.size.height) / 2) // todaysMinCalsGoal
                
                let todaysMinCalsGoal:CGFloat = CGFloat(r.todaysMinCalsGoal)
                let todaysCals:CGFloat = CGFloat(r.todaysCals)
                let aplGoal:CGFloat = CGFloat(r.aplGoal)
                let goal:CGFloat = CGFloat(r.goal)
                
                
                let c_aplGoal = anchor * (aplGoal / todaysMinCalsGoal)
                let c_goal = anchor * (goal / todaysMinCalsGoal)
                
                let c_kcal = anchor * (todaysCals / todaysMinCalsGoal)
                
                Circle()
                    .fill(Color.red.opacity(0.5))
                    .frame(width: c_aplGoal, height: c_aplGoal)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                
                
                
                Circle()
                    .fill(Color.yellow)
                    .frame(width: c_kcal, height: c_kcal)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                
                Circle()
                    .fill(Color.pink.opacity(0.2))
                    .frame(width: anchor, height: anchor)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.pink)
                    .frame(width: anchor, height: anchor)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.green)
                    .frame(width: c_goal, height: c_goal)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                
                

                // Your content on top
                VStack {
                    //Text("\(entry.date, format: .dateTime.hour().minute().second())")
                    Text("\(r.todaysCals) / \(r.todaysMinCalsGoal)")
                    
                    Text("ø \(r.avgCals) / \(r.goal)")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }

    }
}

struct kcaliWidget: Widget {
    let kind: String = "kcaliWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                kcaliWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                kcaliWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("My Widget")
        .description("This is an example widget.")
    }
}

#Preview(as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry(date: .now)
}
