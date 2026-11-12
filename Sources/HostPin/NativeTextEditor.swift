import AppKit
import HostPinCore
import SwiftUI

struct HostsEditorEdit: Identifiable {
    let id = UUID()
    let expected: String
    let range: NSRange
    let replacement: String
}

struct NativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let session: HostsEditorSession
    let findMatch: NSRange?
    let edit: HostsEditorEdit?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorContainer {
        let container = session.container
        container.editor.delegate = context.coordinator
        session.synchronize(text)
        DispatchQueue.main.async { [weak editor = container.editor, weak coordinator = context.coordinator] in
            guard let editor, let coordinator, editor.delegate === coordinator,
                  let window = editor.window else { return }
            window.makeFirstResponder(editor)
        }
        return container
    }

    static func dismantleNSView(_ container: EditorContainer, coordinator: Coordinator) {
        guard container.editor.delegate === coordinator else { return }
        container.editor.breakUndoCoalescing()
        container.clearHighlight()
        if container.window?.firstResponder === container.editor {
            container.window?.makeFirstResponder(nil)
        }
        container.editor.delegate = nil
    }

    func updateNSView(_ container: EditorContainer, context: Context) {
        context.coordinator.parent = self
        let view = container.editor
        let textChanged = session.synchronize(text)
        if let layout = view.layoutManager,
           textChanged || context.coordinator.highlight != findMatch {
            container.clearHighlight()
            context.coordinator.highlight = findMatch
            if let findMatch, findMatch.isValid(in: view.string) {
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor(Theme.accent).withAlphaComponent(0.28),
                                             forCharacterRange: findMatch)
                view.scrollRangeToVisible(findMatch)
            }
        }
        if let edit, context.coordinator.lastEdit != edit.id {
            context.coordinator.lastEdit = edit.id
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator, view.delegate === coordinator, view.window != nil,
                      view.string == edit.expected, edit.range.isValid(in: view.string),
                      view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
                view.breakUndoCoalescing()
                view.replaceCharacters(in: edit.range, with: edit.replacement)
                view.didChangeText()
                view.breakUndoCoalescing()
            }
        }
        container.gutter.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor
        var highlight: NSRange?
        var lastEdit: UUID?
        init(_ parent: NativeTextEditor) {
            self.parent = parent
        }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
        func undoManager(for view: NSTextView) -> UndoManager? { view.undoManager }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard affectedCharRange.isValid(in: textView.string) else { return false }
            guard let replacementString else { return true }
            guard replacementString.utf8.count <= HostsDocument.maxSize, !replacementString.contains("\0") else {
                NSSound.beep()
                return false
            }
            let proposed = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
            guard proposed.utf8.count <= HostsDocument.maxSize else { NSSound.beep(); return false }
            return true
        }
    }
}

/// A draft owns its editor and undo stack across SwiftUI tab teardown/recreation.
@MainActor
final class HostsEditorSession {
    lazy var container: EditorContainer = {
        let view = HostsTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.insertionPointColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.drawsBackground = true
        view.allowsUndo = true
        view.usesFindPanel = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return EditorContainer(editor: view)
    }()

    @discardableResult
    func synchronize(_ text: String) -> Bool {
        let view = container.editor
        guard view.string != text else { return false }
        // A disk reload creates a new document version; previous character ranges
        // must never be replayed against it. User edits already match the binding.
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        container.clearHighlight()
        view.string = text
        container.gutter.needsDisplay = true
        return true
    }
}

final class HostsTextView: NSTextView {
    private let history: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        return manager
    }()
    override var undoManager: UndoManager? { history }

    // NSWindow's default undo/redo actions use its shared manager. Route these
    // standard responder actions to this document's manager instead.
    @objc func undo(_ sender: Any?) { breakUndoCoalescing(); history.undo() }
    @objc func redo(_ sender: Any?) { breakUndoCoalescing(); history.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return history.canUndo }
        if item.action == #selector(redo(_:)) { return history.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return history.canUndo }
        if menuItem.action == #selector(redo(_:)) { return history.canRedo }
        return super.validateMenuItem(menuItem)
    }
    deinit { history.removeAllActions() }
}

private extension NSRange {
    func isValid(in text: String) -> Bool {
        let count = (text as NSString).length
        return location != NSNotFound && location >= 0 && length >= 0 && location <= count && length <= count - location
    }
}

final class EditorContainer: NSView {
    let editor: NSTextView
    let gutter: LineNumberGutter

    init(editor: NSTextView) {
        self.editor = editor
        self.gutter = LineNumberGutter(editor: editor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        gutter.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 38),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineNumberGutter.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { nil }

    func clearHighlight() {
        editor.layoutManager?.removeTemporaryAttribute(.backgroundColor,
            forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }
}

final class LineNumberGutter: NSView {
    private weak var editor: NSTextView?

    init(editor: NSTextView) {
        self.editor = editor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    @objc func scrolled() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let view = editor,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        let document = view.string as NSString
        let startY = view.visibleRect.minY - view.textContainerOrigin.y
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var offset = 0
        var line = 1
        while offset <= document.length {
            let frame: NSRect
            if offset < document.length {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                frame = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                frame = layout.extraLineFragmentRect
            }
            let top = frame.minY - startY
            if top > bounds.height { break }
            if top + frame.height >= 0 {
                let label = NSAttributedString(string: String(line), attributes: attributes)
                label.draw(at: NSPoint(x: bounds.width - label.size().width - 7, y: top + 1))
            }
            guard offset < document.length else { break }
            let next = NSMaxRange(document.lineRange(for: NSRange(location: offset, length: 0)))
            if next == document.length && !view.string.hasSuffix("\n") && !view.string.hasSuffix("\r") { break }
            offset = next
            line += 1
        }
    }
}

