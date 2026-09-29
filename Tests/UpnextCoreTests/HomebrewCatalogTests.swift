import XCTest
@testable import UpnextCore

final class HomebrewCatalogTests: XCTestCase {
    let json = """
    [
      {
        "token": "example",
        "name": ["Example"],
        "version": "2.0.1,4567",
        "url": "https://example.com/intel/Example-2.0.1.dmg",
        "sha256": "abc123",
        "homepage": "https://example.com",
        "artifacts": [{"app": ["Example.app"]}, {"zap": [{"trash": "~/Library/Example"}]}],
        "variations": {
          "arm64_sequoia": {"url": "https://example.com/arm/Example-2.0.1.dmg", "sha256": "def456"}
        }
      },
      {
        "token": "renamed",
        "name": ["Renamed"],
        "version": "1.5",
        "url": "https://example.com/renamed.zip",
        "sha256": "no_check",
        "artifacts": [{"app": ["Weird Name.app", {"target": "Renamed.app"}]}]
      },
      {
        "token": "always-latest",
        "version": "latest",
        "url": "https://example.com/latest.dmg",
        "sha256": "no_check",
        "artifacts": [{"app": ["Latest.app"]}]
      },
      {
        "token": "example@beta",
        "version": "3.0b1",
        "url": "https://example.com/beta.dmg",
        "sha256": "no_check",
        "artifacts": [{"app": ["Example.app"]}]
      }
    ]
    """

    func testParsesAndIndexesByAppName() throws {
        let catalog = try HomebrewCatalog.parse(Data(json.utf8), platformKey: "arm64_sequoia")

        let example = try XCTUnwrap(catalog.cask(forAppNamed: "example.APP"))
        XCTAssertEqual(example.token, "example", "stable cask wins over @beta")
        XCTAssertEqual(example.displayVersion, "2.0.1")
        XCTAssertEqual(example.downloadURL.absoluteString, "https://example.com/arm/Example-2.0.1.dmg")
        XCTAssertEqual(example.sha256, "def456")

        let renamed = try XCTUnwrap(catalog.cask(forAppNamed: "Renamed.app"))
        XCTAssertNil(renamed.sha256)
        XCTAssertNil(catalog.cask(forAppNamed: "Weird Name.app"))

        XCTAssertNil(catalog.cask(forAppNamed: "Latest.app"), "'latest' casks can't be compared")
    }

    func testWithoutMatchingVariationUsesDefaults() throws {
        let catalog = try HomebrewCatalog.parse(Data(json.utf8), platformKey: "arm64_sonoma")
        let example = try XCTUnwrap(catalog.cask(forAppNamed: "Example.app"))
        XCTAssertEqual(example.downloadURL.absoluteString, "https://example.com/intel/Example-2.0.1.dmg")
    }

    func testUpdateMatching() throws {
        let catalog = try HomebrewCatalog.parse(Data(json.utf8), platformKey: nil)
        let cask = try XCTUnwrap(catalog.cask(forAppNamed: "Example.app"))

        let old = makeApp(short: "2.0", build: "4500")
        let update = try XCTUnwrap(UpdateMatcher.update(for: old, cask: cask))
        XCTAssertEqual(update.newVersion, "2.0.1")
        XCTAssertEqual(update.source, .homebrew)
        XCTAssertEqual(update.expectedSHA256, "abc123")

        XCTAssertNil(UpdateMatcher.update(for: makeApp(short: "2.0.1", build: "4567"), cask: cask))
        XCTAssertNil(UpdateMatcher.update(for: makeApp(short: "2.1", build: "5000"), cask: cask))
        // Cask carries the installed build after the comma → already current.
        XCTAssertNil(UpdateMatcher.update(for: makeApp(short: "2.0", build: "4567"), cask: cask))
    }

    func testPlatformKey() {
        XCTAssertEqual(HomebrewCatalog.platformKey(majorOSVersion: 15, arm64: true), "arm64_sequoia")
        XCTAssertEqual(HomebrewCatalog.platformKey(majorOSVersion: 14, arm64: false), "sonoma")
        XCTAssertNil(HomebrewCatalog.platformKey(majorOSVersion: 99, arm64: true))
    }
}

final class WidgetSnapshotTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var snapshot = WidgetSnapshot.placeholder
        snapshot.lastChecked = Date(timeIntervalSince1970: 1_800_000_000)
        let decoded = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testIconFileNamesAreSafe() {
        XCTAssertEqual(WidgetStore.iconFile(for: "com.example/evil").lastPathComponent, "com.example_evil.png")
    }
}
