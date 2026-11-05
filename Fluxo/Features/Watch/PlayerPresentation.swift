//
//  PlayerPresentation.swift
//  Fluxo
//
//  How the full-screen player is shown over the app.
//
//  iOS: the player is a layer above the tab view (not a full-screen cover), so that it can follow the finger:
//  - it grows out of the card or the mini player that opened it (`playerTransitionSource(id:)`),
//  - a vertical drag anywhere on it moves it 1:1 with the finger, with the app visible (and dimmed) behind it;
//    dragging up rubber-bands (black continues below it, the app never shows there),
//  - letting go dismisses it when it was dragged far enough or flicked down (the release velocity carries
//    into the closing spring), and springs back up otherwise,
//  - closing it calls `onDismiss`, which lets the player continue in Picture in Picture,
//  - while it covers the screen at rest, the app underneath is hidden (it keeps its state), so it is not drawn.
//  Its visible area is computed from its own frame and safe area insets (`PlayerClipShape`), so it always
//  covers the whole screen, on every device and orientation.
//  Controls that track a drag themselves (the timeline) use high-priority gestures, so they never move the
//  player.
//
//  macOS: the player covers the main window, with a fade (the window's toolbar is hidden meanwhile).
//

// The touch and pointer player screen (iPhone, iPad, Mac). Apple TV plays in the system's player, whose transport bar the Siri Remote drives (Fluxo/TV).
#if !os(tvOS)
import SwiftUI

// MARK: - Source frames

/// Where the cards that can open the player are on screen (global coordinates), so the player can grow out
/// of the one that opened it. A plain reference type: updating it never re-renders anything.
@MainActor
final class PlayerSourceFrames {
    struct Source {
        let frame: CGRect
        let cornerRadius: CGFloat
    }

    private var sources: [String: Source] = [:]

    func update(_ id: String, frame: CGRect?, cornerRadius: CGFloat) {
        sources[id] = frame.map { Source(frame: $0, cornerRadius: cornerRadius) }
    }

    /// The source `id`, else the mini player (when it is on screen).
    func source(for id: String?) -> Source? {
        sources[id ?? PlayerTransition.miniPlayerID] ?? sources[PlayerTransition.miniPlayerID]
    }
}

extension EnvironmentValues {
    /// The source frames of the player transition; set once at the root of the window.
    @Entry var playerSourceFrames: PlayerSourceFrames?
}

// MARK: - Presentation

extension View {

    /// Shows `content` over this view while `isPresented`. `isVisible` false keeps it mounted but moved off
    /// screen (the player does that while Picture in Picture takes the video over). A drag down past the
    /// threshold, or a flick, calls `onDismiss`. `sourceID` is the card it opens from.
    func playerPresentation<Content: View>(
        isPresented: Bool,
        isVisible: Bool,
        sourceID: String?,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(PlayerPresentationModifier(isPresented: isPresented, isVisible: isVisible, sourceID: sourceID, onDismiss: onDismiss, player: content))
    }
}

private struct PlayerPresentationModifier<Player: View>: ViewModifier {

    let isPresented: Bool
    let isVisible: Bool
    let sourceID: String?
    let onDismiss: () -> Void
    @ViewBuilder let player: () -> Player

