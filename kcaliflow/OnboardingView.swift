//
//  OnboardingView.swift
//  kcaliflow
//
//  Created by René Jossen on 07.04.2026.
//

import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @EnvironmentObject private var pf: PFHealth

    @State private var page = 0
    #if os(iOS)
    @FocusState private var goalFieldFocused: Bool
    #endif

    var body: some View {
        TabView(selection: $page) {
            welcomePage.tag(0)
            goalPage.tag(1)
            appleFitnessPage.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: – Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Text("onboarding_welcome_title")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("onboarding_welcome_tagline")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("onboarding_welcome_body")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            nextButton(label: String(localized: "onboarding_btn_next")) {
                page = 1
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 70)
    }

    // MARK: – Page 2: Goal setup

    private var goalPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("onboarding_goal_title")
                            .font(.largeTitle.bold())

                        Text("onboarding_goal_subtitle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 16) {
                        Picker(String(localized: "setting_tracking_mode"), selection: $pf.trackingMode) {
                            Text(String(localized: "mode_calories")).tag(TrackingMode.calories)
                            Text(String(localized: "mode_steps")).tag(TrackingMode.steps)
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Text(pf.trackingMode == .steps
                                 ? String(localized: "setting_goal_steps")
                                 : String(localized: "setting_goal_kcal"))
                            TextField(
                                pf.trackingMode == .steps ? "10000" : "500",
                                value: $pf.goal,
                                format: .number
                            )
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            .focused($goalFieldFocused)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button(
                                        String(
                                            localized: "button_done"
                                        )
                                    ) {
                                        goalFieldFocused = false
                                    }
                                }
                            }
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            Stepper(
                                "",
                                value: $pf.goal,
                                in: pf.trackingMode == .steps ? 0...50000 : 0...5000,
                                step: pf.trackingMode == .steps ? 500 : 5
                            )
                            .labelsHidden()
                        }

                        Stepper(
                            String(localized: "setting_avg_days")
                                .replacingOccurrences(
                                    of: "{days}",
                                    with: "\(pf.rollingDays)"
                                ),
                            value: $pf.rollingDays,
                            in: 2...pf.maxDays
                        )
                    }
                    .padding()
                    .background(.quaternary)
                    .cornerRadius(12)

                    infoCard(
                        icon: "info.circle",
                        iconColor: .accentColor,
                        title: String(
                            localized: "onboarding_goal_how_title"
                        )
                    ) {
                        Text("onboarding_goal_how_body_1")
                        Text("onboarding_goal_how_body_2")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 24)
            }

            nextButton(label: String(localized: "onboarding_btn_next")) {
                page = 2
            }
            .padding(.horizontal)
            .padding(.bottom, 70)
            .padding(.top, 12)
        }
    }

    // MARK: – Page 3: Apple Fitness

    private var appleFitnessPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("onboarding_fitness_title")
                            .font(.largeTitle.bold())

                        Text("onboarding_fitness_subtitle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    infoCard(
                        icon: "star.fill",
                        iconColor: .pink,
                        title: String(
                            localized: "onboarding_fitness_why_title"
                        )
                    ) {
                        Text("onboarding_fitness_why_body")
                    }

                    infoCard(
                        icon: "lock.fill",
                        iconColor: .secondary,
                        title: String(
                            localized: "onboarding_fitness_lock_title"
                        )
                    ) {
                        Text("onboarding_fitness_lock_body")
                    }

                    infoCard(
                        icon: "lightbulb.fill",
                        iconColor: .secondary,
                        title: String(
                            localized: "onboarding_fitness_tip_title"
                        )
                    ) {
                        Text("onboarding_fitness_tip_body")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 24)
            }

            nextButton(
                label: String(localized: "onboarding_btn_start")
            ) {
                hasCompletedOnboarding = true
            }
            .padding(.horizontal)
            .padding(.bottom, 70)
            .padding(.top, 12)
        }
    }

    // MARK: – Helpers

    @ViewBuilder
    private func infoCard<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(iconColor)
            content()
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary)
        .cornerRadius(12)
    }

    private func nextButton(
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation { action() }
        } label: {
            Text(label)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .cornerRadius(14)
        }
    }
}
