import AVFoundation
import Foundation
import Observation
import Speech
import SwiftData

/// Writes the words of a journal voice note, on the phone, after the entry
/// has saved.
///
/// Rajan, build 58: "The voice recording transcript at the end of saving has
/// to be a must. It should be intelligent -- use the new iOS speech
/// technology, it's much better -- same quality; a couple of my dictionary
/// words and the names I use should be good."
///
/// Two engines, one contract. On iOS 26 the Speech framework's
/// `SpeechAnalyzer` + `SpeechTranscriber` reads the file whole: a newer,
/// long-form model that runs entirely on device and needs no speech-
/// recognition permission (its model assets are Apple's, downloaded once by
/// the system; the AUDIO never leaves the phone). On iOS 18–25, or if the
/// analyzer declines, `SFSpeechRecognizer` with `requiresOnDeviceRecognition`
/// -- and if the device cannot recognise on-device, the note is marked
/// `unavailable` rather than sent to a server. Never a network path for his
/// voice, on either engine.
///
/// "The names I use": both engines take contextual strings. They come from
/// his own record -- proper nouns that recur across `PersonalWritingEntry`
/// (capitalised in every appearance, seen at least twice) and the library's
/// authors and titles -- built once per launch off the main actor
/// (`VocabularyCache`). On the analyzer they ride `AnalysisContext
/// .contextualStrings[.general]`, the API's own hook for exactly this; on
/// the recogniser, `SFSpeechRecognitionRequest.contextualStrings`.
///
/// Storage: `JournalAttachment.transcript` / `.transcriptState`, written by
/// `TranscriptWriter` -- a `@ModelActor`, so the background write owns its
/// own context and returns nothing but values (the SE-0338 rule the repo's
/// other probes follow). The detail view reads through `snapshots(for:)`
/// (a fresh context) rather than off the model object, and re-reads when
/// `revision` moves, which is how "Transcribing…" becomes the words.
///
/// The detail view never shows an error: `failed` and `unavailable` render
/// nothing, and a note the service has not met yet (recorded before this
/// build, or declined and later allowed) is retried once per launch when its
/// entry is opened (`transcribeIfNeeded`).
@MainActor
@Observable
final class VoiceTranscriptionService {
    static let shared = VoiceTranscriptionService()

    /// `JournalAttachment.transcriptState`'s vocabulary. Stored as the raw
    /// string so a value a future build adds still loads today.
    enum State: String, Sendable {
        case pending, done, failed, unavailable
    }

    /// What the detail view draws for one note. A value, across actors.
    struct Snapshot: Sendable, Hashable {
        let state: State
        let transcript: String?
    }

    /// Bumps once per finished note. The detail view's `.task(id:)` key.
    private(set) var revision = 0
    private var inFlight: Set<UUID> = []
    /// Notes this launch has already tried, whatever the outcome -- the bound
    /// on `transcribeIfNeeded`'s retry of `failed`/`unavailable` rows.
    private var attemptedThisLaunch: Set<UUID> = []

    private init() {}

    // MARK: - Permission

    /// Whether THIS device's transcript path asks for speech recognition at
    /// all. The iOS 26 analyzer does not; the `SFSpeechRecognizer` fallback
    /// does. Drives both the compose sheet's explanation line and the ask.
    nonisolated static var usesSpeechAuthorization: Bool {
        if #available(iOS 26, *), SpeechTranscriber.isAvailable { return false }
        return true
    }

    /// True when the ask is still ahead of us: the fallback path is in use
    /// and the system has never put the question. Cheap -- a status read,
    /// no prompt -- so the compose sheet can call it when a note is staged.
    nonisolated static func needsAuthorizationPrompt() -> Bool {
        usesSpeechAuthorization && SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    /// Puts the system question, once, and only on the path that needs it.
    /// The caller has already shown one line of explanation.
    func requestAuthorizationIfNeeded() async {
        guard Self.needsAuthorizationPrompt() else { return }
        _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }

    // MARK: - Work

    /// Transcribes each attachment, one detached utility task per note,
    /// skipping any already in flight. Called by the compose sheet right
    /// after a save that created voice-note rows.
    func transcribe(attachmentIDs: [UUID], container: ModelContainer) {
        for id in attachmentIDs where !inFlight.contains(id) {
            inFlight.insert(id)
            attemptedThisLaunch.insert(id)
            Task.detached(priority: .utility) {
                await Self.run(id: id, container: container)
                await MainActor.run { VoiceTranscriptionService.shared.finished(id) }
            }
        }
    }

    /// The detail view's door: notes this build has not transcribed yet.
    /// `done` is never touched; `pending` (a save whose transcription never
    /// ran -- the app died first) and `failed` are retried once per launch;
    /// `unavailable` only when the permission it lacked is now granted or
    /// the OS no longer needs one; a `nil` state (recorded before transcripts
    /// existed) is simply due. The state read happens off the main actor.
    func transcribeIfNeeded(attachmentIDs: [UUID], container: ModelContainer) {
        let candidates = attachmentIDs.filter { !inFlight.contains($0) && !attemptedThisLaunch.contains($0) }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) {
            let states = await TranscriptWriter(modelContainer: container).states(of: candidates)
            let permissionNowOK = !Self.usesSpeechAuthorization
                || SFSpeechRecognizer.authorizationStatus() == .authorized
            let due = candidates.filter { id in
                guard let raw = states[id], let state = State(rawValue: raw) else { return true }
                switch state {
                case .pending, .failed: return true
                case .unavailable: return permissionNowOK
                case .done: return false
                }
            }
            guard !due.isEmpty else { return }
            await MainActor.run {
                VoiceTranscriptionService.shared.transcribe(attachmentIDs: due, container: container)
            }
        }
    }

