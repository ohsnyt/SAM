//
//  ContextListView.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase G: Contexts
//
//  List view for all contexts (households, businesses, etc.) in SAM.
//  Displays contexts from ContextsRepository with search and filtering.
//

import SwiftUI
import SwiftData

struct ContextListView: View {
    
    // MARK: - Bindings
    
    @Binding var selectedContextID: UUID?
    
    // MARK: - Dependencies
    
    @State private var repository = ContextsRepository.shared
    
    // MARK: - State
    
    @State private var contexts: [SamContext] = []
    @State private var searchText = ""
    @State private var selectedFilter: ContextKind? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreateSheet = false
    
    // MARK: - Body
    
    var body: some View {
        Group {
            if isLoading && contexts.isEmpty {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if contexts.isEmpty {
                emptyView
            } else {
                contextsList
            }
        }
        .navigationTitle("Contexts")
        .searchable(text: $searchText, prompt: "Search contexts")
        .toolbar {
            ToolbarItemGroup {
                // Filter picker
                Picker("Filter", selection: $selectedFilter) {
                    Text("All").tag(nil as ContextKind?)
                    Divider()
                    ForEach([ContextKind.household, .business], id: \.self) { kind in
                        Text(kind.displayName).tag(kind as ContextKind?)
                    }
                }
                .pickerStyle(.menu)
                .help("Filter by context type")
                
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("New Context", systemImage: "plus")
                }
                .help("Create a new context")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateContextSheet(isPresented: $showingCreateSheet) {
                Task {
                    await loadContexts()
                }
            }
        }
        .task {
            await loadContexts()
        }
        .onChange(of: searchText) { _, _ in
            Task {
                await searchContexts()
            }
        }
        .onChange(of: selectedFilter) { _, _ in
            Task {
                await loadContexts()
            }
        }
    }
    
    // MARK: - Contexts List
    
    private var contextsList: some View {
        List(selection: $selectedContextID) {
            ForEach(filteredContexts, id: \.id) { context in
                Button(action: {
                    selectedContextID = context.id
                }) {
                    ContextRowView(context: context)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
    
    private var filteredContexts: [SamContext] {
        if let filter = selectedFilter {
            return contexts.filter { $0.kind == filter }
        }
        return contexts
    }
    
    // MARK: - Empty State
    
    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Contexts", systemImage: "building.2")
        } description: {
            Text("Create contexts to organize households, businesses, and relationships")
        } actions: {
            Button {
                showingCreateSheet = true
            } label: {
                Text("Create Context")
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Loading State
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading contexts...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Error State
    
    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task {
                    await loadContexts()
                }
            }
        }
    }
    
    // MARK: - Data Operations
    
    private func loadContexts() async {
        isLoading = true
        errorMessage = nil
        
        do {
            if let filter = selectedFilter {
                contexts = try repository.filter(by: filter)
            } else {
                contexts = try repository.fetchAll()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func searchContexts() async {
        guard !searchText.isEmpty else {
            await loadContexts()
            return
        }
        
        do {
            contexts = try repository.search(query: searchText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Context Row View

private struct ContextRowView: View {
    let context: SamContext
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon based on kind
            Image(systemName: context.kind.icon)
                .font(.title2)
                .foregroundStyle(context.kind.color)
                .frame(width: 32, height: 32)
            
            // Name and kind
            VStack(alignment: .leading, spacing: 2) {
                Text(context.name)
                    .font(.body)
                
                Text(context.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Participant count
            if !context.participations.isEmpty {
                Label("\(context.participations.count)", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Alert badges
            HStack(spacing: 8) {
                if context.consentAlertCount > 0 {
                    Label("\(context.consentAlertCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                
                if context.reviewAlertCount > 0 {
                    Label("\(context.reviewAlertCount)", systemImage: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                if context.followUpAlertCount > 0 {
                    Label("\(context.followUpAlertCount)", systemImage: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create Context Sheet

private struct CreateContextSheet: View {
    @Binding var isPresented: Bool
    let onCreate: () -> Void
    
    @State private var name = ""
    @State private var selectedKind: ContextKind = .household
    @State private var isCreating = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                
                Picker("Type", selection: $selectedKind) {
                    ForEach([ContextKind.household, .business], id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.icon)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("New Context")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createContext()
                    }
                    .disabled(name.isEmpty || isCreating)
                }
            }
        }
        .frame(width: 400, height: 250)
    }
    
    private func createContext() {
        isCreating = true
        errorMessage = nil
        
        Task {
            do {
                _ = try ContextsRepository.shared.create(
                    name: name,
                    kind: selectedKind
                )
                
                await MainActor.run {
                    isPresented = false
                    onCreate()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }
}

// MARK: - ContextKind Extensions

extension ContextKind {
    var displayName: String {
        // Use the raw value from the enum, which already contains proper display names
        return self.rawValue
    }
    
    var icon: String {
        switch self {
        case .household: return "house.fill"
        case .business: return "building.2.fill"
        case .recruiting: return "person.3.fill"
        case .personalPlanning: return "chart.line.uptrend.xyaxis"
        case .agentTeam: return "person.2.badge.gearshape"
        case .agentExternal: return "building.columns"
        case .referralPartner: return "arrow.triangle.branch"
        case .vendor: return "cart"
        }
    }
    
    var color: Color {
        switch self {
        case .household: return .blue
        case .business: return .purple
        case .recruiting: return .orange
        case .personalPlanning: return .green
        case .agentTeam: return .indigo
        case .agentExternal: return .teal
        case .referralPartner: return .pink
        case .vendor: return .brown
        }
    }
}

// MARK: - Preview

#Preview("With Contexts") {
    let container = SAMModelContainer.shared
    ContextsRepository.shared.configure(container: container)
    
    // Add sample data
    let context = ModelContext(container)
    
    let household1 = SamContext(
        id: UUID(),
        name: "Smith Family",
        kind: .household,
        reviewAlertCount: 1
    )
    
    let household2 = SamContext(
        id: UUID(),
        name: "Johnson Household",
        kind: .household
    )
    
    let business1 = SamContext(
        id: UUID(),
        name: "Acme Corp",
        kind: .business,
        followUpAlertCount: 2
    )
    
    context.insert(household1)
    context.insert(household2)
    context.insert(business1)
    try? context.save()
    
    return NavigationStack {
        ContextListView(selectedContextID: .constant(nil))
            .modelContainer(container)
    }
    .frame(width: 400, height: 600)
}

#Preview("Empty") {
    let container = SAMModelContainer.shared
    ContextsRepository.shared.configure(container: container)
    
    return NavigationStack {
        ContextListView(selectedContextID: .constant(nil))
            .modelContainer(container)
    }
    .frame(width: 400, height: 600)
}
