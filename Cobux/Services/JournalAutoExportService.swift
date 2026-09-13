import SwiftData
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Silently keeps a Mac-visible copy of every `PersonalWritingEntry` current, so the
/// existing `journal-brain-sync.py` LaunchAgent can pick up new in-app Journal writing the
/// same automatic way it already scrapes Apple Journal/Notes -- see "Journal sync pipeline,
/// 2026-08-20" in ai-brain/pending-tasks.md for the full two-sided design.
///
/// Carries the ATTACHMENTS too, not just the text. Until build 52 a voice note or a photo
/// reached iCloud only through `AutoBackupService`, whose `minimumInterval` is 20 hours --
/// so "every Journal should be automatically synced right away, we cannot lose our journal
/// entries at all" was true of the words and false of the recording sitting next to them.
/// A save now copies its own files into `journal-attachments/` beside the export and names
/// them in the JSON (`ExportedEntry.attachmentFiles`). The opportunistic launch path is
/// unchanged and still text-only -- see `export(modelContext:force:)`.
///
/// The fetch, the encode and the writes all happen on a detached `.utility` task against
/// their OWN `ModelContext`, never the caller's -- the same "detached task, fresh
/// ModelContext" pattern `AutoBackupService.backupIfNeeded` establishes, and for the same
/// reason: at real archive size this is a multi-MB encode, and it used to run on the thread
/// drawing the compose sheet's dismissal. Only plain values cross that boundary (a
/// `ModelContainer`, a `Bool`); a `ModelContext` or a `@Model` object never does.
///
/// Routes every ubiquity-container lookup through `UbiquityContainer` -- the throttle check
/// below runs FIRST and returns before ever touching the container on the (overwhelmingly
/// common) call where nothing needs to happen. This used to be backwards: the original version
/// resolved the container URL before checking its own throttle, so Apple's documented
/// not-necessarily-fast lookup ran on every single foreground/background transition regardless
/// of the 20h guard. `documentsURL()` returns `nil` until the container's entitlement is active
/// on this install, and every call below no-ops the moment that happens rather than crashing or
/// logging noise -- the same graceful-degradation shape as `CrashReportCollector`/`DiagnosticLog`
/// reaching for a directory that might not be there yet.
enum JournalAutoExportService {
    private static let defaults = UserDefaults.standard
    private static let lastExportKey = "cobux.journalAutoExport.lastExportDate"
    /// Roughly once a day -- this mirrors a nightly Mac-side cron pickup, not
    /// a live sync, so there is no value in writing more often than that.
    /// Throttle for the OPPORTUNISTIC path only (launch, backgrounding). Was 20
    /// hours, which is why a freshly written entry could not reach the Mac for
    /// most of a day no matter how many times the app was opened: "why the recent
    /// ones are not coming... iCloud Apple reminders are syncing so quick."
    ///
    /// Reminders feels instant because CloudKit pushes on every change. The
    /// equivalent here is `exportAfterWrite()` below, which fires on save and
    /// ignores this entirely. This interval now only bounds the redundant
    /// background sweeps, so it can be short without costing anything: the file
    /// is ~500 KB and writing it is a local write plus an iCloud upload.
    private static let minimumInterval: TimeInterval = 5 * 60
    private static let exportFilename = "cobux-journal-autoexport.json"
    /// Sits beside `exportFilename` in the same container directory: a
    /// recording is found by joining this to the name the JSON gives it. One
    /// directory rather than files loose beside the JSON, so the export file
    /// stays the only thing at the top level of the container's Documents.
    ///
    /// Honest about the other side: as of build 52 `journal-brain-sync.py`
    /// reads the JSON only and does nothing with this directory. The files
    /// being IN iCloud is the whole ask ("we cannot lose our journal entries
    /// at all") and does not depend on the Mac script; teaching that script to
    /// pick them up is a Mac-side change, not an app one.
    private static let attachmentsDirectoryName = "journal-attachments"
    /// A first save after this shipped can have hundreds of never-copied
    /// files behind it. Copies are ordered NEWEST FIRST and capped, so the
    /// entry he just wrote is always in the first batch and an old backlog
    /// drains over the following saves instead of turning one save into a
    /// hundred-file copy. `AutoBackupService.maxAttachmentsPerRun` splits the
    /// same backlog the same way, for the same reason.
    private static let maxAttachmentsPerExport = 50