    #if os(iOS)
    @State private var sourceFrames = PlayerSourceFrames()
    /// Vertical offset of the player while (and right after) it is dragged; positive is down.
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// The drag started vertically; horizontal drags are left to the content.
    @State private var dragAxisIsVertical: Bool?
    @State private var dismissFeedback = 0
    /// The finger's recent positions, for its speed when it lifts.
    @State private var velocityTracker = DragVelocityTracker()
    /// Where the player is laid out (global coordinates) and the safe areas around it.
    @State private var layout = PlayerLayout.zero
    /// The player covers the whole app and nothing moves: the app underneath is hidden (opacity 0, so it keeps
    /// its state) and the GPU does not draw it for the whole viewing session.
    @State private var coversApp = false
    /// The status bar the player asks for (from its controls); nil while it is not shown.
    @State private var playerStatusBar: PlayerStatusBarStyle?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var dragProbe = DragProbe()
    #endif
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        let height = layout.screen.height
        let offset = isVisible ? dragOffset : height
        let progress = min(1, max(0, offset / max(1, height)))
        ZStack {
            content
                // Derived from `isPresented` too, so the app shows again in the very update that removes the
                // player (Stop removes it without `dismiss`), not one update later when `coversApp` follows: the
                // closing slide never uncovers a blank screen.
                .opacity(coversApp && isPresented && isVisible ? 0 : 1)
                .accessibilityHidden(isPresented && isVisible)

            if isPresented {
                // Dims the app while the player covers it; it shows through while the player is dragged.
                Color.black
                    .opacity(isVisible ? 0.45 * (1 - progress) : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(1)

                player()
                    // While the player is pulled up, black continues below its bottom edge (as the rubber band
                    // lifts it), so the app never shows under it. Laid out from the screen rect, from the top
                    // leading corner of the player's frame, so that it reaches every screen edge, also the side
                    // safe areas of a phone in landscape. (With `ignoresSafeArea()` instead, the dragged player
                    // lost the top of its rounded corners.)
                    .background(alignment: .topLeading) {
                        Color.black
                            .frame(width: layout.screen.width, height: layout.screen.height + Self.maximumLift + 20)
                            .offset(x: -layout.insets.leading, y: -layout.insets.top)
                            .allowsHitTesting(false)
                    }
                    // The whole screen at rest; a card with rounded corners once it moves down.
                    .clipShape(PlayerClipShape(
                        cornerRadius: offset > 0 ? min(44, 18 + offset * 0.15) : 0,
                        height: height,
                        bottomExtension: max(0, -offset),
                        outsets: layout.insets
                    ))
                    .offset(y: offset)
                    .allowsHitTesting(isVisible)
                    .gesture(dismissGesture(height: height), including: isVisible ? .all : .subviews)
                    .accessibilityAction(.escape) {
                        dismiss(height: height, velocity: 0)
                    }
                    #if DEBUG
                    .overlay(alignment: .topLeading) {
                        if DebugLaunchOptions.current.isActive {
                            dragProbe.element(offset: dragOffset, isVisible: isVisible)
                        }
                    }
                    #endif
                    .transition(transition)
                    .zIndex(2)
            }
        }
        .onGeometryChange(for: PlayerLayout.self) { proxy in
            PlayerLayout(frame: proxy.frame(in: .global), insets: proxy.safeAreaInsets)
        } action: { layout in
            self.layout = layout
        }
        .onPlayerStatusBarChange { style in
            withAnimation(.easeInOut(duration: 0.25)) {
                playerStatusBar = style
            }
        }
        .playerStatusBar(statusBarStyle(offset: offset))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.12), value: isPresented)
        .animation(isDragging ? nil : .spring(duration: 0.38, bounce: 0), value: isVisible)
        .environment(\.playerSourceFrames, sourceFrames)
        .sensoryFeedback(.impact(weight: .light), trigger: dismissFeedback)
        .onChange(of: isPresented) { _, presented in
            if presented {
                dragOffset = 0
                dragAxisIsVertical = nil
            }
        }
        .task(id: CoverState(isPresented: isPresented, isVisible: isVisible, isDragging: isDragging, isAtRest: dragOffset == 0)) {
            // Hide the app once the opening (or spring back) animation is over; show it at once otherwise.
            guard isPresented, isVisible, !isDragging, dragOffset == 0 else {
                coversApp = false
                return
            }
            try? await Task.sleep(for: .seconds(0.6))
            if !Task.isCancelled {
                coversApp = true
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugPlayerDrag)) { notification in
            // Debug harness: hold the player at a drag offset, as a finger would, for screenshots.
            if let offset = notification.object as? CGFloat {
                coversApp = false
                withAnimation(.spring(duration: 0.3)) {
                    dragOffset = offset
                }
            }
        }
        #endif
        #else
        ZStack {
            content
                .toolbar(isPresented ? .hidden : .automatic, for: .windowToolbar)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)

            if isPresented {
                player()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
        #endif
    }

    #if os(iOS)

    /// Distance after which a released drag dismisses (a share of the height, at most `dismissDistance`, so that
    /// the tall iPad screen needs no longer swipe than a phone), and the flick speed that dismisses from anywhere.
    private static var dismissFraction: CGFloat { 0.22 }
    private static var dismissDistance: CGFloat { 180 }
    private static var dismissVelocity: CGFloat { 800 }
    /// How far the release velocity carries the player, in seconds of travel (a short deceleration projection).
    private static var velocityProjection: CGFloat { 0.15 }
    /// How far a drag up can lift the player (rubber band).
    private static var maximumLift: CGFloat { 80 }

    private func dismissGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if dragAxisIsVertical == nil {
                    dragAxisIsVertical = abs(value.translation.height) > abs(value.translation.width)
                    velocityTracker.reset()
                    #if DEBUG
                    dragProbe.reset()
                    #endif
                }
                guard dragAxisIsVertical == true else {
                    return
                }
                // Show the app before the player moves off it.
                coversApp = false
                isDragging = true
                let translation = value.translation.height
                velocityTracker.add(translation, at: value.time)
                // 1:1 down; up, the resistance grows with the distance (rubber band).
                dragOffset = translation >= 0 ? translation : -Self.rubberBand(-translation, limit: Self.maximumLift)
                #if DEBUG
                dragProbe.record(translation: translation, offset: dragOffset)
                #endif
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragAxisIsVertical = nil
                }
                guard dragAxisIsVertical == true else {
                    return
                }
                let velocity = velocityTracker.releaseVelocity(translation: value.translation.height, at: value.time, reported: value.velocity.height)
                #if DEBUG
                dragProbe.recordRelease(velocity: velocity)
                #endif
                let projected = dragOffset + velocity * Self.velocityProjection
                let threshold = min(height * Self.dismissFraction, Self.dismissDistance)
                if dragOffset > 0 && (projected > threshold || velocity > Self.dismissVelocity) {
                    dismiss(height: height, velocity: velocity)
                } else {
                    // Back up, carrying the finger's speed.
                    let remaining = max(1, abs(dragOffset))
                    withAnimation(.interpolatingSpring(mass: 1, stiffness: 320, damping: 30, initialVelocity: -velocity / remaining)) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// Slides the player down from where it is, carrying `velocity` (points per second), then closes it.
    private func dismiss(height: CGFloat, velocity: CGFloat) {
        coversApp = false
        dismissFeedback += 1
        let remaining = max(1, height - dragOffset)
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.2)
            : .interpolatingSpring(mass: 1, stiffness: 260, damping: 32, initialVelocity: max(0, velocity) / remaining)
        withAnimation(animation) {
            dragOffset = height
        }
        onDismiss()
    }

    /// The status bar for the player at `offset`: the player's own (with its controls) while it covers the screen;
    /// light content while it is dragged and its black is still under the status bar (so it shows as the app
    /// comes into view, even with the controls hidden); the app's own once the player's top edge passed below it,
    /// over the dimmed app.
    private func statusBarStyle(offset: CGFloat) -> PlayerStatusBarStyle {
        guard isPresented, isVisible, let playerStatusBar else {
            return .app
        }
        if offset > layout.insets.top {
            return .app
        }
        if isDragging || offset != 0 {
            return playerStatusBar == .hidden ? .overVideo : playerStatusBar
        }
        return playerStatusBar
    }

    /// iOS-like rubber band: grows ever more slowly and never passes `limit`.
    private static func rubberBand(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        let coefficient: CGFloat = 0.55
        return (1 - 1 / (distance * coefficient / limit + 1)) * limit
    }

    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let insertion = AnyTransition.modifier(
            active: GrowFromSource(source: sourceFrames.source(for: sourceID), layout: layout, isActive: true),
            identity: GrowFromSource(source: nil, layout: layout, isActive: false)
        )
        // Off the whole screen, not by its own height (`.move(edge: .bottom)`): the player's frame stops at the
        // safe areas, so that would leave its top in the bottom safe area for the last frame. That last frame
        // stayed on screen when stopping playback with the tab bar minimized.
        let removal = AnyTransition.modifier(
            active: SlideDown(distance: max(layout.screen.height, 1)),
            identity: SlideDown(distance: 0)
        )
        return .asymmetric(insertion: insertion, removal: removal)
    }

    #endif
}

