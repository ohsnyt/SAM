//
//  PromptLabView.swift
//  SAM
//
//  Created on March 9, 2026.
//  Prompt Lab — Side-by-side prompt variant comparison interface.
//

import SwiftUI
import UniformTypeIdentifiers

struct PromptLabView: View {

    @State private var coordinator = PromptLabCoordinator.shared
    @State private var selectedSite: PromptSite = .noteAnalysis
    @State private var sampleInput: String = PromptSite.noteAnalysis.sampleInput
    @State private var showInputEditor = true
    @State private var showAddVariant = false
    @State private var newVariantName = ""
    @State private var showImportResult = false
    @State private var importResultMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                inputPanel
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                comparisonPanel
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            coordinator.ensureDefaultVariant(for: selectedSite)
        }
        .onChange(of: selectedSite) { _, newSite in
            sampleInput = newSite.sampleInput
            coordinator.ensureDefaultVariant(for: newSite)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Site picker
            Picker("Prompt Site", selection: $selectedSite) {
                ForEach(PromptSite.allCases) { site in
                    Label(site.rawValue, systemImage: site.icon)
                        .tag(site)
                }
            }
            .frame(width: 200)

            Text(selectedSite.outputFormat)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Spacer()

            // Add variant
            Button {
                let variants = coordinator.variants(for: selectedSite)
                newVariantName = "Variant \(variants.count)"
                showAddVariant = true
            } label: {
                Label("Add Variant", systemImage: "plus")
            }
            .popover(isPresented: $showAddVariant) {
                addVariantPopover
            }

            // Run all
            Button {
                Task {
                    await coordinator.runAll(site: selectedSite, input: sampleInput)
                }
            } label: {
                if coordinator.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("Running...")
                } else {
                    Label("Run All", systemImage: "play.fill")
                }
            }
            .disabled(coordinator.isRunning || coordinator.variants(for: selectedSite).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)

            // Import from registry
            Button {
                importFromRegistry()
            } label: {
                Label("Import Registry", systemImage: "square.and.arrow.down")
            }
            .disabled(coordinator.isRunning)
            .alert("Registry Import", isPresented: $showImportResult) {
                Button("OK") {}
            } message: {
                Text(importResultMessage)
            }

            // Clear runs
            Button {
                coordinator.clearRuns(for: selectedSite)
            } label: {
                Label("Clear Results", systemImage: "trash")
            }
            .disabled(coordinator.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Registry Import

    private func importFromRegistry() {
        let panel = NSOpenPanel()
        panel.title = "Import Prompt Registry"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Users/david/Swift/SAM/sam-prompt-research/data/prompt_registry")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try coordinator.importFromRegistry(at: url)
            var message = "Imported \(result.imported) variant(s) from registry v\(result.registryVersion)."
            if result.skipped > 0 {
                message += "\nSkipped \(result.skipped) already-imported variant(s)."
            }
            if !result.unrecognizedSites.isEmpty {
                message += "\nUnrecognized sites: \(result.unrecognizedSites.joined(separator: ", "))"
            }
            importResultMessage = message
            showImportResult = true

            // Refresh the current site's default variant
            coordinator.ensureDefaultVariant(for: selectedSite)
        } catch {
            importResultMessage = "Import failed: \(error.localizedDescription)"
            showImportResult = true
        }
    }

    // MARK: - Input Panel (left side)

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Sample Input", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button {
                    sampleInput = selectedSite.sampleInput
                } label: {
                    Text("Reset")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Site description
            Text(selectedSite.siteDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            // Input editor
            TextEditor(text: $sampleInput)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)

            if let error = coordinator.lastError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        coordinator.lastError = nil
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(.orange.opacity(0.1))
            }
        }
    }

    // MARK: - Comparison Panel (right side, scrollable columns)

    private var comparisonPanel: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 1) {
                let variants = coordinator.variants(for: selectedSite)
                ForEach(variants) { variant in
                    PromptLabColumnView(
                        variant: variant,
                        site: selectedSite,
                        sampleInput: $sampleInput,
                        coordinator: coordinator
                    )
                    .frame(minWidth: 350, idealWidth: 420, maxWidth: 500)
                    if variant.id != variants.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Add Variant Popover

    private var addVariantPopover: some View {
        VStack(spacing: 12) {
            Text("New Variant")
                .font(.headline)

            TextField("Variant name", text: $newVariantName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack {
                Button("From Default") {
                    coordinator.addVariant(
                        for: selectedSite,
                        name: newVariantName,
                        systemInstruction: coordinator.defaultPrompt(for: selectedSite)
                    )
                    showAddVariant = false
                }

                Button("Empty") {
                    coordinator.addVariant(
                        for: selectedSite,
                        name: newVariantName,
                        systemInstruction: ""
                    )
                    showAddVariant = false
                }
            }
        }
        .padding()
    }
}

// MARK: - Column View

struct PromptLabColumnView: View {

    let variant: PromptVariant
    let site: PromptSite
    @Binding var sampleInput: String
    let coordinator: PromptLabCoordinator

    @State private var editedPrompt: String = ""
    @State private var showPrompt = false

    private var latestRun: PromptTestRun? {
        coordinator.latestRun(for: variant.id)
    }

    private var isRunning: Bool {
        coordinator.runningVariantIDs.contains(variant.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
            Divider()
            promptSection
            Divider()
            outputSection
        }
        .background(backgroundColor)
    }

    // MARK: - Header

    private var columnHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Name and badges
                if variant.isDefault {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(variant.name)
                    .font(.headline)
                    .lineLimit(1)

                if coordinator.isDeployed(variant, for: site) {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                }

                Spacer()

                // Actions menu
                Menu {
                    Button("Run This Variant") {
                        Task {
                            await coordinator.runSingle(variant: variant, site: site, input: sampleInput)
                        }
                    }
                    .disabled(isRunning)

                    Button("Duplicate") {
                        coordinator.duplicateVariant(variant, for: site)
                    }

                    Divider()

                    Button("Deploy as Active") {
                        coordinator.deployVariant(variant, for: site)
                    }

                    if !variant.isDefault {
                        Divider()
                        Button("Delete", role: .destructive) {
                            coordinator.deleteVariant(variant, for: site)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            // Rating picker
            HStack(spacing: 4) {
                ForEach(VariantRating.allCases, id: \.self) { rating in
                    Button {
                        coordinator.rateVariant(variant, rating: rating, for: site)
                    } label: {
                        Image(systemName: rating.icon)
                            .font(.caption)
                            .foregroundStyle(ratingColor(rating))
                    }
                    .buttonStyle(.plain)
                    .help(rating.label)
                    .opacity(variant.rating == rating ? 1.0 : 0.3)
                }

                if variant.rating != .unrated {
                    Text(variant.rating.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Prompt Section (collapsible)

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPrompt.toggle()
                }
                if showPrompt {
                    editedPrompt = variant.systemInstruction
                }
            } label: {
                HStack {
                    Image(systemName: showPrompt ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("System Instruction")
                        .font(.caption.bold())
                    if !variant.isDefault {
                        Text("(editable)")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Text("(\(variant.systemInstruction.count) chars)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showPrompt {
                if variant.isDefault {
                    // Default variant — read-only
                    ScrollView {
                        Text(variant.systemInstruction)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                } else {
                    // Custom variant — always editable
                    VStack(spacing: 4) {
                        TextEditor(text: $editedPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120, maxHeight: 300)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(hasUnsavedChanges ? Color.blue : Color.clear, lineWidth: 1)
                            )

                        HStack {
                            if hasUnsavedChanges {
                                Text("Unsaved changes")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }

                            Spacer()

                            if hasUnsavedChanges {
                                Button("Revert") {
                                    editedPrompt = variant.systemInstruction
                                }
                                .font(.caption)

                                Button("Save") {
                                    var updated = variant
                                    updated.systemInstruction = editedPrompt
                                    coordinator.updateVariant(updated, for: site)
                                }
                                .font(.caption)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        editedPrompt != variant.systemInstruction
    }

    // MARK: - Output Section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Output header
            HStack {
                Text("Output")
                    .font(.caption.bold())

                if let run = latestRun {
                    Text(String(format: "%.1fs", run.durationSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("via \(run.backend)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let run = latestRun {
                    Button {
                        ClipboardSecurity.copyPersistent(run.output)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy output")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Output content
            if isRunning {
                VStack {
                    ProgressView()
                        .padding()
                    Text("Generating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let run = latestRun {
                ScrollView {
                    Text(run.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            } else {
                VStack {
                    Image(systemName: "play.circle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No results yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Click Run All or use the menu")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Helpers

    private var backgroundColor: Color {
        switch variant.rating {
        case .winner:   return Color.yellow.opacity(0.05)
        case .good:     return Color.green.opacity(0.04)
        case .rejected: return Color.red.opacity(0.04)
        default:        return Color.clear
        }
    }

    private func ratingColor(_ rating: VariantRating) -> Color {
        switch rating {
        case .unrated:  return .secondary
        case .winner:   return .yellow
        case .good:     return .green
        case .neutral:  return .gray
        case .poor:     return .orange
        case .rejected: return .red
        }
    }
}
