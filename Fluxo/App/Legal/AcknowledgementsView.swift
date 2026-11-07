//
//  AcknowledgementsView.swift
//  Fluxo
//
//  Settings › About › Acknowledgements, on every platform: Fluxo's own license (MIT) and source code, the software
//  it includes with each license and its full text (the Google Cast SDK also with the open-source software inside it
//  and Google's notice of each part, on iPhone and iPad), and the source offer of FFmpeg, which the LGPL requires
//  (section 6): where to get the exact source and build script of the FFmpeg in this build, and that FFmpeg is a
//  separate library that can be replaced. Pushed in Settings on iPhone, iPad and Apple TV; a sheet in the Mac's
//  Settings window. On Apple TV every line takes the focus (the remote walks through the page, VoiceOver reads each
//  line), and addresses come with a QR code to open them on a phone, since Apple TV has no browser.
//
//  License texts stay in English, the language they are written in; everything else is in the String Catalog.
//

import SwiftUI

struct AcknowledgementsView: View {

    /// Presented as a sheet (with Done), or pushed.
    var isModal = false
    /// What the page opens at once (the debug harness's `acknowledgements:<id>`): a component's page (`ffmpeg`), a
    /// part of a component (`googlecast/eigen-3`), or the FFmpeg source offer (`source-offer`, or its checksum:
    /// `source-offer-sha`).
    var initialComponentID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var openComponent: OpenSourceComponent?
    /// The part of `openComponent` its page opens at once (`googlecast/<part>`).
    @State private var openPartID: String?
    /// `initialComponentID` was opened (once: not again when the user comes back to this page).
    @State private var didOpenInitial = false

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear {
                    if !didOpenInitial {
                        didOpenInitial = true
                        show(initialComponentID, proxy: proxy)
                    }
                }
                #if DEBUG
                // The harness again while the page is open (a second `acknowledgements:<id>` step): the first one
                // came through `initialComponentID`, which `onAppear` doesn't see change.
                .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugAcknowledgements)) { notification in
                    Task {
                        // Back to this page first, so the next one is pushed as the row pushes it.
                        openComponent = nil
                        try? await Task.sleep(for: .milliseconds(600))
                        show(notification.object as? String, proxy: proxy)
                    }
                }
                #endif
        }
    }

    /// Opens what `initialComponentID` names.
    private func show(_ target: String?, proxy: ScrollViewProxy) {
        guard let target else {
            return
        }
        if target == "source-offer" || target == "source-offer-sha" {
            // The FFmpeg source offer, at the end of the page (or its checksum, for large text sizes).
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(target, anchor: .top)
            }
            return
        }
        let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
        openPartID = parts.count > 1 ? parts[1] : nil
        openComponent = ([.fluxo] + OpenSourceComponent.thirdParty).first { $0.id == parts.first }
    }

    private var form: some View {
        Form {
            Section {
                Text("Fluxo is free and open-source software, released under the MIT License. You can read, build and change its code.", comment: "Settings › Acknowledgements: the first line, about the app's own license.")
                    .readableWithRemote(debugName: "legal-fluxo")
                LegalLinkRow(title: Text("Source Code", comment: "Settings › About and Acknowledgements: link to the app's source code on GitHub."), url: LegalLinks.sourceCode, systemImage: "chevron.left.forwardslash.chevron.right")
                componentLink(.fluxo, title: Text(verbatim: OpenSourceComponent.License.mit.name))
            } header: {
                Text(verbatim: "Fluxo")
            }

            Section {
                Text(ContentNotice.text)
                    .readableWithRemote(debugName: "legal-content")
            } header: {
                Text("Content", comment: "Settings › Acknowledgements: header of the notice that the app provides no channels or content.")
            }

            Section {
                ForEach(OpenSourceComponent.thirdParty) { component in
                    componentLink(component, title: Text(verbatim: component.name), subtitle: Text(verbatim: component.license.name))
                }
            } header: {
                Text("Third-Party Software", comment: "Settings › Acknowledgements: header of the list of the libraries the app includes.")
            } footer: {
                Text("License texts are shown in English, the language they are written in.", comment: "Settings › Acknowledgements: footer of the list of libraries; the license texts are not translated.")
            }

            FFmpegSourceOfferSection()
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Acknowledgements", comment: "Title of Settings › About › Acknowledgements (licenses of the app and of the software it includes)."))
        .largeTitleAdaptingToTextSize()
        .navigationDestination(item: $openComponent) { component in
            OpenSourceComponentView(component: component, initialPartID: openPartID)
        }
        .toolbar {
            if isModal {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                }
            }
        }
    }

    private func componentLink(_ component: OpenSourceComponent, title: Text, subtitle: Text? = nil) -> some View {
        LegalDisclosureRow(title: title, subtitle: subtitle) {
            openPartID = nil
            openComponent = component
        }
    }
}

