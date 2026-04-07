//
//  kcaliflowApp.swift
//  kcaliflow
//
//  Created by René Jossen on 21.10.2025.
//

import SwiftUI

@main
struct kcaliflowApp: App {
    @StateObject private var pf = PFHealth()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environmentObject(pf)
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                    .environmentObject(pf)
            }
        }
    }
}
