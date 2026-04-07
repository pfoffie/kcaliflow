//
//  ContentView.swift
//  kcaliflow
//
//  Created by René Jossen on 21.10.2025.
//

import SwiftUI
import Charts


struct ContentView: View {
    @StateObject private var pf = PFHealth()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDay: Day? = nil
    @State private var tooltipPos: CGPoint = .zero
    
    var body: some View {
        
        
        let styleScaleDomains = ["Kalorien", "Minimum Heute" , "Durchschnittsziel"]
        let styleScaleRanges = [Color.yellow, Color.pink, Color.green]
        
        let allY = pf.days.map(\.cals) + [pf.goal, pf.todaysMinCalsGoal]
        let minY = Double(allY.min() ?? 0)
        let maxY = Double(allY.max() ?? 1)
        let pad  = max(10, (maxY - minY) * 0.1)   // 10 als Mindest-Puffer

        let lower: Int = Int(max(0, minY - pad))            // wenn du nie < 0 willst
        let upper: Int = Int(maxY + pad)
                
        VStack(spacing: 16) {
            
            
            VStack(spacing: 0) {
                if(pf.todaysCals < pf.todaysMinCalsGoal) {
                    Text(
                        String(localized: "info_rest_kcal")
                        .replacingOccurrences(of: "{kcal}", with: "\(pf.todaysMinCalsGoal - pf.todaysCals)")
                    )
                    .font(.title)
                    
                    Text(
                        String(localized: "info_made_kcal_sofar")
                        .replacingOccurrences(of: "{kcal}", with: "\(pf.todaysCals)")
                    )
                }else{
                    Text(
                        String(localized: "info_made_kcal")
                        .replacingOccurrences(of: "{kcal}", with: "\(pf.todaysCals)")
                    )
                        .font(.title)
                }
            
                Text(
                    String(localized: "info_goal_today")
                    .replacingOccurrences(of: "{kcal}", with: "\(pf.todaysMinCalsGoal)")
                )
                Text(
                    String(localized: "info_curr_average")
                    .replacingOccurrences(of: "{kcal}", with: "\(pf.avgCals)")
                )
            }
            
            
            ZStack {
                // Inner compositing group: chart + right-fade gradient
                ZStack {
                    Chart {
                        if(pf.aplGoal > lower){
                            RectangleMark(
                                yStart: .value("Baseline", lower),
                                yEnd:   .value("Minimum Heute", pf.aplGoal)
                            )
                            .foregroundStyle(Color.red.opacity(0.3))
                        }

                        // Durchschnittsziel
                        RuleMark(y: .value("Durchschnittsziel", pf.goal))
                            .symbol(by: .value("Serie", "Durchschnittsziel"))
                            .foregroundStyle(by: .value("Serie", "Durchschnittsziel"))

                        // Minimum Heute
                        RuleMark(y: .value("Minimum Heute", pf.todaysMinCalsGoal))
                            .lineStyle(.init(lineWidth: 1))
                            .symbol(by: .value("Serie", "Minimum Heute"))
                            .foregroundStyle(by: .value("Serie", "Minimum Heute"))

                        // Pink gradient band spanning full chart width
                        RectangleMark(
                            yStart: .value("Baseline", lower),
                            yEnd:   .value("Minimum Heute", pf.todaysMinCalsGoal)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.pink.opacity(0.55), .pink.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        // Kalorien
                        ForEach (pf.days) { day in
                            LineMark(
                                x: .value("Tag", day.day),
                                y: .value("Kalorien", day.cals)
                            )
                            .symbol(by: .value("Serie", "Kalorien"))
                            .foregroundStyle(by: .value("Serie", "Kalorien"))
                            .interpolationMethod(.monotone)
                        }

                        // Selected day dot (no annotation — tooltip is rendered outside compositingGroup)
                        if let sel = selectedDay {
                            PointMark(
                                x: .value("Tag", sel.day),
                                y: .value("Kalorien", sel.cals)
                            )
                            .foregroundStyle(Color.yellow)
                        }
                    }
                    .frame(height: 200)
                    .padding(.horizontal, -16)
                    .chartYScale(domain: lower...upper)
                    .chartXScale(range: .plotDimension(padding:30))
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartForegroundStyleScale(
                        domain: styleScaleDomains,
                        range: styleScaleRanges
                    )
                    .chartLegend(spacing: 8)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    let origin = geo[proxy.plotFrame!].origin
                                    let relativeX = location.x - origin.x
                                    if let dayVal: Int = proxy.value(atX: relativeX, as: Int.self) {
                                        let nearest = pf.days.min(by: { abs($0.day - dayVal) < abs($1.day - dayVal) })
                                        guard let nearest else { return }
                                        if selectedDay?.id == nearest.id {
                                            withAnimation(.easeInOut(duration: 0.15)) { selectedDay = nil }
                                        } else {
                                            if let xp = proxy.position(forX: nearest.day),
                                               let yp = proxy.position(forY: nearest.cals) {
                                                tooltipPos = CGPoint(x: origin.x + xp, y: origin.y + yp)
                                            }
                                            withAnimation(.easeInOut(duration: 0.15)) { selectedDay = nearest }
                                        }
                                    }
                                }
                        }
                    }

                    // Gradient covers full chart height
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.00), location: 0.00),
                            .init(color: .white.opacity(0.30), location: 0.20),
                            .init(color: .white.opacity(0.60), location: 0.50),
                            .init(color: .white.opacity(0.85), location: 1.00)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .blendMode(.destinationOut)
                    .allowsHitTesting(false)
                    .frame(height: 200)
                    .padding(.horizontal, -16)
                }
                .compositingGroup()

                // Tooltip rendered outside compositingGroup — unaffected by the fade gradient
                if let sel = selectedDay {
                    let date = Calendar.current.date(byAdding: .day, value: -sel.day, to: Date()) ?? Date()
                    VStack(spacing: 2) {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                        Text("\(sel.cals) kcal")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.yellow.opacity(0.9))
                    .foregroundColor(.black)
                    .cornerRadius(4)
                    .position(x: tooltipPos.x, y: max(24, tooltipPos.y - 40))
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 200)
            .overlay {
                if pf.isLoading && pf.days.isEmpty {
                    ProgressView()
                }
            }
            
            HStack(spacing: 12) {
                
                Text(String(localized: "setting_goal_kcal"))
                
                TextField(String(localized: "setting_goal_kcal"), value: $pf.goal, format: .number)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                
                Stepper(String(localized: "setting_goal_kcal"),
                        value: $pf.goal,
                        in: 0...5000,
                        step: 5)
                .labelsHidden()
                
            }
            
            Stepper(String(localized: "setting_avg_days")
                        .replacingOccurrences(of: "{days}", with: "\(pf.rollingDays)"),
                    value: $pf.rollingDays,
                    in: 2...pf.maxDays,
                    step: 1)
        
            Text(String(localized: "note_apple_fitness")
                .replacingOccurrences(of: "{goal}", with: "\(pf.aplGoal)")
                .replacingOccurrences(of: "{min}", with: "\(pf.minCals)"))
                .font(.footnote)
        }
        .padding()
        .task {
            do {
                try await pf.requestAuthorization()
                await pf.loadFromHealthKit()
            } catch {
                print("HealthKit-Fehler:", error.localizedDescription)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await pf.loadFromHealthKit() }
            }
        }
        
    }
}

#Preview {
    ContentView()
}