    /// Fresh reads for the detail view -- through the writer's own context,
    /// so a transcript that landed after the page opened is seen.
    func snapshots(for attachmentIDs: [UUID], container: ModelContainer) async -> [UUID: Snapshot] {
        await TranscriptWriter(modelContainer: container).snapshots(for: attachmentIDs)
    }

    private func finished(_ id: UUID) {
        inFlight.remove(id)
        revision += 1
    }

    // MARK: - One note, off the main actor

    private enum Outcome: Sendable {
        case text(String)
        case unavailable
        case failed(String)
    }

    nonisolated private static func run(id: UUID, container: ModelContainer) async {
        let writer = TranscriptWriter(modelContainer: container)
        guard let url = JournalAttachmentStore.existingFileURL(for: id), url.pathExtension == "m4a" else {
            // No file for this id (or a photo handed in by mistake): nothing
            // to transcribe, and nothing to say about it on the page.
            await writer.write(id: id, transcript: nil, state: .failed)
            return
        }
        await writer.write(id: id, transcript: nil, state: .pending)
        let vocabulary = await VocabularyCache.shared.strings(container: container)
        switch await transcribeFile(at: url, vocabulary: vocabulary) {
        case .text(let words):
            let cleaned = words.trimmingCharacters(in: .whitespacesAndNewlines)
            // Silence transcribes to nothing: `done` with no words, so the
            // page shows neither a transcript nor a "Transcribing…" forever.
            await writer.write(id: id, transcript: cleaned.isEmpty ? nil : cleaned, state: .done)
        case .unavailable:
            await writer.write(id: id, transcript: nil, state: .unavailable)
        case .failed(let why):
            DiagnosticLog.log("journal transcript: failed for \(id.uuidString.prefix(8)) -- \(why)")
            await writer.write(id: id, transcript: nil, state: .failed)
        }
    }

    /// The analyzer first where it exists; the recogniser otherwise, and as
    /// the net under an analyzer that throws (an asset that would not
    /// install, a format it declined).
    nonisolated private static func transcribeFile(at url: URL, vocabulary: [String]) async -> Outcome {
        if #available(iOS 26, *) {
            switch await analyzerTranscript(of: url, vocabulary: vocabulary) {
            case .text(let words):
                return .text(words)
            case .unavailable:
                break
            case .failed(let why):
                DiagnosticLog.log("journal transcript: analyzer declined -- \(why); trying the recogniser")
            }
        }
        return await recognizerTranscript(of: url, vocabulary: vocabulary)
    }

    /// iOS 26: `SpeechAnalyzer` over the whole file. Results are collected
    /// concurrently with analysis (the stream must have a reader before
    /// input arrives), then the analyzer is finalised through the last audio
    /// time it reported. `.transcription` reports only finalised results, so
    /// every piece is kept.
    @available(iOS 26, *)
    nonisolated private static func analyzerTranscript(of url: URL, vocabulary: [String]) async -> Outcome {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale else { return .unavailable }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // The locale's model. Apple's asset, fetched once by the system and
        // shared with every app that asks for it; this is the one download
        // on the path, and it is not his audio.
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported:
            return .unavailable
        case .supported, .downloading:
            do {
                _ = try? await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                return .failed("asset install: \(error)")
            }
        case .installed:
            break
        @unknown default:
            break
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: vocabulary]
                try await analyzer.setContext(context)
            }
            async let collected = collectResults(from: transcriber)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return .text(try await collected)
        } catch {
            return .failed(String(describing: error))
        }
    }

    @available(iOS 26, *)
    nonisolated private static func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var pieces: [String] = []
        for try await result in transcriber.results {
            let piece = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces.joined(separator: " ")
    }

    /// iOS 18–25 (and the net under the analyzer): `SFSpeechRecognizer`,
    /// on-device only. A device that cannot recognise on-device gets
    /// `unavailable`, never the server.
    nonisolated private static func recognizerTranscript(of url: URL, vocabulary: [String]) async -> Outcome {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .unavailable }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return .unavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // The recogniser's hint list is smaller than the analyzer's; the
        // journal's names lead the list, so they are what survives the cut.
        request.contextualStrings = Array(vocabulary.prefix(VocabularyCache.recognizerLimit))

        let once = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { c.resume(returning: .text(result.bestTranscription.formattedString)) }
                } else if let error {
                    once.run { c.resume(returning: .failed(String(describing: error))) }
                }
            }
        }
    }

    /// A recogniser callback can fire more than once; a continuation may
    /// resume exactly once. Locked, because the callback arrives on the
    /// recogniser's own queue.
    private final class ResumeOnce: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

