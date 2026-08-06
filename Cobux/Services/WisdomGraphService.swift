import SwiftData
import Foundation

/// Builds a deterministic "Wisdom Graph" of `Theme` records purely from the free-text
/// tags the user already types on their `Highlight`s. No AI, no network calls — just
/// grouping + co-occurrence counting, so it's instant and free to rebuild at any time.
struct WisdomGraphService {
    /// Optional AI-assisted tag merging — collapses near-synonym tags (e.g.
    /// "ego", "pride", "arrogance") into one canonical theme name. This IS a
    /// real paid Claude call, unlike everything else in this file, so it's
    /// deliberately structured to run at most once per distinct tag set:
    /// the mapping it produces is cached (`UserDefaults`) alongside a hash
    /// of the tag set it was computed from, and `mergeSimilarTags` only
    /// makes a real API call when that hash has actually changed (new
    /// highlights/tags added since the last merge) — tapping the button
    /// again with nothing new reuses the cached mapping for free. Never
    /// runs automatically; only ever triggered by an explicit user tap.
    private static let mergeMappingKey = "cobux.wisdomGraph.tagMergeMapping"
    private static let mergedTagsHashKey = "cobux.wisdomGraph.mergedTagsHash"

    private static func distinctTagsHash(highlights: [Highlight]) -> String {
        var seen = Set<String>()
        for highlight in highlights {
            for tag in highlight.tags {
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty { seen.insert(normalized) }
            }
        }
        return seen.sorted().joined(separator: "|")
    }

    private static func cachedMergeMapping() -> [String: String]? {
        guard let hash = UserDefaults.standard.string(forKey: mergedTagsHashKey),
              let data = UserDefaults.standard.data(forKey: mergeMappingKey),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        _ = hash // presence check only; actual staleness check happens in mergeSimilarTags
        return mapping
    }

    /// Runs the AI merge if (and only if) the current distinct tag set
    /// differs from whatever it was last computed against. `madeAPICall` is
    /// true only when a real, paid Claude request happened; `usedLocalAI` is
    /// true when Apple's on-device model handled it instead (free, private,
    /// no key needed) -- callers should surface these distinctly rather than
    /// let cost-relevant differences blend into one generic "done" message.
    static func mergeSimilarTags(highlights: [Highlight], claudeService: ClaudeService) async throws -> (mapping: [String: String], madeAPICall: Bool, usedLocalAI: Bool) {
        let currentHash = distinctTagsHash(highlights: highlights)
        let cachedHash = UserDefaults.standard.string(forKey: mergedTagsHashKey)

        if cachedHash == currentHash, let cached = cachedMergeMapping() {
            return (cached, false, false)
        }

        let distinctTags = Set(highlights.flatMap { $0.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } })
            .filter { !$0.isEmpty }
            .sorted()

        guard !distinctTags.isEmpty else {
            return ([:], false, false)
        }

