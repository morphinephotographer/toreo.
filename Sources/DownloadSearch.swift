import Foundation

enum DownloadSearch {
    @concurrent
    static func files(matching query: String, in folder: String) async -> [URL] {
        guard !query.isEmpty else { return [] }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        var matches: [URL] = []
        while let url = entries.nextObject() as? URL {
            guard !Task.isCancelled else { return [] }
            guard url.pathExtension.lowercased() == "torrent",
                  url.lastPathComponent.localizedStandardContains(query),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            matches.append(url)
        }
        return matches.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
