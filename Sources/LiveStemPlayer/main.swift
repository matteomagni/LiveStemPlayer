import Foundation
import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let backend = LiveStemBackend()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView(backend: backend)
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1580, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.center()
        window.title = "Live Stem Player & Mixer (macOS)"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        
        app.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()