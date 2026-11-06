//
//  AppSchemaAdoption.swift
//  Fluxo
//
//  The App Intents schemas (`AppSchema`) Fluxo adopts, so Siri AI (Siri with Apple Intelligence) understands
//  what these actions do without a fixed phrase: "Open Sky Sport F1 in Fluxo", "Search Fluxo for football".
//
//  The iOS 27.2 SDK has no schema domain for video or TV apps (its media domain, `audio`, is for music, podcasts,
//  audiobooks and radio). The domain that fits is `system`, whose `open` (open an entity: here, play a channel)
//  and `searchInApp` (show search results in the app) schemas Fluxo adopts.
//
//  `@AppIntent(schema: .system.open)` cannot be written on these types: the schema values exist from iOS 27 and
//  macOS 27, while Fluxo runs from iOS 26.1 and macOS 26 and an intent cannot exist twice (each entity has one
//  `OpenIntent`, and an app has at most ten App Shortcuts). The macro only adds an availability-gated extension;
//  the extensions below are exactly what it generates, so the intents are unchanged on iOS 26 and adopt the schema
//  on iOS 27 (the build's `Metadata.appintents` lists them under the schema). The tvOS 27.2 SDK marks the schemas
//  unavailable on tvOS, so Apple TV has no schema adoption: there, Siri reaches the intents through their App Shortcut
//  phrases.
//

import AppIntents

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension PlayChannelIntent: AssistantSchemaIntent {
    static let __appSchemaIntent = "system.open"
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension SearchInFluxoIntent: AssistantSchemaIntent {
    static let __appSchemaIntent = "system.searchInApp"
}
