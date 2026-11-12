import AppKit
@testable import HostPin
import SwiftUI
import XCTest

final class HostPinEditorTests: XCTestCase {
    @MainActor
    func testDraftUndoRedoSurvivesEditorDetachAndReattach() async throws {
        _ = NSApplication.shared
        let session = HostsEditorSession()
        let original = "127.0.0.1 localhost\n"
        session.synchronize(original)
        let container = session.container
        let editor = container.editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertFalse(undo === window.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("# draft\n", replacementRange: NSRange(location: (original as NSString).length, length: 0))
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        let draft = editor.string
        for _ in 0..<20 {
            editor.breakUndoCoalescing()
            window.contentView = NSView()
            session.synchronize(draft)
            window.contentView = session.container
            XCTAssertTrue(editor === session.container.editor)
            undo.undo()
            XCTAssertEqual(editor.string, original)
            undo.redo()
            XCTAssertEqual(editor.string, draft)
        }
        XCTAssertFalse(window.undoManager?.canUndo ?? false)
        undo.removeAllActions()
    }

    @MainActor
    func testReloadInvalidatesStaleUndoAndRedoRanges() async throws {
        _ = NSApplication.shared
        let session = HostsEditorSession()
        session.synchronize("a long original document")
        let editor = session.container.editor
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("more", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertTrue(undo.canRedo)
        session.synchronize("x")
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        undo.redo()
        XCTAssertEqual(editor.string, "x")
    }

    @MainActor
    func testDetachedEditorStopsUpdatingBindingAndKeepsHistoryPrivate() async throws {
        _ = NSApplication.shared
        var draft = "before"
        let session = HostsEditorSession()
        session.synchronize(draft)
        let representable = NativeTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                             session: session, findMatch: nil, edit: nil)
        let coordinator = representable.makeCoordinator()
        let editor = session.container.editor
        editor.delegate = coordinator
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("after", replacementRange: NSRange(location: 0, length: 6))
        undo.endUndoGrouping()
        XCTAssertEqual(draft, "after")
        NativeTextEditor.dismantleNSView(session.container, coordinator: coordinator)
        XCTAssertNil(editor.delegate)
        XCTAssertTrue(undo.canUndo)
        editor.delegate = coordinator
        undo.undo()
        XCTAssertEqual(draft, "before")
        undo.removeAllActions()
    }
    @MainActor
    func testInvalidUTF16EditRangeIsRejected() async {
        _ = NSApplication.shared
        let session = HostsEditorSession()
        session.synchronize("🍎 localhost")
        let representable = NativeTextEditor(text: .constant("🍎 localhost"), session: session,
                                             findMatch: nil, edit: nil)
        let coordinator = representable.makeCoordinator()
        let editor = session.container.editor
        for range in [NSRange(location: NSNotFound, length: 1),
                      NSRange(location: Int.max - 1, length: Int.max),
                      NSRange(location: 1, length: Int.max)] {
            XCTAssertFalse(coordinator.textView(editor, shouldChangeTextIn: range, replacementString: "x"))
        }
        XCTAssertTrue(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 2), replacementString: "a"))
    }

    @MainActor
    func testStandardUndoRedoActionsAndMenuValidationUseDocumentHistory() async throws {
        _ = NSApplication.shared
        let session = HostsEditorSession()
        session.synchronize("before")
        let editor = session.container.editor
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("after", replacementRange: NSRange(location: 0, length: 6))
        undo.endUndoGrouping()
        let undoAction = #selector(HostsTextView.undo(_:))
        let redoAction = #selector(HostsTextView.redo(_:))
        let undoItem = NSMenuItem(title: "Undo", action: undoAction, keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: redoAction, keyEquivalent: "Z")
        XCTAssertTrue(editor.validateMenuItem(undoItem))
        XCTAssertFalse(editor.validateMenuItem(redoItem))
        XCTAssertTrue(NSApp.sendAction(undoAction, to: editor, from: nil))
        XCTAssertEqual(editor.string, "before")
        XCTAssertTrue(editor.validateMenuItem(redoItem))
        XCTAssertTrue(NSApp.sendAction(redoAction, to: editor, from: nil))
        XCTAssertEqual(editor.string, "after")
        undo.removeAllActions()
    }

}
