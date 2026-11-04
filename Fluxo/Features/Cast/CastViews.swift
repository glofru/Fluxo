//
//  CastViews.swift
//  Fluxo
//
//  The Cast device picker (a sheet), the volume control, and what the player shows instead of the video while a
//  Chromecast plays the channel.
//

import SwiftUI

// MARK: - Device picker

/// Lists the Cast devices on the network. Picking one starts a session, and the player then sends it the
/// current channel; while connected the sheet shows the device's volume and Stop Casting.
struct CastDevicePicker: View {
    let cast: CastController
    let player: AVPlayerViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The troubleshooting tips show after a few seconds without any device.
    @State private var showsTips = false
    @State private var connectTaps = 0

    var body: some View {
        NavigationStack {
            List {
                if let device = cast.connectedDevice {
                    connectedSection(device)
                }

                if let error = cast.connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.error)
                            .font(.callout)
                    }
                }

                Section {
                    if otherDevices.isEmpty && cast.connectedDevice == nil {
                        searchingRow
                    }
                    ForEach(otherDevices) { device in
                        deviceRow(device)
                    }
                } header: {
                    if !otherDevices.isEmpty || cast.connectedDevice == nil {
                        Text(cast.connectedDevice == nil ? "Devices" : "Other Devices")
                    }
                } footer: {
                    Text("The device plays the channel's own stream. Channels that are raw MPEG-TS streams may not play on Chromecast; they keep playing here.")
                }

                if showsTips && cast.devices.isEmpty {
                    tipsSection
                }
            }
            .navigationTitle("Cast")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .animation(.default, value: cast.devices)
            .animation(.default, value: cast.connection)
        }
        .sensoryFeedback(.selection, trigger: connectTaps)
        .sensoryFeedback(.success, trigger: cast.isConnected) { _, isConnected in
            isConnected
        }
        .onAppear {
            cast.clearConnectionError()
            cast.startDiscovery()
        }
        .task {
            try? await Task.sleep(for: .seconds(6))
            showsTips = true
        }
    }

    private var otherDevices: [CastDevice] {
        cast.devices.filter { $0.id != cast.connectedDevice?.id }
    }

    @ViewBuilder
    private func connectedSection(_ device: CastDevice) -> some View {
        Section {
            HStack(spacing: 14) {
                CastIcon(connection: .connected(device), size: 26)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.14), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                    Text(castingLine)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.vertical, 4)

            CastVolumeControl(cast: cast)

            Button(role: .destructive) {
                cast.disconnect()
                dismiss()
            } label: {
                Label("Stop Casting", systemImage: "stop.circle")
                    // The icon is red like the title (a list row tints it with the accent otherwise).
                    .foregroundStyle(Theme.error)
            }
            .accessibilityIdentifier("cast.stop")
        } header: {
            Text("Connected")
        }
    }

    private var castingLine: String {
        if player.isCasting, let name = player.currentChannel?.name {
            return String(localized: "Playing \(name)")
        }
        return cast.connectedDevice?.model ?? String(localized: "Ready to cast")
    }

    private var searchingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Looking for Cast devices…")
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func deviceRow(_ device: CastDevice) -> some View {
        let isConnecting = cast.connectingDevice?.id == device.id
        return Button {
            connectTaps += 1
            cast.connect(to: device)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: device.systemImage)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .foregroundStyle(.primary)
                    if let model = device.model, model != device.name {
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if isConnecting {
                    ProgressView()
                        .accessibilityLabel("Connecting")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .accessibilityHint(isConnecting ? "" : String(localized: "Plays this channel on \(device.name)"))
    }

    private var tipsSection: some View {
        Section {
            Label("Make sure the Chromecast and this device are on the same Wi-Fi network.", systemImage: "wifi")
            Label("Fluxo needs Local Network access to find Cast devices.", systemImage: "network")
            #if os(iOS)
            Button("Open Settings", systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            #endif
        } header: {
            Text("Can't Find Your Device?")
        }
        .font(.callout)
    }
}

#if os(iOS)
extension View {
    /// Presents the Cast device picker when the cast buttons of the player or the mini player ask for it. With
    /// several windows (iPad) it shows in one window only: the one the cast button was tapped in (see
    /// `WindowCoordinator`). Apply at the root of every window that shows the player or the mini player.
    func castDevicePickerSheet(player: AVPlayerViewModel) -> some View {
        modifier(CastDevicePickerSheet(player: player))
    }

    /// The device picker's sheet. Over the player, which is always dark, it is dark too (as the system's AirPlay
    /// picker is over video), so it never turns a light, low-contrast glass over the video; its background is
    /// opaque so the player does not show through behind the list. On iPad (`isRegularWidth`) it is a form sheet
    /// fitted to a compact height, as a short device list leaves the full height empty.
    func castPickerPresentation(overPlayer: Bool, isRegularWidth: Bool) -> some View {
        modifier(CastPickerPresentation(overPlayer: overPlayer, isRegularWidth: isRegularWidth))
    }
}

private struct CastDevicePickerSheet: ViewModifier {
    let player: AVPlayerViewModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(WindowCoordinator.self) private var coordinator: WindowCoordinator?
    @Environment(\.windowID) private var windowID

    func body(content: Content) -> some View {
        let cast = player.cast
        content
            .windowPresentation(.castPicker, isActive: cast.isPickerPresented)
            .sheet(isPresented: Binding(
                get: { coordinator?.shows(.castPicker, in: windowID, isActive: cast.isPickerPresented) ?? cast.isPickerPresented },
                set: { cast.isPickerPresented = $0 }
            )) {
                CastDevicePicker(cast: cast, player: player)
                    .castPickerPresentation(overPlayer: player.isPresented, isRegularWidth: horizontalSizeClass == .regular)
            }
    }
}

private struct CastPickerPresentation: ViewModifier {
    let overPlayer: Bool
    let isRegularWidth: Bool

    func body(content: Content) -> some View {
        sized(content)
            .presentationBackground(Color(uiColor: .systemGroupedBackground))
            .preferredColorScheme(overPlayer ? .dark : nil)
    }

    @ViewBuilder
    private func sized(_ content: Content) -> some View {
        if isRegularWidth {
            content
                .frame(idealWidth: 540, idealHeight: 640)
                .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        } else {
            content
                .mediumAndLargeDetentsAdaptingToTextSize()
        }
    }
}
#endif

// MARK: - Volume

/// The device volume: a slider between mute and full volume (the volume buttons change it too).
struct CastVolumeControl: View {
    let cast: CastController
    var tint: Color = Theme.accent

    /// The value being dragged, so status updates from the device do not move the knob under the finger.
    @State private var draggedVolume: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                cast.setMuted(!cast.isMuted)
            } label: {
                Image(systemName: cast.isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cast.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { draggedVolume ?? (cast.isMuted ? 0 : cast.volume) },
                    set: { draggedVolume = $0 }
                ),
                in: 0...1
            ) { editing in
                if !editing, let value = draggedVolume {
                    cast.setVolume(value)
                    draggedVolume = nil
                }
            }
            .tint(tint)
            .onChange(of: draggedVolume) { _, value in
                // Live while dragging, in steps of a few percent rather than one request per slider update.
                if let value, abs(value - cast.volume) >= 0.04 {
                    cast.setVolume(value)
                }
            }
            .accessibilityLabel("Volume")

            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 28)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.secondaryText)
    }

    private var volume: Double {
        draggedVolume ?? cast.volume
    }
}

