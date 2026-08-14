import Cocoa
import SwiftUI
import Combine

@main
struct RemindersMenuBar: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        if #available(macOS 14.0, *) {
            Window(String(""), id: "SettingsOpener") {
                SettingsOpenerView()
            }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 0, height: 0)
        }

        Settings {
            SettingsView()
        }
        .commands {
            AppCommands()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // swiftlint:disable:next implicitly_unwrapped_optional
    static private(set) var shared: AppDelegate!

    private var didCloseCancellationToken: AnyCancellable?
    private var didShowCancellationToken: AnyCancellable?
    private var didCloseEventDate = Date.distantPast
    private var suppressNextPopoverHideNotification = false

    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    
    private var sharedAuthorizationErrorMessage: String?
    private var currentMenuBarCount = 0
    private var currentReminderPreview: String?

    let popover = NSPopover()
    lazy var statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private(set) lazy var remindersData = RemindersData()
    private(set) lazy var copyShortcutCoordinator = CopyShortcutCoordinator()
    private(set) var mainHostingController: NSHostingController<AnyView>!
    private(set) var presentationCoordinator: MainPresentationCoordinator!

    private func makeMainHostingController() -> NSHostingController<AnyView> {
        let contentView = ContentView()
        return NSHostingController(
            rootView: AnyView(contentView
                .environmentObject(remindersData)
                .environmentObject(copyShortcutCoordinator)
                .environmentObject(presentationCoordinator)
            )
        )
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self

        presentationCoordinator = MainPresentationCoordinator(popover: popover)
        configurePopover()
        configureMenuBarButton()
        configureKeyboardShortcut()
        configureDidCloseNotification()
        configureDidShowNotification()

        if RemindersService.shared.isAuthorized {
            ensureMainContentConfigured()
            presentationCoordinator.restorePresentationIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopOutsideClickMonitors()
    }

    private func configurePopover() {
        setMainPopoverSize(size: UserPreferences.shared.mainPopoverSize)
        popover.animates = false
        popover.behavior = .transient
    }

    private func ensureMainContentConfigured() {
        guard mainHostingController == nil else { return }
        let hostingController = makeMainHostingController()
        mainHostingController = hostingController
        presentationCoordinator.configure(hostingController: hostingController)
    }
    
    func updateMenuBarCount(to count: Int) {
        currentMenuBarCount = count
        applyMenuBarButtonAppearance()
    }

    func updateMenuBarReminderPreview(_ title: String?) {
        currentReminderPreview = title
        applyMenuBarButtonAppearance()
    }

    private func applyMenuBarButtonAppearance() {
        let reminderPreview = currentReminderPreview
        let menuBarCount = currentMenuBarCount

        if let reminderPreview {
            let hideCounter = UserPreferences.shared.hideCounterWhenReminderPreviewIsShown
            if !hideCounter && menuBarCount > 0 {
                statusBarItem.button?.title = "\(menuBarCount) · \(reminderPreview)"
            } else {
                statusBarItem.button?.title = reminderPreview
            }
        } else {
            let buttonTitle = menuBarCount > 0 ? String(menuBarCount) : ""
            statusBarItem.button?.title = buttonTitle
        }

        loadMenuBarIcon()
    }
    
    func loadMenuBarIcon() {
        let isContentVisible = currentMenuBarCount > 0 || currentReminderPreview != nil
        let shouldHideIcon = UserPreferences.shared.hideMenuBarIconWhenContentIsShown && isContentVisible
        statusBarItem.button?.image = shouldHideIcon ? nil : UserPreferences.shared.reminderMenuBarIcon.image
    }
    
    private func configureMenuBarButton() {
        loadMenuBarIcon()
        statusBarItem.button?.imagePosition = .imageLeading
        statusBarItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusBarItem.button?.action = #selector(handleStatusBarButtonAction)
    }
    
    private func configureKeyboardShortcut() {
        KeyboardShortcutService.shared.action(for: .openRemindersMenuBar) { [weak self] in
            self?.showMainPresentation()
        }
    }

    @objc private func handleStatusBarButtonAction() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            toggleMainPresentation()
        }
    }

    private func showRightClickMenu() {
        let menu = RightClickMenuHelper.shared.buildRightClickMenu()
        statusBarItem.menu = menu
        statusBarItem.button?.performClick(nil)
        statusBarItem.menu = nil
    }

    @objc private func toggleMainPresentation() {
        guard RemindersService.shared.isAuthorized else {
            requestAuthorization()
            return
        }

        ensureMainContentConfigured()
        guard let button = statusBarItem.button else { return }

        if presentationCoordinator.isDetached {
            presentationCoordinator.showDetached()
        } else if popover.isShown || didCloseEventDate.elapsedTimeInterval < 0.01 {
            didCloseEventDate = .distantPast
            popover.performClose(button)
        } else {
            presentationCoordinator.showDocked(relativeTo: button)
        }
    }

    private func showMainPresentation() {
        guard RemindersService.shared.isAuthorized else {
            requestAuthorization()
            return
        }

        ensureMainContentConfigured()
        guard let button = statusBarItem.button else { return }

        if presentationCoordinator.isDetached {
            presentationCoordinator.showDetached()
        } else {
            presentationCoordinator.showDocked(relativeTo: button)
        }
    }

    // - MARK: Popover sizing

    func setMainPopoverSize(size: NSSize, persist: Bool = false) {
        let clampedSize = clampedMainWindowSize(size)
        popover.contentSize = clampedSize

        if persist {
            UserPreferences.shared.mainPopoverSize = clampedSize
        }
    }

    func detachMainWindow() {
        guard RemindersService.shared.isAuthorized else {
            requestAuthorization()
            return
        }
        ensureMainContentConfigured()
        suppressNextPopoverHideNotification = popover.isShown
        presentationCoordinator.detach(relativeTo: statusBarItem.button)
    }

    func reattachMainWindow() {
        guard let button = statusBarItem.button else { return }
        ensureMainContentConfigured()
        presentationCoordinator.reattach(relativeTo: button)
    }

    private func mainScreenVisibleFrame() -> NSRect {
        if let screen = statusBarItem.button?.window?.screen {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    }

    func clampedMainWindowSize(_ size: NSSize) -> NSSize {
        let screenSize = mainScreenVisibleFrame()

        let maxWidth = (screenSize.width - MainPopoverSizing.minWidthPadding)
            .constrainedTo(min: MainPopoverSizing.minSize.width, max: MainPopoverSizing.maxSize.width)
        let width = size.width.constrainedTo(min: MainPopoverSizing.minSize.width, max: maxWidth)

        let maxHeight = (screenSize.height - MainPopoverSizing.minHeightPadding)
            .constrainedTo(min: MainPopoverSizing.minSize.height, max: MainPopoverSizing.maxSize.height)
        let height = size.height.constrainedTo(min: MainPopoverSizing.minSize.height, max: maxHeight)

        return NSSize(width: width, height: height)
    }

    // - MARK: Fallback for popover open/close behavior

    private func configureDidCloseNotification() {
        // NOTE: There is an issue where if the menu bar button is clicked on its top part to close the popover
        // there will be a didClose event and then togglePopover will be called (reopening the popover).
        // didCloseEventDate is saved to figure out if the event is recent and the popover should not be reopened.
        didCloseCancellationToken = NotificationCenter.default
            .publisher(for: NSPopover.didCloseNotification, object: popover)
            .sink { [weak self] _ in
                self?.didCloseEventDate = Date()
                self?.stopOutsideClickMonitors()
                guard let self else { return }
                if self.suppressNextPopoverHideNotification {
                    self.suppressNextPopoverHideNotification = false
                } else {
                    NotificationCenter.default.post(name: .mainPresentationDidHide, object: self.presentationCoordinator)
                }
            }
    }

    private func configureDidShowNotification() {
        // SwiftUI `Menu` inside an NSPopover can occasionally break the system's transient dismissal behavior.
        // Install a fallback outside-click monitor while the popover is visible.
        didShowCancellationToken = NotificationCenter.default
            .publisher(for: NSPopover.didShowNotification, object: popover)
            .sink { [weak self] _ in
                self?.startOutsideClickMonitors()
            }
    }

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()

        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                if self?.isClickOutsidePopover(event: event) ?? false {
                    self?.popover.performClose(nil)
                }
            }
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Return nil to swallow the event when dismissing, matching native transient popover behavior.
            let shouldClose = MainActor.assumeIsolated {
                self?.isClickOutsidePopover(event: event) ?? false
            }
            if shouldClose {
                self?.popover.performClose(nil)
            }
            return shouldClose ? nil : event
        }
    }

    private func stopOutsideClickMonitors() {
        if let monitor = globalOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalOutsideClickMonitor = nil
        }
        if let monitor = localOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            localOutsideClickMonitor = nil
        }
    }

    private func isClickOutsidePopover(event: NSEvent) -> Bool {
        guard popover.isShown else { return false }

        let mouseLocation = NSEvent.mouseLocation

        if isMouseInsideStatusBarButton(mouseLocation) {
            return false
        }

        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(mouseLocation) {
            return false
        }

        if let window = NSApp.window(withWindowNumber: event.windowNumber),
           window.frame.contains(mouseLocation) {
            return false
        }

        return true
    }

    private func isMouseInsideStatusBarButton(_ mouseLocation: NSPoint) -> Bool {
        guard let button = statusBarItem.button,
              let window = button.window else {
            return false
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        return rectOnScreen.contains(mouseLocation)
    }
}

