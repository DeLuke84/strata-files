import Foundation
import StrataIndex

/// One listing owns the stream for all its physical folders. Dropping it silences even a delivery already queued.
nonisolated final class ListingWatch: Sendable {
    let ready: Task<Void, Never>
    private let changes: LatestUpdate<Void>
    private let opened: Task<[DirectoryWatcher], Never>
    private let stream = FSEventsStream()

    init(_ folders: [URL], changed: @escaping @MainActor @Sendable () -> Void) {
        let changes = LatestUpdate<Void> { changed() }
        self.changes = changes
        let opened = Task.detached { [stream] () -> [DirectoryWatcher] in
            guard !folders.isEmpty else { return [] }
            let started = await OwnThread.run {
                let roots = Set(folders.map { PathSpelling.system($0.resolvingSymlinksInPath().path) })
                stream.handler = { events in
                    if events.contains(where: { Self.affectsListing($0, roots: roots) }) { changes.send(()) }
                }
                return stream.start(paths: Array(roots), since: nil, latency: 0.12)
            }
            // Keep directory-entry notifications where a file-event stream isn't available.
            return started ? [] : await DirectoryWatcher.watching(folders) { changes.send(()) }
        }
        self.opened = opened
        ready = Task { _ = await opened.value }
    }

    static func affectsListing(_ event: FSEventsStream.Event, roots: Set<String>) -> Bool {
        if event.invalidatesIndex || event.mustScanSubdirectories { return true }
        let path = PathSpelling.system(event.path)
        return roots.contains(path) || roots.contains(IndexRefresh.splitPath(path).parent)
    }

    deinit {
        changes.cancel()
        // Start and stop must never race; neither waits on the presentation's thread.
        Task.detached { [opened, stream] in
            _ = await opened.value
            stream.stop()
        }
    }
}
