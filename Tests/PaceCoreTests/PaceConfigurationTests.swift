import XCTest
@testable import PaceCore

final class PaceConfigurationTests: XCTestCase {
    private var root: URL!
    private var store: PaceConfigurationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceConfigTests-\(UUID().uuidString)", isDirectory: true)
        store = PaceConfigurationStore(fileURL: root.appendingPathComponent("pace/config.toml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingFileUsesDefaults() throws {
        XCTAssertEqual(try store.load(), .defaults)
        XCTAssertNil(store.modificationDate())
    }

    func testDefaultPathHonorsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(
            PaceConfigurationStore.defaultFileURL(environment: [:], homeDirectory: home).path,
            "/Users/someone/.config/pace/config.toml"
        )
        XCTAssertEqual(
            PaceConfigurationStore.defaultFileURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], homeDirectory: home).path,
            "/tmp/xdg/pace/config.toml"
        )
        // Relative XDG paths are invalid per the spec and are ignored.
        XCTAssertEqual(
            PaceConfigurationStore.defaultFileURL(environment: ["XDG_CONFIG_HOME": "xdg"], homeDirectory: home).path,
            "/Users/someone/.config/pace/config.toml"
        )
    }

    func testUpdateWritesNormalizedTOMLAndRoundTrips() throws {
        try store.update { $0.excludedApps = ["com.apple.Terminal", " com.googlecode.iterm2 ", "COM.APPLE.TERMINAL"] }

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("excluded-apps"), text)
        XCTAssertEqual(try store.load().excludedApps, ["com.apple.Terminal", "com.googlecode.iterm2"])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testClearingEveryKeyRemovesTheFile() throws {
        try store.update { $0.excludedApps = ["com.example.App"] }
        try store.update { $0.excludedApps = [] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testHandWrittenFileWithCommentsLoads() throws {
        try write("""
        # Apps whose copies Pace should ignore
        excluded-apps = [
          "com.apple.Terminal", # terminals
          "com.mitchellh.ghostty",
        ]
        """)
        XCTAssertEqual(try store.load().excludedApps, ["com.apple.Terminal", "com.mitchellh.ghostty"])
    }

    func testUnknownKeysAndWrongTypesAreRejected() throws {
        try write("excluded-app = [\"com.apple.Terminal\"]\n")
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("excluded-app"), error.localizedDescription)
        }
        try write("excluded-apps = \"com.apple.Terminal\"\n")
        XCTAssertThrowsError(try store.load())
        try write("excluded-apps = [\"has space\"]\n")
        XCTAssertThrowsError(try store.load())
        try write("excluded-apps = [\n")
        XCTAssertThrowsError(try store.load())
    }

    func testExclusionMatchesBundleIdentifiersCaseInsensitively() {
        let configuration = PaceConfiguration(excludedApps: ["com.apple.Terminal"])
        XCTAssertTrue(configuration.excludesCapture(fromBundleIdentifier: "com.apple.terminal"))
        XCTAssertFalse(configuration.excludesCapture(fromBundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(configuration.excludesCapture(fromBundleIdentifier: nil))
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: store.fileURL)
    }
}
