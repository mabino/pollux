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

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        Window("Player", id: PolluxAppModel.playerWindowID) {
            PlayerWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
