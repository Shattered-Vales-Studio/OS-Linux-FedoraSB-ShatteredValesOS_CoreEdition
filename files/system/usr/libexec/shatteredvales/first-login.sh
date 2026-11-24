#!/usr/bin/env bash
#
# first-login.sh
#
# Purpose:
#   Per-person setup that cannot live in the read-only image. Runs from the
#   desktop autostart at every login but only does work for steps that have
#   not completed yet, so steps added in later images reach existing
#   accounts automatically.
#
#   Core Edition provides the framework and the steps every edition shares.
#   An edition adds its own by shipping a drop-in file in
#   /usr/libexec/shatteredvales/first-login.d/ (sourced in name order) that
#   defines functions and registers them:
#     LOGIN_HOOKS+=(fn)            runs at every login, before the steps
#     STEPS+=("<id>-v1 fn")        runs once, after Core's own steps
#     LATE_STEPS+=("<id>-v1 fn")   runs once, after the Craft app installs
#   A step function returns 0 when done, 2 when it cannot run yet and should
#   be tried again silently at the next login, and anything else on failure.
#   Bump a step's -vN suffix to run it again for everyone.
#
# Usage:
#   Runs automatically at login. Can be re-run manually with `sv-first-login`.
#   `first-login.sh --list-steps` prints the id of every registered step,
#   Core's and the editions', one per line, without running anything (used
#   by sv-doctor).
#
# State:
#   ~/.local/state/shatteredvales/<step>.done marks a finished step.
#
# Exit codes:
#   0 always; failed steps are retried at the next login.

set -uo pipefail

readonly STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/shatteredvales"
readonly LOG_FILE="${STATE_DIR}/first-login.log"
readonly DROPIN_DIR=/usr/libexec/shatteredvales/first-login.d
readonly CRAFT_LIST=/usr/share/shatteredvales/artcraft-apps.list

LOGIN_HOOKS=()
STEPS=()
LATE_STEPS=()

# notify
#   Shows a desktop notification when a graphical session is available.
#   Arguments: $1 summary, $2 body
#   Returns: 0 always
notify() {
    if command -v notify-send >/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        notify-send --app-name="Shattered Vales" --icon=shatteredvales-logo "$1" "$2" || true
    fi
}

# run_step
#   Runs a setup function once per user and records success.
#   Arguments: $1 step id, $2 function name
#   Returns: 0 when done or not runnable yet, 1 when the step failed;
#            either way an unfinished step runs again at the next login
run_step() {
    local id="$1" fn="$2" status
    [[ -f "${STATE_DIR}/${id}.done" ]] && return 0
    echo "== ${id} ($(date -Is))"
    "${fn}"
    status=$?
    case "${status}" in
        0) touch "${STATE_DIR}/${id}.done" ;;
        2) echo "Step ${id} cannot run yet; it will be tried at next login" ;;
        *) echo "Step ${id} failed; it will retry on next login"; return 1 ;;
    esac
}

# run_steps
#   Runs a list of registered steps in order.
#   Arguments: the list entries, each "<id> <function>"
#   Returns: 0 when every step is done or waiting, 1 if any failed
run_steps() {
    local entry failed=0
    for entry in "$@"; do
        run_step "${entry%% *}" "${entry#* }" || failed=1
    done
    return "${failed}"
}

# wait_for_network
#   Waits up to two minutes for connectivity, since autostart can fire
#   before Wi-Fi or Tailscale is up.
#   Returns: 0 when online, 1 on timeout
wait_for_network() {
    nm-online -q -t 120
}

# documents_dir
#   Prints the person's Documents folder, creating it when needed.
#   xdg-user-dir falls back to $HOME when the folder is not configured, and
#   files must never be dropped loose in the home folder.
#   Arguments: none
#   Output: the folder's path on stdout
#   Returns: 0 on success
documents_dir() {
    local documents
    documents="$(xdg-user-dir DOCUMENTS 2>/dev/null)"
    [[ -n "${documents}" && "${documents}" != "${HOME}" ]] || documents="${HOME}/Documents"
    mkdir -p "${documents}"
    echo "${documents}"
}

