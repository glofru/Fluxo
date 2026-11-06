//
//  GuideRefreshFailure.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-03.
//

import Foundation

/// Why the last refresh of a guide source failed, as stored in `EPGSource.lastError`.
///
/// The stored value is a language-independent code ("http.404", "import.notXMLTV"), and the message is built
/// when it is shown: a message saved in the language of the moment would stay in that language after a
/// language change, until the next successful refresh (up to a day later). Only errors without a known kind
/// keep the text of their own description.
enum GuideRefreshFailure {
    case importError(EPGImportError)
    case http(status: Int)
    case damagedFile(zlibCode: Int32)
    case truncatedFile
    case offline
    case timedOut
    case serverNotFound
    case cannotConnect
    case insecureConnection
    /// Any other error: its description at the time it failed.
    case other(String)

    init(_ error: any Error) {
        switch error {
        case let error as EPGImportError:
            self = .importError(error)
        case DownloadError.httpStatus(let status):
            self = .http(status: status)
        case InflatingInputStream.InflateError.zlib(let code):
            self = .damagedFile(zlibCode: code)
        case InflatingInputStream.InflateError.truncated:
            self = .truncatedFile
        case let error as URLError:
            self = Self(urlError: error.code) ?? .other(error.localizedDescription)
        default:
            self = .other(error.localizedDescription)
        }
    }

    private init?(urlError code: URLError.Code) {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cannotFindHost, .dnsLookupFailed:
            self = .serverNotFound
        case .cannotConnectToHost, .networkConnectionLost:
            self = .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .insecureConnection
        default:
            return nil
        }
    }

    // MARK: - Stored form

    private static let textPrefix = "text:"

    /// Reads a stored value. A value saved by an earlier version (a message) is kept as `.other`.
    init(stored value: String) {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        let argument = parts.count == 2 ? parts[1] : nil
        switch (parts.first, argument) {
        case ("import", "sourceNotFound"):
            self = .importError(.sourceNotFound)
        case ("import", "notXMLTV"):
            self = .importError(.notXMLTV)
        case ("import", "incomplete"):
            self = .importError(.incomplete)
        case ("tooLarge", let bytes?) where Int64(bytes) != nil:
            self = .importError(.tooLarge(Int64(bytes)!))
        case ("http", let status?) where Int(status) != nil:
            self = .http(status: Int(status)!)
        case ("zlib", let code?) where Int32(code) != nil:
            self = .damagedFile(zlibCode: Int32(code)!)
        case ("network", "truncated"):
            self = .truncatedFile
        case ("network", "offline"):
            self = .offline
        case ("network", "timedOut"):
            self = .timedOut
        case ("network", "serverNotFound"):
            self = .serverNotFound
        case ("network", "cannotConnect"):
            self = .cannotConnect
        case ("network", "insecure"):
            self = .insecureConnection
        default:
            self = .other(value.hasPrefix(Self.textPrefix) ? String(value.dropFirst(Self.textPrefix.count)) : value)
        }
    }

    /// The value to store in `EPGSource.lastError`.
    var stored: String {
        switch self {
        case .importError(.sourceNotFound):
            return "import.sourceNotFound"
        case .importError(.notXMLTV):
            return "import.notXMLTV"
        case .importError(.incomplete):
            return "import.incomplete"
        case .importError(.tooLarge(let bytes)):
            return "tooLarge.\(bytes)"
        case .http(let status):
            return "http.\(status)"
        case .damagedFile(let code):
            return "zlib.\(code)"
        case .truncatedFile:
            return "network.truncated"
        case .offline:
            return "network.offline"
        case .timedOut:
            return "network.timedOut"
        case .serverNotFound:
            return "network.serverNotFound"
        case .cannotConnect:
            return "network.cannotConnect"
        case .insecureConnection:
            return "network.insecure"
        case .other(let text):
            return Self.textPrefix + text
        }
    }

    // MARK: - Message

    /// The message in the current language.
    var message: String {
        switch self {
        case .importError(let error):
            return error.localizedDescription
        case .http(let status):
            return DownloadError.httpStatus(status).localizedDescription
        case .damagedFile(let code):
            return InflatingInputStream.InflateError.zlib(code).localizedDescription
        case .truncatedFile:
            return InflatingInputStream.InflateError.truncated.localizedDescription
        case .offline:
            return String(localized: "No internet connection.", comment: "Download error (a TV guide or an offline download): the device is offline.")
        case .timedOut:
            return String(localized: "The server took too long to respond.", comment: "Download error (a TV guide or an offline download): the request timed out.")
        case .serverNotFound:
            return String(localized: "The server could not be found. Check the address of the guide.", comment: "TV guide download error: the server name of the guide's address does not exist.")
        case .cannotConnect:
            return String(localized: "Could not connect to the server.", comment: "Download error (a TV guide or an offline download): the server could not be found, did not accept the connection, or the connection was lost.")
        case .insecureConnection:
            return String(localized: "A secure connection to the server could not be made.", comment: "Download error (a TV guide or an offline download): the server's certificate is not valid, or the address needs https.")
        case .other(let text):
            return text
        }
    }
}

extension EPGSource {
    /// The message of the last failed refresh, in the current language; nil after a successful one.
    var lastErrorMessage: String? {
        lastError.map { GuideRefreshFailure(stored: $0).message }
    }
}

