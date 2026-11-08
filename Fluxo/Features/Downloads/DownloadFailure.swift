//
//  DownloadFailure.swift
//  Fluxo
//
//  Why a download failed or could not start, as the manifest stores it (a code, not a message) and as the Library
//  says it (a sentence in the current language, never a bare system error such as "unknown error").
//

import Foundation

/// Why a download failed or could not start.
///
/// A failed download keeps its `reason` (in the manifest), not a message: the message is built when it is shown,
/// in the current language, so it follows a language change. Only errors without a known kind keep the text of
/// their own description, as `GuideRefreshFailure` does.
struct DownloadFailure: Error, Sendable {

    enum Reason: Codable, Hashable, Sendable {
        /// The server answered with an error status.
        case http(status: Int)
        /// The server returned a web page or something else that is not a video.
        case notVideo
        /// The remux engine can neither copy nor convert the file; its message (in English, from
        /// fluxo_remux_convert_file), when it gave one.
        case unsupportedFormat(engineMessage: String?)
        case insufficientSpace
        /// The downloaded HLS stream cannot be played offline.
        case incomplete
        /// AVFoundation could not download the HLS stream.
        case streamUnavailable
        /// No connection, a timeout, a server that cannot be reached, a certificate that is not valid.
        case network(NetworkKind)
        /// The server's answer could not be used (a broken or empty response, content that cannot be decoded).
        case badResponse
        /// The file could not be written on the device (other than a full disk).
        case storage
        /// An error that says nothing useful (`NSURLErrorUnknown`, "unknown error"): the Library says the download
        /// stopped unexpectedly.
        case unexpected
        /// Any other error: its description at the time it failed.
        case other(String)
    }

    enum NetworkKind: String, Codable, Sendable {
        case offline
        case timedOut
        case cannotConnect
        case insecureConnection
    }

    let reason: Reason
    /// Retrying the same link cannot help.
    var isPermanent = false
    /// A network problem (a timeout, a dropped connection, no route): retried automatically, and again when the
    /// network returns.
    var isNetworkError = false

    /// The HTTP status, when the server answered with an error.
    var httpStatus: Int? {
        if case .http(let status) = reason {
            return status
        }
        return nil
    }

    /// The link was refused or is gone (expired credentials or token, an entry the provider removed): a newer copy
    /// of the playlist may have another link for the same entry.
    var isExpiredLink: Bool {
        guard let httpStatus else {
            return false
        }
        return [401, 403, 404, 410].contains(httpStatus)
    }

    /// The message in the current language.
    var message: String {
        reason.message
    }

    static func http(_ status: Int) -> DownloadFailure {
        DownloadFailure(reason: .http(status: status))
    }

    static var notVideo: DownloadFailure {
        DownloadFailure(reason: .notVideo, isPermanent: true)
    }

    static func unsupportedFormat(engineMessage: String? = nil) -> DownloadFailure {
        DownloadFailure(reason: .unsupportedFormat(engineMessage: engineMessage?.isEmpty == false ? engineMessage : nil), isPermanent: true)
    }

    static var insufficientSpace: DownloadFailure {
        DownloadFailure(reason: .insufficientSpace)
    }

    static var incomplete: DownloadFailure {
        DownloadFailure(reason: .incomplete)
    }

    static var streamUnavailable: DownloadFailure {
        DownloadFailure(reason: .streamUnavailable)
    }

    /// A network or other system error: by its kind when it has a known one, otherwise by its description.
    static func network(_ error: any Error) -> DownloadFailure {
        DownloadFailure(reason: Reason(classifying: error), isNetworkError: DownloadTransport.isNetworkError(error))
    }

    /// Any other error, by its kind when it has one, otherwise by its description.
    static func other(_ error: any Error) -> DownloadFailure {
        DownloadFailure(reason: Reason(classifying: error))
    }
}

