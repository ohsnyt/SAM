//
//  LensPickerView.swift
//  SAM
//
//  Floating overlay shown above the graph canvas when no lens is active.
//  Presents the four lens cards in a 2×2 grid; tapping a card asks the
//  coordinator to load that lens.
//

import SwiftUI

struct LensPickerView: View {

    @Bindable var coordinator: RelationshipGraphCoordinator
    var canvasSize: CGSize
    var onPickLens: (GraphLens) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Pick a lens")
                    .samFont(.title2, weight: .semibold)
                Text("Each lens shows a focused view of your network — pick the question you want answered.")
                    .samFont(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(GraphLens.allCases) { lens in
                    LensCard(lens: lens) { onPickLens(lens) }
                }
            }
            .frame(maxWidth: 720)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .padding(40)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct LensCard: View {
    let lens: GraphLens
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: lens.systemImage)
                        .font(.title2)
                        .foregroundStyle(lens.accentColor)
                        .frame(width: 32, height: 32)
                        .background(lens.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lens.title)
                            .samFont(.body, weight: .semibold)
                        Text(lens.subtitle)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(lens.description)
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovering ? lens.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: isHovering ? 1.2 : 0.5)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(lens.title). \(lens.subtitle)")
        .accessibilityHint(lens.description)
    }
}
