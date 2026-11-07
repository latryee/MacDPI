import Darwin
import Foundation
import XCTest
@testable import MacDPICore

final class ProcessResourcesTests: XCTestCase {
    private func reading(_ cpu: UInt64, memory: UInt64 = 1024, identity: UInt64 = 1) -> ProcessResourceReading {
        ProcessResourceReading(identity: identity, cpuNanoseconds: cpu, residentBytes: memory)
    }

    func testAggregatesIntervalCPUAndFinalRSS() throws {
        let before: [Int32: ProcessResourceReading] = [10: reading(5_000_000_000), 11: reading(7_000_000_000, identity: 2)]
        let after: [Int32: ProcessResourceReading] = [10: reading(5_250_000_000, memory: 4096), 11: reading(7_750_000_000, memory: 8192, identity: 2)]
        let result = try XCTUnwrap(ProcessResourceUsage.between(first: before, last: after, elapsedSeconds: 2))
        XCTAssertEqual(result.cpuPercent, 50, accuracy: 0.000_001)
        XCTAssertEqual(result.residentBytes, 12_288)
        // CPU is a one-core percentage, so multithreaded usage is not capped.
        XCTAssertEqual(try XCTUnwrap(ProcessResourceUsage.between(first: before, last: after, elapsedSeconds: 0.25)).cpuPercent, 400)
    }

    func testRejectsRestartedProcessAndDecreasingCounter() {
        let before: [Int32: ProcessResourceReading] = [10: reading(200)]
        XCTAssertNil(ProcessResourceUsage.between(first: before, last: [10: reading(201, identity: 2)], elapsedSeconds: 1))
        XCTAssertNil(ProcessResourceUsage.between(first: before, last: [10: reading(199)], elapsedSeconds: 1))
        XCTAssertNil(ProcessResourceUsage.between(first: [10: reading(0, identity: 0)], last: [10: reading(1, identity: 0)], elapsedSeconds: 1))
    }

    func testRequiresTheSameNonemptyPositivePIDSet() {
        XCTAssertNil(ProcessResourceUsage.between(first: [:], last: [:], elapsedSeconds: 1))
        let before: [Int32: ProcessResourceReading] = [10: reading(0)]
        XCTAssertNil(ProcessResourceUsage.between(first: before, last: [:], elapsedSeconds: 1))
        XCTAssertNil(ProcessResourceUsage.between(first: before, last: [11: reading(1)], elapsedSeconds: 1))
        XCTAssertNil(ProcessResourceUsage.between(first: [0: reading(0)], last: [0: reading(1)], elapsedSeconds: 1))
    }

    func testRejectsInvalidIntervalsAndOverflow() {
        let before: [Int32: ProcessResourceReading] = [10: reading(0)]
        let after: [Int32: ProcessResourceReading] = [10: reading(.max)]
        for elapsed in [0, -1, Double.nan, Double.infinity, -Double.infinity, Double.leastNonzeroMagnitude] {
            XCTAssertNil(ProcessResourceUsage.between(first: before, last: after, elapsedSeconds: elapsed))
        }
        let twoBefore: [Int32: ProcessResourceReading] = [10: reading(0), 11: reading(0)]
        XCTAssertNil(ProcessResourceUsage.between(first: twoBefore, last: [10: reading(.max), 11: reading(1)], elapsedSeconds: 1))
        XCTAssertNil(ProcessResourceUsage.between(first: twoBefore, last: [10: reading(1, memory: .max), 11: reading(1, memory: 1)], elapsedSeconds: 1))
        // A measured unchanged CPU counter is a valid zero delta.
        XCTAssertEqual(ProcessResourceUsage.between(first: before, last: before, elapsedSeconds: 1)?.cpuPercent, 0)
    }

    func testMachTimeConversionHandlesFractionalScaleAndWideProduct() {
        XCTAssertEqual(ProcessResourceReader.nanoseconds(ticks: 24_000_000, numerator: 125, denominator: 3), 1_000_000_000)
        XCTAssertEqual(ProcessResourceReader.nanoseconds(ticks: 5, numerator: 125, denominator: 3), 208)
        XCTAssertEqual(ProcessResourceReader.nanoseconds(ticks: .max, numerator: 2, denominator: 2), .max)
        XCTAssertNil(ProcessResourceReader.nanoseconds(ticks: .max, numerator: 2, denominator: 1))
        XCTAssertNil(ProcessResourceReader.nanoseconds(ticks: 1, numerator: 1, denominator: 0))
        XCTAssertNil(ProcessResourceReader.nanoseconds(ticks: 1, numerator: 0, denominator: 1))
    }

    func testNativeSelfReadingAgreesWithGetrusageTimeUnits() throws {
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        guard let own = ProcessResourceReader.read(pid: getpid()) else {
            throw XCTSkip("Native self resource information is unavailable in this execution environment.")
        }
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        func nanos(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000
        }
        // Independent getrusage uses timeval rather than Mach ticks. Allow
        // timer granularity between the consecutive kernel accounting calls.
        XCTAssertGreaterThanOrEqual(Double(own.cpuNanoseconds), nanos(before) - 2_000_000)
        XCTAssertLessThanOrEqual(Double(own.cpuNanoseconds), nanos(after) + 2_000_000)
        XCTAssertGreaterThan(own.identity, 0)
        XCTAssertGreaterThan(own.residentBytes, 0)
    }

    func testNativeReadingOfOwnRunningChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        XCTAssertTrue(child.isRunning)
        guard let first = ProcessResourceReader.read(pid: child.processIdentifier),
              let second = ProcessResourceReader.read(pid: child.processIdentifier) else {
            throw XCTSkip("Resource information for the test's own running child is unavailable in this execution environment.")
        }
        XCTAssertTrue(child.isRunning)
        XCTAssertGreaterThan(first.identity, 0)
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertGreaterThan(first.residentBytes, 0)
        XCTAssertGreaterThan(second.residentBytes, 0)
        XCTAssertGreaterThanOrEqual(second.cpuNanoseconds, first.cpuNanoseconds)
    }

    func testInvalidPIDsAreUnavailable() {
        XCTAssertNil(ProcessResourceReader.read(pid: 0))
        XCTAssertNil(ProcessResourceReader.read(pid: -1))
        XCTAssertNil(ProcessResourceReader.read(pid: .max))
    }
}
