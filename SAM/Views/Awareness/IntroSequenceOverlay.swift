//
//  IntroSequenceOverlay.swift
//  SAM
//
//  Phase AB: In-App Guidance — First-launch narrated intro sequence view
//

import SwiftUI

/// A narrated 6-slide intro sequence shown on first launch after onboarding.
/// Presents SAM's core value proposition with synchronized speech narration.
struct IntroSequenceOverlay: View {

    @State private var coordinator = IntroSequenceCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Slide content
            slideContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? .none : .easeInOut(duration: 0.4), value: coordinator.currentSlide)

            Divider()

            // Bottom controls
            bottomBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 550, idealWidth: 650, maxWidth: 750,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
        .background(.ultraThinMaterial)
        .onAppear {
            coordinator.startPlayback()
        }
    }

    // MARK: - Slide Content

    @ViewBuilder
    private var slideContent: some View {
        let slide = coordinator.currentSlide

        VStack(spacing: 20) {
            Spacer()

            // Animated SF Symbol
            Image(systemName: slide.symbolName)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: coordinator.isPlaying && !coordinator.isPaused)
                .id(slide)  // Force symbol recreation for each slide
                .transition(.opacity)

            // Headline
            Text(slide.headline)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .id("headline-\(slide.rawValue)")
                .transition(.opacity)

            // Subtitle
            Text(slide.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .id("subtitle-\(slide.rawValue)")
                .transition(.opacity)

            // "Get Started" button on last slide
            if slide == .getStarted {
                Button(action: { coordinator.markComplete() }) {
                    Text("Get Started")
                        .fontWeight(.semibold)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
                .transition(.opacity)
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Pause/Play button
            Button(action: {
                if coordinator.isPaused {
                    coordinator.resume()
                } else {
                    coordinator.pause()
                }
            }) {
                Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                    .font(.body)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(coordinator.isPaused ? "Resume" : "Pause")

            Spacer()

            // Progress dots
            HStack(spacing: 8) {
                ForEach(IntroSequenceCoordinator.IntroSlide.allCases, id: \.rawValue) { slide in
                    Circle()
                        .fill(slide.rawValue <= coordinator.currentSlide.rawValue
                              ? Color.accentColor
                              : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: coordinator.currentSlide)
                }
            }

            Spacer()

            // Skip button
            if coordinator.currentSlide != .getStarted {
                Button("Skip") {
                    coordinator.skip()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            } else {
                // Invisible placeholder to maintain layout
                Button("Skip") {}
                    .buttonStyle(.borderless)
                    .opacity(0)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    IntroSequenceOverlay()
        .frame(width: 650, height: 500)
}
