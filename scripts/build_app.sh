#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="Zoomies"
DEFAULT_BUNDLE_ID="com.baldai.zoomies"
DEFAULT_VERSION="0.1.0"
DEFAULT_BUILD_NUMBER="1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="${DEFAULT_VERSION}"
BUILD_NUMBER="${DEFAULT_BUILD_NUMBER}"
BUNDLE_ID="${DEFAULT_BUNDLE_ID}"
OUTPUT_APP="${REPO_ROOT}/dist/${PRODUCT_NAME}.app"
SIGN_APP="yes"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --version <value>       CFBundleShortVersionString (default: ${DEFAULT_VERSION})
  --build-number <value>  CFBundleVersion (default: ${DEFAULT_BUILD_NUMBER})
  --bundle-id <value>     CFBundleIdentifier (default: ${DEFAULT_BUNDLE_ID})
  --output <path>         Output .app path (default: ${OUTPUT_APP})
  --no-sign               Skip ad-hoc codesign
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_APP="${2:-}"
      shift 2
      ;;
    --no-sign)
      SIGN_APP="no"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" || -z "${BUILD_NUMBER}" || -z "${BUNDLE_ID}" || -z "${OUTPUT_APP}" ]]; then
  echo "Error: version, build-number, bundle-id, and output must be non-empty." >&2
  exit 1
fi

echo "Building ${PRODUCT_NAME} in release mode..."
(
  cd "${REPO_ROOT}"
  swift build -c release
)
BIN_DIR="$(cd "${REPO_ROOT}" && swift build -c release --show-bin-path)"
EXECUTABLE_PATH="${BIN_DIR}/${PRODUCT_NAME}"

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
  echo "Error: executable not found at ${EXECUTABLE_PATH}" >&2
  exit 1
fi

RESOURCE_BUNDLE="$(find "${BIN_DIR}" -maxdepth 1 -type d -name "*_${PRODUCT_NAME}.bundle" | head -n 1 || true)"
if [[ -z "${RESOURCE_BUNDLE}" ]]; then
  echo "Error: SwiftPM resource bundle for ${PRODUCT_NAME} was not found in ${BIN_DIR}" >&2
  exit 1
fi

APP_DIR="${OUTPUT_APP}"
APP_CONTENTS="${APP_DIR}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"

echo "Creating app bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_MACOS}" "${APP_RESOURCES}"

cp "${EXECUTABLE_PATH}" "${APP_MACOS}/${PRODUCT_NAME}"
strip -S -x "${APP_MACOS}/${PRODUCT_NAME}"
cp -R "${RESOURCE_BUNDLE}" "${APP_RESOURCES}/"

SCREENSHOT_SOUND="${RESOURCE_BUNDLE}/screenshot-sound.mp3"
if [[ -f "${SCREENSHOT_SOUND}" ]]; then
  cp "${SCREENSHOT_SOUND}" "${APP_RESOURCES}/"
fi

ICON_SRC="${REPO_ROOT}/dist/Zoomies.icns"
if [[ -f "${ICON_SRC}" ]]; then
  cp "${ICON_SRC}" "${APP_RESOURCES}/AppIcon.icns"
fi

cat > "${APP_CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${PRODUCT_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${PRODUCT_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Zoomies needs Finder access to reopen editing for the selected file.</string>
</dict>
</plist>
EOF

if [[ "${SIGN_APP}" == "yes" ]]; then
  echo "Applying ad-hoc signature..."
  codesign --force --deep --sign - "${APP_DIR}"
fi

echo
echo "Done."
echo "App bundle: ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""
