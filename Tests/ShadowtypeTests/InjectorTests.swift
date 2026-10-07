import ApplicationServices
import XCTest
@testable import Shadowtype

final class InjectorTests: XCTestCase {
    func testFailedSelectedTextWriteRestoresCaretBeforeDeleteFallback() {
        let surface = FakeInjectorAXSurface(value: "KEEPbadTAIL",
                                            selection: CFRange(location: 7, length: 0))
        surface.selectedTextWriteError = .cannotComplete
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let injector = Injector(
            axAccess: surface,
            unicodeTyper: { surface.syntheticallyType($0) },
            backspacePoster: { surface.syntheticallyBackspace($0) })

        XCTAssertTrue(injector.replaceBeforeCaret(utf16Length: 3, keystrokeCount: 3,
                                                  with: "X", in: element))
        XCTAssertEqual(surface.value, "KEEPXTAIL")
        XCTAssertEqual(surface.selection.location, 5)
        XCTAssertEqual(surface.selection.length, 0)
        XCTAssertEqual(surface.syntheticBackspaceCount, 3)
    }

    // Snippet accept: the typed `;sig` run is swapped for a multi-line expansion in one AX op, with
    // the newlines intact and the caret left after the inserted text.
    func testMultiLineSnippetReplacesTypedTriggerAtomically() {
        let surface = FakeInjectorAXSurface(value: "Thanks ;sig",
                                            selection: CFRange(location: 11, length: 0))
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let injector = Injector(
            axAccess: surface,
            unicodeTyper: { surface.syntheticallyType($0) },
            backspacePoster: { surface.syntheticallyBackspace($0) })
        let match = SnippetMatch(name: "sig", expansion: "Best,\nDarío", typedRun: ";sig")

        XCTAssertTrue(injector.replaceBeforeCaret(utf16Length: match.replaceUTF16Length,
                                                  keystrokeCount: match.replaceKeystrokeCount,
                                                  with: match.expansion, in: element))
        XCTAssertEqual(surface.value, "Thanks Best,\nDarío")
        XCTAssertEqual(surface.selection.location, ("Thanks Best,\nDarío" as NSString).length)
        XCTAssertEqual(surface.syntheticBackspaceCount, 0)
        XCTAssertEqual(surface.syntheticTypeCount, 0)
    }

    // AX refused: the ordered fallback deletes exactly the typed run, then types the expansion line by
    // line with a Shift-Return between lines — never a bare typed \n, which SENDS in chat hosts.
    func testMultiLineSnippetFallbackDeletesTypedRunThenTypesLinesWithSoftBreaks() {
        let surface = FakeInjectorAXSurface(value: "Hi ;si",
                                            selection: CFRange(location: 6, length: 0))
        surface.selectedTextWriteError = .cannotComplete
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var typed: [String] = []
        var softBreaks = 0
        let injector = Injector(
            axAccess: surface,
            unicodeTyper: { typed.append($0); return surface.syntheticallyType($0) },
            backspacePoster: { surface.syntheticallyBackspace($0) },
            softNewlinePoster: { softBreaks += 1; _ = surface.syntheticallyType("\n") })

        XCTAssertTrue(injector.replaceBeforeCaret(utf16Length: 3, keystrokeCount: 3,
                                                  with: "Best,\n\nD", in: element))
        XCTAssertEqual(surface.value, "Hi Best,\n\nD")
        XCTAssertEqual(surface.syntheticBackspaceCount, 3)
        XCTAssertEqual(typed, ["Best,", "D"], "the blank line is a soft break, not an empty typed chunk")
        XCTAssertEqual(softBreaks, 2)
        XCTAssertFalse(typed.contains { $0.contains(where: \.isNewline) }, "a line break was typed raw")
    }

    // Single-line text keeps the one-event Unicode path — no soft-break machinery for the common case.
    func testSingleLineFallbackTypesOnceWithoutSoftBreaks() {
        var typed: [String] = []
        var softBreaks = 0
        let injector = Injector(axAccess: FakeInjectorAXSurface(value: "", selection: CFRange(location: 0, length: 0)),
                                unicodeTyper: { typed.append($0); return true },
                                backspacePoster: { _ in },
                                softNewlinePoster: { softBreaks += 1 })
        XCTAssertTrue(injector.inject("hello world", into: nil))
        XCTAssertEqual(typed, ["hello world"])
        XCTAssertEqual(softBreaks, 0)
    }

