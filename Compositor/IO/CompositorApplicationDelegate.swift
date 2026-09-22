import AppKit

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = ProjectWorkspace()
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    /// This unofficial fork checks its own releases and never invokes the upstream binary updater.
    lazy var forkUpdates = ForkUpdateChecker { [weak self] in
        guard let self else { return false }
        return self.workspace.window?.isVisible == true && self.workspace.canSwitch
            && self.session.effectsEditing == nil && self.session.transformEdit == nil
            && self.session.cropRect == nil && self.session.lassoDraft == nil && self.session.shapeDraft == nil
            && !self.session.showsRawDevelop
    }

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            showEditor?()
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        forkUpdates.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) { forkUpdates.applicationDidBecomeActive() }

    func applicationWillTerminate(_ notification: Notification) { forkUpdates.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.canSwitch else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.confirmQuit()) }
        return .terminateLater
    }
}
