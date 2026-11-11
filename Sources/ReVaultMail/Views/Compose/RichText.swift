import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Преобразования текста письма

/// Шрифт и цвет тела письма в редакторе.
@MainActor
enum ComposeFont {
    static let size: CGFloat = 13.5
    static var body: NSFont {
        if UserDefaults.standard.bool(forKey: "useGeist"), let f = NSFont(name: "Geist-Regular", size: size) { return f }
        return NSFont.systemFont(ofSize: size)
    }
    static var color: NSColor { NSColor(Theme.ink) }
    static var attributes: [NSAttributedString.Key: Any] { [.font: body, .foregroundColor: color] }
}

/// Маркеры списков: простой список это строки с префиксом, так он одинаково живёт в тексте и в HTML.
enum ListPrefix {
    static let bullet = "• "

    /// Длина префикса строки и вид списка: nil, если строка не пункт.
    static func detect(_ line: String) -> (length: Int, numbered: Bool)? {
        if line.hasPrefix(bullet) { return ((bullet as NSString).length, false) }
        var digits = 0
        for ch in line {
            if ch.isASCII, ch.isNumber { digits += 1; continue }
            break
        }
        guard digits > 0, digits < 4 else { return nil }
        let rest = line.dropFirst(digits)
        guard rest.hasPrefix(". ") else { return nil }
        return (digits + 2, true)
    }

    static func number(_ line: String) -> Int? {
        guard let d = detect(line), d.numbered else { return nil }
        return Int(line.prefix(d.length - 2))
    }
}

/// Текст без ссылок и вложенных объектов: то, что лежит в черновике и в привязке редактора.
func attributedRaw(_ s: NSAttributedString) -> String {
    s.string.replacingOccurrences(of: "\u{FFFC}", with: "")
}

/// Обычная версия письма: ссылка с текстом уходит как «текст (адрес)».
func attributedToPlain(_ s: NSAttributedString) -> String {
    var out = ""
    let ns = s.string as NSString
    s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
        let piece = ns.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
        out += piece
        if let url = linkString(attrs[.link]) {
            let shown = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = url.replacingOccurrences(of: "mailto:", with: "")
            if !shown.isEmpty, shown != url, shown != bare, !url.hasSuffix(shown) { out += " (\(bare))" }
        }
    }
    return out
}

/// Есть ли в тексте оформление, ради которого письму нужен свой HTML.
func attributedHasFormatting(_ s: NSAttributedString) -> Bool {
    var found = false
    s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, _, stop in
        let st = InlineStyle(attrs)
        if st.bold || st.italic || st.underline || st.link != nil { found = true; stop.pointee = true }
    }
    if found { return true }
    return s.string.components(separatedBy: "\n").contains { ListPrefix.detect($0) != nil }
}

/// HTML тела письма: абзацы как у HTMLText.paragraphs, списки ul/ol, жирный, курсив, подчёркивание, ссылки.
func attributedToHTML(_ s: NSAttributedString) -> String {
    let ns = s.string as NSString
    var lines: [NSRange] = []
    var start = 0
    while start <= ns.length {
        let r = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
        if r.location == NSNotFound {
            lines.append(NSRange(location: start, length: ns.length - start))
            break
        }
        lines.append(NSRange(location: start, length: r.location - start))
        start = r.location + 1
    }

    var html: [String] = []
    var paragraph: [String] = []
    var list: (numbered: Bool, items: [String])?

    func closeParagraph() {
        if !paragraph.isEmpty {
            html.append("<p style=\"margin:0 0 1em 0\">" + paragraph.joined(separator: "<br>") + "</p>")
            paragraph = []
        }
    }
    func closeList() {
        if let l = list {
            let tag = l.numbered ? "ol" : "ul"
            html.append("<\(tag) style=\"margin:0 0 1em 0;padding-left:1.6em\">"
                        + l.items.map { "<li>\($0)</li>" }.joined() + "</\(tag)>")
            list = nil
        }
    }

    for r in lines {
        let line = ns.substring(with: r)
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            closeParagraph(); closeList()
            continue
        }
        if let p = ListPrefix.detect(line) {
            closeParagraph()
            if let l = list, l.numbered != p.numbered { closeList() }
            let content = NSRange(location: r.location + p.length, length: r.length - p.length)
            let item = inlineHTML(s, range: content)
            if list == nil { list = (p.numbered, []) }
            list?.items.append(item)
        } else {
            closeList()
            paragraph.append(inlineHTML(s, range: r))
        }
    }
    closeParagraph(); closeList()
    return html.joined(separator: "\n")
}

