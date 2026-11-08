import Darwin
import XCTest
@testable import MacDPI

final class PersonalTUNProcessTests: XCTestCase {
    @MainActor
    private func waitForExit(_ process: Process) async throws {
        let deadline = DispatchTime.now() + .seconds(3)
        while process.isRunning && DispatchTime.now() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !process.isRunning else {
            XCTFail("The disposable child did not exit in time")
            throw NSError(domain: "MacDPI.ProcessFixture", code: 1)
        }
    }

    @MainActor
    func testHardFallbackStopsOnlyTheCapturedChild() async throws {
        let target = Process(), unrelated = Process()
        for child in [target, unrelated] {
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["20"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
        }
        defer {
            for child in [target, unrelated] where child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        XCTAssertTrue(PersonalTUNController.forceTerminate(target))
        try await waitForExit(target)
        XCTAssertEqual(target.terminationReason, .uncaughtSignal)
        XCTAssertEqual(target.terminationStatus, SIGKILL)
        XCTAssertTrue(unrelated.isRunning)
    }

    @MainActor
    func testHardFallbackDoesNothingToAnExitedChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        try await waitForExit(child)
        XCTAssertFalse(PersonalTUNController.forceTerminate(child))
        XCTAssertEqual(child.terminationStatus, 0)
    }
}
