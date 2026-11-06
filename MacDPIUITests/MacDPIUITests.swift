import XCTest

final class MacDPIUITests: XCTestCase {
    @MainActor
    func testLightAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--test-light-appearance"]
        app.launch()
        XCTAssertTrue(app.buttons["engine-toggle"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "MacDPI Light Dashboard"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
    }
    @MainActor
    func testLocalEngineLifecycleAndDiagnostics() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--test-port", "18086"]
        app.launch()
        let status = app.staticTexts["engine-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label == "Disabled" || status.value as? String == "Disabled")
        let toggle = app.buttons["engine-toggle"]
        toggle.click()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Local proxy ready' OR value == 'Local proxy ready'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        toggle.click()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Disabled' OR value == 'Disabled'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        app.buttons["nav-2"].click()
        app.buttons["readiness-check"].click()
        let report = app.staticTexts["diagnostics-text"]
        XCTAssertTrue(report.label.contains("Configuration valid") || (report.value as? String)?.contains("Configuration valid") == true)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "MacDPI Diagnostics"; attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["nav-0"].click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.buttons["engine-toggle"].waitForExistence(timeout: 5))
        let dashboard = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        dashboard.name = "MacDPI Dashboard"; dashboard.lifetime = .keepAlways; add(dashboard)
        app.terminate()
    }
    @MainActor
    func testProxiedWebWindowClosesWhenEngineIsDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--test-port", "18087"]
        app.launch()
        let toggle = app.buttons["engine-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.click()
        let open = app.buttons["open-proxied-web"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        open.click()
        let address = app.textFields["web-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Choose a site", "Choose a site")).firstMatch
        XCTAssertTrue(prompt.exists)
        // No website is loaded by this test. Closing the engine must tear down the web window.
        app.typeKey("o", modifierFlags: .command)
        app.windows["MacDPI"].buttons["engine-toggle"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.terminate()
    }
}
