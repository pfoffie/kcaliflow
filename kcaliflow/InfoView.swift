//
//  InfoView.swift
//  kcaliflow
//
//  Created by René Jossen on 08.04.2026.
//

import SwiftUI

struct InfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    infoCard(
                        icon: "chart.line.uptrend.xyaxis",
                        iconColor: .accentColor,
                        title: String(localized: "info_page_concept_title")
                    ) {
                        Text("info_page_concept_body")
                    }

                    infoCard(
                        icon: "chart.xyaxis.line",
                        iconColor: .yellow,
                        title: String(localized: "info_page_chart_title")
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(String(localized: "info_page_chart_calories"), systemImage: "triangle.fill")
                                .foregroundStyle(Color.yellow)
                            Label(String(localized: "info_page_chart_min"), systemImage: "square.fill")
                                .foregroundStyle(Color.pink)
                            Label(String(localized: "info_page_chart_avg"), systemImage: "circle.fill")
                                .foregroundStyle(Color.green)
                        }
                        .font(.body)
                        Text("info_page_chart_body")
                            .foregroundStyle(.secondary)
                    }

                    infoCard(
                        icon: "scope",
                        iconColor: .pink,
                        title: String(localized: "info_page_min_title")
                    ) {
                        Text("info_page_min_body")
                    }

                    infoCard(
                        icon: "slider.horizontal.3",
                        iconColor: .secondary,
                        title: String(localized: "info_page_settings_title")
                    ) {
                        Text("info_page_settings_body")
                    }

                    infoCard(
                        icon: "figure.run.circle",
                        iconColor: .green,
                        title: String(localized: "info_page_fitness_title")
                    ) {
                        Text("info_page_fitness_body")
                    }
                }
                .padding()
            }
            .navigationTitle(String(localized: "info_page_nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "button_done")) { dismiss() }
                }
            }
        }
    }

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
}

#Preview {
    InfoView()
}
