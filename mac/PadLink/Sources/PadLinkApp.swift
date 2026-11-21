import SwiftUI

@main
struct PadLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("PadLink", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.isStreaming ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isActive ? "Trennen" : "Mit Pad verbinden") { model.bigButton() }
            .disabled(!model.permissionsOK)
        Divider()
        Button("PadLink öffnen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
