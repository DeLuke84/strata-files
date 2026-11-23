import CoreServices
import Foundation
import StrataIndex

/// One listing owns both kinds of watch. Dropping it silences even a delivery already queued.
nonisolated final class ListingWatch: Sendable {
    let ready: Task<Void, Never>
    private let changes: LatestUpdate<Void>
    private let opened: Task<[DirectoryWatcher], Never>
    private let stream = FSEventsStream()

    typealias StartStream = @Sendable (FSEventsStream, [String]) -> Bool

    init(_ folders: [URL], startStream: @escaping StartStream = { $0.start(paths: $1, since: nil, latency: 0.12) },
         changed: @escaping @MainActor @Sendable () -> Void) {
        let changes = LatestUpdate<Void>(schedule: { DispatchQueue.main.async(execute: $0) }) { changed() }
        self.changes = changes
        let opened = Task.detached { [stream] () -> [DirectoryWatcher] in
            guard !folders.isEmpty else { return [] }
            let watchers = await DirectoryWatcher.watching(folders) { changes.send(()) }
            await OwnThread.run {
                let roots = Set(folders.map { PathSpelling.system($0.resolvingSymlinksInPath().path) })
                stream.handler = { events in
                    if events.contains(where: { Self.affectsListing($0, roots: roots) }) { changes.send(()) }
                }
                _ = startStream(stream, Array(roots))
            }
            return watchers
        }
        self.opened = opened
        ready = Task { _ = await opened.value }
    }

    static func affectsListing(_ event: FSEventsStream.Event, roots: Set<String>) -> Bool {
        let recovery = event.invalidatesIndex || event.mustScanSubdirectories
        let metadataOrContent = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
            | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod
        guard recovery || event.flags & FSEventStreamEventFlags(metadataOrContent) != 0 else { return false }
        let path = PathSpelling.system(event.path)
        guard path.hasPrefix("/") else { return false }
        if roots.contains(path) || roots.contains(IndexRefresh.splitPath(path).parent) { return true }
        return recovery && roots.contains { $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
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
