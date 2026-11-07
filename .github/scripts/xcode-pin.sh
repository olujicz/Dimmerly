# shellcheck shell=bash disable=SC2034
# CI and the Release DMG build with exactly this released Xcode (verify-xcode.sh).
# Every shipped build, including the locally archived App Store edition, must come from
# the same major Xcode and macOS SDK (verify-built-xcode.sh, verify-dmg.sh).
pinned_xcode_version='27.1'
pinned_xcode_build='27A9275'
required_xcode_major='27'
