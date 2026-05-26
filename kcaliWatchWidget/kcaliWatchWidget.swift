//
//  kcaliWatchWidget.swift
//  kcaliWatchWidget
//
//  Created by Rene Jossen on 26.05.2026.
//

import WidgetKit
import SwiftUI

private struct WatchCircularComplicationView: View {
    let entry: KcaliEntry

    private var rings: [SharedRing] {
        generateWidgetRings(from: entry, usesStandHourGoalHighlight: false)
    }

    var body: some View {
        GeometryReader { geometry in
            let anchor = (geometry.size.width + geometry.size.height) / 2.6

            ZStack {
                // watchOS complications use a tighter ring layout than the iOS widgets.
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position

                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                    }
                }

                if entry.todaysCals < entry.primaryTarget {
                    VStack(spacing: 1) {
                        if !entry.isSteps && entry.aplGoal > entry.todaysMinCalsGoal {
                            Text("")
                                .font(.caption2)
                        }
                        Text("\(entry.primaryTarget - entry.todaysCals)")
                            .font(.caption2)
                    }
                }

                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3))
                    .foregroundStyle(entry.stoodThisHour ? Color.blue.opacity(0.5) : Color.white.opacity(0.18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WatchRectangularComplicationView: View {
    let entry: KcaliEntry

    private var rings: [SharedRing] {
        generateWidgetRings(from: entry, usesStandHourGoalHighlight: false)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                GeometryReader { geometry in
                    let innerWidth = max(geometry.size.width * 0.7, 0)

                    ForEach(rings) { ring in
                        let diameter = innerWidth * ring.position

                        if ring.type == .line {
                            Rectangle()
                                .fill(ring.color)
                                .frame(width: 2)
                                .position(x: diameter, y: geometry.size.height / 2)
                        } else {
                            Rectangle()
                                .fill(ring.color)
                                .frame(width: diameter)
                        }
                    }
                }
                .clipShape(Capsule())

                Capsule()
                    .stroke(Color.black.opacity(0.5), lineWidth: 10)
                Capsule()
                    .stroke(Color.black.opacity(0.78), lineWidth: 6)
                Capsule()
                    .stroke(entry.stoodThisHour ? Color.blue : Color.white.opacity(0.18), lineWidth: 2)
            }
            .frame(height: 30)

            HStack {
                if !entry.isSteps && entry.aplGoal > entry.todaysMinCalsGoal {
                    Text("")
                }

                Text("\(entry.todaysCals) / \(entry.primaryTarget)")
                Text("ø \(entry.avgCals) / \(entry.goal)")
            }
            .font(.system(size: 10))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct WatchCornerComplicationView: View {
    let entry: KcaliEntry

    private var rings: [SharedRing] {
        generateWidgetRings(from: entry, usesStandHourGoalHighlight: false)
    }

    var body: some View {
        GeometryReader { geometry in
            let anchor = (geometry.size.width + geometry.size.height) / 2.6

            ZStack {
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position

                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .widgetLabel {
            if entry.todaysCals < entry.primaryTarget {
                let icon = entry.stoodThisHour ? "◉" : "◎"
                let appleMarker = (!entry.isSteps && entry.aplGoal > entry.todaysMinCalsGoal) ? " " : ""
                Text("\(icon) \(entry.primaryTarget - entry.todaysCals)\(appleMarker)")
            } else {
                Text(entry.stoodThisHour ? "●" : "◉")
            }
        }
    }
}

private struct WatchInlineComplicationView: View {
    let entry: KcaliEntry

    var body: some View {
        if entry.todaysCals < entry.primaryTarget {
            let icon = entry.stoodThisHour ? "◉" : "◎"
            let appleMarker = (!entry.isSteps && entry.aplGoal > entry.todaysMinCalsGoal) ? " " : ""
            Text("\(icon) \(entry.primaryTarget - entry.todaysCals)\(appleMarker)")
        } else {
            Text(entry.stoodThisHour ? "●" : "◉")
        }
    }
}

private struct WatchWidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KcaliEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                WatchCircularComplicationView(entry: entry)
            case .accessoryRectangular:
                WatchRectangularComplicationView(entry: entry)
            case .accessoryCorner:
                WatchCornerComplicationView(entry: entry)
            case .accessoryInline:
                WatchInlineComplicationView(entry: entry)
            default:
                WatchRectangularComplicationView(entry: entry)
            }
        }
        .modifier(WatchWidgetBackgroundModifier())
    }
}

private struct WatchWidgetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOSApplicationExtension 10.0, *) {
            content.containerBackground(for: .widget) { Color.clear }
        } else {
            content.background()
        }
    }
}

struct kcaliWatchWidget: Widget {
    let kind: String = "kcaliWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KcaliTimelineProvider()) { entry in
            WatchWidgetRootView(entry: entry)
        }
        .configurationDisplayName("kcaliflow")
        .description(String(localized: "info_widget_description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}
