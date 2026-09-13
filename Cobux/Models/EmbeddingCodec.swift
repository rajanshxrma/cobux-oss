import Foundation

/// The one place a stored embedding blob turns back into `[Float]`.
///
/// It lives in `Models/` rather than beside `EmbeddingService` for a concrete
/// reason: `Cobux/Models` is compiled wholesale into the widget, Messages and
/// Share-extension targets, while `Services/EmbeddingService.swift` is app-only.
/// A decoder referenced from a model's `embedding` getter therefore has to be
/// reachable from all of them, or those targets stop building — which is
/// exactly what happened when the getters first started sharing one.
///
/// Three identical copies of this used to live in `Highlight`, `ChatMessage`
/// and `PersonalWritingEntry`, each mapping one `loadUnaligned` per element.
/// Ranking decodes every stored vector in the library on the way to an answer,
/// so at the shipped corpus that ran on the order of fifteen million times per
/// chat send. This is the same result about an order of magnitude faster.
///
/// Alignment is a non-issue by construction: the destination is Array-allocated
/// and the source is copied byte-wise, so SwiftData's unaligned `Data` slices
/// are handled without any assumption about where they start.
enum EmbeddingCodec {
    /// An empty `Data` — the backfills' "tried, nothing to index" marker —
    /// decodes to an empty array, which ranking callers skip. A trailing
    /// partial float, should storage ever hand one back, is ignored rather
    /// than read past the end.
    static func decode(_ data: Data) -> [Float] {
        let stride = MemoryLayout<Float>.stride
        let count = data.count / stride
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            let copiedBytes = data.copyBytes(to: buffer)
            initializedCount = copiedBytes / stride
        }
    }
}
