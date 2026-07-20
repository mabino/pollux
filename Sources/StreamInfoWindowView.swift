import AppKit
import SwiftUI

struct StreamInfoWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let sourcePageURL = model.sourcePageURL, let extractedStreamURL = model.extractedStreamURL {
                GroupBox("Source Page") {
                    HStack {
                        Text(sourcePageURL.absoluteString)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sourcePageURL.absoluteString, forType: .string)
                        }
                        .font(.caption)
                    }
                    .padding(4)
                }

                GroupBox("Extracted Stream") {
                    HStack {
                        Text(extractedStreamURL.absoluteString)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(extractedStreamURL.absoluteString, forType: .string)
                        }
                        .font(.caption)
                    }
                    .padding(4)
                }
            } else {
                ContentUnavailableView(
                    "No Active Stream",
                    systemImage: "info.circle",
                    description: Text("Start playing a stream to view its extraction details here.")
                )
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 200)
    }
}