# install_craft_app
#   Installs one Craft app as a user Flatpak bundle from its latest GitHub
#   release, after checking the bundle against the release's SHA256SUMS.txt.
#   Uses github.com download URLs rather than the API, which allows only 60
#   unauthenticated requests an hour per IP and would run out when a whole
#   office logs in at once.
#   Arguments: $1 app id, $2 GitHub owner/repo, $3 work directory
#   Returns: 0 on success, 1 on download, checksum or install failure
install_craft_app() {
    local id="$1" repo="$2" work="$3" base sums line file sum
    base="https://github.com/${repo}/releases/latest/download"
    sums="$(curl -fsSL --retry 2 "${base}/SHA256SUMS.txt")" || return 1
    line="$(grep -E "  ${id}-[0-9][^ ]*-linux-x86_64\.flatpak$" <<<"${sums}" | head -n1)"
    [[ -n "${line}" ]] || { echo "No x86_64 Flatpak in the latest ${repo} release"; return 1; }
    file="${line##* }"
    sum="${line%% *}"
    curl -fsSL --retry 2 -o "${work}/${file}" "${base}/${file}" || return 1
    echo "${sum}  ${work}/${file}" | sha256sum -c --quiet - || return 1
    # The same command ArtCraft Launcher runs, so it recognises and updates
    # these installs as its own.
    flatpak install --user -y --noninteractive --reinstall --bundle "${work}/${file}" || return 1
    rm -f "${work:?}/${file}"
}

# craft_installed
#   Tells whether a Craft app's Flatpak is installed for this user or for
#   the whole system.
#   Arguments: $1 Flatpak app id
#   Returns: 0 when installed, 1 otherwise
craft_installed() {
    flatpak info --user "$1" >/dev/null 2>&1 || flatpak info --system "$1" >/dev/null 2>&1
}

# craft_list_sum
#   Fingerprints the edition's ArtCraft list, so a different list (after
#   moving to another edition, or a new image adding apps) is noticed.
#   Arguments: none
#   Output: the list's checksum on stdout
#   Returns: 0 always
craft_list_sum() {
    sha256sum "${CRAFT_LIST}" 2>/dev/null | cut -d' ' -f1
}

# recheck_craft_list
#   Marks the ArtCraft install step as pending again when the list differs
#   from the one last installed. The step only installs apps that are
#   missing, so this adds an edition's extra apps without touching the
#   ones the person already has. Accounts set up before the fingerprint
#   existed are rechecked once, which installs nothing when nothing is
#   missing.
#   Arguments: none
#   Returns: 0 always
recheck_craft_list() {
    local done_mark="${STATE_DIR}/artcraft-apps-v1.done" sum_file="${STATE_DIR}/artcraft-apps.list.sum"
    [[ -f "${done_mark}" ]] || return 0
    [[ "$(cat "${sum_file}" 2>/dev/null)" == "$(craft_list_sum)" ]] && return 0
    echo "The ArtCraft app list changed; installing any apps that are missing"
    rm -f "${done_mark}"
}

