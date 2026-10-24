import XCTest
@testable import DeskFloater

final class HomeLocationTests: XCTestCase {
    private let bundle = "/home/me/starship/desk-floater/.build/Starship Floater.app"
    private let roots: Set<String> = ["/home/me/starship", "/home/me/other"]

    private func resolve(
        _ environment: [String: String],
        bundle: String? = nil,
        cwd: String = "/",
        settings: [String: String] = [:]
    ) -> (root: String, home: String)? {
        HomeLocation.resolve(
            environment: environment,
            bundlePath: bundle ?? self.bundle,
            currentDirectory: cwd,
            settings: settings,
            isCodeRoot: { self.roots.contains($0) }
        )
    }

    func testLauncherEnvironmentWins() {
        let location = resolve(["FM_DESK_FLOATER_ROOT": "/home/me/other", "FM_HOME": "/home/me/home"])
        XCTAssertEqual(location?.root, "/home/me/other")
        XCTAssertEqual(location?.home, "/home/me/home")
    }

    func testReopenWithoutEnvironmentFindsRootFromBundle() {
        let location = resolve([:])
        XCTAssertEqual(location?.root, "/home/me/starship")
        XCTAssertEqual(location?.home, "/home/me/starship", "the home defaults to the code root")
    }

    func testEmptyEnvironmentValuesCountAsUnset() {
        let location = resolve(["FM_DESK_FLOATER_ROOT": "", "FM_HOME": ""])
        XCTAssertEqual(location?.root, "/home/me/starship")
        XCTAssertEqual(location?.home, "/home/me/starship")
    }

    func testFinderUsesSavedRootAndSeparateHome() {
        let location = resolve([:], bundle: "/Applications/Starship Floater.app",
                               settings: ["root": "/home/me/starship", "home": "/home/me/private"])
        XCTAssertEqual(location?.root, "/home/me/starship")
        XCTAssertEqual(location?.home, "/home/me/private")
    }

    func testSavedHomeDefaultsToRootAndEnvironmentOverridesIt() {
        let settings = ["root": "/home/me/starship", "home": "/home/me/private"]
        XCTAssertEqual(resolve([:], bundle: "/Applications/Starship Floater.app",
                               settings: ["root": "/home/me/starship"])?.home, "/home/me/starship")
        XCTAssertEqual(resolve(["FM_HOME": "/home/me/override"], bundle: "/Applications/Starship Floater.app",
                               settings: settings)?.home, "/home/me/override")
        XCTAssertEqual(resolve(["FM_DESK_FLOATER_ROOT": "/home/me/other"], settings: settings)?.home,
                       "/home/me/other")
        XCTAssertEqual(resolve([:], settings: settings)?.home, "/home/me/starship",
                       "source bundles ignore saved settings")
    }

    func testInvalidSettingsDoNotGuessAHome() {
        for settings in [["root": "/missing"], ["root": "relative"],
                         ["root": "/home/me/starship", "home": "relative"]] {
            XCTAssertNil(resolve([:], bundle: "/Applications/Starship Floater.app", settings: settings))
        }
    }

    func testHomeEnvironmentCanSelectACodeRoot() {
        XCTAssertEqual(resolve(["FM_HOME": "/home/me/other"],
                               bundle: "/Applications/Starship Floater.app")?.root, "/home/me/other")
    }

    func testNeverFallsBackToSlash() {
        XCTAssertNil(resolve([:], bundle: "/Applications/Starship Floater.app"))
        XCTAssertNil(resolve([:], bundle: "/tmp/elsewhere/desk-floater/.build/Starship Floater.app"),
                     "a bundle outside a Firstmate code root is not trusted")
    }

    func testWorkingDirectoryCountsOnlyWhenItIsACodeRoot() {
        let location = resolve([:], bundle: "/tmp/x/DeskFloater", cwd: "/home/me/other")
        XCTAssertEqual(location?.root, "/home/me/other")
        XCTAssertEqual(location?.home, "/home/me/other")
        XCTAssertNil(resolve([:], bundle: "/tmp/x/DeskFloater", cwd: "/home/me/nowhere"),
                     "a working directory that is not a code root is not trusted")
    }
}
