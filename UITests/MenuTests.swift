import XCTest

final class MenuTests: XCTestCase {
    func testCollapseExpandAndBackgroundTouches() {
        let app = XCUIApplication(); app.launch()
        let collapse = app.buttons["diagnostics.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 15))
        let background = app.buttons["demo.backgroundButton"]
        XCTAssertTrue(background.isHittable); background.tap()
        XCTAssertTrue(app.staticTexts["demo.backgroundCount"].label.contains("Нажми фон: 1"))
        background.tap(withNumberOfTaps: 2, numberOfTouches: 3)
        let expand = app.buttons["diagnostics.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); expand.tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 5)); collapse.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let hittable = NSPredicate(format: "hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: expand)], timeout: 5), .completed)
        XCTAssertGreaterThanOrEqual(expand.frame.minY, 40); expand.tap()
        func tap(_ element: XCUIElement) {
            for _ in 0..<8 { if element.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(element.isHittable); element.tap()
        }
        func open(_ index: Int) {
            let home = app.buttons["diagnostics.home"]; if home.exists { home.tap() }
            tap(app.buttons["diagnostics.category.\(index)"])
        }
        func group(_ key: String) {
            let header = app.buttons["diagnostics.group.\(key)"]
            if header.value as? String == "Закрыто" { tap(header) }
        }
        func gear(_ key: String) { tap(app.buttons["diagnostics.settings.\(key)"]) }
        open(1)
        let esp = app.switches["diagnostics.esp"]
        XCTAssertTrue(esp.exists); let prior = esp.value as? String
        tap(esp); XCTAssertNotEqual(esp.value as? String, prior)
        XCTAssertFalse(app.switches["diagnostics.espWalls"].exists)
        gear("esp"); XCTAssertTrue(app.switches["diagnostics.espWalls"].exists)
        gear("esp"); XCTAssertFalse(app.switches["diagnostics.espWalls"].exists)
        XCTAssertNotEqual(esp.value as? String, prior, "Closing settings must not disable ESP")
        XCTAssertTrue(app.switches["diagnostics.chams"].exists)
        open(3)
        XCTAssertTrue(app.buttons["diagnostics.unlockVehicle"].exists)
        XCTAssertTrue(app.buttons["diagnostics.startEngine"].exists)
        group("vehicleCare"); XCTAssertTrue(app.buttons["diagnostics.repairVehicle"].exists)
        open(5)
        XCTAssertTrue(app.switches["diagnostics.noSpread"].exists)
        XCTAssertTrue(app.switches["diagnostics.rapidFire"].exists)
        XCTAssertFalse(app.sliders["Множитель скорострельности"].exists)
        gear("rapidFire"); XCTAssertTrue(app.sliders["Множитель скорострельности"].exists)
        group("sounds"); gear("customShotSound")
        XCTAssertTrue(app.buttons["diagnostics.shotPreview"].exists)
        XCTAssertTrue(app.buttons["diagnostics.shotPresets"].exists)
        open(4)
        XCTAssertTrue(app.buttons["diagnostics.suicide"].exists)
        XCTAssertTrue(app.buttons["diagnostics.respawn"].exists)
        XCTAssertTrue(app.switches["diagnostics.noAnim"].exists)
        XCTAssertTrue(app.switches["diagnostics.fastAnim"].exists)
        open(2)
        XCTAssertTrue(app.switches["diagnostics.noCollision"].exists)
        XCTAssertTrue(app.buttons["diagnostics.flightToggle"].exists)
        group("teleports"); XCTAssertTrue(app.buttons["diagnostics.waypoint"].exists)
        open(6)
        XCTAssertTrue(app.switches["diagnostics.silentAim"].exists)
        XCTAssertFalse(app.buttons["diagnostics.aimWhitelist"].exists)
        gear("silentAim"); XCTAssertTrue(app.buttons["diagnostics.aimWhitelist"].exists)
        open(7)
        group("chat"); XCTAssertTrue(app.switches["diagnostics.autoEvent"].exists)
        group("performance"); XCTAssertTrue(app.switches["diagnostics.fpsUp"].exists)
        group("appearanceMenu"); XCTAssertTrue(app.switches["diagnostics.animations"].exists)
        open(0)
    }
}
