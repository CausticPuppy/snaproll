import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        mainWindowController = controller
        // Build the menu now that the controller exists, so File/View menu items
        // can target it directly (project load/save and the instrument/effect
        // view switch live on the window controller).
        NSApp.mainMenu = buildMainMenu(menuTarget: controller)
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
func buildMainMenu(menuTarget: AnyObject? = nil) -> NSMenu {
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

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    let open = fileMenu.addItem(withTitle: "Open Project…",
                                action: #selector(MainWindowController.openProject(_:)), keyEquivalent: "o")
    let saveAs = fileMenu.addItem(withTitle: "Save Project As…",
                                  action: #selector(MainWindowController.saveProjectAs(_:)), keyEquivalent: "S")
    for item in [open, saveAs] { item.target = menuTarget }
    fileMenuItem.submenu = fileMenu

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenuItem.submenu = editMenu

    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    let instrument = viewMenu.addItem(withTitle: "Instrument",
                                      action: #selector(MainWindowController.showInstrumentView(_:)),
                                      keyEquivalent: "1")
    let effect = viewMenu.addItem(withTitle: "Effect",
                                  action: #selector(MainWindowController.showEffectView(_:)),
                                  keyEquivalent: "2")
    for item in [instrument, effect] { item.target = menuTarget }
    viewMenuItem.submenu = viewMenu
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
// The full menu (with the File menu targeting the window controller) is
// installed in applicationDidFinishLaunching once the controller exists.
applyAppIcon(to: app)
app.setActivationPolicy(.regular)
app.run()
