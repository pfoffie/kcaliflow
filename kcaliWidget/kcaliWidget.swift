//
//  kcaliWidget.swift
//  kcaliWidget
//
//  Created by Rene Jossen on 22.10.2025.
//

import WidgetKit
import SwiftUI

private struct IOSHomeWidgetView: View {
    let entry: KcaliEntry

    private var rings: [SharedRing] {
        generateWidgetRings(from: entry)
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let anchor = (geometry.size.width + geometry.size.height) / 2

                // The iOS home widget keeps the larger, information-dense layout.
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position

                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 2))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                }

                VStack {
                    
                    if(entry.primaryTarget == entry.aplGoal && entry.primaryTarget > entry.todaysCals){
                        Text("")
                    }
                    Text("\(entry.todaysCals) / \(entry.primaryTarget)")
                    Text("ø \(entry.avgCals) / \(entry.goal)")
                        .font(.caption2)
                    if(entry.primaryTarget == entry.aplGoal && entry.primaryTarget > entry.todaysCals){
                        Text(" ")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

private struct IOSCircularAccessoryView: View {
    let entry: KcaliEntry

    private var rings: [SharedRing] {
        generateWidgetRings(from: entry)
    }

    var body: some View {
        GeometryReader { geometry in
            let anchor = (geometry.size.width + geometry.size.height) / 2.8

            ZStack {
                ForEach(rings) { ring in
                    let diameter = anchor * ring.position

                    if ring.type == .line {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1.2))
                            .foregroundStyle(ring.color)
                            .frame(width: diameter, height: diameter)
                    } else {
                        Circle()
                            .fill(ring.color)
                            .frame(width: diameter, height: diameter)
                    }
                }

                Text("\(max(entry.primaryTarget - entry.todaysCals, 0))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct IOSRectangularAccessoryView: View {
    let entry: KcaliEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.isSteps ? "Steps" : "Calories")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(entry.todaysCals) / \(entry.primaryTarget)")
                .font(.headline)
            Text("ø \(entry.avgCals) / \(entry.goal)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct IOSInlineAccessoryView: View {
    let entry: KcaliEntry

    var body: some View {
        Text("\(entry.todaysCals) / \(entry.primaryTarget) \(entry.unitLabel)")
    }
}

private struct IOSWidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KcaliEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                IOSCircularAccessoryView(entry: entry)
            case .accessoryRectangular:
                IOSRectangularAccessoryView(entry: entry)
            case .accessoryInline:
                IOSInlineAccessoryView(entry: entry)
            default:
                IOSHomeWidgetView(entry: entry)
            }
        }
        .modifier(WidgetBackgroundModifier(family: family))
    }
}

private struct WidgetBackgroundModifier: ViewModifier {
    let family: WidgetFamily

    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            switch family {
            case .systemSmall:
                content.containerBackground(.fill.tertiary, for: .widget)
            default:
                content.containerBackground(for: .widget) { Color.clear }
            }
        } else {
            content
                .padding(family == .systemSmall ? 0 : 0)
                .background()
        }
    }
}

struct kcaliWidget: Widget {
    let kind: String = "kcaliWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KcaliTimelineProvider()) { entry in
            IOSWidgetRootView(entry: entry)
        }
        .configurationDisplayName("kcaliflow")
        .description(String(localized: "info_widget_description"))
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Xcode Previews
// ---------------------------------------------------------------------------
// One #Preview block per supported widget family so the Xcode canvas shows
// each surface individually.  Two data variants (calories / steps) are added
// for the most information-dense families so edge-cases are visible at a glance.
// All preview code is stripped from release builds by the #if DEBUG guard.
// ---------------------------------------------------------------------------

#if DEBUG

// ── System Small ────────────────────────────────────────────────────────────

/// Home-screen small widget in calories mode — the "normal" in-progress state.
#Preview("Small · Calories", as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewCalories
}

/// Home-screen small widget after the daily goal has been reached.
#Preview("Small · Calories (complete)", as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewCaloriesComplete
}

/// Home-screen small widget in steps mode.
#Preview("Small · Steps", as: .systemSmall) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewSteps
}

// ── Accessory Circular (Lock Screen / StandBy) ──────────────────────────────

/// Circular lock-screen / StandBy complication in calories mode.
#Preview("Circular · Calories", as: .accessoryCircular) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewCalories
}

/// Circular lock-screen / StandBy complication in steps mode.
#Preview("Circular · Steps", as: .accessoryCircular) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewSteps
}

// ── Accessory Rectangular (Lock Screen / StandBy) ───────────────────────────

/// Rectangular lock-screen complication showing today vs. average in calories mode.
#Preview("Rectangular · Calories", as: .accessoryRectangular) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewCalories
}

/// Rectangular lock-screen complication in steps mode.
#Preview("Rectangular · Steps", as: .accessoryRectangular) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewSteps
}

// ── Accessory Inline (Lock Screen) ──────────────────────────────────────────

/// Single-line inline lock-screen complication in calories mode.
#Preview("Inline · Calories", as: .accessoryInline) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewCalories
}

/// Single-line inline lock-screen complication in steps mode.
#Preview("Inline · Steps", as: .accessoryInline) {
    kcaliWidget()
} timeline: {
    KcaliEntry.previewSteps
}

#endif
