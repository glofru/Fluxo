//
//  AppServicesLifecycle.swift
//  Fluxo
//

import SwiftUI

extension View {
    /// App-wide upkeep of the Apple Intelligence and Siri features: re-reads the model availability when the app
    /// becomes active, and keeps Spotlight and the Siri phrase parameters in step with the favorites and history.
    func appServicesLifecycle(_ services: AppServices) -> some View {
        modifier(AppServicesLifecycle(services: services))
    }
}

private struct AppServicesLifecycle: ViewModifier {

    let services: AppServices

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
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
    }
}
