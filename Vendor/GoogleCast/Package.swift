// swift-tools-version:5.9
//
// The Google Cast iOS Sender SDK for Fluxo: Google's dynamic GoogleCast.xcframework, the binary of the GoogleCastDynamic
// product of https://github.com/googlecast/google-cast-ios-sdk (same archive, same checksum), without that package's
// dependency on the gtm-session-fetcher package.
//
// GoogleCast.framework already contains GTMSessionFetcher: it links its own copy and binds to it. Through Google's
// package the app linked a second copy (the static GTMSessionFetcher library), so every GTMSessionFetcher class was in
// the app twice and the Objective-C runtime warned at launch ("Class GTMSessionFetcher is implemented in both …"; which
// copy a lookup by name gets is undefined). Through this package there is one copy, inside GoogleCast.framework. Its
// notice is among the SDK's open-source notices (Fluxo/App/Legal/Licenses/GoogleCast-OSS.json).
//
// Updating the SDK: take the URL and checksum of the GoogleCastDynamicBinary target from the Package.swift of the new
// release of google-cast-ios-sdk, build the iOS app once, then run Tools/Legal/extract-googlecast-licenses.sh and
// Tools/Legal/check-acknowledgements.sh (see "Chromecast" in docs/).

import PackageDescription

let package = Package(
    name: "GoogleCast",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "GoogleCast", targets: ["GoogleCast"]),
    ],
    targets: [
        .binaryTarget(
            name: "GoogleCast",
            url: "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.6_dynamic.zip",
            checksum: "55f6c21291a1315c68063f07e7d76225564bff70f2fd38caad135c71d66eb310"
        ),
    ]
)
