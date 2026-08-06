import SwiftUI
import SwiftData

/// Browse highlights grouped by theme across every book, built purely from the
/// free-text tags the user already types on highlights. No AI, no network calls —
/// deterministic and instant.
struct WisdomGraphView: View {
    @Bindable var claudeService: ClaudeService
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Theme.name) private var themes: [Theme]
    @Query private var highlights: [Highlight]
    @State private var searchText = ""
    @State private var showMergeExplanation = false
    @State private var isMerging = false
    @State private var mergeResultMessage: String?
    @State private var showMergeResult = false
    @State private var showNoAPIKeyAlert = false
    @AppStorage("hasSeenTagMergeExplanation") private var hasSeenTagMergeExplanation = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    /// Filters by theme name only — with the medical textbooks now in the
    /// library, there can be hundreds of narrow, disease-specific themes
    /// (vs. the small handful the self-help books produced), so finding one
    /// by scrolling alone stopped being practical.
    private var filteredThemes: [Theme] {
        guard !searchText.isEmpty else { return themes }
        return themes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 20) {
                    if themes.isEmpty {
                        emptyState
                    } else if filteredThemes.isEmpty {
                        noSearchResultsState
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filteredThemes) { theme in
                                // `allThemes:` always passes the full, unfiltered
                                // list — related-theme navigation inside a theme's
                                // detail view shouldn't be limited by whatever
                                // search text happens to be active here.
                                NavigationLink(destination: WisdomThemeDetailView(theme: theme, allThemes: themes)) {
                                    ThemeCard(theme: theme)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Wisdom Graph")
            .searchable(text: $searchText, prompt: "Search themes")
            .onAppear {
                claudeService.apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey) ?? ""
            }
            .toolbar {
                if !themes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    WisdomGraphService.buildGraph(highlights: highlights, modelContext: modelContext)
                                }
                            } label: {
                                Label("Rebuild (Free)", systemImage: "arrow.clockwise")
                            }

                            Button {
                                if LocalAIService.isAvailable {
                                    // Free and on-device -- no key, no cost, no
                                    // confirmation needed, unlike the Claude path.
                                    runTagMerge()
                                } else if claudeService.apiKey.isEmpty {
                                    showNoAPIKeyAlert = true
                                } else if hasSeenTagMergeExplanation {
                                    runTagMerge()
                                } else {
                                    showMergeExplanation = true
                                }
                            } label: {
                                Label(LocalAIService.isAvailable ? "Merge Similar Tags (On-Device)" : "Merge Similar Tags (AI)", systemImage: "sparkles")
                            }
                            .disabled(isMerging)
                        } label: {
                            if isMerging {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityLabel("Wisdom Graph options")
                    }
                }
            }
            .alert("Merge Similar Tags?", isPresented: $showMergeExplanation) {
                Button("Cancel", role: .cancel) { }
                Button("Merge") {
                    hasSeenTagMergeExplanation = true
                    runTagMerge()
                }
            } message: {
                Text("Uses your Anthropic API key to group near-synonym tags (like \"ego\", \"pride\", \"arrogance\") into one theme. This costs a small amount, roughly a few cents, the first time — after that it's cached and free to reuse unless you add enough new tags to need re-merging.")
            }
            .alert("Merge Result", isPresented: $showMergeResult) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(mergeResultMessage ?? "")
            }
            .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Add your Anthropic API key in Settings to use AI tag merging. The free rebuild option doesn't need one.")
            }
        }
    }

    private func runTagMerge() {
        isMerging = true
        Task {
            do {
                let (mapping, madeAPICall, usedLocalAI) = try await WisdomGraphService.mergeSimilarTags(highlights: highlights, claudeService: claudeService)
                await MainActor.run {
                    isMerging = false
                    withAnimation(.easeInOut(duration: 0.25)) {
                        WisdomGraphService.buildGraph(highlights: highlights, modelContext: modelContext)
                    }
                    if usedLocalAI {
                        mergeResultMessage = mapping.isEmpty
                            ? "No similar tags found to merge — your tags are already distinct. Ran on-device, no cost."
                            : "Merged \(mapping.count) tag(s) into shared themes — ran entirely on-device, no cost."
                    } else if madeAPICall {
                        mergeResultMessage = mapping.isEmpty
                            ? "No similar tags found to merge — your tags are already distinct."
                            : "Merged \(mapping.count) tag(s) into shared themes."
                    } else {
                        mergeResultMessage = "Already up to date — no new tags since the last merge, so no charge this time."
                    }
                    showMergeResult = true
                }
            } catch {
                await MainActor.run {
                    isMerging = false
                    mergeResultMessage = "Couldn't merge tags right now: \(error.localizedDescription)"
                    showMergeResult = true
                }
            }
        }
    }

    private var noSearchResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No themes match \"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal)
    }

    private var emptyState: some View {
        CobuxEmptyStateView(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Build your Wisdom Graph",
            message: "Group your highlights by theme across every book in your library — instant, and free."
        ) {
            CobuxEmptyStateButton("Build Wisdom Graph", systemImage: "sparkles") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    WisdomGraphService.buildGraph(highlights: highlights, modelContext: modelContext)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 40)
    }

}

private struct ThemeCard: View {
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(Color.cobuxAccent)

            Text(theme.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Text("\(theme.highlights.count) highlight\(theme.highlights.count == 1 ? "" : "s")")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.cobuxAccent.opacity(0.15))
                .foregroundStyle(Color.cobuxAccent)
                .clipShape(Capsule())
        }
        .padding(14)
        .frame(height: 120, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct WisdomThemeDetailView: View {
    let theme: Theme
    let allThemes: [Theme]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if theme.highlights.isEmpty {
                    Text("No highlights in this theme.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    ForEach(theme.highlights.sorted(by: { $0.dateAdded > $1.dateAdded })) { highlight in
                        HighlightCitationCard(highlight: highlight)
                    }
                }

                if !theme.relatedThemeNames.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Related Themes")
                            .font(.headline)
                            .padding(.top, 8)

                        RelatedThemeChips(names: theme.relatedThemeNames, allThemes: allThemes)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(theme.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HighlightCitationCard: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(highlight.text)\"")
                .font(.body)
                .italic()

            if let book = highlight.book {
                NavigationLink(destination: BookDetailView(book: book)) {
                    HStack(spacing: 4) {
                        Image(systemName: "book.closed.fill")
                            .font(.caption2)
                        Text(book.title)
                        if let chapter = highlight.chapter, !chapter.isEmpty {
                            Text("· \(chapter)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.cobuxAccent)
                }
            } else if let chapter = highlight.chapter, !chapter.isEmpty {
                Text(chapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !highlight.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(highlight.tags, id: \.self) { tag in
                            TagBadge(tag: tag)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct RelatedThemeChips: View {
    let names: [String]
    let allThemes: [Theme]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    relatedChip(for: name)
                }
            }
        }
    }

    @ViewBuilder
    private func relatedChip(for name: String) -> some View {
        if let match = allThemes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            NavigationLink(destination: WisdomThemeDetailView(theme: match, allThemes: allThemes)) {
                TagBadge(tag: name)
            }
        } else {
            TagBadge(tag: name)
                .opacity(0.5)
        }
    }
}
