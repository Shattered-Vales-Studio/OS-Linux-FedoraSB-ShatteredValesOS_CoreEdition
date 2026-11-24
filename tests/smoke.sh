#!/usr/bin/env bash
#
# smoke.sh
#
# Purpose:
#   Fast checks against a built image without booting it. Runs the image as
#   a container and inspects its filesystem, which works on macOS where the
#   x86_64 OS itself cannot be booted.
#
# Usage:
#   tests/smoke.sh <image-ref>
#
# Exit codes:
#   0 when all checks pass, 1 otherwise.

set -euo pipefail

readonly IMAGE="${1:?usage: smoke.sh <image-ref>}"

# in_image
#   Runs a shell snippet inside the image.
#   Arguments: $1 command string
#   Returns: the command's exit status
in_image() {
    docker run --rm --platform linux/amd64 "${IMAGE}" bash -c "$1"
}

# main
#   Runs every smoke check against the image and reports the result.
#   Arguments: none (the image comes from IMAGE)
#   Returns: 0 when all checks pass, 1 otherwise
main() {
    local failed=0

    echo "-> bootc container lint"
    in_image 'bootc container lint' || failed=1

    echo "-> branding applied to os-release"
    in_image 'grep -q "^NAME=\"Shattered Vales OS\"" /usr/lib/os-release' || failed=1

    echo "-> edition recorded in os-release"
    # Expanded inside the image, from the image's own brand.env.
    # shellcheck disable=SC2016
    in_image '. /usr/share/shatteredvales/brand.env && grep -q "^VARIANT=\"${BRAND_EDITION}\"" /usr/lib/os-release' || failed=1

    echo "-> shell theme contains brand CSS"
    # gresource tooling is removed from the image after patching, but the
    # compiled resource stores the CSS uncompressed, so a binary grep works.
    # Exactly once: editions re-run the patch over Core, and it must replace
    # the branding rather than add a second copy.
    # shellcheck disable=SC2016
    in_image 'test "$(grep -ao "Shattered Vales branding" /usr/share/gnome-shell/gnome-shell-theme.gresource | wc -l)" -eq 1' \
        || failed=1

    echo "-> dconf defaults compiled with brand values"
    in_image 'test -s /etc/dconf/db/local && test -s /etc/dconf/db/gdm && ! grep -rq "@BRAND_" /etc/dconf/db/local.d /etc/dconf/db/gdm.d' || failed=1

    echo "-> Plymouth theme baked into initramfs"
    in_image 'lsinitrd /usr/lib/modules/*/initramfs.img | grep -q "plymouth/themes/shatteredvales"' || failed=1

    echo "-> no unrendered placeholders anywhere in /usr/share/shatteredvales"
    in_image '! grep -rq "@BRAND_" /usr/share/plymouth/themes/shatteredvales' || failed=1

    if (( failed )); then
        echo "SMOKE TESTS FAILED" >&2
        exit 1
    fi
    echo "All smoke tests passed"
}

main "$@"