/// Обычный текст в редактор с оформлением по умолчанию.
@MainActor
func plainToAttributed(_ plain: String) -> NSAttributedString {
    NSAttributedString(string: plain, attributes: ComposeFont.attributes)
}

private struct InlineStyle: Equatable {
    var bold = false, italic = false, underline = false
    var link: String?

    init(_ attrs: [NSAttributedString.Key: Any]) {
        if let f = attrs[.font] as? NSFont {
            let traits = f.fontDescriptor.symbolicTraits
            bold = traits.contains(.bold)
            italic = traits.contains(.italic)
        }
        if let u = attrs[.underlineStyle] as? Int, u != 0, attrs[.link] == nil { underline = true }
        link = linkString(attrs[.link])
    }
}

private func linkString(_ v: Any?) -> String? {
    if let u = v as? URL { return u.absoluteString }
    if let s = v as? String, !s.isEmpty { return s }
    return nil
}

private func inlineHTML(_ s: NSAttributedString, range: NSRange) -> String {
    guard range.length > 0 else { return "" }
    var out = ""
    let ns = s.string as NSString
    s.enumerateAttributes(in: range) { attrs, r, _ in
        let text = ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
        guard !text.isEmpty else { return }
        let st = InlineStyle(attrs)
        var piece = HTMLText.escape(text)
        if st.underline { piece = "<u>\(piece)</u>" }
        if st.italic { piece = "<i>\(piece)</i>" }
        if st.bold { piece = "<b>\(piece)</b>" }
        if let l = st.link { piece = "<a href=\"\(HTMLText.escape(l))\">\(piece)</a>" }
        out += piece
    }
    return out
}

// MARK: Управление редактором

/// Ручка редактора: команды оформления, вставка текста, текущий текст с оформлением.
/// Живёт в @State вида и переживает пересоздание NSTextView.
@MainActor
final class RichTextController {
    fileprivate weak var textView: ComposeTextView?
    /// Последний текст с оформлением: доступен и когда редактор уже убран с экрана.
    private(set) var attributed = NSAttributedString(string: "")
    /// Оформленный текст, который надо показать, когда строка редактора совпадёт с ним (восстановление черновика).
    fileprivate var pendingRestore: NSAttributedString?

