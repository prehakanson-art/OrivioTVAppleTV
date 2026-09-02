import XCTest

/// Drives the tvOS remote (which osascript can't) and records WHICH element has
/// focus after each press, plus a screenshot — so focus behavior is unambiguous.
final class FocusTour: XCTestCase {
    let app = XCUIApplication()

    func testTour() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launch()
        let r = XCUIRemote.shared

        r.press(.select); sleep(10); log("home_loaded")

        r.press(.down); sleep(2); log("down_from_tabbar")
        r.press(.left); sleep(2); log("left")
        r.press(.up); sleep(2); log("up_from_first_card")
        r.press(.down); sleep(2); log("down_again")
        r.press(.right); sleep(2); log("right_to_2nd")
        r.press(.up); sleep(2); log("up_from_2nd_card")
        r.press(.left); sleep(1)
        r.press(.select, forDuration: 2.0); sleep(2); log("longpress_on_card")
        r.press(.menu); sleep(2); log("after_menu")
    }

    /// Tour the Stremio (Aurora) theme: board with the reflective posters + meta
    /// header, the expanded sidebar, and each tab screen. Screenshots per step.
    func testStremioTour() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-stremioTheme"]
        app.launch()
        let r = XCUIRemote.shared

        r.press(.select); sleep(10); log("00_board_top_row")   // dismiss gate → Board (top row focused; check clipping)
        r.press(.down); sleep(1)
        r.press(.right); sleep(1); r.press(.right); sleep(2); log("01_row1_3rd")   // 3rd poster of Popular-Movie
        // Column preservation past See All: Down should land on the next row's
        // poster (empty label), NOT "See All".
        r.press(.down); sleep(2); log("02_down_should_be_poster")
        r.press(.down); sleep(2); log("03_down_again_poster")
        r.press(.up); sleep(2); log("04_up_should_be_poster")

        // Open the sidebar. On the board, Back first returns to the row start,
        // then a second Back bubbles out to the rail.
        r.press(.menu); sleep(1); r.press(.menu); sleep(2); log("05_sidebar_expanded")

        // Rail order is Board · Discover · Library · Search · Addons · Settings.
        // Select each in turn; every screen's Back re-opens the rail on its tab.
        r.press(.down); sleep(1); r.press(.select); sleep(6); log("04_discover")
        r.press(.menu); sleep(2)
        r.press(.down); sleep(1); r.press(.select); sleep(5); log("05_library")
        r.press(.menu); sleep(2)
        r.press(.down); sleep(1); r.press(.select); sleep(5); log("06_search")
        r.press(.menu); sleep(2)
        r.press(.down); sleep(1); r.press(.select); sleep(5); log("07_addons")
        r.press(.menu); sleep(2)
        r.press(.down); sleep(1); r.press(.select); sleep(5); log("08_settings")
    }

    /// Aurora on the Apple TV HD (A8) tier: forces `-lowPower` so the scale-only
    /// focus path (no native card platter / shadows / repeatForever gloss) is
    /// exercised. Just needs to render the board without crashing.
    func testStremioLowPower() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-stremioTheme", "-lowPower"]
        app.launch()
        let r = XCUIRemote.shared
        r.press(.select); sleep(10); log("lp_00_board")
        r.press(.down); sleep(2); r.press(.right); sleep(2); log("lp_01_focus")
        r.press(.down); sleep(2); log("lp_02_down")
    }

    /// Account → Stremio: the new QR sign-in row + the Stremio Link QR page.
    func testStremioAccount() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-settingsDemo", "-paneAccount"]
        app.launch()
        let r = XCUIRemote.shared
        sleep(8); r.press(.select); sleep(2); log("sa_00_after_gate")   // dismiss profile gate if shown
        r.press(.right); sleep(1); log("sa_01_pane")                    // focus into the account pane
        r.press(.down); sleep(1); r.press(.down); sleep(1); log("sa_02_rows")
        r.press(.select); sleep(3); log("sa_03_stremio_view")           // open the Stremio account view
        r.press(.select); sleep(7); log("sa_04_qr")                     // Connect → QR page (creates link)
    }

    /// Diagnose the Modern theme: CW hold menu vs poster hold menu, deterministic.
    func testModernDiagnostics() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-cinemaTheme"]
        app.launch()
        let r = XCUIRemote.shared

        r.press(.select); sleep(10); log("00_cinema_home")   // dismiss profile gate
        for i in 1...16 { r.press(.down); sleep(1) }
        sleep(1); log("bottom")
        attach("STREAMING", app.staticTexts["Streaming Services"].exists ? 1 : 0)
        attach("COLLECTIONS", app.staticTexts["Collections"].exists ? 1 : 0)
    }

    private func menuCount() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Play Manually' OR label CONTAINS 'Remove from' OR label CONTAINS 'Start from Beginning' OR label CONTAINS 'Add to Library' OR label CONTAINS 'Go to Details' OR label CONTAINS 'Mark as'"))
            .count
    }

    /// Drives focus across an Onyx row so the focused card's landscape
    /// expansion (`View.focusExpand` / `FusionMotion.rowExpand`) can be
    /// recorded with `simctl io recordVideo` and inspected frame-by-frame.
    /// Each Right is a fresh expansion: the previous card collapses as the
    /// next one grows.
    func testOnyxExpandMotion() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-onyxTheme", "-homeDemo"]
        app.launch()
        let r = XCUIRemote.shared

        sleep(14)                       // let home + artwork settle
        r.press(.down); sleep(4)        // into the first row of cards
        for _ in 0..<5 { r.press(.right); sleep(3) }
    }

    private func attach(_ name: String, _ value: Int) {
        let t = XCTAttachment(string: "\(name): \(value)")
        t.name = name; t.lifetime = .keepAlways; add(t)
    }

    /// The label + type of whatever currently has focus.
    private func focusedDesc() -> String {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        if focused.isEmpty { return "FOCUS: <none>" }
        return "FOCUS: " + focused.map { "[\($0.elementType.rawValue)] '\($0.label)'" }.joined(separator: " | ")
    }

    private func log(_ name: String) {
        let t = XCTAttachment(string: name + " -> " + focusedDesc())
        t.name = name + "_focus"; t.lifetime = .keepAlways; add(t)
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
