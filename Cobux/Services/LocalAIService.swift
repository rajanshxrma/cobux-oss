import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wraps Apple's on-device Foundation Models framework (Apple Intelligence) --
/// zero network call, zero marginal cost, fully private. Requires iOS 26+ on
/// Apple Intelligence-eligible hardware (iPhone 15 Pro and newer), so every
/// entry point here is a strictly optional fast path: callers must check
/// `isAvailable` first and fall back to the existing Anthropic-API path when
/// it's false, never assume on-device is present. This exists specifically
/// to shrink Utkarsh's ~$5/month API budget for tasks that don't need a
/// frontier model -- starting with Wisdom Graph's tag-merge suggestions.
///
/// The whole `FoundationModels`-dependent surface is behind `#if
/// canImport(FoundationModels)` -- that framework only ships in very recent
/// Xcode/SDK versions, and GitHub's `macos-15` CI runners don't have it yet.
/// Without this guard the whole app fails to compile in CI, not just this
/// feature -- `isAvailable` simply reports `false` on a toolchain that can't
/// even see the framework, which is the correct behavior anyway (it means
/// on-device generation genuinely isn't available there).
enum LocalAIService {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct TagMergeMapping {
        @Generable
        struct Entry {
            @Guide(description: "One of the exact input tags that should be renamed")
            let originalTag: String
            @Guide(description: "The canonical group name it should be merged into")
            let canonicalTag: String
        }
        @Guide(description: "Only tags that should be RENAMED into a shared canonical group -- omit any tag that has no real synonym in the list")
        let mappings: [Entry]
    }
    #endif

    enum LocalAIError: LocalizedError {
        case notAvailable
        var errorDescription: String? { "On-device AI isn't available on this device." }
    }

    #if canImport(FoundationModels)
    /// Same contract as `WisdomGraphService.mergeSimilarTags`'s Claude path --
    /// normalized-lowercase-tag -> canonical display name -- but computed
    /// entirely on-device. Callers should still cache/hash-gate the result
    /// exactly as they do for the paid path, since re-running per tap (even
    /// for free) has no benefit and costs battery/latency.
    @available(iOS 26.0, *)
    static func mergeSimilarTags(distinctTags: [String]) async throws -> [String: String] {
        guard isAvailable else { throw LocalAIError.notAvailable }
        guard !distinctTags.isEmpty else { return [:] }

        let session = LanguageModelSession(instructions: """
            You group near-synonym tags into canonical themes for a personal knowledge app. \
            Given a list of tags, decide which ones are close enough in meaning to merge under \
            one canonical name (e.g. "ego", "pride", "arrogance" could all merge into "Ego"). \
            Only merge tags that genuinely mean the same underlying concept -- don't force \
            unrelated tags together. Leave any tag with no real synonym out of your output entirely.
            """)

        let response = try await session.respond(
            to: "Tags: \(distinctTags.joined(separator: ", "))",
            generating: TagMergeMapping.self
        )

        var mapping: [String: String] = [:]
        for entry in response.content.mappings {
            mapping[entry.originalTag.lowercased()] = entry.canonicalTag
        }
        return mapping
    }
    #else
    static func mergeSimilarTags(distinctTags: [String]) async throws -> [String: String] {
        throw LocalAIError.notAvailable
    }
    #endif
}
