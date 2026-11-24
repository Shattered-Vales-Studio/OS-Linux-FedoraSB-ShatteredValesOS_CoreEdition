# Shattered Vales OS Core Edition

The shared foundation of Shattered Vales OS: Fedora Silverblue with the
Shattered Vales look, everyday apps, the ArtCraft suite, safe automatic
updates you can roll back, and the support tools every edition uses. Core
Edition is installable on its own, as a clean general-purpose desktop, and
every other edition is built on top of it:

| Edition | Image | For |
|---|---|---|
| **Core** | `shatteredvales-os-core` | Anyone who wants the plain Shattered Vales desktop |
| [**Home**](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_HomeEdition) | `shatteredvales-os-home` | Family computers: Family Setup, parental controls, streaming bookmarks |
| [**Studio**](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS) | `shatteredvales-os` | Development workstations: developer tools, Docker, Unity, Claude |

Each image also comes as `-nvidia` for computers with NVIDIA graphics.
Images are signed; verify one with the committed key:

```bash
cosign verify --key cosign.pub ghcr.io/shattered-vales-studio/shatteredvales-os-core:latest
```

## What's on it

- **Look:** the Shattered Vales logo, gold-on-black colours and fonts on the
  boot menu, boot screen, sign-in and lock screens, wallpapers (four more
  in Settings > Appearance), a dock at the bottom and a logo menu at the
  top left. The edition's name sits beside "Shattered Vales OS" in
  Settings > About, on the sign-in screen and in the boot menu.
- **Apps:** Firefox, Thunderbird, VLC, Bitwarden, backups (Déjà Dup),
  Shotwell, Contacts, Maps, Weather and GNOME's everyday apps, installed on
  first boot. More are one click away in Software.
- **ArtCraft:** ArtCraft Launcher in the image, and WordCraft, GridCraft,
  DeckCraft, PdfCraft, PhotoCraft and LightCraft installed for each person
  at first sign-in. The launcher keeps them updated and offers the rest of
  the suite.
- **Accounts:** account pictures are gold for everyday accounts and red for
  administrators, so the sign-in screen shows who can change the computer.
- **Shared folders:** Windows PCs and network drives show up under
  **Network** in Files. To open one directly, choose **Other Locations**,
  type its address (such as `smb://nas.local/Photos`) and tick
  **Remember forever**. To pin shares in everyone's sidebar, list them in
  `/etc/shatteredvales/network-shares`; nothing is pinned by default.
- **Remote access:** Tailscale is installed but not signed in. Nothing is
  shared until someone runs `sudo tailscale up --ssh` and signs in to their
  own tailnet. There is no SSH server.

## Updates

Updates download in the background and apply the next time the computer
restarts. A reminder appears if one has waited a few days. **System
Update** in the dock checks now and offers to restart; right-click it to
see what is waiting or to **go back to the previous version** if anything
misbehaves.

## Drives

