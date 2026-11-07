import Foundation
import XCTest
@testable import MacDPICore

final class TUNFailureCategoryTests: XCTestCase {
    func testSystemErrorContentsCannotEnterCategory() {
        let error = NSError(domain: "private.example", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "secret payload and destination",
                                       NSURLErrorFailingURLStringErrorKey: "https://private.example/account"])
        XCTAssertEqual(TUNFailureCategory.broker(error), .operatingSystem)
        XCTAssertEqual(TUNFailureCategory.broker(error).rawValue, "operating-system")
    }

    func testBrokerReasonsRemainDistinctAndFixed() {
        let cases: [(TUNRouteError, TUNFailureCategory)] = [
            (.baselineChanged, .networkBaselineChanged), (.conflictingVPN, .networkConflict),
            (.systemForwardingEnabled, .networkConflict), (.unsuitableNetwork, .networkStateUnavailable),
            (.policyTooLarge, .policyLimit), (.noEligibleRoutes, .noEligibleRoutes),
            (.invalidLease, .invalidLease), (.alreadyRunning, .alreadyRunning),
            (.journalRequiresRecovery, .recoveryRequired), (.routeConflict, .routeConflict),
            (.routeNotInstalled, .routeMissing), (.engineNotReady, .workerNotReady),
            (.restorationUnverified, .cleanupUnverified)
        ]
        for (error, expected) in cases { XCTAssertEqual(TUNFailureCategory.broker(error), expected) }
    }

    func testWorkerExitCategoriesDoNotInventFailureOnStop() {
        XCTAssertNil(TUNFailureCategory.worker(exitCode: 0, sessionFailed: true))
        XCTAssertEqual(TUNFailureCategory.worker(exitCode: 1, sessionFailed: true), .packetEngine)
        XCTAssertEqual(TUNFailureCategory.worker(exitCode: 2, sessionFailed: true), .invalidSession)
        XCTAssertEqual(TUNFailureCategory.worker(exitCode: 3, sessionFailed: true), .physicalInterface)
        XCTAssertEqual(TUNFailureCategory.worker(exitCode: 4, sessionFailed: true), .controlLease)
        for unknown in [Int32.min, -1, 5, Int32.max] {
            XCTAssertEqual(TUNFailureCategory.worker(exitCode: unknown, sessionFailed: true), .unknownWorkerExit)
        }
        for cancelledCode in [Int32.min, -1, 0, 1, 2, 3, 4, 5, Int32.max] {
            XCTAssertNil(TUNFailureCategory.worker(exitCode: cancelledCode, sessionFailed: false))
        }
    }
}
