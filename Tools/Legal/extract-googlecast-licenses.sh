#!/bin/sh
# Copies the notices of the open-source software inside the Google Cast SDK into the app.
#
# Google ships them with the SDK, in GoogleCast*Binary/OpenSourceLicenses: oss_licenses_index.plist (the name of each
# component, and the offset and size of its text) and oss_licenses.bin (the texts). A binary distribution must
# reproduce them, so this script writes them to Fluxo/App/Legal/Licenses/GoogleCast-OSS.json, which Settings › About ›
# Acknowledgements › Google Cast SDK shows (iPhone and iPad only, the only platforms with the SDK).
#
# Usage: Tools/Legal/extract-googlecast-licenses.sh [SourcePackages directory] [output file]
#   The SourcePackages directory is the one of a build that resolved the packages: <derivedDataPath>/SourcePackages.
#   Without it, the newest ~/Library/Developer/Xcode/DerivedData/Fluxo-*/SourcePackages is used.
#   Run it after updating the Cast SDK in Vendor/GoogleCast/Package.swift (and build once first, so the new SDK is
#   downloaded); Tools/Legal/check-acknowledgements.sh fails until the file matches the SDK of that manifest.
#
# Every component of Google's index must have a license name below (LICENSES): a new component in an SDK update stops
# the script until someone reads its text and names its license.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# The SDK the app links: the local package that wraps Google's dynamic GoogleCast.xcframework.
CAST_PACKAGE=$ROOT/Vendor/GoogleCast/Package.swift

source_packages=${1:-}
if [ -z "$source_packages" ]; then
    source_packages=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Fluxo-*/SourcePackages 2>/dev/null | head -1 || true)
fi
output=${2:-$ROOT/Fluxo/App/Legal/Licenses/GoogleCast-OSS.json}
if [ -z "$source_packages" ] || [ ! -f "$source_packages/workspace-state.json" ]; then
    echo "error: no SourcePackages directory with a workspace-state.json; pass <derivedDataPath>/SourcePackages" >&2
    exit 1
fi

python3 -I - "$CAST_PACKAGE" "$source_packages" "$output" <<'EOF'
import hashlib, json, os, plistlib, re, sys

manifest_path, source_packages, output = sys.argv[1:4]

# The license of each component, read from its text in oss_licenses.bin (Cast SDK 4.8.6). Google's index gives only
# the names. Several texts hold more than one license (gRPC, Eigen, proto): every license they contain is named.
LICENSES = {
    "Abseil": "Apache License 2.0",
    "audio_to_tactile": "Apache License 2.0",
    "cast": "BSD 3-Clause License",
    "Eigen 3": "Mozilla Public License 2.0; parts under BSD-style, Apache 2.0 and MIT licenses",
    "Google Toolbox for Mac": "Apache License 2.0",
    "gRPC": "Apache License 2.0; parts under the Mozilla Public License 2.0",
    "gtm_session_fetcher": "Apache License 2.0",
    "Kiss FFT": "BSD 3-Clause License; parts under the Unlicense",
    "Material Components for iOS": "Apache License 2.0",
    "MDFFontDiskLoader": "Apache License 2.0",
    "MDFInternationalization": "Apache License 2.0",
    "MDFTextAccessibility": "Apache License 2.0",
    "program_image_remapper": "Apache License 2.0",
    "proto": "BSD 3-Clause License, Mozilla Public License 1.1 and Apache License 2.0",
    "Protocol Buffers": "BSD 3-Clause License",
    "Protocol Buffers for Go v2": "BSD 3-Clause License",
    "Protocol Buffers for Java": "BSD 3-Clause License",
    "SimplePing": "Apple Sample Code License",
    "TCMalloc": "Apache License 2.0",
    "tz database": "Public domain; parts under the BSD 3-Clause License",
}

def fail(message):
    print("error: " + message, file=sys.stderr)
    sys.exit(1)

match = re.search(r"GoogleCastSDK-ios-([0-9.]+)_dynamic\.zip", open(manifest_path, encoding="utf-8").read())
if not match:
    fail("no GoogleCastSDK-ios-<version>_dynamic.zip archive in " + manifest_path)
version = match.group(1)

# The SDK the app links (the binary target of Vendor/GoogleCast), and the archive it came from: it must be the version
# of the manifest, or the DerivedData is stale.
state = json.load(open(os.path.join(source_packages, "workspace-state.json")))
artifact = next((a for a in state["object"]["artifacts"]
                 if a["packageRef"]["identity"] == "googlecast" and a["targetName"] == "GoogleCast"), None)
if artifact is None:
    fail(source_packages + " has no GoogleCast artifact of Vendor/GoogleCast; build the iOS app once to download it")
source = artifact.get("source", {})
if "-" + version + "_" not in source.get("url", ""):
    fail("the Cast SDK in %s is %s, not %s of Vendor/GoogleCast/Package.swift; build again to download it"
         % (source_packages, source.get("url", "?"), version))

folder = os.path.join(os.path.dirname(artifact["path"]), "OpenSourceLicenses")
index_path = os.path.join(folder, "oss_licenses_index.plist")
bin_path = os.path.join(folder, "oss_licenses.bin")
index_bytes = open(index_path, "rb").read()
data = open(bin_path, "rb").read()
index = plistlib.loads(index_bytes)

unknown = sorted(entry["name"] for entry in index if entry["name"] not in LICENSES)
if unknown:
    fail("components without a license name in this script: " + ", ".join(unknown)
         + ". Read their texts in oss_licenses.bin and add them to LICENSES.")
gone = sorted(set(LICENSES) - set(entry["name"] for entry in index))
if gone:
    fail("no longer in Google's index, remove them from LICENSES: " + ", ".join(gone))

# One copy of each text (nine components share the same Apache License text).
texts, text_ids, components = [], {}, []
for entry in sorted(index, key=lambda e: e["name"].casefold()):
    offset, size = entry["offset"], entry["size"]
    if offset < 0 or size <= 0 or offset + size > len(data):
        fail("the text of %s is outside oss_licenses.bin" % entry["name"])
    text = data[offset:offset + size].decode("utf-8").replace("\r\n", "\n").strip("\n") + "\n"
    if text not in text_ids:
        text_ids[text] = len(texts)
        texts.append(text)
    components.append({"name": entry["name"], "license": LICENSES[entry["name"]], "text": text_ids[text]})

result = {
    "comment": "Generated by Tools/Legal/extract-googlecast-licenses.sh from the OpenSourceLicenses folder of the "
               "Google Cast SDK. Do not edit.",
    "sdkVersion": version,
    "sdkArchive": source.get("url", ""),
    "sdkArchiveChecksum": source.get("checksum", ""),
    "indexSHA256": hashlib.sha256(index_bytes).hexdigest(),
    "licensesSHA256": hashlib.sha256(data).hexdigest(),
    "components": components,
    "texts": texts,
}
with open(output, "w", encoding="utf-8") as file:
    json.dump(result, file, ensure_ascii=False, indent=1, sort_keys=False)
    file.write("\n")
print("wrote %s: Google Cast SDK %s, %d components, %d texts" % (output, version, len(components), len(texts)))
EOF
