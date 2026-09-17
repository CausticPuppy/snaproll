import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private let preferencesWC = PreferencesWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the saved appearance before any window is shown so there's no
        // flash of the wrong mode.
        AppearancePreference.current.apply()

        let controller = MainWindowController()
        mainWindowController = controller
        // Build the menu now that the controller exists, so File/View menu items
        // can target it directly (project load/save and the instrument/effect
        // view switch live on the window controller). Preferences targets the
        // preferences controller.
        NSApp.mainMenu = buildMainMenu(menuTarget: controller, preferencesTarget: preferencesWC)
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
func buildMainMenu(menuTarget: AnyObject? = nil, preferencesTarget: AnyObject? = nil) -> NSMenu {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Snaproll",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    let settings = appMenu.addItem(withTitle: "Settings…",
                                   action: #selector(PreferencesWindowController.showPreferences(_:)),
                                   keyEquivalent: ",")
    settings.target = preferencesTarget
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Snaproll",
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
    fileMenu.addItem(.separator())
    let writeGroups = fileMenu.addItem(withTitle: "Write Group Map",
                                       action: #selector(MainWindowController.writeGroupMap(_:)),
                                       keyEquivalent: "")
    for item in [open, saveAs, writeGroups] { item.target = menuTarget }
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
    viewMenu.addItem(.separator())
    let groups = viewMenu.addItem(withTitle: "Group Editor",
                                  action: #selector(MainWindowController.showGroupEditor(_:)),
                                  keyEquivalent: "g")
    let toneCopy = viewMenu.addItem(withTitle: "Tone Copy",
                                    action: #selector(MainWindowController.showToneCopy(_:)),
                                    keyEquivalent: "t")
    let monitor = viewMenu.addItem(withTitle: "Monitor",
                                   action: #selector(MainWindowController.showMonitor(_:)),
                                   keyEquivalent: "M")
    for item in [instrument, effect, groups, toneCopy, monitor] { item.target = menuTarget }
    viewMenuItem.submenu = viewMenu
    return mainMenu
}

/// Sets the Dock/app icon from the bundled logo. The `.app` bundle also carries
/// an `.icns` (for the Finder icon); this sets the running app's Dock icon, and
/// makes an icon appear when launched via `swift run`, which has no bundle icon.
///
/// We search resource locations by hand rather than touch `Bundle.module`: that
/// SwiftPM-generated accessor is a lazy static that calls `fatalError` when it
/// can't locate the resource bundle, and merely reading it would crash the app
/// (it can't be guarded with `if let`). That trap fires once the packaged .app
/// is copied to another machine, where the resource-bundle lookup fails.
func applyAppIcon(to app: NSApplication) {
    let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
    let relativePaths = [
        "AppIcon.icns",                            // packaged .app (Contents/Resources)
        "Snaproll_SnaprollApp.bundle/Contents/Resources/AppIcon.png", // swift run, Xcode 27+ (swiftbuild)
        "Snaproll_SnaprollApp.bundle/AppIcon.png", // swift run, older toolchains + packaged fallback
    ]
    for root in roots {
        for path in relativePaths {
            let url = root.appendingPathComponent(path)
            if let icon = NSImage(contentsOf: url) {
                app.applicationIconImage = icon
                return
            }
        }
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
