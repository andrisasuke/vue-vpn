import AppKit
import CoreText

/// One native status item owns independently accessible metric buttons.
@MainActor final class StatsMenuBarController: NSObject {
    private var item:NSStatusItem?
    private let container = StatsMenuContainer()
    private var state = StatsMenuBarState()
    private var appearanceObserver:NSKeyValueObservation?
    var open: ((StatsPage) -> Void)?
    var installed: Bool { item != nil }
    var visiblePages:Set<StatsPage> { state.visiblePages }

    func install() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength:0)
        item = status
        guard let button = status.button else { return }
        button.addSubview(container)
        container.open = { [weak self] page in self?.open?(page) }
        appearanceObserver = button.observe(\.effectiveAppearance,options:[.new]) { [weak self] _,_ in
            Task { @MainActor [weak self] in self?.refreshAppearance() }
        }
        sync()
    }
    func remove() {
        appearanceObserver = nil
        container.removeFromSuperview()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        container.resetArtwork()
    }
    func setVisiblePages(_ pages:Set<StatsPage>) {
        guard !state.setVisiblePages(pages).isEmpty else { return }
        sync()
    }
    func setStyles(_ styles:[StatsPage:StatsMenuStyle]) {
        let old = state.styles
        _ = state.setStyles(styles)
        if old != state.styles { sync() }
    }
    private func refreshAppearance() { sync() }
    func update(_ snapshot:SystemStatsSnapshot) {
        guard !state.update(snapshot).isEmpty else { return }
        sync()
    }
    private func sync() {
        guard let item,let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        container.update(metrics:state.visibleMetrics,visible:state.visiblePages,styles:state.styles,dark:dark)
        item.length = container.frame.width
        item.isVisible = !state.visiblePages.isEmpty
    }
}

private final class StatsMenuButton:NSButton {
    override var acceptsFirstResponder:Bool { true }
}

/// Layout and artwork are independent of a live status item for hostless tests.
@MainActor final class StatsMenuContainer:NSView {
    private struct ArtworkKey:Equatable { let metric:StatsMenuMetric; let style:StatsMenuStyle; let dark:Bool }
    private var rendered:[StatsPage:ArtworkKey] = [:]
    private(set) var buttons:[StatsPage:NSButton] = [:]
    private(set) var artworkUpdates = 0
    var open:((StatsPage)->Void)?
    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect)
        for page in StatsMenuPresentation.order {
            let button = StatsMenuButton(frame:.zero)
            button.isBordered = false; button.imagePosition = .imageOnly
            button.target = self; button.action = #selector(activate(_:))
            button.identifier = NSUserInterfaceItemIdentifier(page.rawValue)
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel("VueVPN Stats \(page.title)")
            addSubview(button); buttons[page] = button
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resetArtwork() { rendered.removeAll() }
    func update(metrics:[StatsMenuMetric],visible:Set<StatsPage>,styles:[StatsPage:StatsMenuStyle],dark:Bool) {
        var x:CGFloat = 0
        let byPage = Dictionary(uniqueKeysWithValues:metrics.map { ($0.page,$0) })
        for page in StatsMenuPresentation.order {
            guard let button = buttons[page] else { continue }
            button.isHidden = !visible.contains(page)
            guard visible.contains(page) else { continue }
            let style = styles[page] ?? .label
            let width = StatsMenuArtwork.statusLength(for:page,style:style)
            button.frame = CGRect(x:x,y:0,width:width,height:StatsMenuArtwork.height)
            x += width
            guard let metric = byPage[page] else { continue }
            let key = ArtworkKey(metric:metric,style:style,dark:dark)
            guard rendered[page] != key else { continue }
            rendered[page] = key; artworkUpdates += 1
            button.image = StatsMenuArtwork.image(for:metric,style:style,dark:dark)
            button.toolTip = metric.tooltip
            button.setAccessibilityLabel(metric.accessibilityLabel)
        }
        let ordered = StatsMenuPresentation.order.filter { visible.contains($0) }.compactMap { buttons[$0] }
        for (index,button) in ordered.enumerated() {
            button.nextKeyView = index+1 < ordered.count ? ordered[index+1] : nil
        }
        frame = CGRect(x:0,y:0,width:x,height:StatsMenuArtwork.height)
    }
    @objc func activate(_ sender:NSButton) {
        guard let page = StatsPage(rawValue:sender.identifier?.rawValue ?? "") else { return }
        open?(page)
    }
}