        if #available(iOS 26.0, *), LocalAIService.isAvailable {
            let localMapping = try await LocalAIService.mergeSimilarTags(distinctTags: distinctTags)
            if let encoded = try? JSONEncoder().encode(localMapping) {
                UserDefaults.standard.set(encoded, forKey: mergeMappingKey)
                UserDefaults.standard.set(currentHash, forKey: mergedTagsHashKey)
            }
            return (localMapping, false, true)
        }

        let prompt = """
        Here is a list of free-text tags from a personal notes app: \(distinctTags.joined(separator: ", ")).

        Some of these are near-synonyms or the same concept phrased differently (e.g. "ego", "pride", "arrogance" could all merge into one). Group ONLY tags that genuinely mean the same underlying concept — do not force unrelated tags together, and leave any tag with no real synonym in this list completely alone (don't include it in your output at all).

        Respond with ONLY a JSON object, no other text, mapping each tag that should be RENAMED to its canonical group name. Example format: {"pride": "Ego", "arrogance": "Ego"}. Every key must be one of the exact tags listed above. Do not include tags that should keep their own name unchanged.
        """

        let response = try await claudeService.sendMessage(userMessage: prompt, conversationHistory: [], systemPrompt: "You are a precise data-normalization assistant. Respond with ONLY valid JSON, nothing else — no markdown fences, no explanation.")

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8),
              let mapping = try? JSONDecoder().decode([String: String].self, from: jsonData) else {
            // Model didn't return clean JSON — fail safe rather than cache
            // garbage; the existing (or no) mapping stays in effect.
            return (cachedMergeMapping() ?? [:], true, false)
        }

        // Normalize keys to match how `buildGraph` normalizes tags, so
        // lookups against it are a direct match.
        let normalizedMapping = Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.lowercased(), $0.value) })

        if let encoded = try? JSONEncoder().encode(normalizedMapping) {
            UserDefaults.standard.set(encoded, forKey: mergeMappingKey)
            UserDefaults.standard.set(currentHash, forKey: mergedTagsHashKey)
        }

        return (normalizedMapping, true, false)
    }

    @MainActor
    static func buildGraph(highlights: [Highlight], modelContext: ModelContext) {
        // 1. Clean rebuild: wipe all existing Theme records. This is cheap and avoids
        //    having to diff/merge stale themes against the current tag set.
        let existingThemes = (try? modelContext.fetch(FetchDescriptor<Theme>())) ?? []
        for theme in existingThemes {
            modelContext.delete(theme)
        }

        // 2. Group highlights by normalized tag (trim + lowercase), tracking:
        //    - highlightsByTag: normalized tag -> the highlights carrying it
        //    - displayNameByTag: normalized tag -> first-seen original casing (for a readable name)
        //    - coOccurrence: normalized tag -> [other normalized tag -> co-occurrence count]
        // Optional AI-merge mapping (normalized raw tag -> canonical group
        // name), if the user has ever run the paid "Merge Similar Tags"
        // action (see the doc comment at the top of this file). Applying it
        // here just means grouping uses the canonical name as the key
        // instead of the raw tag's own casing — completely free, since the
        // mapping was already computed and cached elsewhere.
        let mergeMapping = cachedMergeMapping() ?? [:]

        var highlightsByTag: [String: [Highlight]] = [:]
        var displayNameByTag: [String: String] = [:]
        var coOccurrence: [String: [String: Int]] = [:]

        for highlight in highlights {
            let trimmedTags = highlight.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !trimmedTags.isEmpty else { continue }

            // Dedupe tags within a single highlight (e.g. "Discipline" and "discipline")
            // so it doesn't get double-counted into the same theme.
            var seenOnThisHighlight = Set<String>()
            var distinctNormalizedThisHighlight: [String] = []

            for original in trimmedTags {
                let rawNormalized = original.lowercased()
                // If this tag was merged into a canonical group, group under
                // that instead — the canonical name becomes both the lookup
                // key and (if not already set) the display name.
                let normalized = mergeMapping[rawNormalized]?.lowercased() ?? rawNormalized
                let displayCandidate = mergeMapping[rawNormalized] ?? original

                if displayNameByTag[normalized] == nil {
                    displayNameByTag[normalized] = displayCandidate
                }

                if seenOnThisHighlight.insert(normalized).inserted {
                    distinctNormalizedThisHighlight.append(normalized)
                    highlightsByTag[normalized, default: []].append(highlight)
                }
            }

            // Co-occurrence: every pair of distinct tags on this highlight links those
            // two themes together (only highlights with 2+ tags contribute here).
            if distinctNormalizedThisHighlight.count > 1 {
                for i in 0..<distinctNormalizedThisHighlight.count {
                    for j in 0..<distinctNormalizedThisHighlight.count where i != j {
                        let a = distinctNormalizedThisHighlight[i]
                        let b = distinctNormalizedThisHighlight[j]
                        coOccurrence[a, default: [:]][b, default: 0] += 1
                    }
                }
            }
        }

        // 3 & 4. Create a Theme per distinct tag with at least one highlight, wire up
        //    the highlights relationship, and compute relatedThemeNames from co-occurrence.
        for (normalizedTag, taggedHighlights) in highlightsByTag {
            let displayName = displayNameByTag[normalizedTag] ?? normalizedTag.capitalized

            let related = (coOccurrence[normalizedTag] ?? [:])
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(6)
                .map { displayNameByTag[$0.key] ?? $0.key.capitalized }

            let theme = Theme(name: displayName, relatedThemeNames: Array(related))
            // Theme.highlights carries `@Relationship(inverse: \Highlight.themes)`, so
            // setting this side is sufficient — SwiftData maintains highlight.themes automatically.
            theme.highlights = taggedHighlights

            modelContext.insert(theme)
        }

        try? modelContext.save()
    }
}
