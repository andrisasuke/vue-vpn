import AppKit

/// Installing/removing the real menu item is an explicit lifecycle operation.
/// Hostless tests exercise MenuPresentation and StatusIcon without installing it.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var current: MenuPresentation?
    private var deferred: MenuPresentation?
    private var tracking = false
    var perform: ((MenuPresentation.Action) -> Void)?

    func install() {
        guard item == nil else { return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.setAccessibilityLabel("VueVPN")
        if let current { apply(current) }
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil; tracking = false; deferred = nil
    }

    func update(_ presentation: MenuPresentation) {
        guard presentation != current else { return }
        current = presentation
        if tracking { deferred = presentation; return }
        apply(presentation)
    }

    private func apply(_ presentation: MenuPresentation) {
        guard let item else { return }
        item.button?.image = Self.image(presentation.indicator)
        item.button?.toolTip = presentation.tooltip
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for entry in presentation.items {
            let row = NSMenuItem(title: entry.title, action: #selector(activate(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = ActionBox(entry.action)
            row.isEnabled = entry.enabled
            menu.addItem(row)
        }
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { tracking = true }
    func menuDidClose(_ menu: NSMenu) {
        tracking = false
        if let deferred { self.deferred = nil; apply(deferred) }
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action,
              current?.items.contains(where: { $0.action == action && $0.enabled }) == true else { return }
        perform?(action)
    }

    private static func image(_ indicator: MenuPresentation.Indicator) -> NSImage? {
        let bytes = Data(StatusIcon.rgba(indicator))
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cg = CGImage(width: StatusIcon.width, height: StatusIcon.height,
                               bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: StatusIcon.width*4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 22, height: 18))
        image.isTemplate = false
        return image
    }
}

private final class ActionBox: NSObject {
    let action: MenuPresentation.Action
    init(_ action: MenuPresentation.Action) { self.action = action }
}
