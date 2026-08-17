#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
PROJECT_SPEC="$PROJECT_ROOT/project.yml"
PROJECT_FILE="$PROJECT_ROOT/Pollux.xcodeproj"
SCHEME=${POLLUX_SCHEME:-Pollux}
DERIVED_DATA=${DERIVED_DATA:-$PROJECT_ROOT/.build/DerivedData}
HOST_ARCH=${HOST_ARCH:-$(uname -m)}

function require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 -- "Missing required command: $1"
    exit 1
  fi
}

function generate_project() {
  require_command xcodegen
  mkdir -p "$PROJECT_ROOT/.build"
  cd "$PROJECT_ROOT"
  xcodegen generate --spec "$PROJECT_SPEC" >/dev/null
}

function xcodebuild_args() {
  reply=(
    -project "$PROJECT_FILE"
    -scheme "$SCHEME"
    -derivedDataPath "$DERIVED_DATA"
    -destination "platform=macOS,arch=$HOST_ARCH"
  )
}
