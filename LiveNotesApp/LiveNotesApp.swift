import AppKit
import SwiftUI

@main
@MainActor
final class LiveNotesApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = AppModel.launchModel(arguments: CommandLine.arguments)
    private let isUITest = CommandLine.arguments.contains("--ui-test")

    static func main() {
        let app = NSApplication.shared
        let delegate = LiveNotesApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .environmentObject(model)
            .frame(minWidth: 1120, minHeight: 720)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "LiveNotes"
        window.contentView = NSHostingView(rootView: rootView)
        if !isUITest {
            window.setFrameAutosaveName("LiveNotesMainWindow")
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
