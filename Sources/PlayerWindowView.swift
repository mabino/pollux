import SwiftUI

struct PlayerWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel

    var body: some View {
        Group {
            if let player = model.player {
                VStack(spacing: 0) {
                    AVPlayerViewContainer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        if let notice = model.playbackNotice {
                            NoticeCard(text: notice)
                        }

                        if let playbackError = model.playbackError {
                            UserFacingErrorCard(error: playbackError)
                        }

                        if let sourcePageURL = model.sourcePageURL, let extractedStreamURL = model.extractedStreamURL {
                            GroupBox("Playback Details") {
                                VStack(alignment: .leading, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Source Page")
                                            .font(.subheadline.weight(.semibold))
                                        Text(sourcePageURL.absoluteString)
                                            .font(.callout.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Extracted Stream")
                                            .font(.subheadline.weight(.semibold))
                                        Text(extractedStreamURL.absoluteString)
                                            .font(.callout.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "play.tv",
                    description: Text("Start a URL from the main Pollux window and the extracted stream will open here.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 580)
    }
}
