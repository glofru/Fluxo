//
//  LegalInfo.swift
//  Fluxo
//
//  What Settings › About says about where content comes from, the licenses of Fluxo and of the software it
//  includes, the FFmpeg source offer and the privacy policy. Everything a user, App Review or a distributor needs to
//  check, in one place: the screens (`AcknowledgementsView`, the notices in Home and Add Playlist) read it from here.
//
//  The versions are checked against Fluxo.xcodeproj's Package.resolved and Vendor/FFmpeg/BUILD_INFO.txt by
//  Tools/Legal/check-acknowledgements.sh, so a package update cannot leave this list behind.
//

import Foundation

extension URL {
    /// A web address written in the source. The literals are valid URLs; the fallback only keeps the type
    /// non-optional (no force unwrap).
    fileprivate static func legal(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}

enum LegalLinks {
    /// Fluxo's source code (MIT License).
    static let sourceCode = URL.legal("https://github.com/glofru/Fluxo")
    /// The privacy policy (docs/privacy.md, also published with GitHub Pages).
    static let privacyPolicy = URL.legal("https://github.com/glofru/Fluxo/blob/main/docs/privacy.md")
    /// The FFmpeg source offer: the folder with the release tarball the framework is built from
    /// (`source/ffmpeg-<version>.tar.xz`), its license and BUILD_INFO.txt.
    static let ffmpegSource = URL.legal("https://github.com/glofru/Fluxo/tree/main/Vendor/FFmpeg")
    /// The script that builds FFmpeg.framework from that tarball.
    static let ffmpegBuildScript = URL.legal("https://github.com/glofru/Fluxo/blob/main/Tools/FFmpeg/build-xcframework.sh")
}

/// "Fluxo provides no content": the app is a player for playlists the user adds. Shown on the first-run screen, in
/// Add Playlist and in Settings › About.
enum ContentNotice {
    static var text: String {
        String(localized: "Fluxo doesn't provide any channels or content. Add only playlists from providers you subscribe to or have the right to use.", comment: "Notice on the first-run screen, in Add Playlist and in Settings › About: the app is only a player and comes with no channels, movies or series.")
    }
}

/// A playlist of free, legal content to try the app with (docs/demo/fluxo-demo.m3u in the repository): a live test
/// stream, Apple's HLS example and three Creative Commons films of the Blender Foundation, from their own servers.
enum DemoPlaylist {
    static let url = URL.legal("https://raw.githubusercontent.com/glofru/Fluxo/main/docs/demo/fluxo-demo.m3u")

    static var name: String {
        String(localized: "Fluxo Demo", comment: "Name of the demo playlist that the first-run screen and Add Playlist offer (free test streams and Creative Commons films).")
    }
}

/// One piece of software Fluxo includes, with its license.
struct OpenSourceComponent: Identifiable, Hashable {

    enum License: Hashable {
        case mit
        case apache2
        case lgpl21OrLater
        /// Proprietary terms of the vendor, published at `url`.
        case terms(String)

        /// The license's own name (never translated: it is the legal title).
        var name: String {
            switch self {
            case .mit:
                return "MIT License"
            case .apache2:
                return "Apache License 2.0"
            case .lgpl21OrLater:
                return "GNU Lesser General Public License v2.1 or later"
            case .terms(let name):
                return name
            }
        }
    }

    let id: String
    let name: String
    let version: String
    let copyright: String
    let license: License
    /// What it does in Fluxo.
    let purpose: String
    let homepage: URL
    /// Where the license or the terms are published.
    let licenseURL: URL
    /// The full texts the page shows: the license, and the other notices the component asks to reproduce.
    var texts: [BundledText] = []
    /// The notices of the open-source software inside the component, as its vendor ships them
    /// (`<name>.json` in Licenses, see `IncludedSoftware`).
    var includedSoftwareResource: String?

    /// The open-source software inside the component, with its notices (none when it has no such list).
    var includedSoftware: [IncludedSoftware] {
        includedSoftwareResource.map(IncludedSoftware.load) ?? []
    }

    // MARK: - The components

    /// The version, SHA-256 and license of FFmpeg come from the build (Vendor/FFmpeg/BUILD_INFO.txt).
    static let ffmpegVersion = "9.0.2"
    static let ffmpegTarballSHA256 = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

    static let fluxo = OpenSourceComponent(
        id: "fluxo",
        name: "Fluxo",
        version: "",
        copyright: "Copyright (c) 2026 Gianluca Lofrumento",
        license: .mit,
        purpose: String(localized: "The app itself. Its source code is open: you can read, build and change it.", comment: "Settings › Acknowledgements: what the Fluxo entry is (the app's own open-source code)."),
        homepage: LegalLinks.sourceCode,
        licenseURL: URL.legal("https://github.com/glofru/Fluxo/blob/main/LICENSE"),
        texts: [BundledText(title: License.mit.name, resource: "License-Fluxo-MIT")]
    )

