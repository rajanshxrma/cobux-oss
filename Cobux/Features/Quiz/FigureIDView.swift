import SwiftUI
import CobuxCore

/// "Finally instantiates the dormant Figure model" -- the original Phase 4 plan's own phrase.
/// Guarded to hide itself from the mode picker when zero `Figure` rows exist (see
/// `QuizHomeView`'s `!figures.isEmpty` check), exactly as the plan specified, since image
/// extraction is hard-blocked on Rajan's own Anthropic API key. This is the code path itself,
/// ready the moment that unblocks -- not gated on QuizQuestion/QuizAttempt (a figure isn't a
/// generated question), graded the same free-recall way via the embedding grader.
struct FigureIDView: View {
    let figures: [Figure]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var typedAnswer = ""
    @State private var hasSubmitted = false
    @State private var isCorrect = false
    @State private var correctCount = 0
    @State private var currentImage: UIImage?
    /// `FigureImageLoader.image(for:)` is a genuine disk-read + JPEG-decode `Task.detached`,
    /// not instant -- without this, `currentImage == nil` was treated as "load failed" for
    /// the entire time the very first decode of each figure was still in flight, so every
    /// single figure flashed the alarming "Image unavailable" empty state before its real
    /// image popped in, on every device, every time. Distinguishes "still loading" from
    /// "actually failed to load" so only a genuine decode failure shows the error state.
    @State private var isLoadingImage = true

    private var currentFigure: Figure? {
        figures.indices.contains(currentIndex) ? figures[currentIndex] : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let figure = currentFigure {
                    Text("\(currentIndex + 1) of \(figures.count) · \(correctCount) correct")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Group {
                        if let currentImage {
                            Image(uiImage: currentImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else if isLoadingImage {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            CobuxEmptyStateView(
                                icon: "photo",
                                title: "Image unavailable",
                                message: "\"\(figure.fileName)\" couldn't be loaded from the bundle."
                            )
                        }
                    }
                    .frame(maxHeight: 320)
                    .cobuxCard()
                    .task(id: figure.id) {
                        isLoadingImage = true
                        currentImage = await FigureImageLoader.image(for: figure)
                        isLoadingImage = false
                    }

                    TextField("What is this?", text: $typedAnswer)
                        .textFieldStyle(.roundedBorder)
                        .disabled(hasSubmitted)
                        .padding(.horizontal)

                    if hasSubmitted {
                        Text(isCorrect ? "Correct — \(figure.caption)" : "Not quite — \(figure.caption)")
                            .font(.subheadline)
                            .foregroundStyle(isCorrect ? Color.cobuxGood : Color.cobuxWarning)
                            .padding(.horizontal)
                    }

                    Spacer()

                    Button {
                        if hasSubmitted { advance() } else { submit(figure: figure) }
                    } label: {
                        Text(hasSubmitted ? (currentIndex == figures.count - 1 ? "Finish" : "Next") : "Submit")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hasSubmitted || !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.cobuxAccent : Color.secondary.opacity(0.3))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                    }
                    .disabled(!hasSubmitted && typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.horizontal)
                } else {
                    ProgressView()
                }
            }
            .padding(.top)
            .navigationTitle("Figure ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("End") { onDone(); dismiss() }
                }
            }
        }
    }

    private func submit(figure: Figure) {
        if let answerVector = EmbeddingService.embed(typedAnswer),
           let referenceVector = EmbeddingService.embed(figure.caption) {
            let similarity = EmbeddingService.cosineSimilarity(answerVector, referenceVector)
            isCorrect = FreeRecallGrader.isCorrect(similarity: similarity)
        } else {
            isCorrect = false
        }
        if isCorrect { correctCount += 1 }
        hasSubmitted = true
    }

    private func advance() {
        guard currentIndex < figures.count - 1 else {
            onDone()
            dismiss()
            return
        }
        currentIndex += 1
        typedAnswer = ""
        hasSubmitted = false
    }
}
