#!/usr/bin/env bash
#
# sv-migrate.sh
#
# Purpose:
#   Moves an existing Fedora Silverblue machine onto a Shattered Vales OS
#   edition in one step, keeping every account, file and installed Flatpak.
#   One script serves every edition: Core, Home and Studio.
#     1. Checks the machine (Fedora Atomic, release, free space).
#     2. Picks the image for the hardware: NVIDIA or the standard one.
#     3. Lists packages layered with `rpm-ostree install` and removes the
#        ones that would block the move or that the image already provides
#        (RPM Fusion's NVIDIA driver and kernel-devel, and for Studio
#        Node.js and Fedora's Docker packages).
#     4. Rebases onto the image and offers to restart. On first boot the
#        image switches itself to the signature-verified copy of the same
#        image (shatteredvales-signed-switch.service).
#   Nothing changes until you confirm the plan it prints.
#
# Usage:
#   curl -fsSLO https://raw.githubusercontent.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_CoreEdition/main/sv-migrate.sh
#   bash sv-migrate.sh [--edition core|home|studio] [--testing] [--nvidia | --base]
#                      [--remove-all-layered] [--yes] [--dry-run]
#     --edition             Which edition to move to (default: core)
#     --testing             Use the canary channel (:testing) instead of :latest
#     --nvidia | --base     Override the image picked from the hardware
#     --remove-all-layered  Remove every layered package, not just conflicts
#     --yes                 Do not ask before rebasing or restarting
#     --dry-run             Print the plan and the command, change nothing
#
# Exit codes:
#   0 on success or when the user cancels, 1 on failure, 64 on bad usage.

set -euo pipefail

readonly REGISTRY="ghcr.io/shattered-vales-studio"
readonly IMAGE_MAJOR=45
readonly MIN_FREE_GB=15

# Packages that cannot sit on top of the image. Each pattern is an extended
# regular expression matched against the whole package name.
CONFLICT_PATTERNS=(
    # The NVIDIA image ships its own prebuilt driver; RPM Fusion's akmod
    # driver and its userspace collide with it.
    'akmod-nvidia.*' 'kmod-nvidia.*' 'xorg-x11-drv-nvidia.*' 'nvidia-settings'
    'nvidia-persistenced' 'nvidia-modprobe' 'nvidia-vaapi-driver'
    # Only needed to build akmods; a layered kernel-devel must match the
    # kernel exactly and stalls updates when it cannot.
    'kernel-devel(-matched)?' 'kernel-headers'
)
# Studio ships these itself, so layered copies would clash with the image.
readonly -a STUDIO_CONFLICT_PATTERNS=(
    # The image ships Node.js 26 with the unversioned node and npm commands.
    'nodejs(-npm|-libs|-devel|-full-i18n)?'
    # The image ships Docker CE; Fedora's Docker packages conflict with it.
    'moby-engine' 'docker' 'docker-compose' 'podman-docker'
)
# RPM Fusion's release packages are only removed together with a conflict
# above, since some machines use RPM Fusion for other software.
readonly RPMFUSION_PATTERN='rpmfusion-(free|nonfree)-release(-tainted)?'

# say
#   Prints a highlighted progress line.
#   Arguments: message words
#   Returns: 0 always
say() {
    printf '\n\033[1;33m==>\033[0m \033[1m%s\033[0m\n' "$*"
}

# warn
#   Prints a warning.
#   Arguments: message words
#   Returns: 0 always
warn() {
    printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2
}

# die
#   Prints an error and exits.
#   Arguments: $1 message, $2 exit code (default 1)
#   Returns: does not return
die() {
    printf '\033[1;31mError:\033[0m %s\n' "$1" >&2
    exit "${2:-1}"
}

# confirm
#   Asks a yes/no question; --yes answers yes.
#   Arguments: $1 question
#   Returns: 0 for yes, 1 for no
confirm() {
    (( ASSUME_YES )) && return 0
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "${answer}" =~ ^[Yy] ]]
}

# os_field
#   Reads one field from /etc/os-release without sourcing it.
#   Arguments: $1 field name
#   Output: the value without quotes
#   Returns: 0 always
os_field() {
    sed -n "s/^$1=//p" /etc/os-release | tr -d '"'
}

