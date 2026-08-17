#!/bin/zsh

source "${0:A:h}/common.zsh"

generate_project
print -- "Generated $PROJECT_FILE"
