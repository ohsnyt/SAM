//
//  IntroSequenceOverlay.swift
//  SAM
//
//  In-App Guidance — 4-page welcome sequence shown on first launch
//

import SwiftUI

/// A 4-page aspirational welcome shown on first launch.
/// Replaces the previous video-only intro with a lighter, faster onboarding.
struct IntroSequenceOverlay: View {

    @State private var coordinator = IntroSequenceCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $coordinator.currentPage) {
                welcomePage.tag(0)
                relationshipsPage.tag(1)
                businessPage.tag(2)
                tipsPage.tag(3)
            }
            .tabViewStyle(.automatic)
            .animation(.easeInOut(duration: 0.3), value: coordinator.currentPage)

            Divider()

            // Navigation controls
            HStack {
                Button("Skip") {
                    coordinator.skip()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                // Page dots
                HStack(spacing: 6) {
                    ForEach(0..<coordinator.pageCount, id: \.self) { page in
                        Circle()
                            .fill(page == coordinator.currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if coordinator.currentPage > 0 {
                        Button {
                            coordinator.previousPage()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        coordinator.nextPage()
                    } label: {
                        if coordinator.currentPage == coordinator.pageCount - 1 {
                            Text("Get Started")
                                .fontWeight(.semibold)
                        } else {
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 420)
        .background(.background)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            Text("SAM helps you build your practice")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text("Your cognitive coaching assistant for relationships and business growth.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Page 2: Relationships

    private var relationshipsPage: some View {
        VStack(spacing: 20) {
            Spacer()

            symbolComposition(
                primary: "person.2.fill",
                secondary: "heart.fill",
                accent: .green
            )

            Text("Your relationships, coached")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("SAM observes your interactions and recommends specific actions for each person — who to follow up with, what to say, and why it matters.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Page 3: Business

    private var businessPage: some View {
        VStack(spacing: 20) {
            Spacer()

            symbolComposition(
                primary: "chart.bar.fill",
                secondary: "arrow.up.right",
                accent: .blue
            )

            Text("Your business, visible")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Pipeline health, production metrics, recruiting progress, and strategic insights — all in one place. SAM connects individual actions to business goals.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Page 4: Tips

    private var tipsPage: some View {
        VStack(spacing: 20) {
            Spacer()

            symbolComposition(
                primary: "lightbulb.fill",
                secondary: "questionmark.circle",
                accent: .orange
            )

            Text("Tips will guide you")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Orange tips appear contextually as you explore SAM's features. Dismiss them when you're ready, or find help anytime in the Help menu.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Helpers

    private func symbolComposition(primary: String, secondary: String, accent: Color) -> some View {
        ZStack {
            Image(systemName: primary)
                .font(.system(size: 48))
                .foregroundStyle(accent)

            Image(systemName: secondary)
                .font(.system(size: 20))
                .foregroundStyle(accent.opacity(0.7))
                .offset(x: 30, y: -20)
        }
        .frame(height: 72)
    }
}

// MARK: - Preview

#Preview {
    IntroSequenceOverlay()
}
