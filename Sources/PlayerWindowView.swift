import SwiftUI

struct PlayerWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel

    var body: some View {
        Group {
            if let player = model.player {
                VStack(spacing: 0) {
                    AVPlayerViewContainer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if model.playbackNotice != nil || model.playbackError != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            if let notice = model.playbackNotice {
                                NoticeCard(text: notice)
                            }

                            if let playbackError = model.playbackError {
                                UserFacingErrorCard(error: playbackError)
                            }
                        }
                        .padding(12)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "play.tv",
                    description: Text("Start a URL from the main Pollux window and the extracted stream will open here.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }
}
