import CoreServices
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataDev
import StrataIndex

/// A pane watches the folder it shows and that folder's repository; what it found for a folder it no longer shows is
/// dropped (late results never win).
@MainActor struct BrowserWatchingTests {
    @Test func growingAnAlreadyListedFileUpdatesItsSizeAndDate() async throws {
        let tree = try TestTree("exports/movie.mp4")
        let movie = tree.url("exports/movie.mp4")
        try Data(repeating: 0, count: 48).write(to: movie)
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: movie.path)
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        _ = browser.view
        browser.load(tree.url("exports"))
        await browser.directoryReads.task?.value
        let row = try #require(browser.visibleRows.first)
        try #require(row.entry.size == 48 && row.entry.modified == oldDate)

        let writer = try FileHandle(forWritingTo: movie)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 1, count: 8192))
        try writer.close()
        for _ in 0..<500 where row.entry.size != 8240 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(browser.visibleRows.first === row)
        #expect(row.entry.size == 8240)
        #expect(row.entry.modified != oldDate)
        #expect(tree.snapshot() == ["exports/", "exports/movie.mp4"])
    }

    @Test func onlyVisibleFileChangesAndOverlappingRecoveryEventsRefresh() {
        let roots: Set<String> = ["/private/tmp/exports", "/second"]
        func affects(_ path: String, _ flags: Int = kFSEventStreamEventFlagItemModified) -> Bool {
            ListingWatch.affectsListing(.init(path: path, flags: FSEventStreamEventFlags(flags), id: 1), roots: roots)
        }
        #expect(affects("/tmp/exports"))
        #expect(affects("/private/tmp/exports/movie.mp4"))
        #expect(affects("/second/movie.mp4", kFSEventStreamEventFlagItemInodeMetaMod))
        #expect(!affects("/tmp/exports-old/movie.mp4"))
        #expect(!affects("/second/nested/movie.mp4"))
        #expect(!affects("/second/new", kFSEventStreamEventFlagItemCreated))
        #expect(!affects("/second/old", kFSEventStreamEventFlagItemRenamed))
        #expect(!affects("/tmp", kFSEventStreamEventFlagItemModified))
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagUserDropped] {
            #expect(affects("/tmp", flag))
            #expect(affects("/second", flag))
            #expect(!affects("/second/deep/nested", flag))
            #expect(!affects("/second-lookalike", flag))
        }
        #expect(affects("/second/nested", kFSEventStreamEventFlagMustScanSubDirs))
        #expect(affects("/", kFSEventStreamEventFlagKernelDropped))
        #expect(affects("/", kFSEventStreamEventFlagUserDropped))
        #expect(affects("/", kFSEventStreamEventFlagRootChanged))
    }

    @Test(arguments: [true, false]) func directoryEntriesStayWatchedEvenWithASilentFileStream(starts: Bool) async throws {
        let tree = try TestTree("folder/")
        let changes = Mutex(0)
        let watching = ListingWatch([tree.url("folder")], startStream: { _, _ in starts }) {
            changes.withLock { $0 += 1 }
        }
        await watching.ready.value
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        withExtendedLifetime(watching) {}
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }

    @Test func aRepositoryFoundAfterThePaneMovedOnOrStoppedIsDropped() async throws {
        let tree = try TestTree("repo/.git/HEAD", "repo/src/")
        let store = GitStatusStore()
        store.isEnabled = true
        let watching = BrowserWatching()
        var current = true
        watching.watch([], repositoryOf: tree.url("repo/src"), in: store, changed: {}, isCurrent: { current })
        await watching.finding?.value
        #expect(watching.git?.repository.root.standardizedFileURL.path == tree.url("repo").standardizedFileURL.path)
        current = false
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, isCurrent: { current })
        #expect(watching.git == nil)
        await watching.finding?.value
        #expect(watching.git == nil)
        current = true
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, isCurrent: { current })
        watching.stop()
        await watching.finding?.value
        #expect(watching.git == nil)
        #expect(tree.snapshot() == ["repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/"])
    }

    @Test func aChangeInTheWatchedFolderReadsItAgain() async throws {
        let tree = try TestTree("folder/")
        let watching = BrowserWatching()
        let changes = Mutex(0)
        // Watching once its folder is open: a change made then is caught.
        await watching.watch([tree.url("folder")], repositoryOf: tree.url("folder"), in: GitStatusStore(),
                             changed: { changes.withLock { $0 += 1 } }, isCurrent: { true }).value
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        watching.stop()
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }
}
