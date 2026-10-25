#!/usr/bin/env bash
# make-voicepack.sh — build & publish the Kokoro voicepack Release asset.
#
# Usage: bash scripts/make-voicepack.sh [--publish]
#   --publish  upload to GitHub Release (needs gh auth + proxy); default only builds locally
#
# NOTE: GitHub access from this shell needs the proxy:
#   export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
#
# Source model: sherpa-onnx tts-models release (NOT the v1.13.8 code release — the
# prebuilt models live under the rolling `tts-models` tag). The c-api dylib vendored
# in Task 1 is v1.13.8; `kokoro-int8-multi-lang-v1_1` is the matching int8 dist
# (zh + en lexicons, voices.bin with the 8 zh speakers KokoroVoice indexes).
#
# Output: dist/kokoro-zh-v1.zip        — top level is kokoro/ (VoicepackStore.locatePayload
#                                        expects model.int8.onnx inside it)
#         dist/kokoro-zh-v1.zip.sha256 — for humans; the app hardcodes the hash below
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$REPO_ROOT/dist"

SHERPA_REPO="k2-fsa/sherpa-onnx"
SHERPA_TAG="tts-models"
MODEL_ASSET="kokoro-int8-multi-lang-v1_1.tar.bz2"
MODEL_URL="https://github.com/$SHERPA_REPO/releases/download/$SHERPA_TAG/$MODEL_ASSET"

# Must match AniCompanion/Services/VoicepackStore.swift (releaseAssetURL filename).
ZIP_NAME="kokoro-zh-v1.zip"

# GitHub Release (catsmice/AniCompanion, tag voicepack-kokoro-v1).
RELEASE_TAG="voicepack-kokoro-v1"
PUBLISH_REPO="catsmice/AniCompanion"

PUBLISH=0
PUBLISH_ONLY=0
case "${1:-}" in
    --publish) PUBLISH=1 ;;
    --publish-only) PUBLISH_ONLY=1 ;;   # upload the existing dist/ zip WITHOUT re-packing
esac

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# 0. Proxy hint (don't force it — just remind; downloads stall without it here).
if [[ -z "${https_proxy:-}${HTTPS_PROXY:-}" ]]; then
    echo "NOTE: no proxy detected. GitHub downloads usually need it:"
    echo "  export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897"
fi

mkdir -p "$DIST"
TARBALL="$DIST/$MODEL_ASSET"

# Publish-only short-circuit: upload the zip currently in dist/ as-is. Use this
# after backfilling VoicepackStore with that zip's sha256 — never re-pack between
# backfill and upload (a re-pack produces a different hash).
publish_release() {
    step "Publish to $PUBLISH_REPO release $RELEASE_TAG"
    if gh release view "$RELEASE_TAG" --repo "$PUBLISH_REPO" > /dev/null 2>&1; then
        gh release upload "$RELEASE_TAG" "$DIST/$ZIP_NAME" "$DIST/$ZIP_NAME.sha256" \
            --clobber --repo "$PUBLISH_REPO"
    else
        gh release create "$RELEASE_TAG" "$DIST/$ZIP_NAME" "$DIST/$ZIP_NAME.sha256" \
            --repo "$PUBLISH_REPO" \
            --title "Kokoro voicepack v1" \
            --notes "Kokoro int8 multi-lang v1.1 (zh voices) — on-device TTS voicepack for AniCompanion. sha256 in the .sha256 asset."
    fi
    echo "Published. Verify in-app install (Settings → TTS → Kokoro → Download Voicepack)."
}
if [[ "$PUBLISH_ONLY" == 1 ]]; then
    [[ -f "$DIST/$ZIP_NAME" ]] || die "dist/$ZIP_NAME not built yet — run without --publish-only first"
    publish_release
    exit 0
fi

# 1. Download with curl (gh release download produced corrupted files once — Task 1
#    lesson). Cached: an existing complete tarball is reused; pass --refresh to redownload.
verify_tar() {
    tar -tjf "$1" > /dev/null 2>&1
}
if [[ "${1:-}" == "--refresh" || "${2:-}" == "--refresh" ]] || [[ ! -f "$TARBALL" ]] || ! verify_tar "$TARBALL"; then
    step "Download $MODEL_ASSET"
    curl -fL --retry 3 --progress-bar -o "$TARBALL" "$MODEL_URL" || die "download failed"
    # Integrity check: list the archive; a truncated tar fails here. One retry.
    if ! verify_tar "$TARBALL"; then
        echo "tar integrity check failed — retrying download once..."
        rm -f "$TARBALL"
        curl -fL --retry 3 --progress-bar -o "$TARBALL" "$MODEL_URL" || die "download retry failed"
        verify_tar "$TARBALL" || die "downloaded tarball is corrupt even after retry"
    fi
