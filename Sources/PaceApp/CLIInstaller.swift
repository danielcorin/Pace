import Foundation
import PaceCore

enum CLIInstaller {
    static var destinationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("pace")
    }

    static var bundledCLIURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("pace")
    }

    static func install() throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: bundledCLIURL.path) else {
            throw PaceError.unavailable("The bundled Pace CLI is missing. Rebuild or reinstall Pace.")
        }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path)
            || (try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            let existing = try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path)
            if existing == bundledCLIURL.path { return destinationURL }
            throw PaceError.unavailable(
                "A file already exists at \(destinationURL.path). Move it before installing Pace's CLI."
            )
        }

        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: bundledCLIURL)
        return destinationURL
    }
}
