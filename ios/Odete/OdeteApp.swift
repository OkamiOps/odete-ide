import OdeteApp
import SwiftUI

@main
struct OdeteMain: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands { OdeteCommands() }
    }
}