# step_artcraft_apps
#   Installs the edition's Craft apps (listed in artcraft-apps.list) for
#   this user. Apps the user already has are skipped, and with nothing
#   missing it finishes quietly without going online. Records the list's
#   fingerprint so a changed list runs it again; failures are retried at
#   the next login.
#   Returns: 0 if every app is installed, 1 otherwise
step_artcraft_apps() {
    local id flatpak_id repo work entry failed=0
    local -a missing=()
    while read -r id flatpak_id repo; do
        [[ -z "${id}" || "${id}" == \#* ]] && continue
        craft_installed "${flatpak_id}" || missing+=("${id} ${repo}")
    done < "${CRAFT_LIST}"
    if (( ${#missing[@]} == 0 )); then
        craft_list_sum > "${STATE_DIR}/artcraft-apps.list.sum"
        return 0
    fi
    wait_for_network || return 1
    # Bundles pull their runtime from the user's Flathub remote.
    flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
    notify "Installing ArtCraft apps" "${#missing[@]} apps download in the background; ArtCraft Launcher keeps them updated afterwards."
    work="$(mktemp -d)"
    for entry in "${missing[@]}"; do
        read -r id repo <<<"${entry}"
        echo "Installing ${id} from ${repo}"
        install_craft_app "${id}" "${repo}" "${work}" || { echo "Failed: ${id}"; failed=1; }
    done
    rm -rf "${work}"
    (( failed == 0 )) || return 1
    craft_list_sum > "${STATE_DIR}/artcraft-apps.list.sum"
    notify "ArtCraft apps installed" "Open ArtCraft Launcher to see the suite and check for updates."
}

# is_generated_avatar
#   Tells a picture the user chose apart from the initials avatar GNOME
#   Initial Setup generates. Generated avatars are drawn as a circle with
#   transparent corners; photos and GNOME's stock pictures are opaque
#   squares, which GNOME crops to a circle only when displaying them.
#   Arguments: $1 path to the current account picture
#   Returns: 0 if the picture is a generated initials avatar, 1 otherwise
is_generated_avatar() {
    python3 -I - "$1" <<'PY'
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
try:
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(sys.argv[1])
except Exception:
    sys.exit(1)
if not pixbuf.get_has_alpha():
    sys.exit(1)
pixels = pixbuf.get_pixels()
# Alpha of the top-left pixel (RGBA, so byte 3).
sys.exit(0 if pixels[3] == 0 else 1)
PY
}

# is_admin
#   Tells whether this account is an administrator (a member of wheel).
#   Arguments: none
#   Returns: 0 for administrators, 1 otherwise
is_admin() {
    id -nG | tr ' ' '\n' | grep -qx wheel
}

# sync_user_icon
#   Gives the account the Shattered Vales logo as its picture when it has
#   none, only GNOME's generated initials avatar, or one of the image's own
#   defaults: red for administrators, gold for everyone else, so the login
#   screen shows which accounts can change the computer. Runs at every login
#   so the colour follows the account when it is made or unmade an
#   administrator. Pictures the user chose are never replaced.
#   Arguments: none
#   Returns: 0 when the picture is set or kept, 1 if setting it failed
sync_user_icon() {
    local user_path icon default=/usr/share/shatteredvales/avatar.png
    local admin=/usr/share/shatteredvales/avatar-admin.png picture
    user_path="$(busctl --system call org.freedesktop.Accounts /org/freedesktop/Accounts \
        org.freedesktop.Accounts FindUserById x "$(id -u)" | cut -d'"' -f2)" || return 1
    icon="$(busctl --system get-property org.freedesktop.Accounts "${user_path}" \
        org.freedesktop.Accounts.User IconFile | cut -d'"' -f2)" || return 1
    picture="${default}"
    is_admin && picture="${admin}"
    # AccountsService stores a copy, so the current picture is compared by
    # content with the defaults rather than by path.
    if [[ -s "${icon}" ]]; then
        cmp -s "${icon}" "${picture}" && return 0
        if ! cmp -s "${icon}" "${default}" && ! cmp -s "${icon}" "${admin}" \
            && ! is_generated_avatar "${icon}"; then
            return 0
        fi
    fi
    busctl --system call org.freedesktop.Accounts "${user_path}" \
        org.freedesktop.Accounts.User SetIconFile s "${picture}" >/dev/null
}

# sync_share_bookmarks
#   Adds the shares listed in /etc/shatteredvales/network-shares to the
#   Files sidebar. Runs at every login rather than once, so shares an admin
#   adds later reach existing users. Windows paths (\\server\share) are
#   converted to smb:// addresses; bookmarks already present are left alone.
#   Arguments: none
#   Returns: 0 always
sync_share_bookmarks() {
    local list=/etc/shatteredvales/network-shares
    local bookmarks="${XDG_CONFIG_HOME:-${HOME}/.config}/gtk-3.0/bookmarks"
    local address name url
    [[ -r "${list}" ]] || return 0
    mkdir -p "$(dirname "${bookmarks}")"
    touch "${bookmarks}"
    while read -r address name; do
        [[ -z "${address}" || "${address}" == \#* ]] && continue
        if [[ "${address}" == \\\\* ]]; then
            url="smb://$(sed -e 's#^\\\\##' -e 's#\\#/#g' <<<"${address}")"
        else
            url="${address}"
        fi
        # Compared as a whole first field, since addresses contain dots and
        # other characters grep would treat as a pattern.
        awk -v u="${url}" '$1 == u {found = 1} END {exit !found}' "${bookmarks}" && continue
        echo "${url}${name:+ ${name}}" >> "${bookmarks}"
        echo "Added share bookmark ${url}"
    done < "${list}"
}

# sync_storage_launcher
#   Shows the Set Up Drives launcher to administrators only. The system copy
#   is hidden (NoDisplay=true) because setting up drives needs an
#   administrator; each administrator gets a visible copy in their own
#   applications folder, made from the system file at every sign-in so it
#   never drifts from it and follows the account when it is made or unmade
#   an administrator. A copy this hook did not write is left alone.
#   Arguments: none
#   Returns: 0 always
sync_storage_launcher() {
    local system=/usr/share/applications/shatteredvales-storage.desktop
    local dir="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
    local copy="${dir}/shatteredvales-storage.desktop" marker="X-ShatteredVales-Generated=true"
    if [[ -f "${copy}" ]] && ! grep -qxF "${marker}" "${copy}"; then
        return 0
    fi
    if is_admin && [[ -f "${system}" ]]; then
        mkdir -p "${dir}"
        # The marker goes right after the group header so it stays in the
        # [Desktop Entry] group, before any [Desktop Action] groups.
        if awk -v marker="${marker}" '
            $0 == "NoDisplay=true" { $0 = "NoDisplay=false" }
            { print }
            $0 == "[Desktop Entry]" { print marker }
        ' "${system}" > "${copy}.tmp"; then
            mv "${copy}.tmp" "${copy}"
        else
            rm -f "${copy}.tmp"
        fi
    else
        rm -f "${copy}"
    fi
    return 0
}

# notify_new_drives
#   Tells administrators about internal drives that are not used for
#   anything yet and offers to set them up. USB and other external drives
#   are never mentioned (sv-storage check leaves them out). A drive someone
#   chose "Don't Ask Again" for is remembered by its serial number and not
#   mentioned again; closing the notification means "not now", so it comes
#   back at the next login. The notification waits for an answer in its own
#   background session, so login is never held up.
#   Arguments: none
#   Returns: 0 always
notify_new_drives() {
    local dismissed="${STATE_DIR}/drives-dismissed" found path id title status
    local -a ids=() titles=()
    is_admin || return 0
    command -v sv-storage >/dev/null && command -v notify-send >/dev/null || return 0
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 0
    found="$(sv-storage check 2>/dev/null)"
    status=$?
    (( status == 10 )) || return 0
    touch "${dismissed}"
    while IFS=$'\t' read -r path id title; do
        [[ -n "${path}" && -n "${id}" ]] || continue
        grep -qxF "${id}" "${dismissed}" && continue
        ids+=("${id}")
        titles+=("${title}")
    done <<<"${found}"
    (( ${#ids[@]} )) || return 0
    echo "New drives found: ${titles[*]}"
    local summary="New drive found: ${titles[0]}"
    local body="It is not used for anything yet. Set it up for storage, apps or home folders?"
    if (( ${#titles[@]} > 1 )); then
        summary="${#titles[@]} new drives found"
        # One bullet per drive and a blank line before the question, so the
        # names stay apart even where the notification is shown on one line.
        body="$(printf '• %s\n' "${titles[@]}")

They are not used for anything yet. Set them up for storage, apps or home folders?"
    fi
    # The script runs detached with setsid; its arguments are the dismissed
    # file, the summary, the body and the drive ids.
    # shellcheck disable=SC2016
    setsid -f bash -c '
        file="$1"; summary="$2"; body="$3"; shift 3
        answer="$(notify-send --app-name="Shattered Vales" --icon=shatteredvales-storage \
            --action=setup="Set Up" --action=ignore="Don'"'"'t Ask Again" --wait \
            "${summary}" "${body}")"
        case "${answer}" in
            setup) gtk-launch shatteredvales-storage ;;
            ignore) printf "%s\n" "$@" >> "${file}" ;;
        esac
    ' _ "${dismissed}" "${summary}" "${body}" "${ids[@]}" >/dev/null 2>&1 </dev/null
    return 0
}

# step_terminal_palette
#   Makes the Shattered Vales palette the default colours of the user's
#   Ptyxis profile. Ptyxis reads custom palettes only from the user's data
#   folder, so the palette is copied there. A profile is created when the
#   user has never opened Ptyxis, and a palette the user already chose is
#   left alone.
#   Arguments: none
#   Returns: non-zero if the palette cannot be installed or applied
step_terminal_palette() {
    local dir="${XDG_DATA_HOME:-${HOME}/.local/share}/org.gnome.Ptyxis/palettes"
    local uuid path current
    mkdir -p "${dir}"
    cp /usr/share/shatteredvales/ptyxis/ShatteredVales.palette "${dir}/" || return 1
    uuid="$(gsettings get org.gnome.Ptyxis default-profile-uuid | tr -d "'")" || return 1
    if [[ -z "${uuid}" ]]; then
        # Ptyxis profile ids are 32 hex digits, the same shape it generates.
        uuid="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        gsettings set org.gnome.Ptyxis profile-uuids "['${uuid}']" || return 1
        gsettings set org.gnome.Ptyxis default-profile-uuid "${uuid}" || return 1
    fi
    path="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/${uuid}/"
    current="$(gsettings get "${path}" palette | tr -d "'")" || return 1
    [[ "${current}" == gnome ]] || return 0
    gsettings set "${path}" palette ShatteredVales
}

# load_dropins
#   Sources every edition drop-in, which registers its hooks and steps.
#   A drop-in that fails to load is logged and skipped so Core's own setup
#   still runs.
#   Arguments: none
#   Returns: 0 always
load_dropins() {
    local dropin
    for dropin in "${DROPIN_DIR}"/*.sh; do
        [[ -f "${dropin}" ]] || continue
        # shellcheck source=/dev/null
        source "${dropin}" || echo "Could not load ${dropin}"
    done
}

# register_steps
#   Registers Core's hooks and steps, then loads the editions' drop-ins,
#   which add theirs.
#   Arguments: none
#   Returns: 0 always
register_steps() {
    STEPS=("terminal-palette-v1 step_terminal_palette")
    # Last, because the installs download several hundred MB.
    LATE_STEPS=("artcraft-apps-v1 step_artcraft_apps")
    # The launcher first: the new-drive alert's Set Up button opens it.
    LOGIN_HOOKS=(sync_storage_launcher notify_new_drives)
    load_dropins
}

# main
#   Runs every login hook and pending setup step, logging to the state
#   directory, or lists the registered steps with --list-steps.
#   Arguments: $1 optional --list-steps
#   Returns: 0 always; failed steps are retried at the next login
main() {
    if [[ "${1:-}" == --list-steps ]]; then
        register_steps >/dev/null 2>&1
        local entry
        for entry in "${STEPS[@]}" "${LATE_STEPS[@]}"; do
            echo "${entry%% *}"
        done
        return 0
    fi

    mkdir -p "${STATE_DIR}"
    exec >>"${LOG_FILE}" 2>&1
    register_steps

    local failed=0 hook
    for hook in "${LOGIN_HOOKS[@]}"; do
        "${hook}" || failed=1
    done
    sync_user_icon || failed=1
    sync_share_bookmarks
    run_steps "${STEPS[@]}" || failed=1
    recheck_craft_list
    run_steps "${LATE_STEPS[@]}" || failed=1

    if (( failed )); then
        notify "Setup not finished yet" "It will try again the next time you sign in."
    fi
}

main "$@"
