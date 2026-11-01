import SwiftUI
import AppKit
import Carbon
import Combine
import GhostClipboardCore

// MARK: - Key-able Floating Panel for Option+Space Palette

public final class FloatingPalettePanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.hasShadow = true
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}

// MARK: - AppDelegate (Global Hotkey + Menu Bar + Window Management)

@MainActor
public final class GhostAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public let coordinator = ClipboardCoordinator()
    private var floatingPanel: FloatingPalettePanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var monitoringMenuItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var cancellables = Set<AnyCancellable>()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        coordinator.seedSampleDeveloperClipsIfEmpty()
        coordinator.startMonitoring()

        setupMenuBarExtra()
        setupFloatingPalettePanel()
        registerGlobalHotKey()
        observePreferences()
        applyThemeAppearance(coordinator.preferences.themeMode)

        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.syncExternalPreferencesIfNeeded()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopMonitoring()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    private func observePreferences() {
        coordinator.$preferences
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                guard let self = self else { return }
                self.statusItem?.isVisible = prefs.showMenuBarIcon
                self.updateMenuBarState(prefs: prefs)
                self.applyThemeAppearance(prefs.themeMode)
            }
            .store(in: &cancellables)
    }

    private func applyThemeAppearance(_ themeMode: String) {
        let appearance: NSAppearance?
        switch themeMode {
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        case "light":
            appearance = NSAppearance(named: .aqua)
        default:
            appearance = nil
        }
        if NSApp.appearance != appearance {
            NSApp.appearance = appearance
        }
        settingsWindow?.appearance = appearance
        floatingPanel?.appearance = appearance
    }

    // MARK: - Menu Bar Status Item

    private func setupMenuBarExtra() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = coordinator.preferences.showMenuBarIcon
        if let button = item.button {
            let symbol = coordinator.preferences.monitoringPaused ? "shield.slash" : "shield.lefthalf.filled"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GhostClipboard")
            button.action = #selector(statusBarClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Toggle Floating Palette (⌥Space)", action: #selector(toggleFloatingPalette), keyEquivalent: " "))
        menu.addItem(NSMenuItem(title: "Open Full Workspace", action: #selector(openMainWorkspace), keyEquivalent: "1"))
        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(title: "Pause Monitoring", action: #selector(toggleMonitoring), keyEquivalent: "p")
        menu.addItem(pauseItem)
        self.monitoringMenuItem = pauseItem

        menu.addItem(NSMenuItem(title: "Clear System Clipboard Now", action: #selector(clearClipboardNow), keyEquivalent: "k"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit GhostClipboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for menuItem in menu.items {
            if menuItem.target == nil && menuItem.action != #selector(NSApplication.terminate(_:)) {
                menuItem.target = self
            }
        }
        item.menu = menu
        self.statusItem = item
        updateMenuBarState(prefs: coordinator.preferences)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        coordinator.syncExternalPreferencesIfNeeded()
        updateMenuBarState(prefs: coordinator.preferences)
    }

    private func updateMenuBarState(prefs: GhostPreferences) {
        if let button = statusItem?.button {
            let symbol = prefs.monitoringPaused ? "shield.slash" : "shield.lefthalf.filled"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GhostClipboard")
        }
        if let pauseItem = monitoringMenuItem {
            pauseItem.title = prefs.monitoringPaused ? "Resume Monitoring (Paused)" : "Pause Monitoring"
            pauseItem.state = prefs.monitoringPaused ? .on : .off
        }
    }

    @objc private func statusBarClicked() {
        toggleFloatingPalette()
    }

    @objc public func toggleFloatingPalette() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc public func openMainWorkspace() {
        floatingPanel?.orderOut(nil)
        for win in NSApp.windows where !(win is NSPanel) && win != settingsWindow {
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func toggleMonitoring() {
        coordinator.preferences.monitoringPaused.toggle()
    }

    @objc public func clearClipboardNow() {
        coordinator.clearSystemClipboard()
    }

    @objc public func openSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsWindowView(coordinator: coordinator)
        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "GhostClipboard Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
        applyThemeAppearance(coordinator.preferences.themeMode)
    }

    // MARK: - Floating Palette Setup

    private func setupFloatingPalettePanel() {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 480)
        let panel = FloatingPalettePanel(contentRect: rect)

        let paletteView = FloatingPaletteView(
            coordinator: coordinator,
            onOpenFullHistory: { [weak self] in
                self?.openMainWorkspace()
            },
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            },
            onDismiss: { [weak panel] in
                panel?.orderOut(nil)
            }
        )

        panel.contentView = NSHostingView(rootView: paletteView)
        panel.center()
        self.floatingPanel = panel
    }

    // MARK: - Global Carbon Hotkey Registration (Option + Space)

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<GhostAppDelegate>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    delegate.toggleFloatingPalette()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x47485354), id: 1) // 'GHST'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - Unified Main Entry Point (Handles Case-Insensitive APFS CLI & GUI Dispatch)

@main
enum GhostClipboardMain {
    static func main() {
        let args = CommandLine.arguments
        if GhostCLIRunner.shouldDispatchCLI(from: args) {
            GhostCLIRunner.runAndExit(arguments: Array(args.dropFirst()))
        }
        GhostClipboardApp.main()
    }
}

struct GhostClipboardApp: App {
    @NSApplicationDelegateAdaptor(GhostAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("GhostClipboard Workspace") {
            FullHistoryWindowView(
                coordinator: appDelegate.coordinator,
                onOpenSettings: {
                    appDelegate.openSettingsWindow()
                }
            )
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandMenu("Clipboard") {
                Button("Toggle Floating Palette") {
                    appDelegate.toggleFloatingPalette()
                }
                .keyboardShortcut(" ", modifiers: [.option])

                Button(appDelegate.coordinator.preferences.monitoringPaused ? "Resume Monitoring" : "Pause Monitoring") {
                    appDelegate.toggleMonitoring()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Clear System Clipboard") {
                    appDelegate.clearClipboardNow()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
