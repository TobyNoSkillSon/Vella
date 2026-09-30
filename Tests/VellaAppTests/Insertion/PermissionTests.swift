import XCTest
@testable import Vella

final class PermissionTests: XCTestCase {
    @MainActor private func freshHistory() -> PermissionPromptHistory {
        var shown = false
        return PermissionPromptHistory(read: { shown }, write: { shown = true })
    }

    @MainActor func testMissingPermissionPromptsAndBlocksRecording() {
        var prompts = 0
        let permission = InsertionPermission(isTrusted: { false }, prompt: { prompts += 1 }, history: freshHistory())
        let model = Model(insertionPermission: permission)
        model.toggle()
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.recorder.url)
    }
    @MainActor func testGrantedPermissionDoesNotPrompt() {
        var prompts = 0
        let permission = InsertionPermission(isTrusted: { true }, prompt: { prompts += 1 }, history: freshHistory())
        XCTAssertTrue(permission.ensure())
        XCTAssertEqual(prompts, 0)
    }
    @MainActor func testRechecksPermissionAfterGrantAndRevocation() {
        var trusted = false
        var prompts = 0
        let permission = InsertionPermission(isTrusted: { trusted }, prompt: { prompts += 1 }, history: freshHistory())
        XCTAssertFalse(permission.ensure())
        trusted = true
        XCTAssertTrue(permission.ensure())
        XCTAssertEqual(prompts, 1)
        trusted = false
        XCTAssertFalse(permission.ensure())
        XCTAssertEqual(prompts, 1) // No repeated dialog in the same process.
    }
    @MainActor func testCopyAndPasteHaveDifferentStatus() {
        let model = Model()
        model.phase = .success
        XCTAssertEqual(model.title, "Copied—paste with ⌘V")
        model.insertionWasAutomatic = true
        XCTAssertEqual(model.title, "Paste sent")
    }
    @MainActor func testRepeatedDeniedAttemptsDoNotReopenPrompt() {
        var prompts = 0
        let permission = InsertionPermission(isTrusted: { false }, prompt: { prompts += 1 }, history: freshHistory())
        XCTAssertFalse(permission.ensure())
        XCTAssertFalse(permission.ensure())
        XCTAssertFalse(permission.ensure())
        XCTAssertEqual(prompts, 1)
    }
    @MainActor func testNewProcessDoesNotPromptAfterPreviousSetup() {
        let history = freshHistory()
        var prompts = 0
        let first = InsertionPermission(isTrusted: { false }, prompt: { prompts += 1 }, history: history)
        XCTAssertFalse(first.ensure())
        let relaunched = InsertionPermission(isTrusted: { false }, prompt: { prompts += 1 }, history: history)
        XCTAssertFalse(relaunched.ensure())
        XCTAssertEqual(prompts, 1)
    }
    @MainActor func testExistingGrantNeverPromptsEvenAfterRevocation() {
        let history = freshHistory()
        var prompts = 0
        XCTAssertTrue(InsertionPermission(isTrusted: { true }, prompt: { prompts += 1 }, history: history).ensure())
        XCTAssertFalse(InsertionPermission(isTrusted: { false }, prompt: { prompts += 1 }, history: history).ensure())
        XCTAssertEqual(prompts, 0)
    }
}
