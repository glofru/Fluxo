# Sourced by run_vod.sh and run_formats.sh (after they set ROOT and WORK and source Tools/FFmpeg/env.sh): builds
# VODCheck (VODCheck/main.swift and Stress.swift with the app's PlaybackRoute, PlayerSeeker, PausedTimeShiftPolicy, StreamRemuxer,
# SimpleHTTPServer and the remux engine; the loopback server takes a free port on 127.0.0.1, like the app's) and sets
# CHECK to its path.

build_check() {
    pkg=$WORK/package
    rm -rf "$pkg"
    mkdir -p "$pkg/Sources/FluxoEngine/include" "$pkg/Sources/VODCheck"
    # The engine's C and Objective-C files and its internal headers; its interface (FluxoRemuxEngine.h) is the module's
    # public header.
    # shellcheck disable=SC2086 # FLUXO_ENGINE_SOURCES is a list of words.
    cp $FLUXO_ENGINE_SOURCES "$pkg/Sources/FluxoEngine/"
    for header in "$ROOT"/Fluxo/Features/Player/Engine/*.h; do
        [ "$(basename "$header")" = FluxoRemuxEngine.h ] || cp "$header" "$pkg/Sources/FluxoEngine/"
    done
    cp "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.h" "$pkg/Sources/FluxoEngine/include/"
    cp "$ROOT/Tools/EngineSmokeTest/VODCheck/main.swift" "$ROOT/Tools/EngineSmokeTest/VODCheck/Stress.swift" \
        "$ROOT/Fluxo/Features/Player/PlaybackRoute.swift" "$ROOT/Fluxo/Features/Player/PlayerSeeker.swift" \
        "$ROOT/Fluxo/Features/Player/PausedTimeShiftPolicy.swift" \
        "$ROOT/Fluxo/Features/Playlist/ChannelContentKind.swift" "$ROOT/Fluxo/Features/Series/EpisodeParser.swift" "$pkg/Sources/VODCheck/"
    { echo "import FluxoEngine"; cat "$ROOT/Fluxo/Features/Player/Engine/StreamRemuxer.swift"; } > "$pkg/Sources/VODCheck/StreamRemuxer.swift"
    cp "$ROOT/Fluxo/Features/Player/SimpleHTTPServer.swift" "$pkg/Sources/VODCheck/"
    version=$(sed -n '/flyingfox/,/version/s/.*"version" : "\(.*\)".*/\1/p' "$ROOT/Fluxo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    cat > "$pkg/Package.swift" <<SWIFT
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "VODCheck",
    // The macOS version the app and its FFmpeg build require.
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/swhitty/FlyingFox.git", exact: "$version")],
    targets: [
        // FLUXO_ENGINE_TESTING: the TLS cases trust the local test servers' authority (FLUXO_TEST_CA_FILE), never the app.
        .target(name: "FluxoEngine", cSettings: [.unsafeFlags(["-I$ROOT/Vendor/FFmpeg/include", "-fobjc-arc", "-DFLUXO_ENGINE_TRACE", "-DFLUXO_ENGINE_TESTING"])]),
        .executableTarget(
            name: "VODCheck",
            dependencies: ["FluxoEngine", .product(name: "FlyingFox", package: "FlyingFox")],
            // The app's language settings (Fluxo.xcodeproj, Tools/swift-language.sh).
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
            linkerSettings: [
                .unsafeFlags(["-F$FFMPEG_MACOS_SLICE", "-framework", "FFmpeg", "-Xlinker", "-rpath", "-Xlinker", "$FFMPEG_MACOS_SLICE"]),
                .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"), .linkedFramework("Foundation"), .linkedFramework("Security"),
            ]
        ),
    ]
)
SWIFT
    # (Not piped: a failed build must stop the check rather than run the binary of an earlier build.)
    build_status=0
    (cd "$pkg" && swift build -c release --scratch-path "$WORK/build" > "$WORK/build.log" 2>&1) || build_status=$?
    grep -E ": (error|warning: .*(FluxoRemux|FluxoTranscoder|StreamRemuxer|SimpleHTTP|PlaybackRoute|PlayerSeeker))|^error:|Compiling|Build complete" "$WORK/build.log" | grep -v "^\[" | tail -20 || true
    if [ "$build_status" -ne 0 ]; then
        echo "error: VODCheck did not build (log: $WORK/build.log)" >&2
        return 1
    fi
    CHECK=$(cd "$pkg" && swift build -c release --scratch-path "$WORK/build" --show-bin-path)/VODCheck
    [ -x "$CHECK" ]
}

