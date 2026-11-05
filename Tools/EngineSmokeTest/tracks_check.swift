// Plays the master playlist the remux engine writes for an input with several audio tracks and text subtitles
// (see run_tracks.sh) with AVPlayer (macOS), and checks what the app relies on: the audio and subtitle options
// AVFoundation lists (names, languages, forced, accessibility characteristics), switching the audio track, and
// the subtitle cues it delivers, with their times (they must match the source subtitles).
// Usage: swift tracks_check.swift <master-playlist-url> [expected cue text ...]
// NO_SUBTITLES=1: the input has audio tracks only.
import AVFoundation
import Foundation

let url = URL(string: CommandLine.arguments[1])!
let expectedCues = Array(CommandLine.arguments.dropFirst(2))
let player = AVPlayer()
let item = AVPlayerItem(url: url)
player.replaceCurrentItem(with: item)

final class LegibleCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var cues: [(time: Double, text: String)] = []
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        for string in strings where !string.string.isEmpty {
            let text = string.string.replacingOccurrences(of: "\n", with: " / ")
            cues.append((itemTime.seconds, text))
            print(String(format: "[cue] t=%.2f %@", itemTime.seconds, text as NSString))
            fflush(stdout)
        }
    }
}

let collector = LegibleCollector()
let legibleOutput = AVPlayerItemLegibleOutput()
legibleOutput.setDelegate(collector, queue: .main)
item.add(legibleOutput)

var failures: [String] = []

func describe(_ option: AVMediaSelectionOption) -> String {
    var traits: [String] = []
    if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { traits.append("forced") }
    if option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) { traits.append("sdh") }
    if option.hasMediaCharacteristic(.describesVideoForAccessibility) { traits.append("ad") }
    return "\(option.displayName) [\(option.extendedLanguageTag ?? "-")] \(traits.joined(separator: ","))"
}

Task { @MainActor in
    do {
        let audible = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
        print("[tracks] audio: \(audible?.options.map(describe) ?? [])")
        print("[tracks] subtitles: \(legible?.options.map(describe) ?? [])")
        if (audible?.options.count ?? 0) < 2 { failures.append("fewer than 2 audio options") }
        let expectsSubtitles = ProcessInfo.processInfo.environment["NO_SUBTITLES"] != "1"
        if expectsSubtitles && (legible?.options.count ?? 0) < 1 { failures.append("no subtitle options") }

        player.play()
        try await Task.sleep(for: .seconds(3))
        print("[avplayer] status=\(item.status.rawValue) time=\(item.currentTime().seconds) error=\(item.error?.localizedDescription ?? "-")")
        if item.status != .readyToPlay { failures.append("item not ready") }

        // Switch to the second audio track, then turn on the first full (not forced) subtitle option.
        if let audible, audible.options.count > 1 {
            item.select(audible.options[1], in: audible)
        }
        if let legible, let subtitles = AVMediaSelectionGroup.mediaSelectionOptions(from: legible.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles]).first {
            item.select(subtitles, in: legible)
        }
        // Play on past the first cues (the start can take a moment).
        for _ in 0..<40 where item.currentTime().seconds < 6.5 {
            try await Task.sleep(for: .milliseconds(250))
        }
        if let audible {
            let selected = item.currentMediaSelection.selectedMediaOption(in: audible)
            print("[avplayer] selected audio: \(selected.map(describe) ?? "-") time=\(item.currentTime().seconds) control=\(player.timeControlStatus.rawValue)")
            if selected != audible.options.last { failures.append("audio switch not applied") }
        }
        // Seek into the middle: subtitles must follow.
        await player.seek(to: CMTime(seconds: 11.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .seconds(7))
        print("[avplayer] after seek time=\(item.currentTime().seconds) control=\(player.timeControlStatus.rawValue) error=\(item.error?.localizedDescription ?? "-")")
        if player.timeControlStatus != .playing { failures.append("not playing after the seek") }
    } catch {
        failures.append("error: \(error)")
    }
    for expected in expectedCues where !collector.cues.contains(where: { $0.text.contains(expected) }) {
        failures.append("cue not delivered: \(expected)")
    }
    print(failures.isEmpty ? "[result] PASS" : "[result] FAIL \(failures)")
    exit(failures.isEmpty ? 0 : 1)
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 60))
print("[result] FAIL timeout")
exit(1)
