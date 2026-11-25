#!/usr/bin/env bash
#
# selinux-repair.sh
#
# Purpose:
#   Turns SELinux back on for machines installed from offline USB installers
#   built before OS-Installer PR #11. Those installers started Anaconda with
#   selinux=0, which Anaconda copies onto the installed system's kernel
#   command line, so the machine boots with SELinux disabled and the files
#   the install wrote (the first account's home folder among them) carry
#   no SELinux labels. Updates never remove the argument, so the repair has
#   to edit the kernel arguments itself. It works in stages, one per normal
#   restart, and never restarts the machine on its own:
#     1. Booted with selinux=0: replace it with enforcing=0, so the next
#        restart runs SELinux in permissive mode (it logs, never blocks).
#     2. Booted permissive after stage 1: relabel /etc and /var, and label
#        the files the install left unlabelled under /boot and /sysroot,
#        before anyone can sign in; then remove enforcing=0, so the restart
#        after that is fully enforcing. /usr comes labelled from the image.
#     3. Done: nothing to do.
#   Someone who set SELINUX=disabled in /etc/selinux/config on purpose is
#   left alone. A failed step leaves the machine as it was (disabled or
#   permissive, never unbootable) and is retried at the next start.
#
# Inputs:
#   /proc/cmdline, /etc/selinux/config, rpm-ostree (kernel arguments)
#
# State:
#   /var/lib/shatteredvales/selinux-repair holds the stage reached:
#   "stage1" (kernel arguments changed, waiting for a restart) or "done".
#   Readable by everyone so sv-doctor can report it.
#
# Usage:
#   Run at every boot by shatteredvales-selinux-repair.service.
#
# Exit codes:
#   0 when there is nothing to do or the stage completed, 1 when a stage
#   failed (it is tried again at the next start).

set -euo pipefail

readonly STATE_DIR=/var/lib/shatteredvales
readonly STATE_FILE="${STATE_DIR}/selinux-repair"
readonly CONFIG=/etc/selinux/config
# Long enough for a nightly update download that started just before.
readonly IDLE_TRIES=90
readonly IDLE_WAIT=10

# log
#   Writes a line to the journal (through stdout of the service) and to
#   the boot screen, so a slow relabel does not look like a hang.
#   Arguments: message words
#   Returns: 0 always
log() {
    echo "$*"
    if command -v plymouth >/dev/null && plymouth --ping 2>/dev/null; then
        plymouth display-message --text="$*" 2>/dev/null || true
    fi
}

# has_karg
#   Tells whether the running kernel was started with an argument.
#   Arguments: $1 the exact argument, e.g. selinux=0
#   Returns: 0 when present, 1 otherwise
has_karg() {
    tr ' ' '\n' < /proc/cmdline | grep -qx "$1"
}

# configured_mode
#   Prints the SELinux mode set in /etc/selinux/config.
#   Arguments: none
#   Output: enforcing, permissive, disabled, or nothing when unset
#   Returns: 0 always
configured_mode() {
    sed -n 's/^[[:space:]]*SELINUX=[[:space:]]*\([a-z]*\).*/\1/p' "${CONFIG}" 2>/dev/null | tail -n1
}

# stage
#   Prints the recorded stage.
#   Arguments: none
#   Output: stage1, done, or nothing
#   Returns: 0 always
stage() {
    cat "${STATE_FILE}" 2>/dev/null || true
}

