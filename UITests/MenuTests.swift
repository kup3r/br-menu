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
        func open(_ index: Int) {
            let home = app.buttons["diagnostics.home"]
            if home.exists { home.tap() }
            app.buttons["diagnostics.category.\(index)"].tap()
        }
        open(1)
        let esp = app.switches["diagnostics.esp"]
        XCTAssertTrue(esp.waitForExistence(timeout: 5)); let prior = esp.value as? String
        esp.tap(); XCTAssertNotEqual(esp.value as? String, prior)
        open(3)
        XCTAssertTrue(app.buttons["diagnostics.unlockVehicle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnostics.startEngine"].exists)
        open(5)
        XCTAssertTrue(app.switches["diagnostics.noSpread"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["diagnostics.rapidFire"].exists)
        open(4)
        XCTAssertTrue(app.buttons["diagnostics.suicide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnostics.respawn"].exists)
        XCTAssertTrue(app.switches["diagnostics.noAnim"].exists)
        XCTAssertTrue(app.switches["diagnostics.fastAnim"].exists)
        open(2)
        XCTAssertTrue(app.switches["diagnostics.noCollision"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnostics.flightToggle"].exists)
        open(6)
        XCTAssertTrue(app.switches["diagnostics.silentAim"].waitForExistence(timeout: 5))
        open(7)
        XCTAssertTrue(app.switches["diagnostics.animations"].exists)
        open(0)
    }
}
