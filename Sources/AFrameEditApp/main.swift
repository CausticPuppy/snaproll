import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave MODE_EDIT_EXT so the hardware panel is usable again.
        mainWindowController?.shutDown()
    }
}

// Minimal main menu so ⌘Q works when launched via `swift run`.
func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About aFrame Edit",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit aFrame Edit",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenuItem.submenu = editMenu
    return mainMenu
}

/// Sets the Dock/app icon from the bundled logo. The `.app` bundle also carries
/// an `.icns` (for the Finder icon), but this makes the icon appear when the app
/// is launched via `swift run`, which has no bundle icon.
func applyAppIcon(to app: NSApplication) {
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
       let icon = NSImage(contentsOf: url) {
        app.applicationIconImage = icon
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = buildMainMenu()
applyAppIcon(to: app)
app.setActivationPolicy(.regular)
app.run()