#if os(iOS)
/// Where the player layer is laid out: its frame (global coordinates, inside the safe areas) and the safe area
/// insets around it. The player draws edge to edge, so the screen is the frame plus the insets.
private struct PlayerLayout: Equatable {
    var frame: CGRect
    var insets: EdgeInsets

    static let zero = PlayerLayout(frame: .zero, insets: EdgeInsets())

    /// The whole screen area (global coordinates).
    var screen: CGRect {
        CGRect(
            x: frame.minX - insets.leading,
            y: frame.minY - insets.top,
            width: frame.width + insets.leading + insets.trailing,
            height: frame.height + insets.top + insets.bottom
        )
    }

    /// The center of the screen as a unit point of the frame (the anchor that scales the screen about its center).
    var screenCenterAnchor: UnitPoint {
        guard frame.width > 0, frame.height > 0 else {
            return .center
        }
        return UnitPoint(x: (screen.midX - frame.minX) / frame.width, y: (screen.midY - frame.minY) / frame.height)
    }
}

/// The finger's speed when it lifts. The gesture's own velocity at the end can be close to zero after a quick
/// flick whose last few points slow down (synthesized touches always do, real ones sometimes); the average speed
/// over the last `window` reflects the flick. A finger that stopped before lifting gets no speed from either.
@MainActor
private final class DragVelocityTracker {
    private struct Sample {
        let time: Date
        let translation: CGFloat
    }