    struct ExportedEntry: Codable {
        var source: String
        var title: String
        var text: String
        /// ISO 8601, unlike `PersonalWritingImportService.ExportedEntry`'s
        /// raw AppleScript date string -- this file is written and read by
        /// code this project controls end to end, so there's no reason to
        /// carry that format's locale quirks forward into a new export path.
        var modifiedDate: String?
        /// Filenames inside `journal-attachments/`, or `nil` for an entry with
        /// no photos or recordings. OPTIONAL on purpose: the export file
        /// already on his Mac decodes unchanged, and `journal-brain-sync.py`
        /// reads rows with `.get(...)` and ignores keys it doesn't know, so
        /// this field can ship before the Mac side reads it.
        var attachmentFiles: [String]?
    }

    /// One file to copy into the container, plus the date used to order the
    /// copies. Plain values only -- built while the models are still on the
    /// context that fetched them, so nothing downstream touches SwiftData.
    private struct PendingAttachmentCopy {
        let sourceURL: URL
        let filename: String
        let recency: Date
    }

    /// Call opportunistically on launch/background, same cadence as
    /// `WatchSyncService.sync` in `ContentView` -- cheap to call often since
    /// the throttle check is the very first thing this does, entirely local,
    /// before any iCloud I/O.
    ///
    /// `@MainActor` is load-bearing, not decorative: this used to be a plain
    /// synchronous function (always on-main by construction) and only became
    /// `async` this cycle so it could `await UbiquityContainer`. A nonisolated
    /// `async` function called with `await` from a `@MainActor` context does
    /// NOT stay on the main actor (SE-0338) -- it hops to the background
    /// executor, which means anything it did with the caller's `modelContext`
    /// would touch `container.mainContext` off the main thread on every single
    /// cold launch. That's the exact SwiftData/Core Data concurrency violation
    /// this codebase already has five separate comments warning about (the
    /// "Build-5 crash class" -- see `ContentView.swift`, `WatchSyncService.swift`,
    /// `FlowView.swift`), now hit unconditionally at launch instead of only
    /// on a race. `AutoBackupService`/`AutoRestoreService` both got this right
    /// from the start; this was the one omission.
    ///
    /// Still true after the work moved off the main actor, and the reason the
    /// annotation stayed: `export` reads `modelContext.container` and nothing
    /// else from the caller's context, and it does that read HERE, on-main,
    /// before any hop. `ModelContext` is not `Sendable`; making these entry
    /// points nonisolated would hand one across an isolation boundary, which
    /// is the same bug wearing a different hat.
    @MainActor
    static func exportIfNeeded(modelContext: ModelContext) async {
        _ = await export(modelContext: modelContext, force: false)
    }

    /// Called the instant an entry is saved. Unthrottled and deliberately so --
    /// this is the whole difference between "syncs eventually" and "it's there
    /// when I go looking for it", which is the behaviour he actually wants and
    /// already gets from Reminders.
    ///
    /// Fire-and-forget from the save path: the sheet must dismiss immediately,
    /// so this never blocks the write it is reacting to.
    ///
    /// Coalesced, not throttled -- the distinction matters. Saves can burst
    /// (the compose sheet's save, then a Continue Entry a few seconds later),
    /// and every one of them exports the WHOLE archive; letting them overlap
    /// would mean several full encodes racing and several passes copying into
    /// the same attachment directory at once. So a save that arrives while an
    /// export is already running doesn't start a second one and isn't dropped
    /// either: it sets a flag that runs exactly one more export the moment the
    /// current one finishes. No timer is involved, so nothing waits.
    @MainActor
    static func exportAfterWrite(modelContext: ModelContext) {
        guard !isExporting else {
            exportRequestedAgain = true
            return
        }
        isExporting = true
        Task { @MainActor in
            // The sheet dismisses on the caller's next line, so the app can be
            // backgrounded a heartbeat later with this still in flight. The
            // other caller that can be backgrounded mid-export already holds an
            // assertion for exactly that (`ContentView`'s scene-phase handler,
            // whose comment records that backgrounding "reliably STARTED the
            // export and just as reliably prevented it from finishing"); the
            // save path was the one that didn't. Declared inside this closure,
            // not outside it, so no concurrently-executing closure captures a
            // mutable local -- same shape as `ContentView`'s.
            #if canImport(UIKit)
            let application = UIApplication.shared
            var assertion: UIBackgroundTaskIdentifier = .invalid
            assertion = application.beginBackgroundTask(withName: "CobuxJournalExportAfterWrite") {
                if assertion != .invalid {
                    application.endBackgroundTask(assertion)
                    assertion = .invalid
                }
            }
            #endif
            defer {
                isExporting = false
                #if canImport(UIKit)
                if assertion != .invalid {
                    application.endBackgroundTask(assertion)
                    assertion = .invalid
                }
                #endif
            }
            repeat {
                exportRequestedAgain = false
                _ = await export(modelContext: modelContext, force: true)
            } while exportRequestedAgain
        }
    }

