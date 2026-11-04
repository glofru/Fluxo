//
//  WindowScene.swift
//  Fluxo
//
//  Registers a window with the `WindowCoordinator` and reports which window the user is using: every touch or
//  pointer click in it (iOS), the window becoming active, and keyboard focus (the menu bar commands).
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Makes this view the root of window `id` for `coordinator`. Apply once, at the root of every window.
    /// - Parameter navigation: the window's navigation (main windows), for App Intents.
    func windowScene(_ id: UUID, kind: WindowCoordinator.WindowKind, coordinator: WindowCoordinator, navigation: AppNavigation? = nil) -> some View {
        modifier(WindowSceneModifier(id: id, kind: kind, coordinator: coordinator, navigation: navigation))
    }

    /// Reports that the app-wide `presentation` starts or ends, so that one window claims it (see
    /// `WindowCoordinator.update(_:isActive:)`). Apply in every window that can show it.
    func windowPresentation(_ presentation: WindowCoordinator.Presentation, isActive: Bool) -> some View {
        modifier(WindowPresentationModifier(presentation: presentation, isActive: isActive))
    }
}

private struct WindowSceneModifier: ViewModifier {
    let id: UUID
    let kind: WindowCoordinator.WindowKind
    let coordinator: WindowCoordinator
    let navigation: AppNavigation?

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background {
                WindowActivityProbe {
                    coordinator.noteActivity(in: id)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            #endif
            .environment(\.windowID, id)
            .focusedSceneValue(\.windowID, id)
            .onAppear {
                coordinator.register(id, kind: kind, navigation: navigation)
            }
            .onDisappear {
                coordinator.unregister(id)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    coordinator.noteActivity(in: id)
                }
            }
    }
}

private struct WindowPresentationModifier: ViewModifier {
    let presentation: WindowCoordinator.Presentation
    let isActive: Bool

    @Environment(WindowCoordinator.self) private var coordinator: WindowCoordinator?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, isActive in
                coordinator?.update(presentation, isActive: isActive)
            }
    }
}

#if os(iOS)
/// An invisible view that watches every touch of its window, without taking part in it.
private struct WindowActivityProbe: UIViewRepresentable {
    let onActivity: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onActivity = onActivity
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onActivity = onActivity
    }

    final class ProbeView: UIView {
        var onActivity: (() -> Void)?
        private var recognizer: TouchObserver?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window else {
                return
            }
            let recognizer = TouchObserver { [weak self] in
                self?.onActivity?()
            }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }
    }

    /// Fails as soon as a touch begins, after reporting it: it never recognizes, cancels or delays anything.
    final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let onTouch: () -> Void

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            state = .failed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