    private static let window: TimeInterval = 0.08
    private var samples: [Sample] = []

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    func add(_ translation: CGFloat, at time: Date) {
        samples.append(Sample(time: time, translation: translation))
        samples.removeAll { time.timeIntervalSince($0.time) > Self.window * 2 }
    }

    /// Points per second, positive down: the faster of the gesture's own velocity and the recent average.
    func releaseVelocity(translation: CGFloat, at time: Date, reported: CGFloat) -> CGFloat {
        guard let oldest = samples.first(where: { time.timeIntervalSince($0.time) <= Self.window }) else {
            return reported
        }
        let elapsed = time.timeIntervalSince(oldest.time)
        guard elapsed > 0.008 else {
            return reported
        }
        let average = (translation - oldest.translation) / elapsed
        return abs(average) > abs(reported) ? average : reported
    }
}

/// When the player hides the app underneath (see `coversApp`).
private struct CoverState: Equatable {
    let isPresented: Bool
    let isVisible: Bool
    let isDragging: Bool
    let isAtRest: Bool
}

/// The visible area of the player, in its own coordinates: the screen (its frame grown by the safe area
/// `outsets`), cut to `height` around the screen's center, with rounded corners, and extended below by
/// `bottomExtension`.
///
/// The screen is computed from the player's own frame, never from a mask laid out with `ignoresSafeArea()`
/// (a mask is not laid out like the view it masks: on iPad that left the bottom of the app uncovered). At rest
/// (full height, square corners) the shape reaches well past the screen, so it never cuts anything.
private struct PlayerClipShape: Shape {
    var cornerRadius: CGFloat
    var height: CGFloat
    var bottomExtension: CGFloat
    let outsets: EdgeInsets

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(cornerRadius, AnimatablePair(height, bottomExtension)) }
        set {
            cornerRadius = newValue.first
            height = newValue.second.first
            bottomExtension = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let screen = CGRect(
            x: rect.minX - outsets.leading,
            y: rect.minY - outsets.top,
            width: rect.width + outsets.leading + outsets.trailing,
            height: rect.height + outsets.top + outsets.bottom
        )
        let visibleHeight = min(screen.height, max(0, height))
        if cornerRadius < 0.5 && visibleHeight >= screen.height - 0.5 {
            // At rest: nothing to cut.
            return Path(screen.insetBy(dx: -100, dy: -100).inset(by: EdgeInsets(top: 0, leading: 0, bottom: -bottomExtension, trailing: 0)))
        }
        let visible = CGRect(
            x: screen.minX,
            y: screen.midY - visibleHeight / 2,
            width: screen.width,
            height: visibleHeight + bottomExtension
        )
        return Path(roundedRect: visible, cornerRadius: min(cornerRadius, visible.width / 2, visible.height / 2), style: .continuous)
    }
}

private extension CGRect {
    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(x: minX + insets.leading, y: minY + insets.top, width: width - insets.leading - insets.trailing, height: height - insets.top - insets.bottom)
    }
}