else
    step "Using cached $TARBALL"
fi

# 2. Unpack the payload files. Expected layout: kokoro-int8-multi-lang-v1_1/ with
#    model.int8.onnx, tokens.txt, voices.bin, lexicon.txt, lexicon-us-en.txt (or
#    lexicon-zh.txt), espeak-ng-data/, and extra speaker dirs we don't ship.
step "Unpack payload"
STAGING="$DIST/.staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
tar -xjf "$TARBALL" -C "$STAGING"

SRC="$(find "$STAGING" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$SRC" ]] || { echo "Archive contents:"; tar -tjf "$TARBALL"; die "no top-level dir in tarball"; }

echo "Source layout:"
ls -lh "$SRC"

# The zh lexicon ships as lexicon.txt in the multi-lang pack; the app's key file
# list expects lexicon-zh.txt — rename on the way into the pack.
MODEL_FILE="$(cd "$SRC" && ls model.int8.onnx 2>/dev/null || ls model.onnx 2>/dev/null || true)"
[[ -n "$MODEL_FILE" ]] || { echo "Archive contents:"; tar -tjf "$TARBALL"; die "no model file (model.int8.onnx / model.onnx) in tarball"; }

REQUIRED=(tokens.txt voices.bin espeak-ng-data)
for f in "${REQUIRED[@]}"; do
    [[ -e "$SRC/$f" ]] || { echo "Missing: $f. Archive contents:"; tar -tjf "$TARBALL"; die "unexpected pack layout"; }
done

# 3. Assemble dist/kokoro/ (the zip's top level must be kokoro/).
step "Assemble kokoro/"
PACK="$DIST/kokoro"
rm -rf "$PACK"
mkdir -p "$PACK"
cp -p "$SRC/$MODEL_FILE" "$PACK/model.int8.onnx"
cp -p "$SRC/tokens.txt" "$PACK/"
cp -p "$SRC/voices.bin" "$PACK/"
if [[ -f "$SRC/lexicon-zh.txt" ]]; then
    cp -p "$SRC/lexicon-zh.txt" "$PACK/"
else
    cp -p "$SRC/lexicon.txt" "$PACK/lexicon-zh.txt"
fi
if [[ -f "$SRC/lexicon-us-en.txt" ]]; then
    cp -p "$SRC/lexicon-us-en.txt" "$PACK/"
fi
cp -Rp "$SRC/espeak-ng-data" "$PACK/espeak-ng-data"

# Pin mtimes (the zip records them). NOTE: a re-pack is still NOT bit-identical —
# zip entry order follows directory traversal, which is not stable across runs.
# The correct release flow is: build ONCE → upload THAT zip (--publish-only) →
# paste THAT zip's sha256 into VoicepackStore. Never re-pack between backfill and
# upload.
find "$PACK" -exec touch -t 202501010000.00 {} +

# Sanity: everything VoicepackStore.keyFileNames expects must be present.
for f in model.int8.onnx tokens.txt voices.bin lexicon-zh.txt lexicon-us-en.txt; do
    [[ -e "$PACK/$f" ]] || die "assembled pack is missing $f (pack layout mismatch)"
done

# 4. Zip (top level = kokoro/) + 5. sha256.
step "Zip + sha256"
( cd "$DIST" && rm -f "$ZIP_NAME" "$ZIP_NAME.sha256" && zip -q -r "$ZIP_NAME" kokoro )
SHA="$(shasum -a 256 "$DIST/$ZIP_NAME" | awk '{print $1}')"
SIZE="$(stat -f %z "$DIST/$ZIP_NAME")"
printf '%s  %s\n' "$SHA" "$ZIP_NAME" > "$DIST/$ZIP_NAME.sha256"

rm -rf "$STAGING"

echo
echo "====================================================================="
echo "Built $DIST/$ZIP_NAME ($(echo "scale=1; $SIZE / 1048576" | bc) MB)"
echo "Paste into VoicepackStore.swift:"
echo "    nonisolated static let expectedSHA256 = \"$SHA\""
echo "    nonisolated static let expectedSizeBytes: Int64 = $SIZE"
echo "====================================================================="

# 6. Publish (product owner decision — never run by CI/agents). NOTE: --publish
# re-packs first (new sha256 — must re-backfill); prefer the build-once flow:
# plain run → backfill → --publish-only.
if [[ "$PUBLISH" == 1 ]]; then
    publish_release
else
    echo "Dry run only. Re-run with --publish to upload."
fi