/// A row that opens a page (a component, a part of one): its name, a line under it, and a chevron.
struct LegalDisclosureRow: View {
    let title: Text
    var subtitle: Text?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .foregroundStyle(.primary)
                    if let subtitle {
                        subtitle
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                #if !os(tvOS)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                #endif
            }
            .contentShape(.rect)
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
    }
}

/// The source offer of the LGPL for FFmpeg.
private struct FFmpegSourceOfferSection: View {
    var body: some View {
        Section {
            Text("FFmpeg \(OpenSourceComponent.ffmpegVersion) is licensed under the GNU Lesser General Public License, version 2.1 or later. Its complete source code, the exact release this build is made from, and the script that builds it are published with Fluxo's source code, and stay available for at least three years after the last release that includes them.", comment: "Settings › Acknowledgements: the FFmpeg source offer of the LGPL. The placeholder is the FFmpeg version (9.0.2).")
                .readableWithRemote(debugName: "legal-ffmpeg-offer")
                // A row (not the section) is what a list can scroll to (`acknowledgements:source-offer`).
                .id("source-offer")
            VStack(alignment: .leading, spacing: 4) {
                // The file name on one line (a word that wrapping would break), smaller if it must be.
                Text(verbatim: "ffmpeg-\(OpenSourceComponent.ffmpegVersion).tar.xz")
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: "SHA-256")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                // In groups of eight, so the lines break only between groups: a 64-character word would be broken
                // anywhere, with hyphens that aren't part of the checksum. Copy gives the plain value.
                Text(verbatim: Self.groupedSHA256)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel(Text(verbatim: OpenSourceComponent.ffmpegTarballSHA256))
            }
            .accessibilityElement(children: .combine)
            .readableWithRemote(debugName: "legal-ffmpeg-sha")
            .id("source-offer-sha")
            #if !os(tvOS)
            .contextMenu {
                Button {
                    Self.copy(OpenSourceComponent.ffmpegTarballSHA256)
                } label: {
                    Label {
                        Text("Copy SHA-256", comment: "Settings › Acknowledgements, FFmpeg source offer: context menu item that copies the checksum of the FFmpeg source tarball.")
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            #endif
            LegalLinkRow(title: Text("FFmpeg Source Code", comment: "Settings › Acknowledgements: link to the FFmpeg source tarball in the app's repository."), url: LegalLinks.ffmpegSource, systemImage: "shippingbox")
            LegalLinkRow(title: Text("FFmpeg Build Script", comment: "Settings › Acknowledgements: link to the script that builds FFmpeg for the app."), url: LegalLinks.ffmpegBuildScript, systemImage: "hammer")
            Text("FFmpeg is a separate library inside the app (FFmpeg.framework), which can be replaced with a modified build of it. Fluxo's terms of use don't apply to FFmpeg: it is licensed to you under the LGPL alone, which also allows changing it and reverse engineering for debugging such changes.", comment: "Settings › Acknowledgements: the LGPL notice that FFmpeg is a replaceable library and that the app's terms (EULA) don't restrict it.")
                .readableWithRemote(debugName: "legal-ffmpeg-relink")
        } header: {
            Text("FFmpeg Source Code", comment: "Settings › Acknowledgements: header of the FFmpeg source offer.")
        }
    }

    /// "8c385028 3eb25fa0 …": the SHA-256 in eight groups of eight.
    static var groupedSHA256: String {
        let hash = Array(OpenSourceComponent.ffmpegTarballSHA256)
        return stride(from: 0, to: hash.count, by: 8)
            .map { String(hash[$0 ..< min($0 + 8, hash.count)]) }
            .joined(separator: " ")
    }

    #if !os(tvOS)
    private static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
    #endif
}

/// One component: what it is, its license, the full texts of its license and notices, and the open-source software
/// inside it (the Google Cast SDK's parts), each with its own page.
struct OpenSourceComponentView: View {
    let component: OpenSourceComponent
    /// A part whose page opens at once (the harness's `acknowledgements:googlecast/<part>`).
    var initialPartID: String?

    @State private var parts: [IncludedSoftware] = []
    @State private var openPart: IncludedSoftware?
    /// The `initialPartID` already opened.
    @State private var openedPartID: String?

    var body: some View {
        Form {
            Section {
                Text(component.purpose)
                    .readableWithRemote()
                if !component.version.isEmpty {
                    LabeledContent {
                        Text(verbatim: component.version)
                            .monospacedDigit()
                    } label: {
                        Text("Version", comment: "Settings › Acknowledgements, a library's page: its version.")
                    }
                    .readableWithRemote()
                }
                // The license's name is long ("GNU Lesser General Public License v2.1 or later"): under its label.
                VStack(alignment: .leading, spacing: 4) {
                    Text("License", comment: "Settings › Acknowledgements, a library's page: the name of its license.")
                    Text(verbatim: component.license.name)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .readableWithRemote()
                Text(verbatim: component.copyright)
                    .foregroundStyle(Theme.secondaryText)
                    .readableWithRemote()
                LegalLinkRow(title: Text("Website", comment: "Settings › Acknowledgements, a library's page: link to its website."), url: component.homepage, systemImage: "safari")
                LegalLinkRow(title: Text("License on the Web", comment: "Settings › Acknowledgements, a library's page: link to its license or terms on the web."), url: component.licenseURL, systemImage: "doc.text")
            }

            if !parts.isEmpty {
                Section {
                    ForEach(parts) { part in
                        LegalDisclosureRow(title: Text(verbatim: part.name), subtitle: Text(verbatim: part.license)) {
                            openPart = part
                        }
                    }
                } header: {
                    Text("Open-Source Software in \(component.name)", comment: "Settings › Acknowledgements, the Google Cast SDK's page: header of the list of the open-source software inside the SDK. The placeholder is the SDK's name (Google Cast SDK).")
                } footer: {
                    Text("Each with the notice shipped with the \(component.name).", comment: "Settings › Acknowledgements, the Google Cast SDK's page: footer of the list of the open-source software inside the SDK; each row opens the part's license notice. The placeholder is the SDK's name (Google Cast SDK).")
                }
            }

            ForEach(component.texts, id: \.self) { bundled in
                if let text = bundled.text {
                    LicenseTextSection(title: bundled.title, text: text)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: component.name))
        .largeTitleAdaptingToTextSize()
        .navigationDestination(item: $openPart) { part in
            IncludedSoftwareView(part: part, component: component)
        }
        .task(id: initialPartID) {
            if parts.isEmpty {
                parts = component.includedSoftware
            }
            // The harness's part, once (not again when the user comes back to this page).
            guard let initialPartID, openedPartID != initialPartID,
                  let part = parts.first(where: { $0.id == initialPartID }) else {
                return
            }
            // After this page's own push: a push asked for during it is dropped.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else {
                return
            }
            openedPartID = initialPartID
            openPart = part
        }
    }
}

/// A part of a component (Abseil in the Google Cast SDK): its notice, as the component's vendor ships it.
private struct IncludedSoftwareView: View {
    let part: IncludedSoftware
    let component: OpenSourceComponent

    var body: some View {
        Form {
            Section {
                Text("Part of the \(component.name). Its notice, as shipped with the \(component.name), follows.", comment: "Settings › Acknowledgements, the page of a part of the Google Cast SDK (such as Abseil): the first line. Both placeholders are the SDK's name (Google Cast SDK).")
                    .readableWithRemote()
                VStack(alignment: .leading, spacing: 4) {
                    Text("License", comment: "Settings › Acknowledgements, a library's page: the name of its license.")
                    Text(verbatim: part.license)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .readableWithRemote()
            }
            LicenseTextSection(title: part.name, text: part.text)
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: part.name))
        .largeTitleAdaptingToTextSize()
    }
}

/// The full text of a license or notice, in English (the language it is written in), laid out to flow at any width.
struct LicenseTextSection: View {
    let title: String
    let text: String

    var body: some View {
        Section {
            #if os(tvOS)
            // One focusable line per paragraph, so the remote scrolls through the text.
            ForEach(Array(LicenseText.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                Text(verbatim: paragraph)
                    .font(.caption)
                    .readableWithRemote()
            }
            #else
            // A few blocks of paragraphs, each selectable: the form lays out only the rows on screen, and the longest
            // notices (Eigen's, 66 KB) stay quick to open.
            ForEach(Array(Self.blocks(LicenseText.paragraphs(text)).enumerated()), id: \.offset) { _, block in
                Text(verbatim: block)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .listRowSeparator(.hidden)
            }
            #endif
        } header: {
            Text(verbatim: title)
        }
    }

    /// The paragraphs, joined into blocks of about 4,000 characters.
    private static func blocks(_ paragraphs: [String]) -> [String] {
        var blocks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if !current.isEmpty, current.count + paragraph.count > 4_000 {
                blocks.append(current)
                current = ""
            }
            current += current.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !current.isEmpty {
            blocks.append(current)
        }
        return blocks
    }
}

/// A web address: a link on iPhone, iPad and Mac; on Apple TV, which has no browser, the address and a QR code to
/// open it on a phone.
struct LegalLinkRow: View {
    let title: Text
    let url: URL
    let systemImage: String

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 30) {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    Text(verbatim: url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            } icon: {
                // One width for every symbol, so the titles of the rows line up.
                Image(systemName: systemImage)
                    .frame(width: 48)
            }
            Spacer(minLength: 0)
            QRCodeImage(url: url)
                .frame(width: 140, height: 140)
        }
        .readableWithRemote()
        .accessibilityElement(children: .combine)
        #else
        // As the system's Settings shows a link that leaves the app: a primary title and an arrow, like the rows that
        // open a page here.
        Link(destination: url) {
            HStack {
                Label {
                    title
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 8)
                ExternalLinkArrow()
            }
            .contentShape(.rect)
        }
        // The list tints a link's label with the accent color, over its own foreground style.
        .tint(.primary)
        .help(url.absoluteString)
        #endif
    }
}

/// The arrow at the end of a row that opens a web page (Privacy Policy, Source Code).
struct ExternalLinkArrow: View {
    var body: some View {
        Image(systemName: "arrow.up.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.tertiaryText)
            .accessibilityHidden(true)
    }
}

#if os(tvOS)
import CoreImage.CIFilterBuiltins

/// A QR code of an address, black on a white tile.
private struct QRCodeImage: View {
    let url: URL

    var body: some View {
        if let image = Self.image(for: url) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        return CIContext().createCGImage(code, from: code.extent)
    }
}
#endif

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
