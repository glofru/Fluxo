//
//  ContentProvider.swift
//  FluxoTopShelf
//
//  The Top Shelf of Fluxo on the Apple TV Home Screen, shown while the app's icon is focused in the top row:
//  Continue Watching, Favorites and On Now, as rows of 16:9 images. Selecting an item (or pressing Play/Pause)
//  opens it in the app through a fluxo:// link.
//
//  Everything comes from the snapshot the app writes (`TopShelfSnapshot`, `TopShelfPublisher` in the app): the
//  extension reads one small JSON file and points at images the app already drew, so it starts fast, needs no
//  network and never opens the library. Without a snapshot (the app was never opened, or it has no playlist) it
//  returns nothing and tvOS shows the static Top Shelf image of the app's asset catalog.
//

import Foundation
import OSLog
import TVServices

final class ContentProvider: TVTopShelfContentProvider {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo.TopShelf", category: "TopShelf")

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let snapshot = TopShelfStorage.read(), let images = TopShelfStorage.imagesDirectory else {
            Self.logger.info("No snapshot: the static Top Shelf image shows.")
            return nil
        }
        let content = TopShelfContentBuilder.content(for: snapshot, imagesDirectory: images, now: .now)
        Self.logger.info("Top Shelf: \(content?.sections.map { "\($0.items.count)" }.joined(separator: " + ") ?? "empty", privacy: .public) items")
        return content
    }
}

enum TopShelfContentBuilder {

    /// The sectioned content of a snapshot at `now`; nil when no section has anything to show.
    static func content(for snapshot: TopShelfSnapshot, imagesDirectory: URL, now: Date) -> TVTopShelfSectionedContent? {
        let fileManager = FileManager.default
        let sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = snapshot.sections.compactMap { section in
            let items = section.items.compactMap { item($0, imagesDirectory: imagesDirectory, now: now, fileManager: fileManager) }
            guard !items.isEmpty else {
                return nil
            }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func item(_ entry: TopShelfSnapshot.Item, imagesDirectory: URL, now: Date, fileManager: FileManager) -> TVTopShelfSectionedItem? {
        var title = entry.title
        var progress = entry.progress
        if let airings = entry.airings {
            // A live channel in On Now: only while one of its programmes is on air, titled with it. (No expiration
            // date: tvOS then shows the time left in place of the title, and the title says what is on.)
            guard let airing = airings.first(where: { $0.isOnAir(at: now) }) else {
                return nil
            }
            title = airing.title
            progress = airing.progress(at: now)
        }

        let item = TVTopShelfSectionedItem(identifier: entry.id)
        item.title = title
        item.imageShape = .hdtv
        if let progress, progress > 0 {
            item.playbackProgress = min(1, progress)
        }
        for (name, traits) in [(entry.image, TVTopShelfItem.ImageTraits.screenScale1x), (entry.image2x, .screenScale2x)] {
            guard let name else {
                continue
            }
            let url = imagesDirectory.appending(path: name, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                item.setImageURL(url, for: traits)
            }
        }
        item.playAction = entry.playURL.map(TVTopShelfAction.init(url:))
        item.displayAction = (entry.displayURL ?? entry.playURL).map(TVTopShelfAction.init(url:))
        return item
    }
}