    func testLineSegmentsCountsCRLFOnceAndKeepsBlankLines() {
        XCTAssertEqual(Injector.lineSegments("a\r\nb\n\nc"), ["a", "b", "", "c"])
        XCTAssertEqual(Injector.lineSegments("one"), ["one"])
        XCTAssertEqual(Injector.lineSegments("end\n"), ["end", ""])
    }

    func testUnreadableSelectionRangeDoesNotAppendThroughAXSplice() {
        let surface = FakeInjectorAXSurface(value: "headtail",
                                            selection: CFRange(location: 4, length: 0))
        surface.selectedTextWriteError = .cannotComplete
        surface.selectedRangeReadError = .cannotComplete
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let injector = Injector(
            axAccess: surface,
            unicodeTyper: { surface.syntheticallyType($0) })

        XCTAssertTrue(injector.inject("X", into: element))
        XCTAssertEqual(surface.value, "headXtail")
        XCTAssertEqual(surface.valueWriteCount, 0)
        XCTAssertEqual(surface.syntheticTypeCount, 1)
    }

    func testAXSpliceReplacesSelectedNonBMPUTF16RangeOnceAndMovesCaret() {
        let surface = FakeInjectorAXSurface(value: "A😀B",
                                            selection: CFRange(location: 1, length: 2))
        surface.selectedTextWriteError = .cannotComplete
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let injector = Injector(
            axAccess: surface,
            unicodeTyper: { surface.syntheticallyType($0) })

        XCTAssertTrue(injector.inject("X", into: element))
        XCTAssertEqual(surface.value, "AXB")
        XCTAssertEqual(surface.valueWriteCount, 1)
        XCTAssertEqual(surface.syntheticTypeCount, 0)
        XCTAssertEqual(surface.selection.location, 2)
        XCTAssertEqual(surface.selection.length, 0)
    }
}

private final class FakeInjectorAXSurface: InjectorAXAccess {
    var value: String
    var selection: CFRange
    var selectedTextWriteError: AXError = .success
    var selectedRangeReadError: AXError = .success
    private(set) var valueWriteCount = 0
    private(set) var syntheticTypeCount = 0
    private(set) var syntheticBackspaceCount = 0

    init(value: String, selection: CFRange) {
        self.value = value
        self.selection = selection
    }

    func copyAttributeValue(_ attribute: CFString,
                            from element: AXUIElement) -> (AXError, CFTypeRef?) {
        switch attribute as String {
        case kAXValueAttribute:
            return (.success, value as CFString)
        case kAXSelectedTextRangeAttribute:
            guard selectedRangeReadError == .success else {
                return (selectedRangeReadError, nil)
            }
            var selection = selection
            return (.success, AXValueCreate(.cfRange, &selection))
        default:
            return (.attributeUnsupported, nil)
        }
    }

    func setAttributeValue(_ newValue: CFTypeRef, for attribute: CFString,
                           on element: AXUIElement) -> AXError {
        switch attribute as String {
        case kAXSelectedTextAttribute:
            guard selectedTextWriteError == .success else { return selectedTextWriteError }
            replaceSelection(with: newValue as! String)
            return .success
        case kAXValueAttribute:
            value = newValue as! String
            valueWriteCount += 1
            return .success
        case kAXSelectedTextRangeAttribute:
            guard CFGetTypeID(newValue) == AXValueGetTypeID() else { return .illegalArgument }
            var range = CFRange()
            guard AXValueGetValue(newValue as! AXValue, .cfRange, &range) else {
                return .illegalArgument
            }
            selection = range
            return .success
        default:
            return .attributeUnsupported
        }
    }

    func syntheticallyType(_ text: String) -> Bool {
        syntheticTypeCount += 1
        replaceSelection(with: text)
        return true
    }

    func syntheticallyBackspace(_ count: Int) {
        for _ in 0..<count {
            syntheticBackspaceCount += 1
            if selection.length > 0 {
                replaceSelection(with: "")
            } else if selection.location > 0 {
                selection = CFRange(location: selection.location - 1, length: 1)
                replaceSelection(with: "")
            }
        }
    }

    private func replaceSelection(with replacement: String) {
        let units = Array(value.utf16)
        let start = selection.location
        let end = start + selection.length
        let prefix = String(utf16CodeUnits: units, count: start)
        let suffix = String(utf16CodeUnits: Array(units[end...]), count: units.count - end)
        value = prefix + replacement + suffix
        selection = CFRange(location: start + replacement.utf16.count, length: 0)
    }
}
