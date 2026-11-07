# Sourced by the tools that compile app sources with swiftc: the Swift language settings of the app's targets
# (Fluxo.xcodeproj: SWIFT_VERSION and the SWIFT_UPCOMING_FEATURE_* settings), so the sources build here with the
# same rules as in Xcode. Keep the two in step. See "Swift" in docs/building.md.
FLUXO_SWIFT_LANGUAGE=(
    -swift-version 6
    -enable-upcoming-feature ExistentialAny
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature MemberImportVisibility
    -enable-upcoming-feature NonisolatedNonsendingByDefault
)
