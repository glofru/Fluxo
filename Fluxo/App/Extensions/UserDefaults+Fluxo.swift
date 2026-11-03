//
//  UserDefaults+Fluxo.swift
//  Fluxo
//

import Foundation

extension UserDefaults {
    /// The defaults the app stores its settings in. `ContentView` makes it the `defaultAppStorage` of
    /// every `@AppStorage`, so code that reads a setting directly must read it from here too.
    ///
    /// It is `.standard`, except in Debug builds launched with an isolated debug store
    /// (`-FluxoDebugStore`), which use a separate suite so a test run never changes the real settings.
    static var fluxo: UserDefaults {
        #if DEBUG
        return DebugEnvironment.shared?.userDefaults ?? .standard
        #else
        return .standard
        #endif
    }
}
