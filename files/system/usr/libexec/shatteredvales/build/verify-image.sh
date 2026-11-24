#!/usr/bin/env bash
#
# verify-image.sh
#
# Purpose:
#   Final build gate. Fails the build when the image is not a valid bootc
#   image or breaks any rule in its check lists, so a broken image is never
#   published. Core Edition and every edition built on it share this one
#   gate: each ships a check list in /usr/share/shatteredvales/verify.d,
#   and Core's list stays in every edition, so nothing Core provides can
#   silently go missing from an edition.
#
# Inputs:
#   /usr/share/shatteredvales/verify.d/*.list, one rule per line:
#     rpm <name>                 the package must be installed
#     path <path>                the path must exist (spaces allowed)
#     forbid-rpm <name>          the package must not be installed
#     forbid-path <path>         the path must not exist
#     service-disabled <unit>    the unit must not be enabled
#   Blank lines and lines starting with # are ignored.
#   /usr/libexec/shatteredvales/verify.d/*.sh, extra checks an edition
#   needs (for example parsing an app); each must exit non-zero on failure.
#
# Usage:
#   Run as the last build step, after signing:
#     - type: script
#       snippets:
#         - /usr/libexec/shatteredvales/build/verify-image.sh
#
# Exit codes:
#   0 when every check passes, 1 otherwise.

set -euo pipefail

readonly LIST_DIR=/usr/share/shatteredvales/verify.d
readonly HOOK_DIR=/usr/libexec/shatteredvales/verify.d

# check_rule
#   Checks one rule from a check list.
#   Arguments: $1 rule kind, $2 its argument, $3 "file:line" for messages
#   Returns: 0 when the rule holds, 1 otherwise
check_rule() {
    local kind="$1" arg="$2" where="$3"
    case "${kind}" in
        rpm)
            rpm -q "${arg}" >/dev/null 2>&1 || { echo "MISSING RPM: ${arg} (${where})"; return 1; } ;;
        path)
            [[ -e "${arg}" ]] || { echo "MISSING PATH: ${arg} (${where})"; return 1; } ;;
        forbid-rpm)
            ! rpm -q "${arg}" >/dev/null 2>&1 || { echo "UNEXPECTED RPM: ${arg} (${where})"; return 1; } ;;
        forbid-path)
            [[ ! -e "${arg}" ]] || { echo "UNEXPECTED PATH: ${arg} (${where})"; return 1; } ;;
        service-disabled)
            [[ "$(systemctl is-enabled "${arg}" 2>/dev/null)" != enabled ]] \
                || { echo "UNEXPECTED: ${arg} is enabled (${where})"; return 1; } ;;
        *)
            echo "UNKNOWN RULE: ${kind} (${where})"; return 1 ;;
    esac
}

# check_lists
#   Applies every rule in every check list.
#   Arguments: none
#   Returns: 0 when every rule holds, 1 otherwise (also when no list exists,
#            since a gate that checks nothing would pass any image)
check_lists() {
    local list name line kind arg n failed=0 found=0
    for list in "${LIST_DIR}"/*.list; do
        [[ -f "${list}" ]] || continue
        found=1
        name="$(basename "${list}")"
        n=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            n=$((n + 1))
            [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
            kind="${line%% *}"
            arg="${line#* }"
            check_rule "${kind}" "${arg}" "${name}:${n}" || failed=1
        done < "${list}"
    done
    (( found )) || { echo "No check lists in ${LIST_DIR}"; return 1; }
    return "${failed}"
}

# check_hooks
#   Runs every extra check an edition ships.
#   Arguments: none
#   Returns: 0 when every hook passes, 1 otherwise
check_hooks() {
    local hook failed=0
    for hook in "${HOOK_DIR}"/*.sh; do
        [[ -f "${hook}" ]] || continue
        echo "== $(basename "${hook}")"
        bash "${hook}" || { echo "CHECK FAILED: ${hook}"; failed=1; }
    done
    return "${failed}"
}

# main
#   Runs the check lists, the hooks, the Plymouth theme check and bootc lint.
#   Arguments: none
#   Returns: 0 when every check passes; exits 1 otherwise
main() {
    local failed=0
    check_lists || failed=1
    check_hooks || failed=1
    grep -q '^Theme=shatteredvales' /etc/plymouth/plymouthd.conf \
        || { echo "Plymouth theme not set"; failed=1; }

    bootc container lint || failed=1

    if (( failed )); then
        echo "Image verification failed" >&2
        exit 1
    fi
    echo "Image verification passed"
}

main "$@"
