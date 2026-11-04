import AppKit
import SwiftUI
import XCTest
@testable import CCOP

/// A message over 5 lines is cut at 5 lines and has a Show more button. Real
/// layout, because a long line that wraps counts as several lines.
@MainActor
final class FoldedTextTests: XCTestCase {
    /// The height of the view at a width, after its measurements arrived.
    private func height(_ text: String, open: Bool, width: CGFloat = 400) async -> CGFloat {
        let view = FoldedText(text: text, color: .blue, isOpen: open, toggle: { _ in })
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 2000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let h = host.fittingSize.height
        window.contentView = nil
        return h
    }

    private func lines(_ n: Int) -> String {
        (1...n).map { "line \($0)" }.joined(separator: "\n")
    }

    func testFiveLinesHaveNoButton() async {
        let closed = await height(lines(5), open: false)
        let open = await height(lines(5), open: true)
        XCTAssertEqual(closed, open, accuracy: 0.5, "nothing is cut, and no button is added")
    }

    func testSixLinesAreCutAtFiveLinesAndGetAButton() async {
        let five = await height(lines(5), open: false)
        let closed = await height(lines(6), open: false)
        let open = await height(lines(6), open: true)
        XCTAssertGreaterThan(closed, five + 5, "five lines and the button")
        XCTAssertGreaterThan(open, closed + 5, "the open text has one more line")
    }

    func testAVeryLongMessageStaysAtTheSameClosedHeight() async {
        let six = await height(lines(6), open: false)
        let many = await height(lines(200), open: false)
        XCTAssertEqual(six, many, accuracy: 0.5)
    }

    func testOneLongParagraphThatWrapsIsCutToo() async {
        let paragraph = String(repeating: "word ", count: 400)
        let six = await height(lines(6), open: false)
        let closed = await height(paragraph, open: false)
        let open = await height(paragraph, open: true)
        XCTAssertEqual(closed, six, accuracy: 0.5)
        XCTAssertGreaterThan(open, closed + 50)
    }

    func testAShortMessageHasNoButton() async {
        let closed = await height("/clear", open: false)
        let open = await height("/clear", open: true)
        XCTAssertEqual(closed, open, accuracy: 0.5)
        XCTAssertLessThan(closed, 30)
    }
}
