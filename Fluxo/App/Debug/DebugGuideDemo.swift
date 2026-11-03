//
//  DebugGuideDemo.swift
//  Fluxo
//
//  Debug-only TV guide demo, compiled out of release builds:
//  `-FluxoDebugGuideDemo YES` runs the app on an in-memory store with the sample playlists and a sample guide
//  (the real library is never opened), `-FluxoDebugOpenGuide YES` opens the TV Guide at launch
//  (`-FluxoDebugOpenFavorites YES` the Favorites, and `-FluxoDebugGuideSources YES` the Guide Sources sheet), and on macOS
//  `-FluxoDebugSnapshot <name>` writes a PNG of every visible window to the app's temporary folder after
//  `-FluxoDebugSnapshotDelay <seconds>` (default 6), then quits (`-FluxoDebugOpenSettings YES` opens the
//  Settings window first). The Guide also reads `-FluxoDebugGuideSearch <term>` and `-FluxoDebugGuideDetail YES`.
//

#if DEBUG
import SwiftData
import SwiftUI

enum DebugGuideDemo {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "FluxoDebugGuideDemo")
    }

    static var opensGuide: Bool {
        UserDefaults.standard.bool(forKey: "FluxoDebugOpenGuide")
    }

    /// `-FluxoDebugOpenFavorites YES` (iOS tab or macOS sidebar), to check the guide overlay of channel cards.
    static var opensFavorites: Bool {
        UserDefaults.standard.bool(forKey: "FluxoDebugOpenFavorites")
    }

    /// The demo container, when the demo was requested.
    static func makeContainerIfRequested() -> ModelContainer? {
        guard isEnabled else {
            return nil
        }
        return MainActor.assumeIsolated {
            let container = PreviewSampleData.makeContainer(withSamples: true)
            GuidePreviewData.seedGuide(into: container.mainContext, now: .now)
            return container
        }
    }
}

extension View {
    /// Writes snapshots of the windows when `-FluxoDebugSnapshot` is set (macOS).
    func debugSnapshots() -> some View {
        task {
            #if os(macOS)
            await DebugSnapshot.runIfRequested()
            #endif
        }
    }
}

#if os(macOS)
@MainActor
private enum DebugSnapshot {
    private static var didRun = false

    static func runIfRequested() async {
        let defaults = UserDefaults.standard
        guard !didRun, let name = defaults.string(forKey: "FluxoDebugSnapshot"), !name.isEmpty else {
            return
        }
        didRun = true
        if defaults.bool(forKey: "FluxoDebugOpenSettings") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        let delay = defaults.double(forKey: "FluxoDebugSnapshotDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 6))
        let directory = FileManager.default.temporaryDirectory
        let windows = NSApp.windows.filter(\.isVisible).flatMap { window in
            [window] + (window.attachedSheet.map { [$0] } ?? [])
        }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView else {
                continue
            }
            let bounds = view.bounds
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                continue
            }
            view.cacheDisplay(in: bounds, to: bitmap)
            let url = directory.appendingPathComponent("\(name)-\(index).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("FluxoDebug: snapshot %@", url.path)
        }
        NSApp.terminate(nil)
    }
}
#endif
#endif
