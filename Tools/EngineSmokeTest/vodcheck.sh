# Sourced by run_vod.sh and run_formats.sh (after they set ROOT, WORK and CHECK_PORT and source
# Tools/FFmpeg/env.sh): builds VODCheck (VODCheck/main.swift with the app's PlaybackRoute, StreamRemuxer,
# SimpleHTTPServer and the remux engine, on loopback port CHECK_PORT) and sets CHECK to its path.

build_check() {
    pkg=$WORK/package
    rm -rf "$pkg"
    mkdir -p "$pkg/Sources/FluxoEngine/include" "$pkg/Sources/VODCheck"
    cp "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.c" "$ROOT/Fluxo/Features/Player/Engine/FluxoTranscoder.c" \
        "$ROOT/Fluxo/Features/Player/Engine/FluxoTranscoder.h" "$pkg/Sources/FluxoEngine/"
    cp "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.h" "$pkg/Sources/FluxoEngine/include/"
    cp "$ROOT/Tools/EngineSmokeTest/VODCheck/main.swift" "$ROOT/Fluxo/Features/Player/PlaybackRoute.swift" \
        "$ROOT/Fluxo/Features/Playlist/ChannelContentKind.swift" "$ROOT/Fluxo/Features/Series/EpisodeParser.swift" "$pkg/Sources/VODCheck/"
    { echo "import FluxoEngine"; cat "$ROOT/Fluxo/Features/Player/Engine/StreamRemuxer.swift"; } > "$pkg/Sources/VODCheck/StreamRemuxer.swift"
    sed "s/static let port: UInt16 = debugPortOverride ?? 19123/static let port: UInt16 = $CHECK_PORT/" "$ROOT/Fluxo/Features/Player/SimpleHTTPServer.swift" > "$pkg/Sources/VODCheck/SimpleHTTPServer.swift"
    grep -q "port: UInt16 = $CHECK_PORT" "$pkg/Sources/VODCheck/SimpleHTTPServer.swift"
    version=$(sed -n '/flyingfox/,/version/s/.*"version" : "\(.*\)".*/\1/p' "$ROOT/Fluxo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    cat > "$pkg/Package.swift" <<SWIFT
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "VODCheck",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/swhitty/FlyingFox.git", exact: "$version")],
    targets: [
        .target(name: "FluxoEngine", cSettings: [.unsafeFlags(["-I$ROOT/Vendor/FFmpeg/include"])]),
        .executableTarget(
            name: "VODCheck",
            dependencies: ["FluxoEngine", .product(name: "FlyingFox", package: "FlyingFox")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-F$FFMPEG_MACOS_SLICE", "-framework", "FFmpeg", "-Xlinker", "-rpath", "-Xlinker", "$FFMPEG_MACOS_SLICE"]),
                .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
SWIFT
    (cd "$pkg" && swift build -c release --scratch-path "$WORK/build" 2>&1 | grep -E "error|warning: .*(FluxoRemux|StreamRemuxer|SimpleHTTP|PlaybackRoute)|Compiling|Build complete" | grep -v "^\[" | tail -20)
    CHECK=$(cd "$pkg" && swift build -c release --scratch-path "$WORK/build" --show-bin-path)/VODCheck
    [ -x "$CHECK" ]
}

