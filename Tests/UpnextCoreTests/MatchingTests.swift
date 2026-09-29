import XCTest
@testable import UpnextCore

final class NumericCoreTests: XCTestCase {
    func testNumericCore() {
        XCTAssertEqual(VersionComparator.numericCore("3.6.6-8b85519e"), "3.6.6")
        XCTAssertEqual(VersionComparator.numericCore("v2.1.0"), "2.1.0")
        XCTAssertEqual(VersionComparator.numericCore("1.2 (345)"), "1.2")
        XCTAssertEqual(VersionComparator.numericCore("2024.10."), "2024.10")
        XCTAssertNil(VersionComparator.numericCore("latest"))
    }

    /// The GitHub Desktop case: cask "3.6.6-8b85519e", app "3.6.6".
    func testHashSuffixIsNotAnUpdate() {
        let cask = HomebrewCask(token: "github", name: "GitHub Desktop", version: "3.6.6-8b85519e",
                                downloadURL: URL(string: "https://example.com/gh.zip")!, sha256: nil,
                                homepage: nil, appNames: ["GitHub Desktop.app"], installsPkg: false)
        XCTAssertEqual(cask.displayVersion, "3.6.6")
        XCTAssertNil(UpdateMatcher.update(for: makeApp(short: "3.6.6", build: "3.6.6"), cask: cask))

        let newer = makeApp(short: "3.6.5", build: "3.6.5")
        XCTAssertEqual(UpdateMatcher.update(for: newer, cask: cask)?.newVersion, "3.6.6")
    }

    func testSuffixOnlyDifferencesAreIgnored() {
        let cask = HomebrewCask(token: "x", name: "X", version: "5.0_2",
                                downloadURL: URL(string: "https://example.com/x.zip")!, sha256: nil,
                                homepage: nil, appNames: ["X.app"], installsPkg: false)
        XCTAssertNil(UpdateMatcher.update(for: makeApp(short: "5.0", build: "50"), cask: cask))
    }
}

final class HomebrewBundleIDTests: XCTestCase {
    func testMatchesByBundleIdentifier() throws {
        let json = """
        [{
          "token": "foo",
          "version": "2.0",
          "url": "https://example.com/foo.dmg",
          "sha256": "no_check",
          "artifacts": [
            {"app": ["Foo Installer Name.app"]},
            {"uninstall": [{"quit": "com.example.foo"}]},
            {"zap": [{"trash": ["~/Library/Preferences/com.example.foo.helper.plist", "~/Library/Caches/foo"]}]}
          ]
        }]
        """
        let catalog = try HomebrewCatalog.parse(Data(json.utf8), platformKey: nil)
        XCTAssertNil(catalog.cask(forAppNamed: "Foo.app"))
        XCTAssertEqual(catalog.cask(forAppNamed: "Foo.app", bundleIdentifier: "com.example.foo")?.token, "foo")
        XCTAssertEqual(catalog.cask(forAppNamed: "Other.app", bundleIdentifier: "com.example.foo.helper")?.token, "foo")
        XCTAssertNil(catalog.cask(forAppNamed: "Other.app", bundleIdentifier: "com.example.bar"))
    }
}

final class ElectronTests: XCTestCase {
    func testParsesGenericAppUpdateYAML() throws {
        let feed = try XCTUnwrap(ElectronFeed(appUpdateYAML: """
        provider: generic
        url: 'https://downloads.example.com/desktop/'
        updaterCacheDirName: example-updater
        """))
        XCTAssertEqual(feed.manifestURL.absoluteString, "https://downloads.example.com/desktop/latest-mac.yml")
        XCTAssertEqual(feed.downloadURL(for: "Example 1.2.zip")?.absoluteString,
                       "https://downloads.example.com/desktop/Example%201.2.zip")
    }

    func testParsesGitHubAppUpdateYAML() throws {
        let feed = try XCTUnwrap(ElectronFeed(appUpdateYAML: """
        owner: acme
        repo: widget-app
        provider: github
        channel: beta
        """))
        XCTAssertEqual(feed.manifestURL.absoluteString,
                       "https://github.com/acme/widget-app/releases/latest/download/beta-mac.yml")
        XCTAssertEqual(feed.downloadURL(for: "App-arm64.zip")?.absoluteString,
                       "https://github.com/acme/widget-app/releases/latest/download/App-arm64.zip")
    }

    func testURLPlaceholdersAndChannelFallback() throws {
        let yaml = "provider: generic\nurl: https://updates.example.com/${os}/${arch}\nchannel: stable\n"
        let feed = try XCTUnwrap(ElectronFeed(appUpdateYAML: yaml))
        XCTAssertEqual(feed.manifestURLs.map(\.absoluteString), [
            "https://updates.example.com/mac/arm64/stable-mac.yml",
            "https://updates.example.com/mac/arm64/latest-mac.yml",
        ])
    }

    func testUnknownProviderIsIgnored() {
        XCTAssertNil(ElectronFeed(appUpdateYAML: "provider: keygen\naccount: x"))
        XCTAssertNil(ElectronFeed(appUpdateYAML: ""))
    }

    let manifest = """
    version: 1.4.0
    files:
      - url: Example-1.4.0-mac.zip
        sha512: aW50ZWw=
        size: 100
      - url: Example-1.4.0-arm64-mac.zip
        sha512: YXJt
        size: 90
      - url: Example-1.4.0-arm64.dmg
        sha512: ZG1n
        size: 95
      - url: Example-1.4.0-arm64-mac.zip.blockmap
        sha512: Ymxr
    path: Example-1.4.0-mac.zip
    sha512: aW50ZWw=
    releaseDate: '2026-09-01T10:00:00.000Z'
    releaseNotes: |
      - Fixed: a thing
    """

    func testPicksAppleSiliconZip() throws {
        let release = try XCTUnwrap(ElectronRelease(manifestYAML: manifest))
        XCTAssertEqual(release.version, "1.4.0")
        XCTAssertEqual(release.files.count, 4)
        let best = try XCTUnwrap(release.bestFileForAppleSilicon)
        XCTAssertEqual(best.url, "Example-1.4.0-arm64-mac.zip")
        XCTAssertEqual(best.sha512, "YXJt")
        XCTAssertEqual(best.size, 90)
    }

    func testUpdateMatching() throws {
        let feed = ElectronFeed(provider: .generic(URL(string: "https://dl.example.com/app")!))
        let release = try XCTUnwrap(ElectronRelease(manifestYAML: manifest))

        let update = try XCTUnwrap(UpdateMatcher.update(for: makeApp(short: "1.3.2", build: "1.3.2"),
                                                        feed: feed, release: release))
        XCTAssertEqual(update.newVersion, "1.4.0")
        XCTAssertEqual(update.source, .electron)
        XCTAssertEqual(update.expectedSHA512Base64, "YXJt")
        XCTAssertEqual(update.downloadURL.absoluteString, "https://dl.example.com/app/Example-1.4.0-arm64-mac.zip")

        XCTAssertNil(UpdateMatcher.update(for: makeApp(short: "1.4.0", build: "1.4.0"), feed: feed, release: release))
    }

    func testOldStyleManifestWithOnlyPath() throws {
        let release = try XCTUnwrap(ElectronRelease(manifestYAML: "version: 2.0.0\npath: App-2.0.0.zip\nsha512: abc"))
        XCTAssertEqual(release.bestFileForAppleSilicon?.url, "App-2.0.0.zip")
    }
}