// MARK: - Player backdrop

/// Shown in place of the video while a Chromecast plays the channel: where it plays, the loading state, and the
/// device volume. The player's own controls (play / pause, seeking, channel up / down, stop) drive the receiver.
struct CastingBackdrop: View {
    let viewModel: AVPlayerViewModel

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let cast = viewModel.cast
        ZStack {
            Theme.brandGradient
                .opacity(0.55)
                .ignoresSafeArea()

            if let device = cast.connectedDevice {
                if verticalSizeClass == .compact {
                    // Landscape phones: one line between the top and bottom controls.
                    HStack(spacing: 12) {
                        CastIcon(connection: cast.connection, size: 26)
                        title(device)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                } else {
                    VStack(spacing: 16) {
                        CastIcon(connection: cast.connection, size: 44)
                            .frame(width: 88, height: 88)
                            .glassEffect(.regular.tint(Theme.accent.opacity(0.35)), in: .circle)
                        title(device)
                        CastVolumeControl(cast: cast, tint: .white)
                            .frame(maxWidth: 300)
                    }
                    .padding(24)
                }
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cast.backdrop")
    }

    private func title(_ device: CastDevice) -> some View {
        VStack(spacing: 4) {
            Text("Casting to \(device.name)")
                .font(.headline)
                .multilineTextAlignment(.center)
            if viewModel.playbackState.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                    Text(viewModel.playbackState.label)
                }
                .font(.caption)
                .foregroundStyle(Theme.Player.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewPlayer(connected: Bool) -> AVPlayerViewModel {
    let cast = CastController(backend: SimulatedCastBackend(delay: .milliseconds(10)))
    let player = AVPlayerViewModel(cast: cast)
    if connected {
        cast.connect(to: SimulatedCastBackend.devices[0])
    }
    return player
}

#Preview("Device picker") {
    let player = previewPlayer(connected: false)
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CastDevicePicker(cast: player.cast, player: player)
                #if os(iOS)
                .castPickerPresentation(overPlayer: false, isRegularWidth: false)
                #endif
        }
}

#Preview("Device picker over the player") {
    let player = previewPlayer(connected: true)
    Theme.brandGradient
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            CastDevicePicker(cast: player.cast, player: player)
                #if os(iOS)
                .castPickerPresentation(overPlayer: true, isRegularWidth: false)
                #endif
        }
}

#Preview("Device picker, connected") {
    let player = previewPlayer(connected: true)
    CastDevicePicker(cast: player.cast, player: player)
}

#Preview("Casting backdrop") {
    let player = previewPlayer(connected: true)
    CastingBackdrop(viewModel: player)
        .background(.black)
        .environment(\.colorScheme, .dark)
}
#endif
