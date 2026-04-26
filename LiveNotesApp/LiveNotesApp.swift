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
            .frame(
                minWidth: isUITest ? 900 : 1120,
                minHeight: isUITest ? 640 : 720
            )

        let windowSize = NSSize(
            width: isUITest ? 980 : 1360,
            height: isUITest ? 720 : 860
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        if isUITest {
            window.setFrame(testWindowFrame(size: windowSize), display: true)
        } else {
            window.center()
        }
        window.title = "LiveNotes"
        window.contentView = NSHostingView(rootView: rootView)
        if !isUITest {
            window.setFrameAutosaveName("LiveNotesMainWindow")
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func testWindowFrame(size: NSSize) -> NSRect {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let origin = NSPoint(
            x: max(frame.minX, frame.midX - size.width / 2),
            y: max(frame.minY, frame.midY - size.height / 2)
        )
        return NSRect(origin: origin, size: size)
    }
}
