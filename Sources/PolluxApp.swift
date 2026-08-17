import SwiftUI

@main
struct PolluxApp: App {
    @NSApplicationDelegateAdaptor(PolluxAppDelegate.self) private var appDelegate
    @StateObject private var model = PolluxAppModel()

    var body: some Scene {
        WindowGroup(id: PolluxAppModel.mainWindowID, for: StreamRequest.self) { $request in
            MainWindowView(request: request)
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 210)
        .commands {
            PolluxCommands(model: model)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(viewModel: appDelegate.updaterViewModel)
            }
        }

        Settings {
            SettingsView(updatesSection: AnyView(UpdatesSectionView(viewModel: appDelegate.updaterViewModel)))
                .environmentObject(model)
        }

        Window("Pollux Error", id: PolluxAppModel.errorWindowID) {
            ErrorWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 460, height: 220)
        .windowResizability(.contentSize)

        Window("Player", id: PolluxAppModel.playerWindowID) {
            PlayerWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 1100, height: 720)

        Window("Stream Info", id: PolluxAppModel.infoWindowID) {
            StreamInfoWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 550, height: 260)

        Window("Extraction Log", id: PolluxAppModel.logWindowID) {
            ExtractionLogWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 700, height: 450)
    }
}

struct PolluxCommands: Commands {
    @ObservedObject var model: PolluxAppModel
    @ObservedObject private var recents = RecentStreamsStore.shared
    @Environment(\.openWindow) private var openWindow

    init(model: PolluxAppModel) {
        self.model = model
    }

    var body: some Commands {
        // Replace the stock "New Window" item with stream-oriented actions.
        CommandGroup(replacing: .newItem) {
            Button("Open New Stream…") {
                openWindow(id: PolluxAppModel.mainWindowID, value: StreamRequest())
            }
            .keyboardShortcut("n", modifiers: [.command])

            Menu("Open Recent") {
                if recents.urls.isEmpty {
                    Button("No Recent Streams") {}
                        .disabled(true)
                } else {
                    ForEach(recents.urls, id: \.self) { url in
                        Button(url) {
                            openWindow(id: PolluxAppModel.mainWindowID, value: StreamRequest(url: url))
                        }
                    }

                    Divider()

                    Button("Clear Menu") {
                        recents.clear()
                    }
                }
            }
        }

        CommandGroup(after: .newItem) {
            Button("Get Info") {
                openWindow(id: PolluxAppModel.infoWindowID)
            }
            .keyboardShortcut("i", modifiers: [.command])
        }

        CommandGroup(after: .windowArrangement) {
            Button("Extraction Log") {
                openWindow(id: PolluxAppModel.logWindowID)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
