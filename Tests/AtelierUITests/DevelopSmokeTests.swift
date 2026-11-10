import XCTest

final class DevelopSmokeTests: XCTestCase {
    func testMatchLookSkinModeWithAReferenceWithoutAFace() throws {
        let app = try launchDevelop()
        defer { app.terminate() }
        app.typeKey("m", modifierFlags: [.command, .shift])
        let gallery = app.buttons["Built-in References"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.click()
        let study = app.buttons["Mad Max: Fury Road — Desert Action"]
        XCTAssertTrue(study.waitForExistence(timeout: 10))
        study.click()

        let skin = app.descendants(matching: .any).matching(identifier: "match-look-skin-tones").firstMatch
        XCTAssertTrue(skin.waitForExistence(timeout: 10))
        skin.click()
        let match = app.menuItems["Match Skin Tone"]
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.click()
        let warning = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No usable face skin in the reference.")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Apply"].isEnabled)

        skin.click()
        app.menuItems["Off"].click()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 10))
        app.buttons["Cancel"].click()
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 10))
    }

    func testExposureEditAndUndo() throws {
        let app = try launchDevelop()
        defer { app.terminate() }

        let value = app.staticTexts["develop-slider-value-Exposure"]
        XCTAssertTrue(value.waitForExistence(timeout: 15))
        let original = try XCTUnwrap(value.value as? String ?? (value.label.isEmpty ? nil : value.label))
        XCTAssertEqual(original, "+0.00")
        value.click()

        let field = app.textFields["develop-slider-field-Exposure"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("1")
        field.typeKey(.return, modifierFlags: [])
        assertLabel("+1.00", on: value)

        app.typeKey("z", modifierFlags: .command)
        assertLabel(original, on: value)
    }

    private func launchDevelop() throws -> XCUIApplication {
        let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ATELIER_UI_APP"])
        let dataPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ATELIER_UI_DATA"])
        let app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        app.launchEnvironment = [
            "ATELIER_CATALOG_PATH": dataPath + "/\(UUID().uuidString).ateliercatalog",
            "ATELIER_UI_SMOKE": "1",
            "HOME": dataPath,
            "CFFIXED_USER_HOME": dataPath,
            "TMPDIR": dataPath + "/tmp",
            "LC_ALL": "en_US.UTF-8",
        ]
        continueAfterFailure = false
        app.launch()

        let library = app.menuBars.menuBarItems["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.click()
        let develop = library.menuItems["Develop"]
        XCTAssertTrue(develop.waitForExistence(timeout: 15))
        develop.click()

        return app
    }

    private func assertLabel(_ label: String, on element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == true AND (value == %@ OR label == %@)", label, label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected \(label); found \(element.debugDescription)")
    }
}
