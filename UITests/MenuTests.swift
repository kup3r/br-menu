import XCTest

final class MenuTests: XCTestCase {
    func testCollapseExpandAndBackgroundTouches() {
        let app = XCUIApplication()
        app.launch()
        let collapse = app.buttons["diagnostics.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 15))
        let background = app.buttons["demo.backgroundButton"]
        XCTAssertTrue(background.isHittable)
        background.tap()
        XCTAssertTrue(app.staticTexts["demo.backgroundCount"].label.contains("Нажми фон: 1"))
        collapse.tap()
        let expand = app.buttons["diagnostics.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let hittable = NSPredicate(format: "hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: expand)], timeout: 5), .completed)
        XCTAssertGreaterThanOrEqual(expand.frame.minY, 40, "BR must stay below the portrait status bar")
        expand.tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        let tabs = app.segmentedControls["diagnostics.tabs"]
        tabs.buttons["ESP"].tap()
        let grid = app.switches["diagnostics.esp"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let prior = grid.value as? String
        grid.tap()
        XCTAssertNotEqual(grid.value as? String, prior)
        tabs.buttons["Авто"].tap()
        XCTAssertTrue(app.buttons["diagnostics.stopVehicle"].waitForExistence(timeout: 5))
        tabs.buttons["Оруж."].tap()
        XCTAssertTrue(app.buttons["diagnostics.ammoRefill"].waitForExistence(timeout: 5))
        tabs.buttons["Aim"].tap()
        XCTAssertTrue(app.switches["diagnostics.silentAim"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnostics.aimWhitelist"].exists)
        tabs.buttons["⚙︎"].tap()
        XCTAssertTrue(app.switches["diagnostics.animations"].waitForExistence(timeout: 5))
        tabs.buttons["Движ."].tap()
        XCTAssertTrue(app.buttons["diagnostics.flightToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnostics.waypoint"].exists)
        XCTAssertTrue(app.buttons["diagnostics.waypointCancel"].exists)
        tabs.buttons["Обзор"].tap()
    }
}