# record
#   Records the stage reached.
#   Arguments: $1 stage name
#   Returns: non-zero if the state cannot be written
record() {
    mkdir -p "${STATE_DIR}"
    printf '%s\n' "$1" > "${STATE_FILE}.tmp"
    chmod 0644 "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

# wait_for_idle
#   Waits until rpm-ostree has no transaction running, since an update
#   being downloaded or deployed would refuse or race a kernel-argument
#   change.
#   Arguments: none
#   Returns: 0 when idle, 1 after the timeout
wait_for_idle() {
    local i
    for (( i = 0; i < IDLE_TRIES; i++ )); do
        if [[ -z "$(rpm-ostree status --json | jq -r '.transaction // empty | tostring')" ]]; then
            return 0
        fi
        sleep "${IDLE_WAIT}"
    done
    echo "rpm-ostree stayed busy; trying again at the next start"
    return 1
}

# edit_kargs
#   Changes kernel arguments with rpm-ostree. When an update is already
#   waiting for a restart, rpm-ostree applies the change to that waiting
#   update rather than replacing it, so the update is kept.
#   Arguments: rpm-ostree kargs options
#   Returns: rpm-ostree's exit status
edit_kargs() {
    wait_for_idle || return 1
    rpm-ostree kargs "$@"
}

# relabel
#   Restores the SELinux labels of /etc and /var (including home folders
#   and every other mount below them) from the loaded policy. Missing
#   files are expected on a running system (a temporary file deleted while
#   the walk runs), so only a failure to run at all is an error.
#   Arguments: none
#   Returns: 0 when restorecon ran, non-zero if it could not start
relabel() {
    local started=${SECONDS} rc=0
    log "Repairing file security labels; this can take a few minutes..."
    restorecon -RF -T 0 /etc /var || rc=$?
    # restorecon exits 255 when any single file failed, which a file that
    # vanished mid-walk causes; anything else means it did not run.
    if (( rc != 0 && rc != 255 )); then
        echo "restorecon failed (exit ${rc})"
        return 1
    fi
    echo "Relabelled /etc and /var in $(( SECONDS - started )) s (restorecon exit ${rc})"
    relabel_unlabelled_system
}

# relabel_unlabelled_system
#   Labels the files under /boot and /sysroot that the install wrote with no
#   label at all. bootupd is confined and cannot read unlabelled boot files,
#   so /boot gets its policy labels (boot_t) from restorecon. The policy has
#   no entries for /sysroot: on a healthy machine ostree's files there are
#   root_t, inherited from /sysroot itself, while restorecon would make them
#   default_t, which confined services cannot read; so unlabelled files
#   there get root_t, exactly as on a healthy machine. Both are mounted
#   read-only, so this runs in a private mount namespace where they are
#   remounted writable, the way ostree itself writes there; the rest of the
#   system keeps seeing them read-only. Only unlabelled files are touched,
#   and the stateroot's var tree is skipped: it is the same /var seen
#   through another path, already relabelled above.
#   Arguments: none
#   Returns: 0 always; a failure here is logged and SELinux still comes on,
#            since these files only matter to bootloader updates
relabel_unlabelled_system() {
    local count
    # The single-quoted script runs in the new namespace, not this shell.
    # shellcheck disable=SC2016
    count="$(unshare --mount --propagation private -- bash -c '
        set -uo pipefail
        for m in /boot /sysroot; do
            mountpoint -q "$m" && mount -o remount,rw "$m"
        done
        boot="$(mktemp)" sysroot="$(mktemp)"
        find /boot -xdev -context "*:unlabeled_t:*" -print0 > "${boot}" 2>/dev/null
        find /sysroot -xdev -path "/sysroot/ostree/deploy/*/var" -prune \
            -o -context "*:unlabeled_t:*" -print0 > "${sysroot}" 2>/dev/null
        xargs -0 -r restorecon -F < "${boot}"
        xargs -0 -r chcon -h system_u:object_r:root_t:s0 < "${sysroot}"
        cat "${boot}" "${sysroot}" | tr -cd "\0" | wc -c
        rm -f "${boot}" "${sysroot}"
    ')" || true
    echo "Labelled ${count:-0} unlabelled files under /boot and /sysroot"
}

# main
#   Decides which stage applies to this boot and runs it.
#   Arguments: none
#   Returns: 0 when nothing to do or the stage completed, 1 on failure
main() {
    local mode current
    [[ -e /run/ostree-booted ]] || exit 0
    mode="$(configured_mode)"
    current="$(stage)"

    if has_karg selinux=0; then
        case "${mode}" in
            enforcing|permissive) ;;
            *)
                echo "SELinux is set to '${mode:-unset}' in ${CONFIG}; leaving it disabled"
                exit 0 ;;
        esac
        [[ "${current}" == stage1 ]] && exit 0
        echo "Booted with selinux=0 from an older offline installer; scheduling the repair"
        edit_kargs --delete-if-present=selinux=0 --append-if-missing=enforcing=0
        record stage1
        echo "Stage 1 done: the next restart runs SELinux in permissive mode and relabels"
        exit 0
    fi

    if [[ "${current}" == stage1 ]]; then
        if ! selinuxenabled; then
            echo "SELinux is still off in this boot; waiting for the next restart"
            exit 0
        fi
        relabel
        edit_kargs --delete-if-present=enforcing=0
        record "done"
        echo "Stage 2 done: SELinux enforces from the next restart"
        exit 0
    fi

    # A restart into an update deployed before stage 2 removed enforcing=0
    # would carry it again; finish the job instead of staying permissive.
    if [[ "${current}" == "done" ]] && has_karg enforcing=0; then
        echo "enforcing=0 is back on the command line; removing it again"
        edit_kargs --delete-if-present=enforcing=0
    fi
}

main "$@"
