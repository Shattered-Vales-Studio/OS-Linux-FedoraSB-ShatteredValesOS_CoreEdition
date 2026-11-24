#!/usr/bin/env bash
#
# write-banners.sh
#
# Purpose:
#   Writes the console sign-in banner (/etc/issue.d) and the terminal
#   message of the day (/usr/lib/motd.d) from brand.env: the OS name in
#   gold, the edition in the edition colour and the links to the site and
#   its guides. Generated rather than shipped as files so each edition's
#   banners follow its brand.env without a copy of their own.
#
# Inputs:
#   /usr/share/shatteredvales/brand.env
#
# Usage:
#   Run at image build time by apply-branding.sh.
#
# Exit codes:
#   0 on success, non-zero if a banner cannot be written.

set -euo pipefail

# shellcheck source=/dev/null
source /usr/share/shatteredvales/brand.env

readonly ISSUE=/etc/issue.d/50-shatteredvales.issue
readonly MOTD=/usr/lib/motd.d/50-shatteredvales

# truecolor
#   Converts a #rrggbb colour to the SGR parameters of a 24-bit foreground.
#   Arguments: $1 colour
#   Output: "38;2;r;g;b" on stdout
#   Returns: 0 always
truecolor() {
    local hex="${1#\#}"
    printf '38;2;%d;%d;%d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# main
#   Writes both banners.
#   Arguments: none
#   Returns: 0 on success
main() {
    local esc=$'\e' accent edition muted
    accent="$(truecolor "${BRAND_ACCENT}")"
    edition="$(truecolor "${BRAND_EDITION_COLOR_DARK}")"
    muted="$(truecolor "${BRAND_TEXT_MUTED}")"

    mkdir -p "$(dirname "${ISSUE}")" "$(dirname "${MOTD}")"
    # agetty knows only named colours, and the Linux console cannot show
    # 24-bit colour, so the console banner uses the closest named ones.
    cat > "${ISSUE}" <<ISSUE
\\e{yellow}\\e{bold}${BRAND_OS_NAME}\\e{reset} \\e{${BRAND_EDITION_TTY_COLOR}}${BRAND_EDITION}\\e{reset}  ·  ${BRAND_URL}
\\e{halfbright}Guides: ${BRAND_DOCS_URL}\\e{reset}

ISSUE
    cat > "${MOTD}" <<MOTD

  ${esc}[1;${accent}m${BRAND_OS_NAME}${esc}[0m ${esc}[1;${edition}m${BRAND_EDITION}${esc}[0m  ·  ${BRAND_URL}
  ${esc}[${muted}mStatus: sv-doctor    Updates: sv-update    Guides: ${BRAND_DOCS_URL}${esc}[0m

MOTD
}

main "$@"