    var isEmpty: Bool { attributedRaw(attributed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var plain: String { attributedToPlain(attributed) }
    /// HTML только если есть оформление: иначе письмо собирается как раньше из обычного текста.
    var html: String? { attributedHasFormatting(attributed) ? attributedToHTML(attributed) : nil }

    fileprivate func remember(_ s: NSAttributedString) { attributed = s }

    /// Показать оформленный текст (вернуть из сессии). Применится, как только строка редактора станет такой же.
    func restore(_ s: NSAttributedString) {
        pendingRestore = s
        attributed = s
        if let tv = textView, attributedRaw(tv.attributedString()) == attributedRaw(s) {
            tv.textStorage?.setAttributedString(s)
            pendingRestore = nil
        }
    }

    func focus() {
        guard let tv = textView, let w = tv.window else { return }
        w.makeFirstResponder(tv)
    }

    func toggleBold() { textView?.toggleTrait(.boldFontMask) }
    func toggleItalic() { textView?.toggleTrait(.italicFontMask) }
    func toggleUnderline() { textView?.toggleUnderlineStyle() }
    func insertLink() { textView?.askForLink() }
    func toggleList(numbered: Bool) { textView?.toggleList(numbered: numbered) }

    /// Вставить текст в позицию курсора (шаблон). Если перед курсором стоит trigger, он заменяется.
    func insert(_ text: String, replacingTrigger trigger: String? = nil) {
        guard let tv = textView else { return }
        var r = tv.selectedRange()
        if let trigger, r.length == 0 {
            let ns = tv.string as NSString
            let len = (trigger as NSString).length
            if r.location >= len, ns.substring(with: NSRange(location: r.location - len, length: len)) == trigger {
                r = NSRange(location: r.location - len, length: len)
            }
        }
        tv.replace(r, with: text)
        focus()
    }
}

// MARK: NSTextView письма

final class ComposeTextView: NSTextView {
    var onAttach: ((URL) -> Void)?
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Свой перехват клавиш на время фокуса: Cmd+K и другие заняты кнопками окна (поиск), здесь они про текст.
    private var keyMonitor: Any?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
            installMonitor()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            onFocusChange?(false)
            removeMonitor()
        }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeMonitor() }
    }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.window?.firstResponder === self else { return event }
                return self.handleShortcut(event) ? nil : event
            }
        }
    }

    private func removeMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // Физические клавиши: работают и в русской раскладке.
    private enum Key { static let b: UInt16 = 11, i: UInt16 = 34, u: UInt16 = 32, k: UInt16 = 40, ret: UInt16 = 36, seven: UInt16 = 26, eight: UInt16 = 28 }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return handleShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        // поверх открыт лист (ссылка, шаблон): клавиши его
        if window?.attachedSheet != nil { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command] {
            switch event.keyCode {
            case Key.b: toggleTrait(.boldFontMask); return true
            case Key.i: toggleTrait(.italicFontMask); return true
            case Key.u: toggleUnderlineStyle(); return true
            case Key.k: askForLink(); return true
            case Key.ret: onSubmit?(); return true
            default: break
            }
        }
        if mods == [.command, .shift] {
            switch event.keyCode {
            case Key.seven: toggleList(numbered: true); return true
            case Key.eight: toggleList(numbered: false); return true
            default: break
            }
        }
        return false
    }

    // MARK: Оформление

    /// Жирный или курсив: на выделении меняется весь кусок, без выделения меняется то, что будет набрано.
    func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let r = selectedRange()
        let base = ComposeFont.body
        if r.length == 0 {
            var attrs = typingAttributes
            let f = (attrs[.font] as? NSFont) ?? base
            let has = fm.traits(of: f).contains(trait)
            attrs[.font] = has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            typingAttributes = attrs
            return
        }
        guard let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        var all = true
        ts.enumerateAttribute(.font, in: r) { v, _, stop in
            let f = (v as? NSFont) ?? base
            if !fm.traits(of: f).contains(trait) { all = false; stop.pointee = true }
        }
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in
            let f = (v as? NSFont) ?? base
            ts.addAttribute(.font, value: all ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: sub)
        }
        ts.endEditing()
        didChangeText()
    }

    func toggleUnderlineStyle() {
        let r = selectedRange()
        if r.length == 0 {
            var attrs = typingAttributes
            let on = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            attrs[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            typingAttributes = attrs
            return
        }
        guard let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        var all = true
        ts.enumerateAttribute(.underlineStyle, in: r) { v, _, stop in
            if ((v as? Int) ?? 0) == 0 { all = false; stop.pointee = true }
        }
        ts.beginEditing()
        if all { ts.removeAttribute(.underlineStyle, range: r) } else { ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
        ts.endEditing()
        didChangeText()
    }

    /// Ссылка: адрес спрашивается листом над окном. Без выделения вставляется сам адрес.
    func askForLink() {
        guard let w = window else { return }
        let r = selectedRange()
        let selected = (string as NSString).substring(with: r)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        if let existing = r.length > 0 ? textStorage?.attribute(.link, at: r.location, effectiveRange: nil) : nil {
            field.stringValue = (existing as? URL)?.absoluteString ?? (existing as? String) ?? ""
        } else if selected.hasPrefix("http") || selected.contains(".") && !selected.contains(" ") {
            field.stringValue = selected
        }
        let alert = NSAlert()
        alert.messageText = r.length > 0 ? "Link \"\(selected.prefix(40))\"" : "Insert link"
        alert.informativeText = "Web address or email."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add link")
        alert.addButton(withTitle: "Cancel")
        if r.length > 0 { alert.addButton(withTitle: "Remove link") }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: w) { [weak self] resp in
            guard let self else { return }
            if resp == .alertThirdButtonReturn {
                self.setLink(nil, range: r)
            } else if resp == .alertFirstButtonReturn {
                let url = Self.normalizeURL(field.stringValue)
                guard !url.isEmpty else { return }
                if r.length == 0 {
                    var attrs = self.typingAttributes
                    attrs[.link] = url
                    let s = NSAttributedString(string: url.replacingOccurrences(of: "mailto:", with: ""), attributes: attrs)
                    if self.shouldChangeText(in: r, replacementString: s.string) {
                        self.textStorage?.replaceCharacters(in: r, with: s)
                        self.didChangeText()
                        self.setSelectedRange(NSRange(location: r.location + s.length, length: 0))
                        var after = self.typingAttributes
                        after[.link] = nil
                        self.typingAttributes = after
                    }
                } else {
                    self.setLink(url, range: r)
                }
            }
            self.window?.makeFirstResponder(self)
        }
    }

    private func setLink(_ url: String?, range r: NSRange) {
        guard let ts = textStorage, r.length > 0, shouldChangeText(in: r, replacementString: nil) else { return }
        ts.beginEditing()
        if let url { ts.addAttribute(.link, value: url, range: r) } else { ts.removeAttribute(.link, range: r) }
        ts.endEditing()
        didChangeText()
    }

    static func normalizeURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if s.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil { return s }
        if s.contains("@"), !s.contains("/") { return "mailto:" + s }
        return "https://" + s
    }

    /// Список на строках выделения: все уже пункты этого вида снимаются, иначе ставятся.
    func toggleList(numbered: Bool) {
        let ns = string as NSString
        let para = ns.paragraphRange(for: selectedRange())
        let block = ns.substring(with: para)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        let all = lines.allSatisfy { l in ListPrefix.detect(l).map { $0.numbered == numbered } ?? false }
        var n = 0
        let out = lines.map { l -> String in
            let stripped = ListPrefix.detect(l).map { String(l.dropFirst($0.length)) } ?? l
            if all { return stripped }
            n += 1
            return (numbered ? "\(n). " : ListPrefix.bullet) + stripped
        }
        let text = out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(para, with: text)
        let caretEnd = para.location + (text as NSString).length - (trailingNewline ? 1 : 0)
        setSelectedRange(NSRange(location: caretEnd, length: 0))
    }

    /// Замена куска с сохранением отмены и уведомлением редактора.
    func replace(_ r: NSRange, with text: String) {
        guard shouldChangeText(in: r, replacementString: text) else { return }
        let attrs = r.location < (textStorage?.length ?? 0) && r.length > 0
            ? (textStorage?.attributes(at: r.location, effectiveRange: nil) ?? typingAttributes) : typingAttributes
        var clean = attrs
        clean[.link] = nil
        textStorage?.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: clean))
        didChangeText()
        setSelectedRange(NSRange(location: r.location + (text as NSString).length, length: 0))
    }

    /// Return в пункте списка продолжает список, Return в пустом пункте его заканчивает.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange()
        guard caret.length == 0 else { return super.insertNewline(sender) }
        let para = ns.paragraphRange(for: caret)
        var line = ns.substring(with: para)
        if line.hasSuffix("\n") { line.removeLast() }
        guard let p = ListPrefix.detect(line) else { return super.insertNewline(sender) }
        if (line as NSString).length <= p.length {
            replace(NSRange(location: para.location, length: (line as NSString).length), with: "")
            return
        }
        let next = p.numbered ? "\((ListPrefix.number(line) ?? 0) + 1). " : ListPrefix.bullet
        replace(caret, with: "\n" + next)
    }

    // MARK: Вставка и перетаскивание

    override func paste(_ sender: Any?) {
        if takeFiles(from: NSPasteboard.general) { return }
        pasteAsPlainText(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takeFiles(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Файлы и картинки из буфера или перетаскивания становятся вложениями письма.
    private func takeFiles(from pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { onAttach?($0) }
            return true
        }
        // картинка без файла (скриншот в буфере, картинка из браузера): кладём во временный PNG
        let hasText = pb.availableType(from: [.string]) != nil
        if !hasText, pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb),
           let url = Self.writeTempPNG(img) {
            onAttach?(url)
            return true
        }
        return false
    }

    static func writeTempPNG(_ img: NSImage) -> URL? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReVaultMail-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = dir.appendingPathComponent("Pasted image \(f.string(from: Date())).png")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Pasted image \(f.string(from: Date())) \(i).png"); i += 1
        }
        do { try png.write(to: url) } catch { return nil }
        return url
    }
}

