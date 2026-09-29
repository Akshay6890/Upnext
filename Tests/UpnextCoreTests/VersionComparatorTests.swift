import XCTest
@testable import UpnextCore

final class VersionComparatorTests: XCTestCase {
    private func assertNewer(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(VersionComparator.compare(a, b), .orderedDescending, "\(a) > \(b)", file: file, line: line)
        XCTAssertEqual(VersionComparator.compare(b, a), .orderedAscending, "\(b) < \(a)", file: file, line: line)
    }

    func testNumericComponents() {
        assertNewer("1.10", "1.9")
        assertNewer("2.0", "1.99.99")
        assertNewer("1.0.1", "1.0")
        assertNewer("10", "9")
        assertNewer("2024.10.1", "2024.9.30")
    }

    func testPreReleases() {
        assertNewer("2.0", "2.0b3")
        assertNewer("2.0b4", "2.0b3")
        assertNewer("2.0rc1", "2.0b9")
        assertNewer("1.0.1", "1.0b1")
    }

    func testEquality() {
        XCTAssertEqual(VersionComparator.compare("1.0", "1.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("1.0.0", "1.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("1.0B1", "1.0b1"), .orderedSame)
    }

    func testBuildNumbers() {
        assertNewer("1234", "1233")
        XCTAssertTrue(VersionComparator.isNewer("5210", than: "5209"))
        XCTAssertFalse(VersionComparator.isNewer("5209", than: "5209"))
    }
}