// MARK: - Storage

/// The one writer of `JournalAttachment.transcript`/`transcriptState`.
/// `@ModelActor`: owns its context, returns values only.
@ModelActor
actor TranscriptWriter {
    func write(id: UUID, transcript: String?, state: VoiceTranscriptionService.State) {
        var descriptor = FetchDescriptor<JournalAttachment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        row.transcript = transcript
        row.transcriptState = state.rawValue
        do {
            try modelContext.save()
        } catch {
            DiagnosticLog.log("journal transcript: save failed -- \(error)")
        }
    }

    /// `transcriptState` per id; an id with a row but no state maps to nil,
    /// same as one with no row.
    func states(of ids: [UUID]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for id in ids {
            var descriptor = FetchDescriptor<JournalAttachment>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.transcriptState]
            if let state = try? modelContext.fetch(descriptor).first?.transcriptState {
                out[id] = state
            }
        }
        return out
    }

    func snapshots(for ids: [UUID]) -> [UUID: VoiceTranscriptionService.Snapshot] {
        var out: [UUID: VoiceTranscriptionService.Snapshot] = [:]
        for id in ids {
            var descriptor = FetchDescriptor<JournalAttachment>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.transcript, \.transcriptState]
            guard let row = try? modelContext.fetch(descriptor).first,
                  let raw = row.transcriptState,
                  let state = VoiceTranscriptionService.State(rawValue: raw) else { continue }
            out[id] = VoiceTranscriptionService.Snapshot(state: state, transcript: row.transcript)
        }
        return out
    }
}

// MARK: - His vocabulary

/// The contextual strings both engines are handed, built once per launch.
///
/// (a) Proper nouns from his own journal: a word counts when it is
/// capitalised in EVERY appearance (a word he also writes lowercase --
/// "Today"/"today" -- is a sentence start, not a name), appears at least
/// twice, and is three letters or longer. Possessives are folded ("Rajan's"
/// is "Rajan"). Ordered by how often he writes them, capped at 200.
/// (b) The library's authors, then titles, up to a total of 300.
///
/// Bounded reads: `propertiesToFetch` keeps each row to its text column, and
/// the entry fetch stops at 4,000 rows -- three years of daily writing is
/// roughly 1,100.
actor VocabularyCache {
    static let shared = VocabularyCache()

    static let journalLimit = 200
    static let totalLimit = 300
    /// What the `SFSpeechRecognizer` path is handed -- its hint list is
    /// meant for the order of a hundred phrases, not three hundred.
    static let recognizerLimit = 150

    private var cached: [String]?
    private var loading: Task<[String], Never>?

    func strings(container: ModelContainer) async -> [String] {
        if let cached { return cached }
        if let loading { return await loading.value }
        let task = Task<[String], Never> {
            await VocabularyProbe(modelContainer: container)
                .contextualStrings(journalLimit: Self.journalLimit, totalLimit: Self.totalLimit)
        }
        loading = task
        let value = await task.value
        cached = value
        loading = nil
        return value
    }
}

/// `ReminderRotationProbe`'s shape: a `@ModelActor` owns a context confined to
/// it and returns plain values.
@ModelActor
actor VocabularyProbe {
    func contextualStrings(journalLimit: Int, totalLimit: Int) -> [String] {
        var strings = journalProperNouns(limit: journalLimit)
        var seen = Set(strings.map { $0.lowercased() })

        var books = FetchDescriptor<Book>()
        books.fetchLimit = 400
        books.propertiesToFetch = [\.title, \.author]
        let rows = (try? modelContext.fetch(books)) ?? []
        // Authors before titles: a name is what a recogniser gets wrong.
        for value in rows.map(\.author) + rows.map(\.title) {
            guard strings.count < totalLimit else { break }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, !seen.contains(trimmed.lowercased()) else { continue }
            seen.insert(trimmed.lowercased())
            strings.append(trimmed)
        }
        return strings
    }

    private func journalProperNouns(limit: Int) -> [String] {
        var entries = FetchDescriptor<PersonalWritingEntry>()
        entries.fetchLimit = 4_000
        entries.propertiesToFetch = [\.text]
        let texts = ((try? modelContext.fetch(entries)) ?? []).map(\.text)

        var capitalised: [String: Int] = [:]
        var seenLowercase: Set<String> = []
        for text in texts {
            let tokens = text.split { !$0.isLetter && $0 != "'" && $0 != "’" }
            for raw in tokens {
                var token = Substring(raw)
                for suffix in ["'s", "’s"] where token.hasSuffix(suffix) {
                    token = token.dropLast(2)
                }
                guard token.count >= 3, let first = token.first, first.isLetter else { continue }
                let word = String(token)
                if first.isUppercase {
                    capitalised[word, default: 0] += 1
                } else {
                    seenLowercase.insert(word.lowercased())
                }
            }
        }
        return capitalised
            .filter { $0.value >= 2 && !seenLowercase.contains($0.key.lowercased()) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }
}
