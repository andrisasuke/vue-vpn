import AppKit

/// Only editable fields use text controls. Neutral selection and border colors
/// keep PIN/name/address editing consistent with the existing application.
@MainActor
final class NativeTextInput: NSView, NSTextFieldDelegate {
    private(set) var field:NSTextField
    private var secure:Bool
    private let fontSize:CGFloat
    private(set) var palette:ThemePalette = .light
    var maximumLength:Int
    var changed:((String) -> Void)?
    var submitted:(() -> Void)?
    var focusChanged:((Bool) -> Void)?
    override var isFlipped:Bool { true }

    init(frame:NSRect,value:String,label:String,secure:Bool = false,fontSize:CGFloat = 12,maximumLength:Int = 256) {
        self.secure = secure;self.fontSize = fontSize;self.maximumLength = maximumLength
        field = secure ? NSSecureTextField() : NSTextField()
        super.init(frame:frame)
        configure(label:label,value:value)
    }
    required init?(coder:NSCoder) { fatalError("Programmatic native input") }

    private func configure(label:String,value:String) {
        field.autoresizingMask = [.width,.minYMargin,.maxYMargin]
        field.isBordered = false;field.isBezeled = false;field.drawsBackground = false
        field.focusRingType = .none
        field.font = VPNDrawing.systemFont(size:fontSize,weight:400)
        field.textColor = NSColor(cgColor:VPNDrawing.color(palette.text))
        field.isEditable = true;field.isSelectable = true
        field.usesSingleLineMode = true
        field.stringValue = value;field.delegate = self
        field.setAccessibilityLabel(label)
        field.target = self;field.action = #selector(commit)
        addSubview(field)
        layoutField()
    }

    override func layout() {
        super.layout()
        layoutField()
    }

    private func layoutField() {
        // Center the actual native control, not just its inactive cell drawing.
        // The field editor then uses the same one-line frame when focused.
        let height = min(bounds.height,max(0,field.intrinsicContentSize.height))
        field.frame = NSRect(x:bounds.minX,y:bounds.midY-height/2,width:bounds.width,height:height)
    }

    // Keep the padding around the one-line control clickable.
    override func mouseDown(with event:NSEvent) { focus() }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !visibleRect.isEmpty else { return }
        addCursorRect(visibleRect,cursor:field.isEnabled ? .iBeam : .arrow)
    }

    func applyTheme(_ palette:ThemePalette) {
        self.palette = palette
        field.textColor = NSColor(cgColor:VPNDrawing.color(palette.text))
        if let placeholder = field.placeholderString ?? field.placeholderAttributedString?.string {
            field.placeholderAttributedString = NSAttributedString(string:placeholder,attributes:[
                .foregroundColor:NSColor(cgColor:VPNDrawing.color(palette.secondaryText))!,
                .font:VPNDrawing.systemFont(size:fontSize,weight:400)])
        }
        styleEditor()
        needsDisplay = true
    }

    func update(value:String,enabled:Bool) {
        if field.stringValue != value { field.stringValue = value }
        field.isEnabled = enabled
        window?.invalidateCursorRects(for:self)
    }
    func showPassword(_ visible:Bool) {
        guard secure == visible else { return }
        let wasFocused = field.currentEditor() != nil
        let wasEnabled = field.isEnabled
        let selection = (field.currentEditor() as? NSTextView)?.selectedRange()
        let value = field.stringValue,label = field.accessibilityLabel() ?? "Password"
        field.stringValue = "";field.removeFromSuperview()
        secure = !visible;field = secure ? NSSecureTextField() : NSTextField()
        configure(label:label,value:value)
        field.isEnabled = wasEnabled
        if wasFocused {
            window?.makeFirstResponder(field)
            if let selection { (field.currentEditor() as? NSTextView)?.setSelectedRange(selection) }
            styleEditor()
        }
    }
    func focus() { window?.makeFirstResponder(field);styleEditor() }
    func clear() { field.stringValue = "" }
    @objc private func commit() { submitted?() }

    private func styleEditor() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.textColor = NSColor(cgColor:VPNDrawing.color(palette.text))
        editor.selectedTextAttributes = [.backgroundColor:palette.theme == .light ? NSColor(srgbRed:0.83,green:0.85,blue:0.82,alpha:1) : NSColor(cgColor:VPNDrawing.color(palette[.selection,light:0xd4d9d1]))!,
                                         .foregroundColor:NSColor(cgColor:VPNDrawing.color(palette.text))!]
        editor.insertionPointColor = NSColor(cgColor:VPNDrawing.color(palette.text))!
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
    }
    func controlTextDidBeginEditing(_ notification:Notification) { styleEditor();focusChanged?(true) }
    func controlTextDidEndEditing(_ notification:Notification) { focusChanged?(false) }
    func controlTextDidChange(_ notification:Notification) {
        if field.stringValue.count > maximumLength { field.stringValue = String(field.stringValue.prefix(maximumLength)) }
        changed?(field.stringValue)
    }
}
