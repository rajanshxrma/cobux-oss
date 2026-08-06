import SwiftUI
import SwiftData

/// The one-tap export safety net promised for the 2.0.0 migration but never actually
/// built: "First 2.0.0 launch offers a one-tap export before touching anything." Shown
/// at most once ever, gated by `hasOfferedPostUpgradeExport`, and only when there's
/// existing content actually worth protecting -- a genuinely fresh install has nothing
/// to export yet, so it's silently skipped for that case rather than shown empty.
struct PostUpgradeExportPromptView: View {
    let books: [Book]
    let chatMessages: [ChatMessage]
    @Environment(\.dismiss) private var dismiss
    @State private var showExporter = false
    @State private var exportDocument: BackupFileDocument?
    @State private var exportMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.cobuxAccent)
                    .padding(.top, 24)

                Text("Back Up Before You Continue")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("This update changes how Cobux stores your books, chat history, and quiz progress. As a precaution, you can save a backup file now -- it takes one tap and costs nothing to skip.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

                Button {
                    exportNow()
                } label: {
                    Text("Export Backup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cobuxAccent)
                .padding(.horizontal, 24)

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Skip for Now") { dismiss() }
                    .padding(.bottom, 24)
            }
            .background(Color.cobuxBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "cobux-backup") { result in
            switch result {
            case .success: exportMessage = "Backup exported. You can restore it anytime from Settings."
            case .failure(let error): exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportNow() {
        do {
            let data = try BackupService.exportData(books: books, chatMessages: chatMessages)
            exportDocument = BackupFileDocument(data: data)
            showExporter = true
        } catch {
            exportMessage = "Couldn't create backup: \(error.localizedDescription)"
        }
    }
}
