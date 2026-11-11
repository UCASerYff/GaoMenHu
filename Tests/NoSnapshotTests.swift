import Foundation

@main struct NoSnapshotTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gaomenhu-no-snapshots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library.initial(browsers: ["edge"])
        let destination = root.appendingPathComponent("current.zip")
        let summary = try FullBackup.export(library: library, version: "1.18", destination: destination)
        let payload = try FullBackup.read(destination, currentVersion: "1.18")
        precondition(payload.library == library)
        precondition(summary.fileCount == 2)
        precondition(summary.snapshotCount == 0)
        precondition(FullBackup.maximumSnapshots == 0)
        precondition(Set(payload.manifest.files.keys) == ["library.json"])
        let store = LibraryStore(directory: root.appendingPathComponent("Data"), persistent: false)
        try store.save(library)
        precondition(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Snapshots").path))
        print("No-snapshot export and storage tests passed")
    }
}
