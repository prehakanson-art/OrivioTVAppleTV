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

    /// The detail page's Play button: where opening focus lands, and whether a
    /// held Select opens the Play Manually menu. Both are reported as counts so
    /// a run either proves or disproves the report without anyone watching.
    ///
    /// `XCUIRemote.press(_:forDuration:)` DOES deliver a held Select in the
    /// simulator — the note that hold menus are device-only to test is wrong.
    func testDetailPlayHold() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-detailDemo"]
        holdOnPlay(label: "movie")
    }

    /// The same page for a SHOW — the case the hold menu still works on.
    func testDetailPlayHoldSeries() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-detailDemo", "-detailSeries"]
        holdOnPlay(label: "series")
    }

    /// A movie again, but focus is moved OFF Play and back ON before the hold.
    /// If the menu opens here but not in `testDetailPlayHold`, the defect is in
    /// the page's opening focus, not in the menu.
    func testDetailPlayHoldAfterMove() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-detailDemo"]
        holdOnPlay(label: "moved", nudgeFocus: true)
    }

    private func holdOnPlay(label: String, nudgeFocus: Bool = false) {
        app.launch()
        let r = XCUIRemote.shared
        sleep(10)
        if nudgeFocus {
            r.press(.right); sleep(2)     // off Play, onto the + icon
            r.press(.left); sleep(2)      // back onto Play the normal way
            log("\(label)_00_after_nudge")
        }
        log("\(label)_01_detail_opened")
        // Opening focus: 1 when the Play/Resume pill holds it.
        let focused = focusedDesc()
        attach("OPENS_ON_PLAY", focused.contains("Play") || focused.contains("Resume") ? 1 : 0)
        let t = XCTAttachment(string: focused)
        t.name = "\(label)_focused_desc"; t.lifetime = .keepAlways; add(t)

        attach("MENU_BEFORE_HOLD", menuCount())
        r.press(.select, forDuration: 2.0); sleep(3)
        log("\(label)_02_after_hold")
        attach("MENU_AFTER_HOLD", menuCount())
    }

    /// Leaving the rail with Right lands on the FIRST card of the row the
    /// viewer left (ContentFocusRouter), not on whichever card the engine
    /// finds nearest the rail's centre. Reported as RAIL_EXIT_FIRST (1 = the
    /// same element that held focus at the row start before the rail opened).
    func testRailExitLandsOnRowStart() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-homeDemo"]
        app.launch()
        let r = XCUIRemote.shared
        sleep(12); log("re_00_home")
        r.press(.down); sleep(2); log("re_01_first_row")
        r.press(.down); sleep(2); log("re_02_second_row")
        r.press(.right); sleep(1); r.press(.right); sleep(2); log("re_03_third_card")
        r.press(.menu); sleep(2); log("re_04_back_to_start")   // Back → first card of the row
        let atStart = focusedDesc()
        r.press(.menu); sleep(2); log("re_05_rail")            // Back on the first card → rail
        let onRail = focusedDesc()
        r.press(.right); sleep(2); log("re_06_after_right")    // Right → back into content
        let landed = focusedDesc()
        attach("RAIL_OPENED", onRail != atStart ? 1 : 0)
        attach("RAIL_EXIT_FIRST", landed == atStart ? 1 : 0)
        let t = XCTAttachment(string: "start=\(atStart)\nrail=\(onRail)\nlanded=\(landed)")
        t.name = "re_focus_summary"; t.lifetime = .keepAlways; add(t)
    }

    /// Search: LEFT from the search bar must reach the rail. Reported as "Left
    /// does nothing there, Back still opens the rail", worst when Trending
    /// fails. These follow the report's steps and log focus after each press.
    ///
    /// Trending loaded, Search entered from Home through the rail.
    func testSearchLeftToRailFromHome() {
        launchSearchTour(["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("sh_00_home")
        r.press(.menu); sleep(2); log("sh_01_rail")         // Back at Home root → rail
        r.press(.down); sleep(1); log("sh_02_rail_search")  // Home → Search
        r.press(.select); sleep(5); log("sh_03_search")     // open Search
        searchBarLeftSteps(tag: "sh")
    }

    /// Trending loaded, the app launched straight into Search.
    func testSearchLeftToRailCold() {
        launchSearchTour(["-searchDemo", "-focusLog"])
        sleep(12); log("sc_00_search")
        searchBarLeftSteps(tag: "sc")
    }

    /// Trending EMPTY: add-ons emptied for this launch only, so nothing exists
    /// below the bar. Launched straight into Search.
    func testSearchLeftToRailColdNoTrending() {
        launchSearchTour(Self.noAddonsArgs + ["-searchDemo", "-focusLog"])
        sleep(12); log("sn_00_search")
        searchBarLeftSteps(tag: "sn")
    }

    /// Trending EMPTY, Search re-entered through the rail (Back opens the
    /// rail, Select re-picks Search), so the tab-switch path runs first.
    func testSearchLeftToRailViaRailNoTrending() {
        launchSearchTour(Self.noAddonsArgs + ["-searchDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("sr_00_search")
        r.press(.menu); sleep(2); log("sr_01_rail")        // Back at Search root → rail
        r.press(.select); sleep(4); log("sr_02_search")    // re-pick Search
        searchBarLeftSteps(tag: "sr")
    }

    /// "Hide the sidebar" ON: no rail on screen until a Left with nowhere to
    /// go (or Back) calls it. Launched straight into Search.
    func testSearchLeftToRailAutoHideCold() {
        launchSearchTour(Self.autoHideArgs + ["-searchDemo", "-focusLog"])
        sleep(12); log("ac_00_search")
        searchBarLeftSteps(tag: "ac")
    }

    /// "Hide the sidebar" ON, Search entered from Home through the rail.
    func testSearchLeftToRailAutoHideFromHome() {
        launchSearchTour(Self.autoHideArgs + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("ah_00_home")
        r.press(.menu); sleep(2); log("ah_01_rail")
        r.press(.down); sleep(1); log("ah_02_rail_search")
        r.press(.select); sleep(5); log("ah_03_search")
        searchBarLeftSteps(tag: "ah")
    }

    /// After opening the keyboard on the field and closing it with Back.
    func testSearchLeftToRailAfterKeyboard() {
        launchSearchTour(["-searchDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("sk_00_search")
        r.press(.select); sleep(3); log("sk_01_keyboard")
        r.press(.menu); sleep(3); log("sk_02_keyboard_closed")
        searchBarLeftSteps(tag: "sk")
    }

    /// After opening Discover from the bar and coming back.
    func testSearchLeftToRailAfterDiscover() {
        launchSearchTour(["-searchDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("sd_00_search")
        r.press(.right); sleep(1); log("sd_01_discover_button")
        r.press(.select); sleep(5); log("sd_02_discover")
        r.press(.menu); sleep(4); log("sd_03_back")
        searchBarLeftSteps(tag: "sd")
    }

    /// After opening a Trending title and coming back.
    func testSearchLeftToRailAfterDetail() {
        launchSearchTour(["-searchDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("st_00_search")
        r.press(.down); sleep(2); log("st_01_poster")
        r.press(.select); sleep(4); log("st_02_detail")
        r.press(.menu); sleep(4); log("st_03_back")
        searchBarLeftSteps(tag: "st")
    }

    /// Left pressed straight after picking Search in the rail, no pause.
    func testSearchLeftToRailRightAfterTabSwitch() {
        launchSearchTour(["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("sq_00_home")
        r.press(.menu); sleep(2)
        r.press(.down); sleep(1)
        r.press(.select)
        r.press(.left); sleep(2); log("sq_01_left_now")
        r.press(.left); sleep(2); log("sq_02_left_again")
    }

    /// The same window with Trending EMPTY: Back opens the rail, Select
    /// re-picks Search, Left at once.
    func testSearchLeftToRailRightAfterTabSwitchNoTrending() {
        launchSearchTour(Self.noAddonsArgs + ["-searchDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("sw_00_search")
        r.press(.menu); sleep(2); log("sw_01_rail")
        r.press(.select)
        r.press(.left); sleep(2); log("sw_02_left_now")
        r.press(.left); sleep(2); log("sw_03_left_again")
    }

    /// Left pressed straight after leaving the rail with Right, no pause: the
    /// rail's other short `.disabled` window.
    func testSearchLeftToRailRightAfterRailExit() {
        launchSearchTour(["-searchDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(12); log("se_00_search")
        r.press(.menu); sleep(2); log("se_01_rail")        // Back at Search root → rail
        r.press(.right)                                    // leave the rail
        r.press(.left); sleep(2); log("se_02_left_now")
        r.press(.left); sleep(2); log("se_03_left_again")
    }

    /// Home, Hybrid hero (the default): down from the rolling banner into the
    /// rows, along a row with a rest long enough for the hero to commit, back
    /// up to the hero, and down again. Focus + screenshot after every press.
    func testHomeHybridIntoRowsAndBack() {
        launchSearchTour(["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hy_00_home")
        r.press(.down); sleep(3); log("hy_01_down_cw")
        r.press(.down); sleep(3); log("hy_02_down_featured")
        r.press(.down); sleep(3); log("hy_03_down_row")
        r.press(.right); sleep(2); log("hy_04_right1")
        r.press(.right); sleep(2); log("hy_05_right2")
        r.press(.right); sleep(5); log("hy_06_right3_rest")
        r.press(.up); sleep(3); log("hy_07_up_featured")
        r.press(.up); sleep(3); log("hy_08_up_cw")
        r.press(.up); sleep(3); log("hy_09_up_hero")
        r.press(.down); sleep(3); log("hy_10_down_again")
        r.press(.right); sleep(2); log("hy_11_right")
    }

    /// The same tour with the layout the account actually uses: Hybrid hero,
    /// Featured section OFF, so Down from Continue Watching goes straight into
    /// the catalog rows.
    func testHomeHybridNoFeaturedIntoRowsAndBack() {
        launchSearchTour(Self.layoutArgs(#""heroLayout":"hybrid","showFeaturedBar":false"#)
                         + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hn_00_home")
        r.press(.down); sleep(3); log("hn_01_down_cw")
        r.press(.down); sleep(3); log("hn_02_down_row1")
        r.press(.down); sleep(3); log("hn_03_down_row2")
        r.press(.right); sleep(2); log("hn_04_right1")
        r.press(.right); sleep(2); log("hn_05_right2")
        r.press(.right); sleep(5); log("hn_06_right3_rest")
        r.press(.up); sleep(3); log("hn_07_up_row1")
        r.press(.up); sleep(3); log("hn_08_up_cw")
        r.press(.up); sleep(3); log("hn_09_up_hero")
        r.press(.down); sleep(3); log("hn_10_down_again")
        r.press(.right); sleep(2); log("hn_11_right")
    }

    /// Fast presses on the account's layout (Hybrid, Featured off) across the
    /// moments the slow tours showed are fragile: the pin/unpin swap, the
    /// invisible filler hops on UP, and quick steps along a row. Ends with
    /// single presses that must still move focus.
    func testHomeHybridFastPresses() {
        launchSearchTour(Self.layoutArgs(#""heroLayout":"hybrid","showFeaturedBar":false"#)
                         + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hf_00_home")
        r.press(.down); r.press(.down); sleep(2); log("hf_01_down_down")
        r.press(.up); r.press(.up); sleep(2); log("hf_02_up_up")
        r.press(.down); r.press(.down); r.press(.down); sleep(2); log("hf_03_down_x3")
        for _ in 0..<6 { r.press(.right) }
        sleep(2); log("hf_04_right_x6")
        r.press(.up); r.press(.up); r.press(.up); sleep(2); log("hf_05_up_x3")
        r.press(.down); r.press(.up); r.press(.down); r.press(.up); sleep(2); log("hf_06_zigzag")
        r.press(.down); sleep(2); log("hf_07_single_down")
        r.press(.down); sleep(2); log("hf_08_single_down")
        r.press(.right); sleep(2); log("hf_09_single_right")
        r.press(.left); sleep(2); log("hf_10_single_left")
        r.press(.up); sleep(2); log("hf_11_single_up")
    }

    /// Home refreshing UNDER a focused card, on the account's layout. Auto-
    /// refresh at its shortest cadence (1 min, this launch only) forces a full
    /// catalog reload while focus rests in the second row. A focus UPDATE in
    /// the log during the wait, with no press behind it, is the refresh moving
    /// focus; the presses after it check navigation still works.
    func testHomeHybridRefreshWhileFocused() {
        launchSearchTour(Self.layoutArgs(#""heroLayout":"hybrid","showFeaturedBar":false"#)
                         + ["-orivio.home.autorefresh.v1", "1", "-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hr_00_home")
        r.press(.down); sleep(2); r.press(.down); sleep(2); r.press(.down); sleep(2)
        r.press(.right); sleep(2); r.press(.right); sleep(2); log("hr_01_resting")
        sleep(80); log("hr_02_after_refresh")
        r.press(.right); sleep(2); log("hr_03_right")
        r.press(.down); sleep(2); log("hr_04_down")
        r.press(.up); sleep(2); log("hr_05_up")
        r.press(.up); sleep(2); log("hr_06_up")
    }

    /// Hybrid: browse into the rows, go back UP to the rolling hero, rest there
    /// through a spotlight rotation, then Back to the rail and Right out of it.
    /// The rail exit hands focus to ContentFocusRouter's last ROW (the hero's
    /// Play button never registers), so this lands a programmatic focus write
    /// in a row — and the Hybrid pin swap — while the viewer was on the hero.
    func testHomeHybridRailExitFromHero() {
        launchSearchTour(Self.layoutArgs(#""heroLayout":"hybrid","showFeaturedBar":false"#)
                         + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hx_00_home")
        r.press(.down); sleep(2); r.press(.down); sleep(2)
        r.press(.right); sleep(2); log("hx_01_row1_card2")
        r.press(.up); sleep(2); r.press(.up); sleep(3); log("hx_02_back_on_hero")
        sleep(20); log("hx_03_hero_after_rotation")
        r.press(.menu); sleep(2); log("hx_04_rail")
        r.press(.right); sleep(3); log("hx_05_right_out_of_rail")
        r.press(.right); sleep(2); log("hx_06_right")
        r.press(.down); sleep(2); log("hx_07_down")
        r.press(.up); sleep(2); log("hx_08_up")
        r.press(.up); sleep(3); log("hx_09_up")
    }

    /// Hybrid: leave the rail from a ROW (not the hero). Back walks to the row
    /// start, Back again opens the rail, Right must land on that row's first
    /// card — the path a hero router entry must not disturb.
    func testHomeHybridRailExitFromRow() {
        launchSearchTour(Self.layoutArgs(#""heroLayout":"hybrid","showFeaturedBar":false"#)
                         + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hw_00_home")
        r.press(.down); sleep(2); r.press(.down); sleep(2)
        r.press(.right); sleep(2); r.press(.right); sleep(2); log("hw_01_row1_card3")
        r.press(.menu); sleep(2); log("hw_02_back_to_row_start")
        r.press(.menu); sleep(2); log("hw_03_rail")
        r.press(.right); sleep(3); log("hw_04_right_out_of_rail")
        r.press(.right); sleep(2); log("hw_05_right")
        r.press(.up); sleep(2); log("hw_06_up")
        r.press(.up); sleep(3); log("hw_07_up")
    }

    /// "Hide the sidebar" ON, Home: summon the rail from the hero and from a
    /// row's first card (Left with nowhere to go), and with Back; leave it with
    /// Right and Back. Screenshots show where the rows and hero text sit with
    /// the rail hidden and while it is open; focus is logged after every press.
    func testHomeAutoHideRailInset() {
        launchSearchTour(Self.autoHideArgs + ["-homeDemo", "-focusLog"])
        homeAutoHideRailSteps(tag: "ah")
    }

    /// The same presses with Hero Layout = Pinned Focus: the billboard is a
    /// fixed header above the scroll, so its text moves separately from the rows.
    func testHomeAutoHideRailInsetPinned() {
        launchSearchTour(Self.layoutArgs(#""autoHideSidebar":true,"heroLayout":"pinnedFocus""#)
                         + ["-homeDemo", "-focusLog"])
        homeAutoHideRailSteps(tag: "ap")
    }

    /// The same presses with Hero Layout = Hybrid (pins on the way into the rows).
    func testHomeAutoHideRailInsetHybrid() {
        launchSearchTour(Self.layoutArgs(#""autoHideSidebar":true,"heroLayout":"hybrid""#)
                         + ["-homeDemo", "-focusLog"])
        homeAutoHideRailSteps(tag: "ay")
    }

    /// Grid View at the Large poster size, where the grid's column count
    /// depends on the width the rows get. The rail is summoned from the first
    /// poster of a grid line and dismissed again, then focus moves around.
    func testHomeAutoHideRailInsetGridLarge() {
        launchSearchTour(Self.layoutArgs(
            #""autoHideSidebar":true,"homeLayout":"grid","posterSize":"large","showFeaturedBar":false"#)
            + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("ag_00_home")
        r.press(.down); sleep(2); log("ag_01_down")
        r.press(.down); sleep(2); log("ag_02_down")
        r.press(.down); sleep(2); log("ag_03_down")
        r.press(.right); sleep(2); log("ag_04_right")
        r.press(.right); sleep(2); log("ag_05_right")
        r.press(.left); sleep(2); log("ag_06_left")
        r.press(.left); sleep(2); log("ag_07_left_line_start")
        r.press(.left); sleep(2); log("ag_08_left_summons_rail")
        r.press(.right); sleep(3); log("ag_09_right_out_of_rail")
        r.press(.up); sleep(2); log("ag_10_up")
        r.press(.down); sleep(2); log("ag_11_down")
        r.press(.menu); sleep(2); log("ag_12_back_to_rail")
        r.press(.menu); sleep(3); log("ag_13_back_out_of_rail")
        r.press(.right); sleep(2); log("ag_14_right")
    }

    /// Pinned Focus, rail hidden: summon it from the Featured bar, then press
    /// LEFT inside the open rail (which can drop focus back into the page and
    /// leave the rail parked), then leave with Right.
    func testHomeAutoHideLeftInsideRailPinned() {
        launchSearchTour(Self.layoutArgs(#""autoHideSidebar":true,"heroLayout":"pinnedFocus""#)
                         + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14)
        r.press(.down); sleep(2); r.press(.down); sleep(2); log("lp_00_on_featured_bar")
        r.press(.left); sleep(2); log("lp_01_left_summons_rail")
        r.press(.left); sleep(2); log("lp_02_left_inside_rail")
        r.press(.right); sleep(3); log("lp_03_right")
    }

    /// Rolling hero, rail hidden: summon it from the hero's button, press LEFT
    /// inside the open rail, then leave with Right.
    func testHomeAutoHideLeftInsideRailRolling() {
        launchSearchTour(Self.autoHideArgs + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("lr_00_on_hero")
        r.press(.left); sleep(2); log("lr_01_left_summons_rail")
        r.press(.left); sleep(2); log("lr_02_left_inside_rail")
        r.press(.right); sleep(3); log("lr_03_right")
    }

    /// Rolling hero, rail hidden: summon the rail from the first Continue
    /// Watching card, press LEFT inside the open rail, then Right, Back, Back,
    /// Up — the stretch of `testHomeAutoHideRailInset` that runs through the
    /// parked-rail state.
    func testHomeAutoHideLeftInsideRailFromRow() {
        launchSearchTour(Self.autoHideArgs + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14)
        r.press(.down); sleep(2); log("lw_00_first_row")
        r.press(.left); sleep(2); log("lw_01_left_summons_rail")
        r.press(.left); sleep(2); log("lw_02_left_inside_rail")
        r.press(.right); sleep(3); log("lw_03_right")
        r.press(.menu); sleep(2); log("lw_04_back")
        r.press(.menu); sleep(3); log("lw_05_back")
        r.press(.up); sleep(3); log("lw_06_up")
    }

    private func homeAutoHideRailSteps(tag: String) {
        let r = XCUIRemote.shared
        sleep(14); log("\(tag)_00_home_hidden")
        r.press(.left); sleep(2); log("\(tag)_01_left_from_hero")
        r.press(.right); sleep(3); log("\(tag)_02_right_out_of_rail")
        r.press(.down); sleep(2); log("\(tag)_03_first_row")
        r.press(.right); sleep(2); log("\(tag)_04_second_card")
        r.press(.left); sleep(2); log("\(tag)_05_first_card")
        r.press(.left); sleep(2); log("\(tag)_06_left_from_first_card")
        r.press(.right); sleep(3); log("\(tag)_07_right_out_of_rail")
        r.press(.menu); sleep(2); log("\(tag)_08_back_to_rail")
        r.press(.menu); sleep(3); log("\(tag)_09_back_out_of_rail")
        r.press(.up); sleep(3); log("\(tag)_10_up_to_hero")
    }

    /// Hybrid: open a title from the second row, come back, keep navigating.
    func testHomeHybridDetailPopRestore() {
        launchSearchTour(Self.layoutArgs(#""heroLayout":"hybrid","showFeaturedBar":false"#)
                         + ["-homeDemo", "-focusLog"])
        let r = XCUIRemote.shared
        sleep(14); log("hd_00_home")
        r.press(.down); sleep(2); r.press(.down); sleep(2); r.press(.down); sleep(2)
        r.press(.right); sleep(2); log("hd_01_row2_card2")
        r.press(.select); sleep(5); log("hd_02_detail")
        r.press(.menu); sleep(4); log("hd_03_back_home")
        r.press(.right); sleep(2); log("hd_04_right")
        r.press(.up); sleep(2); log("hd_05_up")
        r.press(.up); sleep(2); log("hd_06_up")
        r.press(.up); sleep(3); log("hd_07_up_hero")
        r.press(.down); sleep(3); log("hd_08_down")
    }

    /// A Layout blob for one launch: the four required fields plus `extra`
    /// (JSON members, comma-separated, no braces). Read, never written.
    private static func layoutArgs(_ extra: String) -> [String] {
        let json = #"{"orderKeys":[],"disabledKeys":[],"customTitles":{},"hideUnreleasedContent":false,"# + extra + "}"
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        return ["-orivio.homecatalog.v1", "<\(hex)>"]
    }

    /// "Hide the sidebar until it's needed" for this launch only: the Layout
    /// blob with its four required fields and the switch on. Read, never
    /// written — `load()` assigns under `suppressChange` and doesn't save.
    private static var autoHideArgs: [String] {
        let json = #"{"orderKeys":[],"disabledKeys":[],"customTitles":{},"hideUnreleasedContent":false,"autoHideSidebar":true}"#
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        return ["-orivio.homecatalog.v1", "<\(hex)>"]
    }

    /// Argument-domain overrides (read for this launch, never written): no
    /// installed add-ons, both defaults marked removed so `ensureDefaults`
    /// doesn't restore them, and a last-refresh stamp in the future so the
    /// launch manifest refresh — which would SAVE the empty list — never runs.
    private static let noAddonsArgs = [
        "-orivio.addons.v1.p1", "<5b5d>",
        "-orivio.addons.forgottenDefaults.v1.p1",
        "(\"https://v3-cinemeta.strem.io/manifest.json\", \"https://opensubtitles-v3.strem.io/manifest.json\")",
        "-orivio.addons.lastRefresh.v1", "9999999999"
    ]

    private func launchSearchTour(_ args: [String]) {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = args
        app.launch()
    }

    /// Up onto the bar, then Left twice: the first Left may only cross from
    /// the Discover button to the field. SEARCH_LEFT_LEFT_BAR = 1 when focus
    /// ended somewhere other than where it sat on the bar.
    private func searchBarLeftSteps(tag: String) {
        let r = XCUIRemote.shared
        r.press(.up); sleep(1); r.press(.up); sleep(2); log("\(tag)_04_bar")
        let onBar = focusedDesc()
        r.press(.left); sleep(2); log("\(tag)_05_left1")
        r.press(.left); sleep(2); log("\(tag)_06_left2")
        let after = focusedDesc()
        attach("\(tag.uppercased())_SEARCH_LEFT_LEFT_BAR", after != onBar ? 1 : 0)
        let t = XCTAttachment(string: "bar=\(onBar)\nafter=\(after)")
        t.name = "\(tag)_focus_summary"; t.lifetime = .keepAlways; add(t)
    }

    /// The transport bar at rest: the dark playhead line between the white
    /// watched run and the cached band, and the band's contrast.
    func testPlayerBarSnapshot() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-playerDemo"]
        app.launch()
        let r = XCUIRemote.shared
        sleep(20); log("pb_00_playing")
        r.press(.select); sleep(2); log("pb_01_controls")
        r.press(.down); sleep(2); log("pb_02_down")
        sleep(6); log("pb_03_later")
    }

    /// Press-driven scrubbing: click the bar to enter scrub, hop with edge
    /// presses (these must HOP, not commit), then Select to commit. Screenshots
    /// carry the readout so the target's motion is verifiable.
    func testScrubPressFlow() {
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "0"
        app.launchEnvironment["MTL_SHADER_VALIDATION"] = "0"
        app.launchArguments = ["-playerDemo"]
        app.launch()
        let r = XCUIRemote.shared
        sleep(18); log("sp_00_playing")
        r.press(.select); sleep(2); log("sp_01_paused_controls")   // click video: pause + controls
        r.press(.select); sleep(2); log("sp_02_scrub_open")        // click bar: enter scrub
        r.press(.right); sleep(2); log("sp_03_hop_right")          // must hop, not commit
        r.press(.right); sleep(2); log("sp_04_hop_right_2")
        r.press(.left); sleep(2); log("sp_05_hop_left")
        r.press(.select); sleep(3); log("sp_06_committed")         // commit + resume
        sleep(3); log("sp_07_after")
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
