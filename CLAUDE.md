# CLAUDE.md — Shattered Vales OS Core Edition

You are working on Shattered Vales OS **Core Edition**: the shared base of
every Shattered Vales OS edition, and an installable edition of its own. It
is a custom Fedora Atomic (Silverblue) image built with BlueBuild and
published to GHCR as `shatteredvales-os-core` and
`shatteredvales-os-core-nvidia`. Read this whole file before making changes.

## How the editions fit together

```
ghcr.io/blue-build/base-images/fedora-silverblue(-nvidia-open)
  └─ shatteredvales-os-core(-nvidia)        this repository (Core Edition)
       ├─ shatteredvales-os-home(-nvidia)    Home Edition
       ├─ shatteredvales-os(-nvidia)         Studio Edition
       └─ future editions
```

- Each edition's recipe uses `shatteredvales-os-core(-nvidia)` as its
  `base-image` with `image-version: latest`, so it builds on Core's
  **promoted** image. A change here reaches an edition at that edition's
  next build (nightly, or a manual run) after Core is promoted, and then
  goes through the edition's own `:testing` canary and promotion.
- Anything every edition should have goes here: packages, Flatpaks, files,
  first-login steps, `sv-doctor` checks, release-gate rules. No edition repo
  needs a change to receive it.
- Editions only add or replace. Never put something here that an edition
  would have to remove; layers cannot cleanly take things away.
- Editions replace a single-file config (Firefox policy, `mimeapps.list`,
  `artcraft-apps.list`) by shipping their own copy, and
  extend layered ones with drop-ins:

| What | Core | Edition drop-in |
|---|---|---|
| Desktop defaults | `/etc/dconf/db/local.d/10-shatteredvales-desktop` | `50-shatteredvales-<edition>` (later name wins) |
| Per-person setup | `first-login.sh` | `/usr/libexec/shatteredvales/first-login.d/*.sh` |
| Support checks | `sv-doctor` | `/usr/libexec/shatteredvales/sv-doctor.d/*.sh` |
| Release gate | `verify.d/core.list` | `/usr/share/shatteredvales/verify.d/<edition>.list`, `/usr/libexec/shatteredvales/verify.d/*.sh` |
| First-boot Flatpaks | `recipes/common/flatpaks.yml` | the edition's own `default-flatpaks` module (BlueBuild appends) |

## How this repository works

- `recipes/recipe-base.yml` and `recipes/recipe-nvidia.yml` differ **only** in
  `name`, `description` and `base-image`. Every other change goes in
  `recipes/common/*.yml` so the two images can never drift.
- `files/system/` is copied to `/` in the image. `files/scripts/` holds
  build-time scripts that only Core runs.
- Build steps that editions must run again over Core live **in the image**,
  in `/usr/libexec/shatteredvales/build/`: `apply-branding.sh` (os-release,
  banners, shell theme, dconf, boot splash) and `verify-image.sh` (the
  release gate). Every step must be safe to run twice.
- `branding/` is the single source for colors, fonts and artwork. Gold,
  black and the fonts mirror tokens in the website's
  `assets/css/variables.css`; the edition colour and the administrator red
  are not site tokens and their contrast ratios are documented in
  `branding/brand.env`. Check contrast for any new colour pairing before
  using it (AAA 7:1 for text).
- `scripts/render-branding.sh [target-repo]` renders artwork for Core or,
  with an edition's repository as the target, for that edition, using
  Core's fonts, logo and wallpaper generator. Rendered PNGs are committed.
  Never hand-edit them; change `branding/` and re-render.
- Brand values reach the image through `/usr/share/shatteredvales/brand.env`
  (a copy made by the renderer). Templates use `@BRAND_*@` placeholders that
  build scripts substitute.
- `sv-migrate.sh` moves a Silverblue machine onto any edition
  (`--edition core|home|studio`); edition READMEs link to this copy.
- Installer USB sticks are built by `Shattered-Vales-Studio/OS-Installer`.

## Commands

| Command | Purpose |
|---|---|
| `just branding` | Render Core's artwork from `branding/` |
| `just validate` | Schema-check recipes |
| `just build [base\|nvidia]` | Build an image locally (linux/amd64) |
| `just test [base\|nvidia]` | Smoke-test a local build |
| `just lint` | shellcheck every script |
| `just keys` | Create the cosign key pair (one time) |

## Testing limits