    /// Guards `exportAfterWrite`'s coalescing. `@MainActor` state read and
    /// written only from `@MainActor` code, so there is no lock and no race.
    @MainActor private static var isExporting = false
    @MainActor private static var exportRequestedAgain = false

    /// Ignores the throttle and reports what happened. Exists because the
    /// automatic path is invisible: it only runs at launch, it silently skips
    /// when throttled, and it says nothing either way -- so when Rajan wanted
    /// his journal synced *now*, there was no way to make it happen or to see
    /// why it hadn't.
    ///
    /// Everything past the throttle check runs off the main actor. The one
    /// thing taken from the caller is `modelContext.container`, read here on
    /// the main actor: `ModelContainer` is `Sendable` and safe to hand over,
    /// the context it came from is not.
    ///
    /// `force` means "he just saved," and it is what turns the attachment
    /// sweep on. The opportunistic path (`exportIfNeeded`, `force: false`) is
    /// deliberately unchanged and still text-only, so a cold launch pays
    /// nothing new.
    @MainActor
    @discardableResult
    static func export(modelContext: ModelContext, force: Bool) async -> Bool {
        if !force,
           let last = defaults.object(forKey: lastExportKey) as? Date,
           Date.now.timeIntervalSince(last) < minimumInterval {
            return false
        }

        let container = modelContext.container
        return await Task.detached(priority: .utility) {
            await writeExport(container: container, includeAttachments: force)
        }.value
    }

