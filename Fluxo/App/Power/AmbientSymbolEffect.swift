//
//  AmbientSymbolEffect.swift
//  Fluxo
//
//  Status symbols that animate for as long as they show (the LIVE waves, the recording dot, the "now playing"
//  waveform) make the screen draw a new frame all the time, also over the video, where the glass behind them is
//  rendered again at every frame. The ambient effect plays the animation, then rests a few seconds before the next
//  run: the symbol still looks alive, and the screen only redraws it during a run. It does not animate at all with
//  Reduce Motion, in Low Power Mode, or when the device is hot.
//

import SwiftUI

extension SymbolEffectOptions {
    /// One run of the effect, then a rest of `ambientRestDuration` seconds, for as long as the symbol shows.
    static var ambient: SymbolEffectOptions {
        .repeat(.periodic(delay: ambientRestDuration))
    }

    static let ambientRestDuration: Double = 3
}

extension View {
    /// A repeating indicator effect that rests between its runs (see `SymbolEffectOptions.ambient`), off with Reduce
    /// Motion and while the device saves energy (`PowerMonitor.isConstrained`).
    func ambientSymbolEffect<Effect: IndefiniteSymbolEffect & SymbolEffect>(_ effect: Effect, isActive: Bool = true) -> some View {
        modifier(AmbientSymbolEffectModifier(effect: effect, isActive: isActive))
    }
}

private struct AmbientSymbolEffectModifier<Effect: IndefiniteSymbolEffect & SymbolEffect>: ViewModifier {
    let effect: Effect
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(effect, options: .ambient, isActive: isActive && !reduceMotion && !PowerMonitor.shared.isConstrained)
    }
}
