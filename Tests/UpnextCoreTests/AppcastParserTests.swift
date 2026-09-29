import XCTest
@testable import UpnextCore

final class AppcastParserTests: XCTestCase {
    let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Example</title>
        <item>
          <title>Version 2.1 beta</title>
          <sparkle:version>210</sparkle:version>
          <sparkle:shortVersionString>2.1b1</sparkle:shortVersionString>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/Example-2.1b1.zip" length="100" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 2.0</title>
          <sparkle:releaseNotesLink>https://example.com/notes/2.0.html</sparkle:releaseNotesLink>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-2.0.dmg"
                     sparkle:version="200" sparkle:shortVersionString="2.0"
                     sparkle:edSignature="c2lnbmF0dXJl" length="12345678"
                     type="application/octet-stream"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/delta-190-200.delta" sparkle:version="200"
                       sparkle:deltaFrom="190" length="10"/>
          </sparkle:deltas>
        </item>
        <item>
          <title>Version 1.9</title>
          <description><![CDATA[<ul><li>Fixes</li></ul>]]></description>
          <enclosure url="https://example.com/Example-1.9.dmg" sparkle:version="190"
                     sparkle:shortVersionString="1.9" length="1"/>
        </item>
        <item>
          <title>Version 3.0 (needs a newer macOS)</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-3.0.dmg" sparkle:version="300" length="1"/>
        </item>
      </channel>
    </rss>
    """

    func testParsesItems() throws {
        let items = AppcastParser.parse(Data(feed.utf8))
        XCTAssertEqual(items.count, 4)

        let v2 = try XCTUnwrap(items.first { $0.version == "200" })
        XCTAssertEqual(v2.shortVersion, "2.0")
        XCTAssertEqual(v2.downloadURL?.absoluteString, "https://example.com/Example-2.0.dmg",
                       "delta enclosures must not replace the full download")
        XCTAssertEqual(v2.length, 12_345_678)
        XCTAssertEqual(v2.edSignature, "c2lnbmF0dXJl")
        XCTAssertEqual(v2.releaseNotesURL?.absoluteString, "https://example.com/notes/2.0.html")
        XCTAssertEqual(v2.minimumSystemVersion, "13.0")

        let v19 = try XCTUnwrap(items.first { $0.version == "190" })
        XCTAssertEqual(v19.descriptionHTML, "<ul><li>Fixes</li></ul>")
    }

    func testBestItemSkipsBetaAndIncompatible() throws {
        let items = AppcastParser.parse(Data(feed.utf8))
        let best = try XCTUnwrap(AppcastParser.bestItem(in: items, systemVersion: "14.5.0"))
        XCTAssertEqual(best.version, "200")

        let old = try XCTUnwrap(AppcastParser.bestItem(in: items, systemVersion: "12.7.0"))
        XCTAssertEqual(old.version, "190")
    }

    func testMatchesAgainstBuildVersion() throws {
        let items = AppcastParser.parse(Data(feed.utf8))
        let best = try XCTUnwrap(AppcastParser.bestItem(in: items, systemVersion: "14.0"))

        let outdated = makeApp(short: "1.9", build: "190")
        let update = try XCTUnwrap(UpdateMatcher.update(for: outdated, appcastItem: best))
        XCTAssertEqual(update.newVersion, "2.0")
        XCTAssertEqual(update.source, .sparkle)

        let current = makeApp(short: "2.0", build: "200")
        XCTAssertNil(UpdateMatcher.update(for: current, appcastItem: best))
    }

    func testEmptyOrGarbageFeed() {
        XCTAssertTrue(AppcastParser.parse(Data("not xml".utf8)).isEmpty)
        XCTAssertNil(AppcastParser.bestItem(in: [], systemVersion: "14.0"))
    }
}

func makeApp(short: String, build: String, name: String = "Example.app") -> InstalledApp {
    InstalledApp(
        url: URL(fileURLWithPath: "/Applications/\(name)"),
        name: "Example",
        bundleIdentifier: "com.example.app",
        shortVersion: short,
        buildVersion: build,
        sparkleFeedURL: nil,
        kind: .web
    )
}