extension DownloadFailure.Reason {
    /// The reason of a system error: the URL error (also when AVFoundation wraps it), a file error, or its text when
    /// it says something.
    init(classifying error: any Error) {
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let nsError = current else {
                break
            }
            if nsError.domain == NSURLErrorDomain {
                let code = URLError.Code(rawValue: nsError.code)
                if let kind = DownloadFailure.NetworkKind(code) {
                    self = .network(kind)
                    return
                }
                switch code {
                case .badServerResponse, .zeroByteResource, .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse,
                     .resourceUnavailable, .redirectToNonExistentLocation, .httpTooManyRedirects, .badURL, .unsupportedURL:
                    self = .badResponse
                    return
                case .cannotCreateFile, .cannotOpenFile, .cannotWriteToFile, .cannotMoveFile, .cannotRemoveFile, .cannotCloseFile:
                    self = .storage
                    return
                case .unknown:
                    self = .unexpected
                    return
                default:
                    break
                }
            }
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError) || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
                self = .insufficientSpace
                return
            }
            if nsError.domain == NSCocoaErrorDomain, (NSFileWriteUnknownError...NSFileWriteVolumeReadOnlyError).contains(nsError.code) {
                self = .storage
                return
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let text = error.localizedDescription
        let nsError = error as NSError
        // Foundation's own description of an error that has none ("The operation couldn’t be completed. (Domain
        // error 3.)", in the current language): it names the error's domain and code, which no real message does.
        let isGeneric = Self.lastParenthesized(text).map { $0.contains(nsError.domain) && $0.contains(String(nsError.code)) } ?? false
        self = isGeneric || Self.isUninformative(text) ? .unexpected : .other(text)
    }

    /// A description that tells the viewer nothing: "unknown error", "The operation couldn’t be completed. (… error
    /// -1.)", in any language for that one (it ends with a domain and a code). Also for the texts earlier builds
    /// stored.
    static func isUninformative(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.isEmpty
            || lowered.contains("unknown error")
            || lowered.contains("error -1.)")
            || lowered.contains("(null)")
            || lowered.hasPrefix("the operation couldn’t be completed")
            || lowered.hasPrefix("the operation couldn't be completed")
            || lastParenthesized(text).map(namesErrorDomainAndCode) == true
    }

    /// The last part of a text in parentheses, when the text ends with it.
    private static func lastParenthesized(_ text: String) -> Substring? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.last == ")" || trimmed.last == "）", let open = trimmed.lastIndex(where: { $0 == "(" || $0 == "（" }) else {
            return nil
        }
        return trimmed[open...]
    }

    /// The end of Foundation's description of an error without one, in every language: only an error domain, the
    /// word for "error" before or after it, and a code, such as "(NSURLErrorDomain error -1.)", "(Errore
    /// NSURLErrorDomain -1.)", "(AVFoundationErrorDomainエラー-11800)", "(Fluxo.DownloadError error 2.)". A domain is
    /// an "…ErrorDomain" name, an Apple "com.apple.…" one, or a Swift error type ("Module.Type", each part capitalized),
    /// so a server's own text such as "(host example.com, status 500)" or "(server example.com 500)" stays.
    private static func namesErrorDomainAndCode(_ part: Substring) -> Bool {
        part.wholeMatch(of: /[(（]\s*(?:[\p{L}\p{M}]+[:.]?\s*(?:[A-Za-z]+ErrorDomain|com\.apple\.[A-Za-z0-9_.]+|[A-Z_][A-Za-z0-9_]*(?:\.[A-Z_][A-Za-z0-9_]*)+)|(?:[A-Za-z]+ErrorDomain|com\.apple\.[A-Za-z0-9_.]+|[A-Z_][A-Za-z0-9_]*(?:\.[A-Z_][A-Za-z0-9_]*)+)\s*[\p{L}\p{M}]+[:.]?)\s*[-−]?[0-9]+\s*[.。]?\s*[)）]/) != nil
    }
}

