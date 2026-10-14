#!/usr/bin/env bash
#
# Build the Homebrew-cask distribution artifact.
#
# A cask needs two things a source repo does not have: a versioned download URL,
# and a sha256 of the exact bytes at that URL. This produces both.
#
#   Scripts/release.sh            build, package into dist/, print the sha256
#   Scripts/release.sh --update   ...and write the sha256 into Casks/grammarbar.rb
#
# After running this, attach dist/GrammarBar-<version>.zip to a GitHub Release
# tagged v<version>. The cask URL assumes exactly that layout, so the bytes must
# be the ones this script produced - do not rebuild between zipping and uploading.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
UPDATE_CASK=0
[ "${1:-}" = "--update" ] && UPDATE_CASK=1

VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || { echo "ERROR: could not read MARKETING_VERSION from project.yml" >&2; exit 1; }

APP_NAME="GrammarBar"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
BUILD_DIR=".build-xcode"
DIST_DIR="dist"

echo "==> GrammarBar ${VERSION}"

echo "==> Regenerating the Xcode project from project.yml"
command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate >/dev/null

echo "==> Building Release"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
  -configuration Release -derivedDataPath "${BUILD_DIR}" build >/dev/null

APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "ERROR: no app at ${APP_PATH}" >&2; exit 1; }

# Guard against shipping a build that would surprise the user: the menu bar
# behaviour is the whole product, and it is a plist key, not code.
if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "${APP_PATH}/Contents/Info.plist" 2>/dev/null)" != "true" ]; then
  echo "ERROR: built app lacks LSUIElement=true - it would show a Dock icon" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "${DIST_DIR}/${ZIP_NAME}"

echo "==> Packaging (ditto, to preserve bundle metadata)"
# --keepParent so extracting yields GrammarBar.app at the zip root, which is what
# the cask's `app "GrammarBar.app"` stanza expects.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "${DIST_DIR}/${ZIP_NAME}"

SHA=$(shasum -a 256 "${DIST_DIR}/${ZIP_NAME}" | awk '{print $1}')
URL="https://github.com/kusalkalinga00/grammarbar-project/releases/download/v${VERSION}/${ZIP_NAME}"

echo
echo "artifact : ${DIST_DIR}/${ZIP_NAME}"
echo "size     : $(du -h "${DIST_DIR}/${ZIP_NAME}" | awk '{print $1}')"
echo "sha256   : ${SHA}"
echo "url      : ${URL}"

if [ "$UPDATE_CASK" = "1" ]; then
  /usr/bin/sed -i '' -E "s|^  sha256 \".*\"|  sha256 \"${SHA}\"|" Casks/grammarbar.rb
  /usr/bin/sed -i '' -E "s|^  version \".*\"|  version \"${VERSION}\"|" Casks/grammarbar.rb
  echo
  echo "==> Casks/grammarbar.rb updated (version + sha256)"
fi

cat <<EOF

Next:
  1. Create the release, attaching THIS zip (do not rebuild it first):
       gh release create v${VERSION} "${DIST_DIR}/${ZIP_NAME}" \
         --title "v${VERSION}" --notes "See README.md"
  2. Verify the cask against the live URL:
       brew audit --cask ./Casks/grammarbar.rb
EOF