    /// The whole job -- fetch, encode, write, copy -- with no main actor
    /// anywhere in it and no value from the caller's context in scope.
    ///
    /// Note the ORDER: the ubiquity lookup is awaited FIRST, before the
    /// context exists. This function is nonisolated and `async`, so it can
    /// resume on a different thread after an `await`; every SwiftData read
    /// therefore has to sit on one side of the only suspension point, on the
    /// thread of the context that fetched it. `AutoBackupService.performBackup`
    /// is ordered this way for the same reason.
    private static func writeExport(container: ModelContainer, includeAttachments: Bool) async -> Bool {
        guard let containerDocumentsURL = await UbiquityContainer.shared.documentsURL() else { return false }

        // Own context, never the caller's -- the same "detached task, fresh
        // ModelContext" pattern `AutoBackupService.performBackup` uses,
        // because at real archive size this fetch + encode is multi-MB.
        let context = ModelContext(container)
        let entries = (try? context.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        guard !entries.isEmpty else { return false }

        // Built once per export run, already hoisted OUT of the `entries.map`
        // below -- the per-entry cost this rule exists to catch is the one
        // thing this line is deliberately positioned to avoid. `writeExport`
        // itself is the detached, nonisolated half of the job (see the doc
        // comment above: no main actor anywhere in it), so a shared `static
        // let` would hand an `ISO8601DateFormatter` to a background caller,
        // which is not the condition `ChatView`'s hoisted pair is safe under.
        // lint-ok: formatter-constructed-per-render -- once per export run, off-main by design, already outside the per-entry map
        let formatter = ISO8601DateFormatter()
        var pendingCopies: [PendingAttachmentCopy] = []
        let exported = entries.map { entry -> ExportedEntry in
            // Resolve by id, never by a hardcoded extension -- a voice note is
            // `<id>.m4a` and a photo is `<id>.jpg`, and assuming the second is
            // what kept recordings out of every automatic backup once already
            // (`AutoBackupService.syncAttachmentSidecars` carries that scar).
            var filenames: [String] = []
            for attachment in entry.attachments {
                guard let sourceURL = JournalAttachmentStore.existingFileURL(for: attachment.id) else { continue }
                filenames.append(sourceURL.lastPathComponent)
                if includeAttachments {
                    pendingCopies.append(PendingAttachmentCopy(
                        sourceURL: sourceURL,
                        filename: sourceURL.lastPathComponent,
                        recency: entry.modifiedDate ?? entry.dateImported
                    ))
                }
            }
            return ExportedEntry(
                source: entry.source,
                title: entry.title,
                text: entry.text,
                modifiedDate: entry.modifiedDate.map(formatter.string(from:)),
                attachmentFiles: filenames.isEmpty ? nil : filenames
            )
        }

        // Silent to the user, never silent to the log. A failure here means
        // writing he can see in the app has not reached the Mac, which is
        // exactly the class of evidence `DiagnosticLog` exists for -- but the
        // one thing it must never do is surface as an error in the editor.
        // Only genuine failures are logged: a missing ubiquity container above
        // is the documented no-op on a device without iCloud, and logging that
        // would fill the 500-entry log with the normal case.
        let data: Data
        do {
            data = try JSONEncoder().encode(exported)
        } catch {
            DiagnosticLog.log("journal auto-export: encoding \(exported.count) entries failed -- \(error.localizedDescription)")
            return false
        }

        try? FileManager.default.createDirectory(at: containerDocumentsURL, withIntermediateDirectories: true)

        // Files before the JSON: the JSON is what the Mac side reads to learn
        // an attachment exists, so writing it first would leave a window where
        // it names a recording that isn't in the container yet.
        if includeAttachments {
            copyAttachments(
                pendingCopies.sorted { $0.recency > $1.recency },
                into: containerDocumentsURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
            )
        }

        let fileURL = containerDocumentsURL.appendingPathComponent(exportFilename)
        do {
            try data.write(to: fileURL, options: .atomic)
            defaults.set(Date.now, forKey: lastExportKey)
            return true
        } catch {
            // Best-effort, same as every other silent background sync in this
            // app -- a failed write here just means tonight's export waits
            // for the next opportunistic call rather than surfacing an error
            // nobody's looking at.
            DiagnosticLog.log("journal auto-export: writing \(exported.count) entries failed -- \(error.localizedDescription)")
            return false
        }
    }

    /// Copies the attachments that aren't in the container yet, newest first,
    /// up to `maxAttachmentsPerExport`.
    ///
    /// "Already at the destination" is a complete skip, not just an
    /// optimization: `JournalAttachmentStore.save` never mutates a file once
    /// written, so a name that is already there is already the right bytes.
    /// That is what keeps this a no-op for the hundreds copied by earlier
    /// saves. Every failure is silent by design -- nothing here can throw back
    /// into the editor.
    private static func copyAttachments(_ pending: [PendingAttachmentCopy], into directory: URL) {
        guard !pending.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied = 0
        var failed = 0
        for candidate in pending {
            guard copied < maxAttachmentsPerExport else { break }
            let destinationURL = directory.appendingPathComponent(candidate.filename)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else { continue }
            do {
                try FileManager.default.copyItem(at: candidate.sourceURL, to: destinationURL)
                copied += 1
            } catch {
                // One unreadable file must not stop the rest of the sweep.
                failed += 1
            }
        }
        // One line for the whole sweep, not one per file: a photo that did not
        // reach iCloud is worth evidence, and a per-file loop would be the
        // "record everything" noise `DiagnosticLog`'s own doc rules out.
        if failed > 0 {
            DiagnosticLog.log("journal auto-export: \(failed) attachment file(s) could not be copied to iCloud")
        }
    }
}