extension DownloadFailure.NetworkKind {
    init?(_ code: URLError.Code) {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost:
            self = .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .insecureConnection
        default:
            return nil
        }
    }
}

extension DownloadFailure.Reason {
    /// The message in the current language.
    var message: String {
        switch self {
        case .http(let status):
            switch status {
            case 401, 403:
                return String(localized: "The provider refused the download. The link may have expired: refresh the playlist and try again.", comment: "Download error: the server answered 401 or 403.")
            case 404, 410:
                return String(localized: "The provider no longer has this video. Refresh the playlist and try again.", comment: "Download error: the server answered 404 or 410.")
            case 429:
                return String(localized: "The provider limits downloads right now. Try again later.", comment: "Download error: the server answered 429 (too many requests).")
            default:
                return DownloadError.httpStatus(status).localizedDescription
            }
        case .notVideo:
            return String(localized: "This link doesn't lead to a video that can be downloaded.", comment: "Download error: the server returned a web page or something else that is not a video.")
        case .unsupportedFormat(let engineMessage):
            let message = String(localized: "This video format can't be played on this device, so it isn't downloaded.", comment: "Download error: the file is in a format the app can neither play nor convert (such as an unknown video codec).")
            guard let engineMessage else {
                return message
            }
            // The engine named the codec: its sentence says it all ("This video can't be played: its video format
            // (vp9) isn't supported."). Otherwise its technical detail follows, isolated so that its Latin text
            // and colons keep their order in a right-to-left sentence.
            if let sentence = EngineMessage.formatSentence(engineMessage) {
                return sentence
            }
            let detail = TextParts.isolated(EngineMessage.localized(engineMessage))
            return String(
                localized: "DownloadFailure.withDetail",
                defaultValue: "\(message) (\(detail))",
                comment: "Download error: the reason a video can't be downloaded, then in parentheses the technical detail from the converter (often in English, such as 'Unable to open the stream: Invalid data found when processing input'). Use the parentheses and spacing of your language."
            )
        case .insufficientSpace:
            return String(localized: "There isn't enough free space on this device for this download.", comment: "Download error: the device does not have enough free storage.")
        case .incomplete:
            return String(localized: "The download is incomplete. Try again.", comment: "Download error: the downloaded stream cannot be played offline.")
        case .streamUnavailable:
            // AVFoundation's own description is often only "unknown error": say what it means here.
            return String(localized: "This stream can't be saved for offline viewing right now. Try again later.", comment: "Download error: the system could not download an HLS stream for offline playback (an AVFoundation error).")
        case .network(.offline):
            return String(localized: "No internet connection.", comment: "Download error (a TV guide or an offline download): the device is offline.")
        case .network(.timedOut):
            return String(localized: "The server took too long to respond.", comment: "Download error (a TV guide or an offline download): the request timed out.")
        case .network(.cannotConnect):
            return String(localized: "Could not connect to the server.", comment: "Download error (a TV guide or an offline download): the server could not be found, did not accept the connection, or the connection was lost.")
        case .network(.insecureConnection):
            return String(localized: "A secure connection to the server could not be made.", comment: "Download error (a TV guide or an offline download): the server's certificate is not valid, or the address needs https.")
        case .badResponse:
            return String(localized: "The provider sent something that can't be downloaded. Try again later.", comment: "Download error: the server's response was broken, empty or could not be decoded.")
        case .storage:
            return String(localized: "The download couldn't be saved on this device. Try again.", comment: "Download error: the file could not be written on the device (not because the disk is full).")
        case .unexpected:
            return Self.unexpectedMessage
        case .other(let text):
            // Downloads that failed in earlier builds kept "unknown error" and the like.
            return Self.isUninformative(text) ? Self.unexpectedMessage : text
        }
    }
}

extension DownloadFailure.Reason {
    static var unexpectedMessage: String {
        String(localized: "The download stopped unexpectedly. Try again.", comment: "Download error: the system reported an error without a useful description.")
    }
}
