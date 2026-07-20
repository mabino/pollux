import SwiftUI

@main
struct PolluxApp: App {
    @StateObject private var model = PolluxAppModel()

    var body: some Scene {
        WindowGroup("Pollux") {
            MainWindowView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 160)
        .commands {
            PolluxCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
