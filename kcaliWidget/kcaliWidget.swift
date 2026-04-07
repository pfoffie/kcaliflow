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
        let r = SharedStore.read();
        return KcaliEntry(date: Date(),
                          aplGoal: r.aplGoal,
                          minCals: r.minCals,
                          avgCals: r.avgCals,
                          goal: r.goal,
                          todaysCals: r.todaysCals,
                          todaysMinCalsGoal: r.todaysMinCalsGoal)
    }

    func getSnapshot(in context: Context, completion: @escaping (KcaliEntry) -> ()) {
        let r = SharedStore.read();
        let entry = KcaliEntry(date: Date(),
                               aplGoal: r.aplGoal,
                               minCals: r.minCals,
                               avgCals: r.avgCals,
                               goal: r.goal,
                               todaysCals: r.todaysCals,
                               todaysMinCalsGoal: r.todaysMinCalsGoal
                    )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        var entries: [KcaliEntry] = []
        
        let r = SharedStore.read();
        let currentDate = Date()
        entries.append(KcaliEntry(date: currentDate,
                                  aplGoal: r.aplGoal,
                                  minCals: r.minCals,
                                  avgCals: r.avgCals,
                                  goal: r.goal,
                                  todaysCals: r.todaysCals,
                                  todaysMinCalsGoal: r.todaysMinCalsGoal))
        
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        let timeline = Timeline(entries: entries, policy: .after(next))
        completion(timeline)
    }

//    func relevances() async -> WidgetRelevances<Void> {
//        // Generate a list containing the contexts this widget is relevant in.
//    }
}

struct KcaliEntry: TimelineEntry {
    let date: Date
    let aplGoal: Int
    let minCals: Int
    let avgCals: Int
    let goal: Int
    let todaysCals: Int
    let todaysMinCalsGoal: Int
}

struct kcaliWidgetEntryView : View {
    var entry: Provider.Entry
    var body: some View {
        
        ZStack {
            GeometryReader { geo in
                let anchor = ((geo.size.width + geo.size.height) / 2)
                
                let p_avgCals = CGFloat(entry.avgCals) / CGFloat(entry.goal)
                
                let c_goal = anchor
                let c_avgCals = anchor * p_avgCals
                
                
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.green)
                    .frame(width: c_goal, height: c_goal)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                if(p_avgCals < 1.0){
                    Circle()
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: c_avgCals, height: c_avgCals)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }else{
                    Circle()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: c_avgCals, height: c_avgCals)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    if(entry.aplGoal > entry.todaysMinCalsGoal){
                        
                        let p_todaysCals = CGFloat(entry.todaysCals) / CGFloat(entry.aplGoal)
                        if(p_todaysCals < 1.0){
                            
                            let c_todayCals = anchor * p_todaysCals
                            
                            
                            Circle()
                                .fill(Color.white)
                                .frame(width: c_todayCals, height: c_todayCals)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            Circle()
                                .fill(Color.pink.opacity(0.5))
                                .frame(width: c_todayCals, height: c_todayCals)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            
                            
                            Circle()
                                .stroke(style: StrokeStyle(lineWidth: 2))
                                .foregroundStyle(Color.red)
                                .frame(width: c_goal, height: c_goal)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    }
                }
                
                if(entry.aplGoal > entry.todaysMinCalsGoal){
                    VStack {
                        Text("")
                        Text("\(entry.todaysCals) / \(entry.aplGoal)")
                        
                        Text("ø \(entry.avgCals) / \(entry.goal)")
                            .font(.caption2)
                        Text(" ")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    
                }else{
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
    KcaliEntry(date: .now,
               aplGoal: 555,
               minCals: 666,
               avgCals: 999,
               goal: 888,
               todaysCals: 666,
               todaysMinCalsGoal: 555)
}