@MainActor
final class MainPresentationCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private static let frameAutosaveName = "MainDetachedWindowFrame"

    @Published private(set) var isDetached: Bool

    let popover: NSPopover
    private var hostingController: NSViewController?
    private var detachedPanel: NSPanel?

    init(popover: NSPopover) {
        self.popover = popover
        isDetached = UserPreferences.shared.mainWindowIsDetached
        super.init()
    }

    func configure(hostingController: NSViewController) {
        precondition(self.hostingController == nil, "The main hosting controller must only be configured once")
        self.hostingController = hostingController
    }

    func restorePresentationIfNeeded() {
        if isDetached {
            attachToDetachedPanel()
            showDetached()
        } else {
            attachToPopover()
        }
    }

    func attachToPopover() {
        guard let hostingController else { return }
        if detachedPanel?.contentViewController === hostingController {
            detachedPanel?.contentViewController = nil
        }
        if popover.contentViewController !== hostingController {
            popover.contentViewController = hostingController
        }
    }

    func showDocked(relativeTo button: NSStatusBarButton) {
        attachToPopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func detach(relativeTo button: NSStatusBarButton?) {
        guard !isDetached else {
            showDetached()
            return
        }

        let sourceFrame = popover.contentViewController?.view.window?.frame
        FilterPanelController.shared.close()
        popover.performClose(nil)
        popover.contentViewController = nil

        isDetached = true
        UserPreferences.shared.mainWindowIsDetached = true
        attachToDetachedPanel(sourceFrame: sourceFrame, relativeTo: button)
        showDetached()
    }

    func reattach(relativeTo button: NSStatusBarButton) {
        guard isDetached else {
            showDocked(relativeTo: button)
            return
        }

        FilterPanelController.shared.close()
        detachedPanel?.orderOut(nil)
        detachedPanel?.contentViewController = nil
        isDetached = false
        UserPreferences.shared.mainWindowIsDetached = false
        attachToPopover()
        showDocked(relativeTo: button)
    }

    func showDetached() {
        guard isDetached else { return }
        attachToDetachedPanel()
        NSApp.activate(ignoringOtherApps: true)
        detachedPanel?.makeKeyAndOrderFront(nil)
    }

    func hideCurrentPresentation() {
        FilterPanelController.shared.close()
        if isDetached {
            detachedPanel?.orderOut(nil)
            NotificationCenter.default.post(name: .mainPresentationDidHide, object: self)
        } else {
            popover.performClose(nil)
        }
    }

    func activeMainWindow(for event: NSEvent) -> NSWindow? {
        let window = isDetached ? detachedPanel : popover.contentViewController?.view.window
        guard window?.isVisible == true, event.window === window else { return nil }
        return window
    }

    func resizeDockedContent(to size: NSSize, persist: Bool) {
        guard !isDetached else { return }
        AppDelegate.shared.setMainPopoverSize(size: size, persist: persist)
    }

    var dockedContentSize: NSSize {
        popover.contentSize
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        FilterPanelController.shared.close()
        NotificationCenter.default.post(name: .mainPresentationDidHide, object: self)
        return false
    }

    private func attachToDetachedPanel(sourceFrame: NSRect? = nil, relativeTo button: NSStatusBarButton? = nil) {
        guard let hostingController else { return }
        let panel = detachedPanel ?? makeDetachedPanel(sourceFrame: sourceFrame, relativeTo: button)
        if popover.contentViewController === hostingController {
            popover.contentViewController = nil
        }
        if panel.contentViewController !== hostingController {
            panel.contentViewController = hostingController
        }
        detachedPanel = panel
    }

    private func makeDetachedPanel(sourceFrame: NSRect?, relativeTo button: NSStatusBarButton?) -> NSPanel {
        let initialSize = AppDelegate.shared.clampedMainWindowSize(popover.contentSize)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = AppConstants.appName
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        if #available(macOS 13.0, *) {
            panel.collectionBehavior.insert(.canJoinAllApplications)
        }
        panel.minSize = MainPopoverSizing.minSize
        panel.maxSize = MainPopoverSizing.maxSize
        panel.delegate = self
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            if let sourceFrame {
                panel.setFrameOrigin(sourceFrame.origin)
            } else if let screen = button?.window?.screen ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: visibleFrame.midX - initialSize.width / 2,
                    y: visibleFrame.midY - initialSize.height / 2
                ))
            }
        }
        ensureVisible(panel)
        return panel
    }

    private func ensureVisible(_ panel: NSPanel) {
        let screen = NSScreen.screens.max { first, second in
            first.visibleFrame.intersection(panel.frame).area < second.visibleFrame.intersection(panel.frame).area
        } ?? NSScreen.main
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let size = NSSize(
            width: min(panel.frame.width, visibleFrame.width),
            height: min(panel.frame.height, visibleFrame.height)
        )
        let origin = NSPoint(
            x: panel.frame.minX.constrainedTo(min: visibleFrame.minX, max: visibleFrame.maxX - size.width),
            y: panel.frame.minY.constrainedTo(min: visibleFrame.minY, max: visibleFrame.maxY - size.height)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

// - MARK: Authorization functions

extension AppDelegate: NSAlertDelegate {
    private func requestAuthorization() {
        RemindersService.shared.requestAccess { [weak self] granted, errorMessage in
            if granted {
                return
            }
                
            print("Access to reminders not granted:", errorMessage ?? "no error description")
            DispatchQueue.main.async {
                self?.sharedAuthorizationErrorMessage = errorMessage
                self?.presentNoAuthorizationAlert()
            }
        }
    }
    
    private func presentNoAuthorizationAlert() {
        let alert = NSAlert()
        alert.messageText = rmbLocalized(.appNoRemindersAccessAlertMessage, arguments: AppConstants.appName)
        let reasonDescription = rmbLocalized(
            .appNoRemindersAccessAlertReasonDescription,
            arguments: AppConstants.appName
        )
        let actionDescription = rmbLocalized(
            .appNoRemindersAccessAlertActionDescription,
            arguments: AppConstants.appName
        )
        alert.informativeText = "\(reasonDescription)\n\(actionDescription)"
        if sharedAuthorizationErrorMessage != nil {
            alert.delegate = self
            alert.showsHelp = true
        }
        
        alert.addButton(withTitle: rmbLocalized(.okButton))
        alert.addButton(withTitle: rmbLocalized(.openSystemPreferencesButton))
        alert.addButton(withTitle: rmbLocalized(.appQuitButton)).hasDestructiveAction = true
        
        NSApp.activate(ignoringOtherApps: true)
        let modalResponse = alert.runModal()
        switch modalResponse {
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            NSApp.terminate(self)
        default:
            sharedAuthorizationErrorMessage = nil
        }
    }
    
    internal func alertShowHelp(_ alert: NSAlert) -> Bool {
        let helpAlert = NSAlert()
        let errorDescription = sharedAuthorizationErrorMessage ?? "no error description"
        helpAlert.icon = NSImage(systemSymbolName: "calendar.badge.exclamationmark", accessibilityDescription: nil)
        helpAlert.messageText = rmbLocalized(.appNoRemindersAccessAlertMessage, arguments: AppConstants.appName)
        helpAlert.informativeText = "Authorization error: \(errorDescription)"
        helpAlert.runModal()
        
        return true
    }
}
