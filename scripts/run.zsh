#!/bin/zsh

source "${0:A:h}/common.zsh"

CONFIGURATION=${CONFIGURATION:-Debug}

generate_project
xcodebuild_args
xcodebuild "${reply[@]}" -configuration "$CONFIGURATION" build -quiet

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Pollux.app"
open -na "$APP_PATH" --args "$@"
