#!/bin/zsh

source "${0:A:h}/common.zsh"

CONFIGURATION=${CONFIGURATION:-Debug}

generate_project
xcodebuild_args
xcodebuild "${reply[@]}" -configuration "$CONFIGURATION" build -quiet

print -- "Built Pollux ($CONFIGURATION)"
