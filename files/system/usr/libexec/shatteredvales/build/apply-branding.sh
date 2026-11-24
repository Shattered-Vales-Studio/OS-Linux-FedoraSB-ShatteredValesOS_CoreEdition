#!/usr/bin/env bash
#
# apply-branding.sh
#
# Purpose:
#   Applies /usr/share/shatteredvales/brand.env and the rendered artwork to
#   the whole image: os-release, the console and terminal banners, the GNOME
#   Shell theme, the dconf databases and the boot splash. Core Edition runs
#   it once; every edition built on Core runs it again after copying in its
#   own brand.env, artwork and dconf files, so the edition's name, colours
#   and settings replace Core's. Every step is safe to repeat.
#
# Inputs:
#   /usr/share/shatteredvales/brand.env and the files it describes.
#
# Usage:
#   Run at image build time from a recipe:
#     - type: script
#       snippets:
#         - /usr/libexec/shatteredvales/build/apply-branding.sh
#
# Exit codes:
#   0 on success, non-zero as soon as a step fails.

set -euo pipefail

readonly BUILD_DIR=/usr/libexec/shatteredvales/build

# main
#   Runs each branding step in order. The Plymouth step regenerates the
#   initramfs, so it runs last, after everything that could invalidate it.
#   Arguments: none
#   Returns: 0 on success
main() {
    local step
    for step in set-os-release write-banners patch-shell-theme dconf-update build-plymouth; do
        echo "== ${step}"
        "${BUILD_DIR}/${step}.sh"
    done
}

main "$@"
