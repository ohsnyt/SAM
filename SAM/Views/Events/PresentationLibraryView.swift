//
//  PresentationLibraryView.swift
//  SAM
//
//  Created on March 11, 2026.
//  Presentation Library — manage reusable presentations for recurring events.
//  Supports drag-and-drop PDF import with automatic content digestion.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TipKit

struct PresentationLibraryView: View {

    @State private var presentations: [SamPresentation] = []
    @State private var selectedPresentationID: UUID?
    @State private var showNewPresentation = false
    @State private var refreshToken = UUID()
    @State private var isDropTargeted = false
    @State private var presentationListWidth: CGFloat = 300
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            presentationList
                .frame(width: presentationListWidth)

            PresentationListDivider(listWidth: $presentationListWidth)

            Group {
                if let id = selectedPresentationID,
                   let presentation = presentations.first(where: { $0.id == id }) {
                    PresentationDetailView(presentation: presentation, onUpdate: { refreshToken = UUID() })
                } else {
                    ContentUnavailableView(
                        "Select a Presentation",
                        systemImage: "doc.richtext",
                        description: Text("Choose a presentation from the list, or drag and drop a PDF here")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showNewPresentation) {
            PresentationFormSheet { presentation in
                selectedPresentationID = presentation.id
                refreshToken = UUID()
            }
        }
        .restoreOnUnlock(isPresented: $showNewPresentation)
        .alert("Delete Presentation?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedPresentation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this presentation? It will be unlinked from any events. This cannot be undone.")
        }
        .dismissOnLock(isPresented: $showDeleteConfirmation)
    }

    // MARK: - List

