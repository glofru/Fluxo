//
//  AppServicesLifecycle.swift
//  Fluxo
//

import AppIntents
import SwiftUI

extension View {
    /// App-wide upkeep of the Apple Intelligence and Siri features: re-reads the model availability when the app
    /// becomes active, keeps Spotlight and the Siri phrase parameters in step with the favorites and history, and
    /// tells the system what is watched (intent donations), so Siri can suggest a channel at the time it is usually
    /// watched and Apple Intelligence knows the user's habits.
    func appServicesLifecycle(_ services: AppServices) -> some View {
        modifier(AppServicesLifecycle(services: services))
    }
}

private struct AppServicesLifecycle: ViewModifier {

    let services: AppServices

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            // Apple TV: the fluxo:// links (`FluxoLink`) do what the intents of the same name do.
            .fluxoLinks(services)
            #endif
            .task {
                // After launch work (guide, imports) has had its turn.
                services.spotlight.scheduleUpdate(after: .seconds(5))
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    services.intelligence.refreshAvailability()
                    services.spotlight.scheduleUpdate()
                case .background:
                    // The watch history changed while the app was used.
                    services.spotlight.scheduleUpdate(after: .zero)
                default:
                    break
                }
            }
            .onChange(of: services.library.favoriteKeys) {
                services.spotlight.scheduleUpdate()
            }
            .onChange(of: services.player.currentItem?.bookmarkKey) { _, key in
                guard key != nil, let item = services.player.currentItem else {
                    return
                }
                services.donatePlay(item)
                // The watch history changed: the phrases learn the channel. Not at every channel change while zapping
                // (each would index again during playback): once the channel was kept a while, or when the app
                // goes to the background (which updates at once).
                services.spotlight.scheduleUpdate(after: .seconds(90))
            }
    }
}