/// Closing transition: slides the player down by `distance`.
private struct SlideDown: ViewModifier {
    let distance: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: distance)
    }
}

/// Opening transition: the player starts exactly over its source card (scaled to the card's width and cut to
/// its height, so the middle of the video sits in the card) and grows to the full screen. Without a known source
/// it slides up from the bottom.
private struct GrowFromSource: ViewModifier {
    let source: PlayerSourceFrames.Source?
    let layout: PlayerLayout
    let isActive: Bool

    func body(content: Content) -> some View {
        let geometry = geometry
        content
            .clipShape(PlayerClipShape(cornerRadius: geometry.cornerRadius, height: geometry.visibleHeight, bottomExtension: 0, outsets: layout.insets))
            // Scaled about the screen's center (not the frame's, which the safe areas move).
            .scaleEffect(geometry.scale, anchor: layout.screenCenterAnchor)
            .offset(geometry.offset)
            .opacity(geometry.opacity)
    }

    private var geometry: (scale: CGFloat, offset: CGSize, visibleHeight: CGFloat, cornerRadius: CGFloat, opacity: Double) {
        let screen = layout.screen
        let full = max(1, screen.height)
        guard isActive else {
            return (1, .zero, full, 0, 1)
        }
        guard let source, screen.width > 0, !source.frame.isEmpty else {
            return (1, CGSize(width: 0, height: full), full, 0, 1)
        }
        let frame = source.frame
        let scale = max(0.05, frame.width / screen.width)
        let offset = CGSize(width: frame.midX - screen.midX, height: frame.midY - screen.midY)
        return (scale, offset, min(full, frame.height / scale), source.cornerRadius / scale, 0.2)
    }
}

#if DEBUG
/// Debug harness: what the player did during the last drag, as the accessibility value of an invisible element
/// ("player.dragProbe"), so the gesture UI tests can check that it followed the finger 1:1 and sprang back.
@MainActor
private final class DragProbe {
    private var samples = 0
    private var maximumOffset: CGFloat = 0
    private var maximumDeviation: CGFloat = 0
    private var releaseVelocity: CGFloat = 0

    func reset() {
        samples = 0
        maximumOffset = 0
        maximumDeviation = 0
        releaseVelocity = 0
    }

    func recordRelease(velocity: CGFloat) {
        releaseVelocity = velocity
    }

    func record(translation: CGFloat, offset: CGFloat) {
        samples += 1
        maximumOffset = max(maximumOffset, offset)
        if translation >= 0 {
            maximumDeviation = max(maximumDeviation, abs(offset - translation))
        }
    }

    /// `visible=1` while the player is on screen (0 while it hands the video to Picture in Picture).
    func element(offset: CGFloat, isVisible: Bool) -> some View {
        let value = String(format: "visible=%d samples=%d maxOffset=%.1f maxDeviation=%.2f offset=%.1f releaseVelocity=%.0f", isVisible ? 1 : 0, samples, maximumOffset, maximumDeviation, offset, releaseVelocity)
        return Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "Drag probe"))
            .accessibilityValue(value)
            .accessibilityIdentifier("player.dragProbe")
    }
}
#endif
#endif

#if DEBUG
extension Notification.Name {
    /// Debug harness: holds the player at a drag offset (the object is a CGFloat).
    static let fluxoDebugPlayerDrag = Notification.Name("FluxoDebugPlayerDrag")
    /// Debug harness: shows and keeps (true) or hides (false) the player's controls (the object is a Bool).
    static let fluxoDebugPlayerControls = Notification.Name("FluxoDebugPlayerControls")
    /// Debug harness (`player-guide`): the player's guide control (nil), or Full Guide ("full").
    static let fluxoDebugPlayerGuide = Notification.Name("FluxoDebugPlayerGuide")
}
#endif

#Preview("Player over the app") {
    @Previewable @State var isPresented = true
    Button {
        isPresented = true
    } label: {
        Text(verbatim: "Open")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .playerPresentation(isPresented: isPresented, isVisible: true, sourceID: nil, onDismiss: { isPresented = false }) {
        Color.black
            .overlay {
                Text(verbatim: "Drag me down")
                    .foregroundStyle(.white)
            }
    }
}
#endif
