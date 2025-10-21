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
                    Text("Noch \(pf.todaysMinCalsGoal - pf.todaysCals) KCAL")
                        .font(.title)
                    
                    Text("Bisher erreicht: \(pf.todaysCals) KCAL")
                }else{
                    Text("\(pf.todaysCals) KCAL geschafft")
                        .font(.title)
                }
            
                Text("Ziel heute: \(pf.todaysMinCalsGoal) KCAL")
                Text("Aktueller Durchschnitt: \(pf.avgCals) KCAL")
            }
            
            
            ZStack{
                Chart {
                    
                    if(pf.aplGoal > lower){
                        RectangleMark(
                            xStart: .value("Start", pf.days.first?.day ?? 0),
                            xEnd:   .value("Ende",  pf.days.last?.day  ?? 0),
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
                    
                    RectangleMark(
                        xStart: .value("Start", pf.days.first?.day ?? 0),
                        xEnd:   .value("Ende",  pf.days.last?.day  ?? 0),
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
                    
                    
                }
                .padding(.trailing, 1)
                .frame(height: 200)
                .chartYScale(domain: lower...upper)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartForegroundStyleScale(
                    domain: styleScaleDomains,
                    range: styleScaleRanges
                )
               
               LinearGradient(
                   gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.00), location: 0.00),
                        .init(color: .white.opacity(0.30), location: 0.20),
                        .init(color: .white.opacity(0.60), location: 0.50),
                        //.init(color: .white.opacity(0.95), location: 1.00)
                        .init(color: .white.opacity(0.85), location: 1.00)
                   ]),
                   startPoint: .leading,
                   endPoint: .trailing
               )
               .blendMode(.destinationOut)
               .frame(height: 175, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            .compositingGroup()
            
            HStack(spacing: 12) {
                
                Text("Kalorienziel:")
                
                TextField("Kalorienziel", value: $pf.goal, format: .number)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                
                Stepper("Kalorienziel",
                        value: $pf.goal,
                        in: 0...5000,
                        step: 5)
                .labelsHidden()
                
            }
            
            Stepper("Durchschnitt aus \(pf.rollingDays) Tagen",
                    value: $pf.rollingDays,
                    in: 2...pf.maxDays,
                    step: 1)
        
            Text(" Fitness Ziel: \(pf.aplGoal) KCAL\nWir empfehlen, das Kalorienziel auf eine Zahl zu setzen, die du immer erreichst. (in deinem Fall \(pf.minCals) KCAL)")
                .font(.footnote)
        }
        .padding()
        .task {
            do {
                NSLog("task -> do")
                try await pf.requestAuthorization()
                await pf.loadFromHealthKit()
            } catch {
                print("HealthKit-Fehler:", error.localizedDescription)
            }
        }
        
    }
}

#Preview {
    ContentView()
}