- The Mac can **build** and **inspect** images, not boot them. Real boot
  testing (Plymouth, GDM, lock screen, first login) needs an x86_64 machine
  or a VM (GNOME Boxes or virt-manager on a Linux machine).
- A change here can break every edition. Before promoting Core, check that
  Home and Studio still build on Core's `:testing` (run their build
  workflows by hand with Core's `:testing` if needed) and boot one of them.
- When you change anything visual, tell the user exactly what to check on
  real hardware, since you cannot see it.
- `bootc container lint` fails with "Function not implemented (os error 38)"
  under amd64 emulation on Apple Silicon, even on the untouched base image.
  It is an emulator limitation, not an image fault; CI runs it natively.
  Never weaken the gate.

## Rules

- Keep the two recipes identical apart from `name`, `description` and
  `base-image`.
- Core is neutral: no developer tooling, no family-only features, no app
  folders, no SSH server. Editions add those.
- Tailscale is installed but never signed in by the image, the installer or
  any script. Never commit Tailscale keys, password hashes or `cosign.key`.
- Never bake self-updating tools into `/usr`; it is read-only. Per-person
  setup goes in `first-login.sh` as a versioned step registered in `STEPS`
  or `LATE_STEPS`. Bump the suffix to force a step to run again for
  everyone. A step returns 2 when it cannot run yet (it is retried quietly).
- SELinux must stay enforcing. `shatteredvales-selinux-repair.service`
  turns it back on for machines whose installer booted them with
  `selinux=0`; it edits kernel arguments only through `rpm-ostree kargs`
  (which keeps a waiting update), never restarts the machine itself, and
  leaves anyone who set `SELINUX=disabled` in `/etc/selinux/config` alone.
- `verify-image.sh` is the release gate. When adding software, add a rule
  to `files/system/usr/share/shatteredvales/verify.d/core.list`.
- GNOME Shell CSS selectors, extension settings and AccountsService's D-Bus
  API can change between releases. On every Fedora major bump, re-check
  `files/system/usr/share/shatteredvales/theme/shell-overrides.css.in` and
  the dconf extension keys, and test on hardware before merging. Core moves
  to a new Fedora release first; editions follow when Core is promoted.
- Builds from `main` publish only `:testing` (`alt-tags` in both recipes).
  `:latest` moves only through `.github/workflows/promote.yml`, which
  verifies the signature and re-tags by digest. Never make CI push `:latest`
  directly: every edition builds on Core's `:latest`.
- System-wide defaults that people may override go in `/etc` config files
  (dconf `local.d`, browser policies, `mimeapps.list`), never into home folders.
- `sv-storage` must never offer, change or format a drive holding a
  system path (/, /boot, /boot/efi, /sysroot, /usr, /etc, /var, swap) or
  anything mounted it did not mean to unmount, and every check runs again
  in the privileged step. Its fstab entries use the UUID with `nofail` and
  `x-systemd.device-timeout=10s`, so a missing drive never blocks start-up.
  Apps, home folders and containers move only at boot, through
  `shatteredvales-storage-move.service`, before anyone can sign in, after
  a free-space check, and the old copy is kept until `sv-storage cleanup`.
  A folder counts as moved only when it is mounted from a non-system
  drive: on Fedora Atomic `/var/home` is a btrfs subvolume of the system
  drive (the installer's `/home` fstab line), so a homes move switches
  that line off with a marker comment and keeps the old copy in the
  subvolume, which `cleanup` empties. New-drive alerts cover
  internal drives only. Run `tests/sv-storage.sh` after changing it.
- `sv-storage setup`, `remove` and `cleanup` are for administrators
  (wheel) and refuse everyone else before any password prompt; the Set Up
  Drives launcher is hidden system-wide and shown to administrators by a
  per-account copy that `first-login.sh` keeps in step. `sv-storage usb`
  is for everyone: it runs as the person through udisks, whose polkit
  defaults allow changing removable and USB drives in an active session
  and never the computer's own drives. Never add a polkit rule that
  widens what non-administrators may format.
- The repository is public: anyone may build and use these images.

## Code standards (organization policy)

- Every script starts with a header block stating its purpose, inputs, usage
  and exit codes. Every function has a doc comment describing what it does,
  its arguments and its return value (docstrings in Python).
- Inline comments explain **why**, never restate what the code does.
- Never write change-tracking comments ("added", "updated per request",
  "new logic"). Code is always written as a clean final artifact.
- Shell: `set -euo pipefail` (except where failures are deliberately
  tolerated, which must be commented), quoted expansions, shellcheck-clean.
