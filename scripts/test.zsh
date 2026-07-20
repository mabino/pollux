#!/bin/zsh

source "${0:A:h}/common.zsh"

generate_project
xcodebuild_args
xcodebuild "${reply[@]}" test -quiet

print -- "Pollux tests passed"