    private var presentationList: some View {
        VStack(spacing: 0) {
            TipView(PresentationLibraryTip())
                .tipViewStyle(SAMTipViewStyle())
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack {
                Text("Presentations")
                    .samFont(.title2, weight: .bold)
                Spacer()
                if selectedPresentationID != nil {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                Button {
                    showNewPresentation = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ZStack {
                List(selection: $selectedPresentationID) {
                    let items = loadPresentations()
                    if items.isEmpty {
                        ContentUnavailableView(
                            "No Presentations",
                            systemImage: "doc.richtext",
                            description: Text("Drag and drop a PDF here to get started")
                        )
                    } else {
                        ForEach(items, id: \.id) { presentation in
                            PresentationRowView(presentation: presentation)
                                .tag(presentation.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        selectedPresentationID = presentation.id
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete Presentation", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)

                // Drop target overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .samFont(.title)
                                    .foregroundStyle(.blue)
                                Text("Drop to add presentation")
                                    .samFont(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadPresentations() -> [SamPresentation] {
        _ = refreshToken
        let context = SAMModelContainer.newContext()
        let descriptor = FetchDescriptor<SamPresentation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let results = (try? context.fetch(descriptor)) ?? []
        if results != presentations {
            presentations = results
        }
        return results
    }

    // MARK: - Drag & Drop

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf" || url.pathExtension.lowercased() == "pptx" || url.pathExtension.lowercased() == "key"
                else { return }

                Task { @MainActor in
                    createPresentationFromFile(url: url)
                }
            }
        }
    }

    private func deleteSelectedPresentation() {
        guard let id = selectedPresentationID else { return }

        let context = SAMModelContainer.newContext()
        let descriptor = FetchDescriptor<SamPresentation>(
            predicate: #Predicate<SamPresentation> { $0.id == id }
        )
        guard let presentation = try? context.fetch(descriptor).first else { return }

        // Unlink from events
        for event in presentation.linkedEvents {
            event.presentation = nil
        }
        context.delete(presentation)
        try? context.save()

        selectedPresentationID = nil
        refreshToken = UUID()
    }

    private func createPresentationFromFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Create bookmark
        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileName = url.deletingPathExtension().lastPathComponent
        let fileExt = url.pathExtension.lowercased()

        // Derive a title from the filename
        let title = fileName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let file = PresentationFile(
            fileName: url.lastPathComponent,
            fileType: fileExt,
            bookmarkData: bookmarkData,
            fileSizeBytes: resourceValues?.fileSize
        )

        let context = SAMModelContainer.newContext()
        let presentation = SamPresentation(title: title)
        presentation.fileAttachments = [file]
        context.insert(presentation)
        try? context.save()

        selectedPresentationID = presentation.id
        refreshToken = UUID()

        // Kick off background analysis
        Task {
            await PresentationAnalysisCoordinator.shared.analyze(presentation: presentation)
            refreshToken = UUID()
        }
    }
}

// MARK: - Row

struct PresentationRowView: View {
    let presentation: SamPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(presentation.title)
                    .samFont(.headline)
                    .lineLimit(1)
                if presentation.contentSummary == nil && !presentation.fileAttachments.isEmpty {
                    Image(systemName: "sparkles")
                        .samFont(.caption2)
                        .foregroundStyle(.orange)
                        .help("Content not yet analyzed")
                }
            }

            HStack(spacing: 8) {
                if let duration = presentation.estimatedDurationMinutes {
                    Label("\(duration) min", systemImage: "clock")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                if !presentation.topicTags.isEmpty {
                    Text(presentation.topicTags.prefix(3).joined(separator: ", "))
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                let deliveries = presentation.linkedEvents.filter { $0.status == .completed }.count
                if deliveries > 0 {
                    Text("\(deliveries) delivered")
                        .samFont(.caption2)
                        .foregroundStyle(.green)
                }

                if let next = presentation.nextScheduledAt {
                    Text("Next: \(next.formatted(date: .abbreviated, time: .omitted))")
                        .samFont(.caption2)
                        .foregroundStyle(.blue)
                }

                if !presentation.fileAttachments.isEmpty {
                    Label("\(presentation.fileAttachments.count)", systemImage: "paperclip")
                        .samFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct PresentationDetailView: View {
    let presentation: SamPresentation
    let onUpdate: () -> Void
    @State private var isImportingFile = false
    @State private var analysisCoordinator = PresentationAnalysisCoordinator.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title)
                        .samFont(.title2, weight: .bold)

                    if let desc = presentation.presentationDescription {
                        Text(desc)
                            .samFont(.body)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        if let duration = presentation.estimatedDurationMinutes {
                            Label("\(duration) minutes", systemImage: "clock")
                                .samFont(.caption)
                        }
                        if let audience = presentation.targetAudience {
                            Label(audience, systemImage: "person.2")
                                .samFont(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)

                    if !presentation.topicTags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(presentation.topicTags, id: \.self) { tag in
                                Text(tag)
                                    .samFont(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.1), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Divider()

                // Files
                filesSection

                Divider()

                // Content Summary
                contentSummarySection

                Divider()

                // Delivery History
                deliveryHistorySection
            }
            .padding(16)
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.pdf, .presentation],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .dismissOnLock(isPresented: $isImportingFile)
    }

    // MARK: - Files Section

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files")
                    .samFont(.headline)
                Spacer()
                Button {
                    isImportingFile = true
                } label: {
                    Label("Add File", systemImage: "plus")
                        .samFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if presentation.fileAttachments.isEmpty {
                Text("No files attached. Add PDFs or slide decks.")
                    .samFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(presentation.fileAttachments) { file in
                    HStack(spacing: 8) {
                        Image(systemName: fileIcon(for: file.fileType))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(file.fileName)
                                .samFont(.body)
                                .lineLimit(1)
                            Text(file.fileType.uppercased())
                                .samFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let size = file.fileSizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            removeFile(file)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Content Summary Section

    private var contentSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Content Summary")
                    .samFont(.headline)
                Spacer()
                if !presentation.fileAttachments.isEmpty {
                    let isAnalyzing = analysisCoordinator.analysisStatus == .extracting
                        || analysisCoordinator.analysisStatus == .analyzing
                    Button {
                        Task {
                            await PresentationAnalysisCoordinator.shared.analyze(presentation: presentation)
                            onUpdate()
                        }
                    } label: {
                        if isAnalyzing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Analyzing...")
                            }
                        } else {
                            Text(presentation.contentSummary != nil ? "Re-analyze" : "Analyze Content")
                        }
                    }
                    .samFont(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAnalyzing)
                }
            }

            if let summary = presentation.contentSummary {
                Text(summary)
                    .samFont(.body)

                if !presentation.keyTalkingPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key Talking Points")
                            .samFont(.subheadline, weight: .bold)
                            .padding(.top, 4)
                        ForEach(presentation.keyTalkingPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .samFont(.caption)
                                    .foregroundStyle(.blue)
                                Text(point)
                                    .samFont(.callout)
                            }
                        }
                    }
                }

                if let analyzedAt = presentation.contentAnalyzedAt {
                    Text("Last analyzed \(analyzedAt.formatted(date: .abbreviated, time: .shortened))")
                        .samFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Add files and click 'Analyze Content' to generate a summary and talking points.")
                    .samFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Delivery History

    private var deliveryHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delivery History")
                .samFont(.headline)

            let events = presentation.linkedEvents.sorted { $0.startDate > $1.startDate }

            if events.isEmpty {
                Text("Not yet linked to any events.")
                    .samFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(events, id: \.id) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.status.icon)
                            .foregroundStyle(event.isUpcoming ? .blue : .secondary)
                        VStack(alignment: .leading) {
                            Text(event.title)
                                .samFont(.body)
                            Text(event.startDate.formatted(date: .abbreviated, time: .shortened))
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.status.displayName)
                            .samFont(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for type: String) -> String {
        switch type.lowercased() {
        case "pdf":  return "doc.fill"
        case "key":  return "rectangle.fill.on.rectangle.fill"
        case "pptx", "ppt": return "rectangle.fill.on.rectangle.fill"
        default:     return "doc"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let bookmarkData = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                let file = PresentationFile(
                    fileName: url.lastPathComponent,
                    fileType: url.pathExtension.lowercased(),
                    bookmarkData: bookmarkData,
                    fileSizeBytes: resourceValues.fileSize
                )
                presentation.fileAttachments.append(file)
                presentation.updatedAt = .now
                onUpdate()
            } catch {
                // Bookmark creation failed
            }
        }
    }

    private func removeFile(_ file: PresentationFile) {
        presentation.fileAttachments.removeAll { $0.id == file.id }
        presentation.updatedAt = .now
        onUpdate()
    }
}

// MARK: - Draggable Divider

private struct PresentationListDivider: View {
    @Binding var listWidth: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = listWidth + value.translation.width
                        listWidth = min(max(newWidth, 260), 500)
                    }
            )
    }
}

// MARK: - New Presentation Form

struct PresentationFormSheet: View {
    let onCreate: (SamPresentation) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var duration = ""
    @State private var targetAudience = ""
    @State private var tagsText = ""
    @State private var isImportingFile = false
    @State private var pendingFiles: [PendingFile] = []

    struct PendingFile: Identifiable {
        let id = UUID()
        let fileName: String
        let fileType: String
        let bookmarkData: Data
        let fileSizeBytes: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Presentation")
                    .samFont(.title2, weight: .bold)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...6)
                HStack {
                    TextField("Duration (minutes)", text: $duration)
                        .frame(maxWidth: 150)
                    TextField("Target Audience", text: $targetAudience)
                }
                TextField("Tags (comma-separated)", text: $tagsText)

                // File attachments
                Section("Files") {
                    ForEach(pendingFiles) { file in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.blue)
                            Text(file.fileName)
                                .samFont(.body)
                            Spacer()
                            Button {
                                pendingFiles.removeAll { $0.id == file.id }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        isImportingFile = true
                    } label: {
                        Label("Add PDF or Slides", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Create") { createPresentation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.pdf, .presentation],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                pendingFiles.append(PendingFile(
                    fileName: url.lastPathComponent,
                    fileType: url.pathExtension.lowercased(),
                    bookmarkData: bookmark,
                    fileSizeBytes: size
                ))
                // Auto-fill title from first file if empty
                if title.isEmpty {
                    title = url.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                }
            }
        }
        .dismissOnLock(isPresented: $isImportingFile)
    }

    private func createPresentation() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let durationInt = Int(duration)

        let context = SAMModelContainer.newContext()
        let presentation = SamPresentation(
            title: title,
            presentationDescription: description.isEmpty ? nil : description,
            topicTags: tags,
            estimatedDurationMinutes: durationInt,
            targetAudience: targetAudience.isEmpty ? nil : targetAudience
        )

        // Attach files
        presentation.fileAttachments = pendingFiles.map { file in
            PresentationFile(
                fileName: file.fileName,
                fileType: file.fileType,
                bookmarkData: file.bookmarkData,
                fileSizeBytes: file.fileSizeBytes
            )
        }

        context.insert(presentation)
        try? context.save()

        onCreate(presentation)

        // Auto-analyze if files were attached
        if !presentation.fileAttachments.isEmpty {
            Task {
                await PresentationAnalysisCoordinator.shared.analyze(presentation: presentation)
            }
        }

        dismiss()
    }
}
