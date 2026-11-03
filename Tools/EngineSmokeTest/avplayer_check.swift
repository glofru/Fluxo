// Plays an HLS URL produced by the remux engine with AVPlayer (macOS) and exercises the time-shift
// operations the app uses: pause, resume, skip back, skip forward, go live. Prints what AVPlayer reports.
// Usage: swift avplayer_check.swift <playlist-url>
import AVFoundation
import Foundation

let url = URL(string: CommandLine.arguments[1])!
let player = AVPlayer()
let item = AVPlayerItem(url: url)
item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
player.replaceCurrentItem(with: item)
player.play()

func report(_ label: String) {
    let range = item.seekableTimeRanges.last?.timeRangeValue
    let start = range?.start.seconds ?? .nan
    let end = range.map { $0.start.seconds + $0.duration.seconds } ?? .nan
    let current = item.currentTime().seconds
    let status = ["unknown", "readyToPlay", "failed"][item.status.rawValue]
    let control = ["paused", "waiting", "playing"][player.timeControlStatus.rawValue]
    print(String(format: "[avplayer] %-12@ status=%@ control=%@ current=%.1f seekable=%.1f...%.1f behindLive=%.1f error=%@",
                 label as NSString, status, control, current, start, end, end - current,
                 (item.error?.localizedDescription ?? "-") as NSString))
    fflush(stdout)
}

func seek(_ seconds: Double) {
    let tolerance = CMTime(value: 1, timescale: 4)
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
}

let steps: [(Double, String, () -> Void)] = [
    (4, "start", {}),
    (8, "playing", {}),
    (12, "pause", { player.pause() }),
    (20, "paused 8s", {}),
    (21, "resume", { player.play() }),
    (25, "after resume", {}),
    (26, "skip -10", { seek(item.currentTime().seconds - 10) }),
    (29, "after -10", {}),
    (30, "skip +30", {
        let range = item.seekableTimeRanges.last!.timeRangeValue
        let liveLimit = range.start.seconds + range.duration.seconds - 6
        seek(min(item.currentTime().seconds + 30, liveLimit))
    }),
    (33, "after +30", {}),
    (34, "skip -20", { seek(item.currentTime().seconds - 20) }),
    (37, "after -20", {}),
    (38, "go live", {
        let range = item.seekableTimeRanges.last!.timeRangeValue
        seek(range.start.seconds + range.duration.seconds - 6)
        player.play()
    }),
    (42, "after live", {}),
]
let begin = Date()
for (time, label, action) in steps {
    while Date().timeIntervalSince(begin) < time {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    action()
    report(label)
}
