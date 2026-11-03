import AppKit

/// Retains NSAlert's existing validation/call sites and response codes while presenting
/// the same opaque navy surfaces as Mission Control. Secure fields remain NSSecureTextField.
final class MissionAlert: NSAlert {
    override func runModal() -> NSApplication.ModalResponse {
        let controller = MissionAlertController(alert: self)
        return controller.run()
    }
}

private final class MissionAlertController: NSObject, NSWindowDelegate {
    private let alert: NSAlert
    private let panel: NSPanel
    private let background = NSColor(srgbRed: 0.055, green: 0.098, blue: 0.161, alpha: 1)
    init(alert: NSAlert) {
        self.alert = alert
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "TokenPulse"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = background
        panel.isReleasedWhenClosed = false
    }
    func run() -> NSApplication.ModalResponse {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(wrappingLabelWithString: alert.messageText)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = NSColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: 1)
        let detail = NSTextField(wrappingLabelWithString: alert.informativeText)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(srgbRed: 0.60, green: 0.68, blue: 0.78, alpha: 1)
        stack.addArrangedSubview(title); stack.addArrangedSubview(detail)
        if let accessory = alert.accessoryView {
            accessory.removeFromSuperview()
            accessory.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(accessory)
            accessory.widthAnchor.constraint(equalToConstant: 372).isActive = true
            accessory.heightAnchor.constraint(greaterThanOrEqualToConstant: max(28, accessory.frame.height)).isActive = true
            if let field = accessory as? NSTextField {
                field.font = .systemFont(ofSize: 13)
                field.focusRingType = .default
            }
        }
        let actions = NSStackView()
        actions.orientation = .horizontal; actions.spacing = 9
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(spacer)
        // NSAlert adds the primary action first. Keep that response index but place it last.
        for index in alert.buttons.indices.reversed() {
            let button = NSButton(title: alert.buttons[index].title, target: self, action: #selector(selectAction(_:)))
            button.tag = index; button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12, weight: .medium)
            if index == 0 {
                button.keyEquivalent = "\r"
                button.bezelColor = NSColor(srgbRed: 0.345, green: 0.824, blue: 0.925, alpha: 1)
            } else if button.title == "Cancel" { button.keyEquivalent = "\u{1b}" }
            actions.addArrangedSubview(button)
        }
        stack.addArrangedSubview(actions)
        let content = NSView(); panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 420, height: max(220, stack.fittingSize.height + 44)))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        if let field = alert.accessoryView { panel.makeFirstResponder(field) }
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }
    @objc private func selectAction(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .abort)
        return false
    }
}
