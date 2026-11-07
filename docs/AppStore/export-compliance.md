# Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set for the app on every platform (build setting
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`), so App Store Connect does not ask the export-compliance question for
each build. It is NO because every use of cryptography in Fluxo is exempt:

| Use | Implementation | Why it is exempt |
|---|---|---|
| HTTPS for playlists, guides, logos, streams | URLSession and AVFoundation (Apple's TLS) | Encryption provided by the operating system |
| HTTPS inside the remux engine | FFmpeg's `tls` protocol on **Secure Transport** (Apple's TLS library; no OpenSSL or other crypto library is linked) | Operating-system encryption, used for authentication and data in transit only |
| HLS AES-128 decryption | FFmpeg's `crypto` protocol (built-in AES) | Decrypting media the user is entitled to, i.e. copy protection of content, not information security; the app offers no encryption to the user |
| iCloud sync, encrypted fields | CloudKit `encryptedValues` | Operating-system encryption |
| Cache keys, sync record names, recommendation fingerprints | SHA-256 hashes (CryptoKit) | Hashing, not encryption |

Fluxo has no proprietary or non-standard algorithm, no VPN, no end-to-end messaging and no encryption feature
exposed to the user.

**Re-check before a release** if any of these change: a new crypto library in FFmpeg (OpenSSL, mbedTLS, libsrt's
crypto), a custom protocol, or a feature that encrypts user data. Then set the key to YES and answer the questions in
App Store Connect (and file the annual self-classification report if required).

Sources: Apple, "Complying with Encryption Export Regulations"; U.S. EAR §740.17(b)(1) and Note 4 to Category 5,
Part 2. This is the developer's assessment, not legal advice.