# booted_json
#   Prints one field of the booted deployment from rpm-ostree's JSON status.
#   python3 is used because jq is not part of stock Silverblue.
#   Arguments: $1 field name; list fields are printed one item per line
#   Output: the value
#   Returns: 0 always
booted_json() {
    rpm-ostree status --json | python3 -I -c '
import json, sys
field = sys.argv[1]
for d in json.load(sys.stdin)["deployments"]:
    if d.get("booted"):
        value = d.get(field)
        if isinstance(value, list):
            print("\n".join(str(v) for v in value))
        elif value is not None:
            print(value)
' "$1"
}

# has_nvidia_gpu
#   Looks for a display-class PCI device from NVIDIA in sysfs, so the check
#   works without pciutils.
#   Returns: 0 if present, 1 otherwise
has_nvidia_gpu() {
    local dev
    for dev in /sys/bus/pci/devices/*; do
        [[ "$(cat "${dev}/vendor" 2>/dev/null)" == 0x10de ]] || continue
        [[ "$(cat "${dev}/class" 2>/dev/null)" == 0x03* ]] && return 0
    done
    return 1
}

# preflight
#   Stops on machines this script cannot safely move and warns about
#   unusual ones.
#   Arguments: none
#   Returns: does not return on a blocking problem
preflight() {
    local version variant free_gb ref
    if [[ ! -e /run/ostree-booted ]] || ! command -v rpm-ostree >/dev/null; then
        die "This is not a Fedora Atomic (Silverblue) machine. Use the USB installer instead."
    fi
    (( EUID != 0 )) || die "Run as your normal account; it asks for your password when needed."

    ref="$(booted_json container-image-reference)"
    # Matched up to the tag, since one edition's name can start another's
    # (shatteredvales-os and shatteredvales-os-home).
    if [[ "${ref}" =~ ${REGISTRY}/${IMAGE_NAME}(-nvidia)?: ]]; then
        echo "This machine already runs ${EDITION_NAME} (${ref#*://})."
        echo "To switch between the NVIDIA and standard image use sv-gpu-image; see the README."
        exit 0
    fi
    if [[ "${ref}" == *"${REGISTRY}/"* ]]; then
        warn "This machine runs another Shattered Vales OS edition (${ref#*://})."
        warn "Moving to ${EDITION_NAME} replaces that edition's apps and tools; files,"
        warn "accounts and Flatpak apps stay."
        confirm "Switch to ${EDITION_NAME}?" || exit 0
    fi

    version="$(os_field VERSION_ID)"
    variant="$(os_field VARIANT_ID)"
    echo "This machine: $(os_field PRETTY_NAME)"
    if [[ "${version}" != "${IMAGE_MAJOR}" ]]; then
        warn "It runs Fedora ${version}; the image is Fedora ${IMAGE_MAJOR}. This moves it to Fedora ${IMAGE_MAJOR} at the same time."
    fi
    if [[ "${variant}" != silverblue ]]; then
        warn "It runs the '${variant:-unknown}' edition, not Silverblue (GNOME). Desktop settings from other desktops will not carry over."
        confirm "Continue anyway?" || exit 0
    fi

    free_gb=$(( $(df --output=avail -k /sysroot | tail -n1) / 1024 / 1024 ))
    (( free_gb >= MIN_FREE_GB )) \
        || die "Only ${free_gb} GB free on the system disk; the move needs about ${MIN_FREE_GB} GB."

    if [[ -n "$(rpm-ostree status --json | python3 -I -c 'import json,sys; print(any(d.get("staged") for d in json.load(sys.stdin)["deployments"]) or "")')" ]]; then
        warn "An update is already waiting for a restart; this move replaces it."
    fi
}

# classify_layered
#   Splits the booted deployment's layered packages into conflicts, which
#   must go, and others, which can stay. Fills the CONFLICTS and OTHERS
#   arrays.
#   Arguments: none
#   Returns: 0 always
classify_layered() {
    local pkg pattern rpmfusion=()
    CONFLICTS=() OTHERS=()
    while read -r pkg; do
        [[ -n "${pkg}" ]] || continue
        for pattern in "${CONFLICT_PATTERNS[@]}"; do
            if [[ "${pkg}" =~ ^(${pattern})$ ]]; then
                CONFLICTS+=("${pkg}")
                continue 2
            fi
        done
        if [[ "${pkg}" =~ ^(${RPMFUSION_PATTERN})$ ]]; then
            rpmfusion+=("${pkg}")
        else
            OTHERS+=("${pkg}")
        fi
    done < <(booted_json requested-packages)
    if (( ${#CONFLICTS[@]} > 0 )); then
        CONFLICTS+=("${rpmfusion[@]}")
    else
        OTHERS+=("${rpmfusion[@]}")
    fi
}

# main
#   Parses options, prints the plan, rebases and offers a restart.
#   Arguments: see Usage
#   Returns: 0 on success
main() {
    local channel=latest gpu="" remove_all=0 dry_run=0 edition=core image ref pkg
    ASSUME_YES=0
    while (( $# )); do
        case "$1" in
            --edition)
                (( $# >= 2 )) || die "--edition needs core, home or studio" 64
                edition="$2"
                shift ;;
            --testing) channel=testing ;;
            --nvidia) gpu=nvidia ;;
            --base) gpu=base ;;
            --remove-all-layered) remove_all=1 ;;
            --yes) ASSUME_YES=1 ;;
            --dry-run) dry_run=1 ;;
            -h|--help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,3\}//'; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" 64 ;;
        esac
        shift
    done

    case "${edition}" in
        core) IMAGE_NAME=shatteredvales-os-core EDITION_NAME="Core Edition" ;;
        home) IMAGE_NAME=shatteredvales-os-home EDITION_NAME="Home Edition" ;;
        studio)
            IMAGE_NAME=shatteredvales-os EDITION_NAME="Studio Edition"
            CONFLICT_PATTERNS+=("${STUDIO_CONFLICT_PATTERNS[@]}") ;;
        *) die "Unknown edition: ${edition} (core, home or studio)" 64 ;;
    esac
    readonly IMAGE_NAME EDITION_NAME CONFLICT_PATTERNS

    say "Checking this machine"
    preflight

    if [[ -z "${gpu}" ]]; then
        if has_nvidia_gpu; then gpu=nvidia; else gpu=base; fi
    fi
    if [[ "${gpu}" == nvidia ]]; then
        image="${REGISTRY}/${IMAGE_NAME}-nvidia:${channel}"
        echo "Graphics: NVIDIA, so the NVIDIA image (prebuilt open drivers)."
    else
        image="${REGISTRY}/${IMAGE_NAME}:${channel}"
        echo "Graphics: AMD or Intel, so the standard image."
    fi
    ref="ostree-unverified-registry:${image}"

    say "Packages installed on top of Fedora"
    classify_layered
    local -a remove=("${CONFLICTS[@]}")
    if (( remove_all )); then
        remove+=("${OTHERS[@]}")
    fi
    if (( ${#CONFLICTS[@]} + ${#OTHERS[@]} == 0 )); then
        echo "None."
    else
        (( ${#CONFLICTS[@]} > 0 )) && echo "Removed (they clash with the image): ${CONFLICTS[*]}"
        if (( ${#OTHERS[@]} > 0 )); then
            if (( remove_all )); then
                echo "Also removed (--remove-all-layered): ${OTHERS[*]}"
            else
                echo "Kept: ${OTHERS[*]}"
                echo "  Kept packages are reinstalled on top of every update, which makes"
                echo "  updates slower and stops automatic background updates. Most apps"
                echo "  are available as Flatpaks in the Software app instead; run again"
                echo "  with --remove-all-layered to drop them."
            fi
        fi
    fi

    local -a cmd=(sudo rpm-ostree rebase)
    for pkg in "${remove[@]}"; do
        cmd+=("--uninstall=${pkg}")
    done
    cmd+=("${ref}")

    say "Plan"
    echo "Image:    ${image}"
    echo "Command:  ${cmd[*]}"
    echo "Kept:     every user account, home folder, setting and Flatpak app."
    echo "Undo:     choose the previous entry in the boot menu, or run: rpm-ostree rollback"
    if [[ "${gpu}" == nvidia ]] && mokutil --sb-state 2>/dev/null | grep -q enabled; then
        echo
        warn "Secure Boot is on. After the first restart run 'blujust enroll-secure-boot-key',"
        warn "restart, choose 'Enroll MOK' on the blue screen and enter the password 'bluebuild'."
        warn "Until then the NVIDIA driver does not load and the screen uses basic graphics."
    fi

    if (( dry_run )); then
        echo
        echo "Dry run: nothing was changed."
        return 0
    fi
    echo
    confirm "Move this machine to Shattered Vales OS ${EDITION_NAME} now? (downloads several GB)" || { echo "Cancelled; nothing was changed."; return 0; }

    say "Downloading and preparing the image"
    "${cmd[@]}"

    say "Done"
    echo "Restart to start ${EDITION_NAME}. After it boots it switches itself to the"
    echo "signature-verified image in the background; that applies at the next restart."
    echo "Then run sv-doctor to check everything."
    if confirm "Restart now?"; then
        systemctl reboot
    fi
}

main "$@"