// MARK: Вид для SwiftUI

/// Редактор тела письма на NSTextView: оформление, списки, вставка обычным текстом, картинки как вложения.
/// text это строка без оформления (для черновика и проверок), оформленный текст держит controller.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: RichTextController
    var minHeight: CGFloat = 110
    var maxHeight: CGFloat = 260
    @Binding var height: CGFloat
    var onAttach: (URL) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Набрали «;;»: открыть выбор шаблона.
    var onTrigger: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = ComposeTextView(frame: .zero)
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticDashSubstitutionEnabled = false   // длинного тире в письмах нет
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.font = ComposeFont.body
        tv.textColor = ComposeFont.color
        tv.typingAttributes = ComposeFont.attributes
        tv.linkTextAttributes = [.foregroundColor: NSColor(Theme.blueText), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        scroll.documentView = tv

        controller.textView = tv
        context.coordinator.apply(text, to: tv)
        context.coordinator.wire(tv)
        DispatchQueue.main.async { context.coordinator.reportHeight(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposeTextView else { return }
        controller.textView = tv
        context.coordinator.wire(tv)
        if text != context.coordinator.lastRaw {
            context.coordinator.apply(text, to: tv)
            DispatchQueue.main.async { context.coordinator.reportHeight(tv) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        /// Строка, которую редактор последней отдал наружу или принял: так видно, что текст поменяли снаружи.
        var lastRaw = ""

        init(_ p: RichTextEditor) { parent = p }

        func wire(_ tv: ComposeTextView) {
            tv.onAttach = { [weak self] url in self?.parent.onAttach(url) }
            tv.onSubmit = { [weak self] in self?.parent.onSubmit() }
            tv.onFocusChange = { [weak self] f in
                guard let self else { return }
                DispatchQueue.main.async { self.parent.onFocusChange(f) }
            }
        }

        /// Текст поменяли снаружи (загрузка черновика, агент, перевод): оформление берётся из сессии, если строка та же.
        func apply(_ text: String, to tv: ComposeTextView) {
            let c = parent.controller
            let s: NSAttributedString
            if let p = c.pendingRestore, attributedRaw(p) == text {
                s = p
                c.pendingRestore = nil
            } else if attributedRaw(tv.attributedString()) == text {
                s = tv.attributedString()
            } else {
                s = plainToAttributed(text)
            }
            if !tv.attributedString().isEqual(to: s) {
                tv.textStorage?.setAttributedString(s)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
            tv.typingAttributes = ComposeFont.attributes
            lastRaw = text
            c.remember(s)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposeTextView else { return }
            let snapshot = tv.attributedString().copy() as? NSAttributedString ?? NSAttributedString()
            parent.controller.remember(snapshot)
            let raw = attributedRaw(snapshot)
            lastRaw = raw
            if parent.text != raw { parent.text = raw }
            reportHeight(tv)
            // «;;» прямо перед курсором
            let caret = tv.selectedRange()
            let ns = tv.string as NSString
            if caret.length == 0, caret.location >= 2, ns.substring(with: NSRange(location: caret.location - 2, length: 2)) == ";;" {
                let fire = parent.onTrigger
                DispatchQueue.main.async { fire() }
            }
        }

        func reportHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 6
            let clamped = min(max(h, parent.minHeight), parent.maxHeight)
            if abs(parent.height - clamped) > 0.5 { parent.height = clamped }
        }

        /// Клик по ссылке в редакторе не открывает браузер: ссылку правят через Cmd+K.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
    }
}

/// Полоска оформления: B I U, ссылка, списки.
struct FormatBar: View {
    let controller: RichTextController

    var body: some View {
        HStack(spacing: 2) {
            button("bold", "Bold (Cmd+B)") { controller.toggleBold() }
            button("italic", "Italic (Cmd+I)") { controller.toggleItalic() }
            button("underline", "Underline (Cmd+U)") { controller.toggleUnderline() }
            button("link", "Link (Cmd+K)") { controller.insertLink() }
            button("list.bullet", "Bulleted list (Cmd+Shift+8)") { controller.toggleList(numbered: false) }
            button("list.number", "Numbered list (Cmd+Shift+7)") { controller.toggleList(numbered: true) }
        }
    }

    private func button(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.icon)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