    static let ffmpeg = OpenSourceComponent(
        id: "ffmpeg",
        name: "FFmpeg",
        version: ffmpegVersion,
        copyright: "Copyright (c) the FFmpeg developers",
        license: .lgpl21OrLater,
        purpose: String(localized: "Opens, converts and records the streams the system player can't play directly. Fluxo uses the libavformat, libavcodec, libavutil, libswscale and libswresample libraries, built without any GPL or non-free part.", comment: "Settings › Acknowledgements: what FFmpeg does in Fluxo. Keep the library names as they are."),
        homepage: URL.legal("https://ffmpeg.org"),
        licenseURL: URL.legal("https://ffmpeg.org/legal.html"),
        texts: [
            BundledText(title: "GNU Lesser General Public License v2.1", resource: "License-LGPL-2.1"),
            // FFmpeg's own overview (LICENSE.md of the tarball): which parts are under which license. Its title is the
            // app's description of it, so it is translated.
            BundledText(title: String(localized: "FFmpeg License Overview (LICENSE.md)", comment: "Settings › Acknowledgements, FFmpeg page: header of FFmpeg's own summary of which parts of it are under which license (its file LICENSE.md, shown in English below). Keep FFmpeg and LICENSE.md as they are."), resource: "License-FFmpeg-Overview"),
            // The DCT code from libjpeg (jrevdct.c, jfdctfst.c, jfdctint_template.c), which the MPEG-4, MPEG-2,
            // WMV and MJPEG decoders of this build use: its license asks binaries to credit the IJG.
            BundledText(title: "Independent JPEG Group", resource: "License-IJG"),
        ]
    )

    static let flyingFox = OpenSourceComponent(
        id: "flyingfox",
        name: "FlyingFox",
        version: "0.24.1",
        copyright: "Copyright (c) 2022 Simon Whitty",
        license: .mit,
        purpose: String(localized: "The small web server, reachable only from this device, that gives converted streams to the system player.", comment: "Settings › Acknowledgements: what FlyingFox (an HTTP server library) does in Fluxo: the loopback server of the player."),
        homepage: URL.legal("https://github.com/swhitty/FlyingFox"),
        licenseURL: URL.legal("https://github.com/swhitty/FlyingFox/blob/main/LICENSE"),
        texts: [BundledText(title: License.mit.name, resource: "License-FlyingFox-MIT")]
    )

    static let googleCast = OpenSourceComponent(
        id: "googlecast",
        name: "Google Cast SDK",
        version: "4.8.6",
        copyright: "Copyright (c) Google LLC",
        license: .terms("Google Cast SDK Terms of Service"),
        purpose: String(localized: "Plays channels on Chromecast and other Google Cast devices. The SDK, including the Google Sans fonts it contains, is licensed under the Google Cast SDK Terms of Service. It also contains open-source software, listed below with the notices Google ships with the SDK.", comment: "Settings › Acknowledgements: what the Google Cast SDK does in Fluxo and how it is licensed. A list of the open-source software inside it follows. iPhone and iPad only."),
        homepage: URL.legal("https://developers.google.com/cast"),
        licenseURL: URL.legal("https://developers.google.com/cast/docs/terms"),
        // Copied from the SDK's OpenSourceLicenses by Tools/Legal/extract-googlecast-licenses.sh.
        includedSoftwareResource: "GoogleCast-OSS"
    )

    /// The copy inside GoogleCast.framework (the app links no other, see Vendor/GoogleCast/Package.swift): it has no
    /// version of its own.
    static let gtmSessionFetcher = OpenSourceComponent(
        id: "gtmsessionfetcher",
        name: "GTMSessionFetcher",
        version: "",
        copyright: "Copyright (c) Google LLC",
        license: .apache2,
        purpose: String(localized: "A networking library the Google Cast SDK uses.", comment: "Settings › Acknowledgements: what GTMSessionFetcher does in Fluxo (a dependency of the Google Cast SDK)."),
        homepage: URL.legal("https://github.com/google/gtm-session-fetcher"),
        licenseURL: URL.legal("https://github.com/google/gtm-session-fetcher/blob/main/LICENSE"),
        texts: [BundledText(title: License.apache2.name, resource: "License-Apache-2.0")]
    )

    /// The third-party software in this build (the Cast SDK and its fetcher only on iPhone and iPad).
    static var thirdParty: [OpenSourceComponent] {
        #if os(iOS)
        [ffmpeg, flyingFox, googleCast, gtmSessionFetcher]
        #else
        [ffmpeg, flyingFox]
        #endif
    }
}

/// A text file of Licenses in the app bundle (`<resource>.txt`), shown in full under `title`: a legal title, never
/// translated ("GNU Lesser General Public License v2.1"), or the app's own description of the text, translated.
struct BundledText: Hashable {
    let title: String
    let resource: String

    /// The text, from the app bundle.
    var text: String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A piece of open-source software inside a component, with its notice as the component's vendor ships it: the
/// Google Cast SDK lists about twenty (Abseil, gRPC, Protocol Buffers, Eigen, Material Components for iOS…) in its
/// OpenSourceLicenses folder. Tools/Legal/extract-googlecast-licenses.sh copies them to Licenses/GoogleCast-OSS.json,
/// bundled on iPhone and iPad only (the platforms with the SDK); Tools/Legal/check-acknowledgements.sh checks the file
/// against the SDK of Package.resolved.
struct IncludedSoftware: Identifiable, Hashable {
    /// The name in Google's list ("Material Components for iOS"), never translated.
    let name: String
    /// The license, or licenses, its text holds ("Apache License 2.0").
    let license: String
    let text: String

    /// A stable name for the debug harness (`acknowledgements:googlecast/eigen-3`).
    var id: String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private struct File: Decodable {
        struct Component: Decodable {
            let name: String
            let license: String
            let text: Int
        }

        let components: [Component]
        let texts: [String]
    }

    /// The list in `<resource>.json`, in its order (by name); empty when the file isn't in this build.
    static func load(_ resource: String) -> [IncludedSoftware] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.components.compactMap { component in
            file.texts.indices.contains(component.text)
                ? IncludedSoftware(name: component.name, license: component.license, text: file.texts[component.text])
                : nil
        }
    }
}
