import SwiftUI

@main
struct TernApp: App {
    @State private var model: AppModel

    init() {
        SystemEnvironment.bootstrap()
        let settings = SettingsStore()
        _model = State(initialValue: AppModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            TerminalScreen(model: model)
                .tint(ChromeColor.accent)
        }
    }
}