/// Template artwork lets AppKit choose the menu-bar tint on light and dark
/// backgrounds. The drawing handler remains vector sharp at either display scale.
@MainActor enum StatsMenuArtwork {
    static let height:CGFloat = 22
    // Eight vector resources at most; sampled values are never cache keys.
    private static var icons:[String:NSImage] = [:]
    private static func icon(for page:StatsPage,dark:Bool) -> NSImage {
        let key = "\(page.rawValue).\(dark)"
        if let cached = icons[key] { return cached }
        let shape:VPNIcon = page == .cpu ? .chip : page == .ram ? .memory : page == .ssd ? .ssd : .network
        let image = NSImage(size:CGSize(width:20,height:20),flipped:false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x:0,y:rect.minY+rect.maxY)
            context.scaleBy(x:1,y:-1)
            shape.draw(in:rect,color:StatusIcon.connectedGreenRGB,context:context)
            context.restoreGState()
            return true
        }
        icons[key] = image
        return image
    }
    private static let labelFont = NSFont.systemFont(ofSize:9,weight:.regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize:13,weight:.medium)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular)
    private static let percentWidth = ("100%" as NSString).size(withAttributes:[.font:valueFont]).width
    private static let arrowWidth = ("↓" as NSString).size(withAttributes:[.font:rateFont]).width
    private static let maxRateWidth = ("999+GB/s" as NSString).size(withAttributes:[.font:rateFont]).width
    // Align visible ink, accounting for the different margins in each 24-unit shape.
    private static func valueRight(for page:StatsPage) -> CGFloat {
        let sample = page == .network ? "↓999+GB/s" : "100%"
        let font = page == .network ? rateFont : valueFont
        let text = NSAttributedString(string:sample,attributes:[.font:font])
        let bounds = CTLineGetImageBounds(CTLineCreateWithAttributedString(text),nil)
        return ceil(2 + bounds.width)
    }
    static func iconRect(for page:StatsPage) -> CGRect {
        let inset:CGFloat = page == .ssd ? 3.0 : page == .network ? 2.0 : 1.0
        return CGRect(x:valueRight(for:page)+4-inset,y:1,width:20,height:20)
    }
    static func size(for page:StatsPage,style:StatsMenuStyle = .label) -> CGSize {
        if style == .icon { return CGSize(width:iconRect(for:page).maxX+1,height:height) }
        if page == .network {
            return CGSize(width:ceil(arrowWidth+2+maxRateWidth)+2,height:height)
        }
        let labelWidth = (page.title as NSString).size(withAttributes:[.font:labelFont]).width
        return CGSize(width:ceil(max(labelWidth,percentWidth))+2,height:height)
    }
    // The image already includes its own ink margins. Do not add another two
    // points on each side when AppKit centers it in the status button.
    static func statusLength(for page:StatsPage,style:StatsMenuStyle = .label) -> CGFloat { size(for:page,style:style).width }

    private static func textRect(for text:NSAttributedString,in size:CGSize,y:CGFloat,height:CGFloat) -> CGRect {
        // Keep the visible glyph edge at a fixed inset even when a leading "1"
        // or the unavailable dash has a different font bearing.
        let bearing = CTLineGetImageBounds(CTLineCreateWithAttributedString(text),nil).minX
        let x = 2 - bearing
        return CGRect(x:x,y:y,width:size.width-x-1,height:height)
    }

    private static func rightAlignedTextRect(_ text:NSAttributedString,page:StatsPage,y:CGFloat,height:CGFloat) -> CGRect {
        let bounds = CTLineGetImageBounds(CTLineCreateWithAttributedString(text),nil)
        let x = valueRight(for:page) - bounds.maxX
        return CGRect(x:x,y:y,width:ceil(text.size().width)+2,height:height)
    }

    static func image(for metric:StatsMenuMetric,style:StatsMenuStyle = .label,dark:Bool = false) -> NSImage {
        let size = size(for:metric.page,style:style)
        let network = metric.page == .network
        let ink = style == .label ? NSColor.black : (dark ? NSColor.white : NSColor.black)
        let top = NSAttributedString(string:metric.top,
            attributes:[.font:network ? rateFont : labelFont,.foregroundColor:ink])
        let bottom = NSAttributedString(string:metric.bottom,
            attributes:[.font:network ? rateFont : valueFont,.foregroundColor:ink])
        let topRect = textRect(for:top,in:size,y:network ? 11 : 12,height:network ? 11 : 10)
        let bottomRect = textRect(for:bottom,in:size,y:0,height:network ? 11 : 14)
        let image = NSImage(size:size,flipped:false) { _ in
            if style == .label {
                top.draw(in:topRect)
                bottom.draw(in:bottomRect)
            } else if network {
                top.draw(in:rightAlignedTextRect(top,page:metric.page,y:11,height:11))
                bottom.draw(in:rightAlignedTextRect(bottom,page:metric.page,y:0,height:11))
            } else {
                bottom.draw(in:rightAlignedTextRect(bottom,page:metric.page,y:4,height:16))
            }
            if style == .icon {
                icon(for:metric.page,dark:dark).draw(in:iconRect(for:metric.page),from:.zero,operation:.sourceOver,fraction:1)
            }
            return true
        }
        image.isTemplate = style == .label
        return image
    }
}
