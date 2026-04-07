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
                Text("Willkommen bei\nkcaliflow")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("Weniger Druck. Mehr Freiheit.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("kcaliflow berechnet einen gewichteten Rollendurchschnitt deiner aktiven Kalorien. Du musst nicht jeden Tag Bestleistung bringen – verbrenne heute mehr, und morgen darfst du weniger.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            nextButton(label: "Weiter") { page = 1 }
        }
        .padding(.horizontal)
        .padding(.bottom, 70)
    }

    // MARK: – Page 2: Goal setup

    private var goalPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {

                    Text("Dein Ziel")
                        .font(.largeTitle.bold())

                    Text("Lege fest, wie viele kcal du im Durchschnitt pro Tag verbrennen möchtest.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Text("Kalorienziel:")
                        TextField("500", value: $pf.goal, format: .number)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Stepper("", value: $pf.goal, in: 0...5000, step: 5)
                            .labelsHidden()
                    }

                    Stepper(
                        "Durchschnitt aus \(pf.rollingDays) Tagen",
                        value: $pf.rollingDays,
                        in: 2...pf.maxDays
                    )
                }
                .padding()
                .background(.quaternary)
                .cornerRadius(12)

                infoCard(icon: "info.circle", iconColor: .accentColor, title: "Wie funktioniert das?") {
                    Text("Dein Ziel ist ein **Durchschnittswert** über mehrere Tage – kein tägliches Pflichtpensum. Wenn du heute 1'000 kcal verbrennst und dein Ziel 500 kcal ist, kannst du morgen 0 kcal erreichen und liegst trotzdem im Schnitt.")
                    Text("Das Besondere: Ältere Tage zählen weniger. Je weiter ein Tag zurückliegt, desto geringer sein Einfluss auf deinen aktuellen Durchschnitt. Der Effekt von heute **verblasst mit der Zeit** – und gibt dir immer schneller wieder Spielraum.")
                }
                Spacer()

                nextButton(label: "Weiter") { page = 2 }
            }
            .padding(.horizontal)
        }
    }

    // MARK: – Page 3: Apple Fitness

    private var appleFitnessPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {

                    Text("Apple Fitness Ziel")
                        .font(.largeTitle.bold())

                    Text("Damit deine Fitness-Streaks nicht reissen.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                infoCard(icon: "star.fill", iconColor: .pink, title: "Warum brauchst du das?") {
                    Text("Die Fitness-App misst täglich, ob du dein Bewegungsziel erreichst – das ist die Grundlage für deine Streaks. kcaliflow zeigt dir, wie viel du **heute mindestens** verbrennen solltest, damit dein gewichteter Durchschnitt stimmt.")
                }

                infoCard(icon: "lock.fill", iconColor: .secondary, title: "Warum kann kcaliflow das nicht automatisch setzen?") {
                    Text("Apple erlaubt Apps leider nicht, das Bewegungsziel in der Fitness-App automatisch zu verändern. Du musst es dort manuell anpassen.")
                }

                infoCard(icon: "lightbulb.fill", iconColor: .secondary, title: "Unsere Empfehlung") {
                    Text("Setze das Ziel auf eine Zahl, die du **an einem normalen Tag** in der Regel erreichst. An Ausnahmetagen – zum Beispiel einem Ruhetag – kannst du das Ziel in der Fitness-App für genau diesen Tag manuell nach unten korrigieren.")
                }

                nextButton(label: "Los geht's!") {
                    hasCompletedOnboarding = true
                }
            }
            .padding(.horizontal)
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

    private func nextButton(label: String, action: @escaping () -> Void) -> some View {
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
