import AppKit
import SwiftUI

/// Lists previously extracted streams and lets you resume one without re-running extraction. Each row
/// fast-paths playback through `PolluxAppModel.playRecord` (no Chromium). A Clear button empties the
/// list. Retention is configured in Settings ▸ Extraction ▸ Previous Streams.
struct PreviousStreamsWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @ObservedObject private var library = StreamLibraryStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var playingRecordID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Previous Streams (\(library.records.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") {
                    library.clear()
                }
                .disabled(library.records.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if library.records.isEmpty {
                ContentUnavailableView {
                    Label("No Previous Streams", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Streams you extract are saved here so you can resume them without re-running extraction. Adjust how many are kept in Settings.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else {
                List(library.records) { record in
                    row(for: record)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func row(for record: StreamRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(record.streamURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text("\(record.kind.displayName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                play(record)
            } label: {
                if playingRecordID == record.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(playingRecordID != nil)
        }
        .padding(.vertical, 4)
    }

    private func play(_ record: StreamRecord) {
        playingRecordID = record.id
        Task {
            let started = await model.playRecord(record)
            playingRecordID = nil
            if started {
                openWindow(id: PolluxAppModel.playerWindowID)
            } else {
                openWindow(id: PolluxAppModel.errorWindowID)
            }
        }
    }
}
