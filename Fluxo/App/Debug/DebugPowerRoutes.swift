//
//  DebugPowerRoutes.swift
//  Fluxo
//
//  Debug harness: routes for the energy adaptations (`power:`, `power-log`). See Tools/Simulator/README.md.
//

#if DEBUG
import AVFoundation
import Foundation
import os

enum DebugPowerRoutes {

    static let all: [DebugRoute] = [
        DebugRoute("power:<low-power|normal|fair|serious|critical|system>", "Pretends Low Power Mode is on, or a thermal state (normal: neither), or follows the system.") { _, argument in
            let value = argument.lowercased()
            guard ["low-power", "lowpower", "on", "normal", "nominal", "off", "fair", "serious", "critical", "system", ""].contains(value) else {
                throw DebugRouteError.invalidArgument("power", argument)
            }
            PowerMonitor.shared.applyDebugPower(value)
        },
        DebugRoute("power-log", "Writes the energy state (Low Power Mode, thermal state, the player's energy profile, the guide refresh) to Status/power.log.") { context, _ in
            let power = PowerMonitor.shared
            let player = context.player
            let item = player.player.currentItem
            let resolution = item.map { "\(Int($0.preferredMaximumResolution.width))x\(Int($0.preferredMaximumResolution.height))" } ?? "-"
            let line = "power-log: lowPower=\(power.isLowPowerModeEnabled) thermal=\(power.thermalState.logName) background=\(power.isInBackground)"
                + " playbackActive=\(power.isPlaybackActive) defersOptionalWork=\(power.defersOptionalWork)"
                + " guideRefreshDeferred=\(context.epg.isStaleRefreshDeferred)"
                + " rendersVideo=\(player.surface.rendersVideo) preventsDisplaySleep=\(player.player.preventsDisplaySleepDuringVideoPlayback)"
                + " itemMaxResolution=\(resolution) itemPeakBitRate=\(item.map { Int($0.preferredPeakBitRate) } ?? -1)"
                + " profile=[\(player.energyProfile?.summary ?? "none")]"
            DebugLaunchOptions.logger.notice("\(line, privacy: .public)")
            appendStatus(line)
        },
        DebugRoute("energy-check", "Checks the rules of PlaybackEnergyProfile and writes `energy-check: ok` or the failures to Status/power.log.") { _, _ in
            let failures = checkEnergyProfile()
            let line = failures.isEmpty ? "energy-check: ok" : "energy-check: FAILED " + failures.joined(separator: "; ")
            DebugLaunchOptions.logger.notice("\(line, privacy: .public)")
            appendStatus(line)
            if !failures.isEmpty {
                throw DebugRouteError.invalidArgument("energy-check", failures.joined(separator: "; "))
            }
        },
    ]

    /// The expected profile for the situations that matter.
    private static func checkEnergyProfile() -> [String] {
        typealias Profile = PlaybackEnergyProfile
        typealias Conditions = PlaybackEnergyProfile.Conditions
        var failures: [String] = []
        func expect(_ name: String, _ conditions: Conditions, interval: Double, limit: Profile.QualityLimit, sleepPrevented: Bool, renders: Bool) {
            let profile = Profile(conditions)
            if profile.timeObserverInterval.seconds != interval || profile.qualityLimit != limit
                || profile.preventsDisplaySleep != sleepPrevented || profile.rendersVideo != renders {
                failures.append("\(name): \(profile.summary)")
            }
        }
        expect("player screen", Conditions(isPlayerScreenVisible: true, isPlayerPresented: true),
               interval: 0.5, limit: .none, sleepPrevented: true, renders: true)
        expect("opening", Conditions(isPlayerPresented: true),
               interval: 2, limit: .none, sleepPrevented: false, renders: true)
        expect("mini player", Conditions(),
               interval: 2, limit: .none, sleepPrevented: false, renders: false)
        expect("background, audio only", Conditions(isInBackground: true),
               interval: 2, limit: .lowest, sleepPrevented: false, renders: false)
        expect("background, player screen open", Conditions(isInBackground: true, isPlayerScreenVisible: true, isPlayerPresented: true),
               interval: 2, limit: .lowest, sleepPrevented: false, renders: true)
        expect("Picture in Picture", Conditions(isInBackground: true, isPictureInPictureActive: true),
               interval: 1, limit: .hd720, sleepPrevented: true, renders: true)
        expect("Low Power Mode", Conditions(isLowPowerModeEnabled: true, isPlayerScreenVisible: true, isPlayerPresented: true),
               interval: 0.5, limit: .hd1080, sleepPrevented: true, renders: true)
        expect("serious", Conditions(thermalState: .serious, isPlayerScreenVisible: true, isPlayerPresented: true),
               interval: 0.5, limit: .hd720, sleepPrevented: true, renders: true)
        expect("critical in Low Power Mode", Conditions(isLowPowerModeEnabled: true, thermalState: .critical, isPlayerScreenVisible: true, isPlayerPresented: true),
               interval: 0.5, limit: .sd480, sleepPrevented: true, renders: true)
        expect("background in Low Power Mode", Conditions(isLowPowerModeEnabled: true, isInBackground: true),
               interval: 2, limit: .lowest, sleepPrevented: false, renders: false)
        return failures
    }

    private static func appendStatus(_ text: String) {
        let url = DebugEnvironment.statusDirectory.appendingPathComponent("power.log")
        try? FileManager.default.createDirectory(at: DebugEnvironment.statusDirectory, withIntermediateDirectories: true)
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