- **Set Up Drives** (in the app grid of administrators' accounts) walks
  through using an extra
  internal drive: as a **storage** folder for big files (it appears in the
  Files sidebar), or as the new home of **apps**, everyone's **home
  folders** or **containers**. It shows the drive's model, size and type,
  explains each choice and asks you to type the drive's name before
  erasing anything. It checks first that the folder fits on the drive.
  Apps, home folders and containers move at the next restart, before
  anyone signs in; the old copy is kept until you run `sv-storage
  cleanup`. Setting up drives is for administrators only:
  anyone else is told to ask an administrator, and the launcher only
  appears for administrators.
- **Format USB Drive**, for everyone and without a password, erases a USB stick or memory card for Windows, Mac,
  TVs and cameras (exFAT), old devices (FAT32), Windows (NTFS) or Linux
  (ext4). It also fixes sticks that were used for an installer with
  balenaEtcher. It only ever offers USB sticks, memory cards and other
  removable or USB drives.
- The drive holding the system is never offered, and extra drives are set
  up so the computer still starts when one is missing.
- Administrators get a notification when a new **internal** drive is not
  used yet. USB sticks and external USB, Thunderbolt and eSATA drives
  never trigger it, even USB hard drives that claim to be fixed disks; set
  those up by hand if you want them as storage.
- **Several drives in one computer:** in the installer, tick **only** the
  NVMe drive the system goes on and choose **Automatic**. After the first
  start, use **Set Up Drives** for the others.

| Command | Does |
|---|---|
| `sv-storage` | Lists every drive and what it is used for |
| `sv-storage setup [drive]` | Sets up an unused drive (administrators) |
| `sv-storage usb [drive]` (or `sv-format-usb`) | Formats a USB stick or card (anyone) |
| `sv-storage remove [name]` | Stops using a storage drive, keeps its files (administrators) |
| `sv-storage cleanup` | Frees the space of old copies after a move (administrators) |

Add `--dry-run` to `setup`, `usb` or `remove` to see exactly what would be
done without changing anything.

### SELinux on machines from older offline installers

Offline USB installers built before the installer fix of 24 November 2026
left SELinux switched off on the machines they installed. Those machines
repair themselves after updating: the next restart runs SELinux in
permissive mode and relabels files before anyone signs in, and the restart
after that turns SELinux fully on. `sv-doctor` shows the progress. Nothing
needs typing; the manual commands remain in the
[OS-Installer README](https://github.com/Shattered-Vales-Studio/OS-Installer#readme)
for reference.

## Installing

### On a new computer

Use a USB stick made with the installer in
[Shattered-Vales-Studio/OS-Installer](https://github.com/Shattered-Vales-Studio/OS-Installer)
and flashed with balenaEtcher.

### On a computer already running Fedora Silverblue

No reinstall needed: accounts, files and Flatpak apps all stay. One script
moves a machine onto any edition:

```bash
curl -fsSLO https://raw.githubusercontent.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_CoreEdition/main/sv-migrate.sh
bash sv-migrate.sh                     # Core Edition
bash sv-migrate.sh --edition home      # Home Edition
bash sv-migrate.sh --edition studio    # Studio Edition
```

The script picks the right image for the graphics card, removes add-on
packages that would clash (such as RPM Fusion's NVIDIA driver), shows the
plan and asks before changing anything. Add `--dry-run` to only see the
plan. After the restart the computer switches itself to the
signature-verified image.

**NVIDIA computers with Secure Boot on:** after the first restart run
`blujust enroll-secure-boot-key`, restart, choose *Enroll MOK* on the blue
screen and enter the password `bluebuild`.

## Release channels

| Tag | Who runs it | Updated |
|---|---|---|
| `:testing` | One or two test machines | Every build from `main` (nightly) |
| `:latest` | Every other machine, and every edition's build | Weekly (Tuesdays) by the *promote-images* workflow, or on demand |
| `:stable-YYYYMMDD` | Nobody directly; rollback points | Each promotion |

Promotion re-tags the already-signed `:testing` image after verifying its
signature. Set the repository variable `PAUSE_PROMOTION` to `true` to hold
promotions; run *promote-images* manually with an older `stable-YYYYMMDD`
tag to roll back.

Editions build on Core's `:latest`. A change merged here therefore reaches
an edition in three steps: Core's `:testing` (canary), Core's `:latest`
(promotion), then the edition's next nightly build, which puts it on the
edition's own `:testing` before that edition's promotion.

## Useful commands

| Command | Does |
|---|---|
| `sv-update` | Shows the waiting update; `now` updates immediately, `rollback` goes back |
| `sv-doctor` | Health check for whoever helps; `sv-doctor --copy` copies the report |
| `sv-gpu-image status` | Shows whether the right image for the graphics card is installed |
| `sv-first-login` | Re-runs per-person setup |
| `sv-storage` | Lists drives; see [Drives](#drives) |
| `rpm-ostree rollback` | Boots the previous version |

## Keeping up with Fedora

- **Updates within a release** are automatic: nightly builds start from
  BlueBuild's base images, which pick up Fedora's updates daily, and the
  weekly promotion moves them to `:latest`.
- **New Fedora releases** (every April and October): the *fedora-release*
  workflow checks every Monday. When Fedora N+1 is released and the base
  images publish it, it pushes a `fedora-<N+1>` branch with the version
  bumps and opens an issue with the pull request link and a test
  checklist. Core moves first; the editions follow when Core is promoted.
- **GitHub Actions** used by the workflows are kept current by Dependabot.

## Developing

See [CLAUDE.md](CLAUDE.md) for how the editions fit together and the rules
for changing Core, and [branding/README.md](branding/README.md) for the
artwork.
