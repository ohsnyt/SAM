//
//  IntroSequenceOverlay.swift
//  SAM
//
//  Phase AB: In-App Guidance — First-launch intro video view
//

import SwiftUI
import AVKit

/// A full intro video shown on first launch after onboarding.
/// Plays a 2:39 video presenting SAM's value proposition, then shows a "Get Started" button.
struct IntroSequenceOverlay: View {

    @State private var coordinator = IntroSequenceCoordinator.shared
    @State private var player: AVPlayer?
    @State private var playerObserver: Any?

    var body: some View {
        ZStack {
            // Video fills the sheet
            if let player {
                VideoPlayer(player: player)
                    .disabled(true) // Prevent user interaction with transport controls
            } else {
                // Fallback if video can't be loaded
                Color.black
                    .overlay {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 128, height: 128)
                    }
            }

            // Overlay controls
            VStack {
                Spacer()

                if coordinator.videoFinished {
                    // "Get Started" button after video ends
                    Button(action: { coordinator.markComplete() }) {
                        Text("Get Started")
                            .fontWeight(.semibold)
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    // Skip button during video playback
                    HStack {
                        Spacer()
                        Button("Skip") {
                            coordinator.skip()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(20)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.4), value: coordinator.videoFinished)
        }
        .frame(minWidth: 756, idealWidth: 882, maxWidth: 1260,
               minHeight: 432, idealHeight: 504, maxHeight: 720)
        .background(.black)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            tearDownPlayer()
        }
    }

    // MARK: - Player Setup

    private func setupPlayer() {
        guard let url = Bundle.main.url(forResource: "SAM_intro_video_hb", withExtension: "mp4") else { return }
        let avPlayer = AVPlayer(url: url)
        player = avPlayer

        // Observe when playback reaches the end
        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                coordinator.videoDidFinish()
            }
        }

        avPlayer.play()
    }

    private func tearDownPlayer() {
        player?.pause()
        if let observer = playerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        playerObserver = nil
        player = nil
    }
}

// MARK: - Preview

#Preview {
    IntroSequenceOverlay()
        .frame(width: 882, height: 504)
}
