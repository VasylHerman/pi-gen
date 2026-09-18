# Raspberry Pi 4 custom-kernel demo image

A [pi-gen](https://github.com/RPi-Distro/pi-gen) based build system that produces a
bootable Raspberry Pi OS (Bookworm, 64-bit) image for the Raspberry Pi 4 with:

* a **kernel built from source** (`raspberrypi/linux`, `rpi-6.12.y`, `bcm2711_defconfig`
  plus a Kconfig fragment) installed as `/boot/firmware/kernel8-demo.img` and selected
  in `config.txt`;
* **nginx** serving a static demo page (`index.html` + SVG image) on port 80, with a
  small service that publishes live `uname`/system facts as `/sysinfo.json` so the
  page can show that the custom kernel is the one running.

Two variants come out of the same stages:

| | `./build-dev.sh` | `./build-release.sh` |
| --- | --- | --- |
| Base | complete Raspberry Pi OS Lite (pi-gen stage2) | the same, then `stage-slim` removes what the server does not need |
| Kernels | custom + stock Debian kernel as fallback | custom kernel only |
| Extras | compilers, gdb, GPIO/camera/media tooling, all Wi-Fi firmware, docs, man pages | none of those; Wi-Fi (on-board Broadcom) and Bluetooth stay |
| Output | `deploy/image_<date>-pi4-demo-dev.zip`, ~666 MB | `deploy/image_<date>-pi4-demo.img.xz`, ~158 MB ([details](#image-size)) |
| Use | bench work, debugging on the device | flashing devices, CI releases |

This is a demo project. Both images ship a fixed user/password and SSH enabled; see
`config/common.conf` before reusing any of this for something real.

## Layout

```
.
├── .github/workflows/release.yml  tag push -> build-release.sh on arm64 runner -> GitHub release
├── build-dev.sh / build-release.sh  one-line wrappers: scripts/build-image.sh <variant>
├── scripts/build-image.sh   the engine: builds the Docker environment, runs pi-gen, collects deploy/
├── Dockerfile               Debian Bookworm + pi-gen deps + kernel toolchain
├── config/
│   ├── common.conf          everything shared: user, locale, STAGE_LIST, KERNEL_* knobs
│   ├── dev.conf             IMG_NAME=pi4-demo-dev, zip, RELEASE_SLIM=0
│   └── release.conf         IMG_NAME=pi4-demo, xz,  RELEASE_SLIM=1
├── pi-gen/                  upstream pi-gen, git submodule, branch bookworm-arm64 (unmodified)
├── run-qemu.sh              boots deploy/*.img in qemu-system-aarch64 (virt machine, HVF/KVM)
├── stage-kernel/            builds and installs the custom kernel
│   └── 00-build-kernel/
│       ├── 00-run.sh        clone → defconfig + fragment → build → install into rootfs
│       └── files/demo.config  Kconfig fragment (LOCALVERSION, /proc/config.gz, virtio)
├── stage-web/               nginx + demo page
│   └── 00-nginx/
│       ├── 00-packages      nginx-light
│       ├── 01-run.sh        copy www/, bake build facts, install service, enable units
│       └── files/           nginx site, demo-sysinfo script + unit, www/index.html, www/pi-demo.svg
└── stage-slim/              EXPORT_IMAGE lives here: this rootfs becomes the image
    └── 00-slim/
        ├── 00-run.sh        no-op unless RELEASE_SLIM=1; purge, verify keep-list, trim files
        └── files/           keep-packages, purge-packages, dpkg/apt policy snippets
```

`STAGE_LIST` in `config/common.conf` runs upstream `stage0 stage1 stage2` (= Raspberry Pi
OS Lite) and then `stage-kernel stage-web stage-slim`, identical for both variants; the
variant files only set the image name, the compression and `RELEASE_SLIM`. pi-gen itself
is not patched; the only thing the Dockerfile adds inside the submodule is
`stage2/SKIP_IMAGES` so that only the final stage is exported.

## Prerequisites

* Docker Desktop (tested on Apple Silicon; the container is native arm64 there). On an
  amd64 host the Dockerfile adds `qemu-user-static` and `crossbuild-essential-arm64`
  and the engine registers binfmt, which needs a Linux host kernel with `binfmt_misc`.
* Roughly 20 GB free in Docker's disk image per variant: stage rootfs copies (~1.8 GB
  each), the kernel source and object tree (~3 GB), and the exported image.
* Time: about 10 minutes for a full build on an M-series Mac, 6 of them the kernel
  compile. Later runs are incremental.

Clone with the submodule:

```sh
git clone --recurse-submodules https://github.com/VasylHerman/pi-gen-demo.git
# or, in an existing checkout:
git submodule update --init
```

## Build

```sh
./build-release.sh     # production image
./build-dev.sh         # developer image
```

Both accept `shell` (root shell in the build environment with the variant's volumes)
and `reset` (delete the variant's cached work volume). Output lands in `deploy/`:
the compressed image, `kernel8-demo.img` (for QEMU), the `.info` package list and
`build.log`. Set `DEPLOY_COMPRESSION=none` in the variant file for a raw `.img`.

Flash the image with Raspberry Pi Imager or `dd`, boot a Pi 4 / 400 / CM4, and open
<http://pi-demo.local/>. Verify on the board:

```sh
ssh pi@pi-demo.local          # password: raspberry (demo only)
uname -r                      # 6.12.xx-v8-demo
zcat /proc/config.gz | grep LOCALVERSION
grep kernel= /boot/firmware/config.txt
cat /etc/demo-kernel          # release, branch, commit, build date
curl -s http://localhost/sysinfo.json
```

### Releases from CI

`.github/workflows/release.yml` runs `./build-release.sh` on GitHub's arm64 runner and
publishes a release whenever a version tag is pushed:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The release carries `image_<date>-pi4-demo-v1.0.0.img.xz`, `kernel8-demo.img` (for
`run-qemu.sh`), the `.info` package list, `build.log` and `SHA256SUMS`. The tag is baked
into the image name, `/etc/rpi-issue` and the demo page via `IMG_NAME` and
`PI_GEN_RELEASE`, which the configs accept from the environment. A manual run from the
Actions tab (workflow_dispatch) builds and uploads the same files as a workflow artifact
without creating a release. Expect 30 to 45 minutes on the 4-vCPU runner.

### Running without a board (QEMU)

```sh
brew install qemu        # macOS; QEMU >= 8 with the arm64 system emulator
./run-qemu.sh            # boots the newest deploy/*.img (extracts the zip/xz if needed)
```

Then open <http://localhost:8080/> or `ssh -p 2222 pi@localhost`. Quit with `Ctrl-a x`.

This uses the `virt` machine and the custom kernel (`deploy/kernel8-demo.img`, copied out
by stage-kernel): the Kconfig fragment adds virtio disk/NIC drivers, so the very same
kernel boots on the Pi and in QEMU, while the stock Debian kernel cannot boot here at
all. On Apple Silicon the guest runs under HVF at near-native speed. By default the
image is opened with `-snapshot`, so first-boot changes are discarded; use `SNAPSHOT=0`
to persist them. In QEMU the page reports the model as `linux,dummy-virt` and no CPU
temperature; everything else, including the `uname -r` check, is real.

QEMU also ships a `raspi4b` machine that boots the kernel with the real
`bcm2711-rpi-4-b.dtb`, but it emulates no Ethernet or USB, so it is only useful for
watching the kernel come up on the serial console.

### Iterating

Each variant keeps its state in a Docker volume (`pigen_dev_work`, `pigen_release_work`),
so every run resumes where the last one stopped: debootstrap output is reused, kernel
compilation is incremental, and stage scripts re-run on the existing rootfs. The
standard pi-gen workflow applies (shown for dev; same for release):

| Goal | Command |
| --- | --- |
| Re-run after a failed or interrupted build | `./build-dev.sh` |
| Change only the web content or the slim lists | `touch stage-kernel/SKIP pi-gen/stage{0,1,2}/SKIP`, then `CLEAN=1 ./build-dev.sh` |
| Rebuild the kernel from the current source tree | `touch pi-gen/stage{0,1,2}/SKIP; CLEAN=1 ./build-dev.sh` |
| Pull the newest commits on `KERNEL_BRANCH` | set `KERNEL_UPDATE=1` in `config/common.conf` for one run |
| Start from scratch | `./build-dev.sh reset && ./build-dev.sh` |
| Poke around the build environment | `./build-dev.sh shell` |

`SKIP` in a stage directory means "do not run this stage, reuse its rootfs from the work
volume". `CLEAN=1` deletes and recreates the rootfs of every stage that is *not*
skipped. Remove the `SKIP` files before a release build. (`SKIP` files inside `pi-gen/`
are ignored by its `.gitignore`; the ones in `stage-*` are not, so do not commit them.)

## The custom kernel

`stage-kernel/00-build-kernel/00-run.sh` follows the official
[kernel build documentation](https://www.raspberrypi.com/documentation/computers/linux_kernel.html):

1. shallow-clone `KERNEL_GIT_URL` at `KERNEL_BRANCH` (or `KERNEL_COMMIT`) into the work
   volume;
2. `make bcm2711_defconfig`, merge `files/demo.config` with `scripts/kconfig/merge_config.sh`,
   `make olddefconfig`, then fail the build if any fragment option was dropped;
3. `make Image modules dtbs` with `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`;
4. install into the stage rootfs: `modules_install` (stripped) under `/lib/modules/`,
   `Image` as `/boot/firmware/kernel8-demo.img`, `bcm2711*.dtb` and `overlays/` into
   `/boot/firmware/`, the `.config` under `/usr/share/doc/demo-kernel/`;
5. append a `[pi4] kernel=kernel8-demo.img [all]` block to `config.txt`, write
   `/etc/demo-kernel` with the release, commit and build date, and drop a copy of the
   kernel into `deploy/` for `run-qemu.sh`.

The fragment sets `CONFIG_LOCALVERSION="-v8-demo"` (so `uname -r` shows the build is
custom), enables `CONFIG_IKCONFIG_PROC` (so `/proc/config.gz` exists on the board) and
adds virtio block/net plus the generic PCI host so the kernel also boots under QEMU.
Add your own options there; the post-`olddefconfig` check tells you if Kconfig refused
one.

Design notes:

* In the dev image the stock `linux-image-rpi-v8` package stays installed. To boot it
  instead, comment out the `kernel=` line in `/boot/firmware/config.txt`. The release
  image has no stock kernel.
* The custom kernel is *not* registered as `/boot/vmlinuz-<release>`. `update-initramfs
  -k all` (run by pi-gen's export step) enumerates that path, and the `raspi-firmware`
  hooks only know the `-rpi-v8` / `-rpi-2712` flavours, so keeping the kernel out of
  `/boot` keeps both mechanisms from touching it. `bcm2711_defconfig` has MMC, USB
  storage and ext4 built in and boots without an initramfs; `auto_initramfs=1` looks
  for `initramfs8-demo`, finds nothing, and loads none.
* The DTBs and overlays in `/boot/firmware` are the ones built from the custom tree
  (same 6.12 series as the stock kernel, so both kernels boot with them). In the dev
  image a later `apt upgrade` of the stock kernel package rewrites them from the stock
  package; normally fine, but pin `KERNEL_COMMIT` if you want to be sure what you tested
  is what you ship.

## The release image

`stage-slim/00-slim/00-run.sh` runs only when `RELEASE_SLIM=1`. It never touches
pi-gen; it works on the finished rootfs:

1. installs a dpkg `path-exclude` policy (no docs, man pages or non-English message
   catalogs for anything installed later, licenses kept) and an apt policy (no
   translation lists, no Recommends);
2. marks every package in `files/keep-packages` as manually installed, purges
   `files/purge-packages` with `--auto-remove`, runs `autoremove --purge`, and fails the
   build if anything from the keep-list disappeared;
3. deletes already-installed docs, man pages and non-English locales, the modules of
   every kernel except the custom one, and from `/boot/firmware` the stock kernels,
   initramfs files, Pi 5 kernel, other boards' device trees and the Pi 1-3 firmware
   variants;
4. logs the rootfs size before and after (`grep stage-slim deploy/build.log`).

Adjust the two lists to taste. Things that look removable but are not: `initramfs-tools`
and `linux-base` (pi-gen's export step calls `update-initramfs`), `python3` (a
dependency of `rpi-eeprom`), `lua5.1` (a dependency of `raspi-config`), and
`/var/lib/apt/lists` (the export step re-runs `apt-get update`, so deleting them here
only gets undone).

### Image size

Measured on the 2026-09-18 builds (kernel 6.12.110):

| | dev | release |
| --- | --- | --- |
| rootfs (uncompressed) | 1800 MB, 606 packages | 758 MB, 375 packages |
| boot partition contents | 88 MB (3 kernels, 2 initramfs, all boards' firmware) | 38 MB (custom kernel, Pi 4 firmware and DTBs) |
| raw `.img` | 2.7 GB | 1.6 GB |
| compressed image | 666 MB zip | 158 MB xz |

The `stage-slim:` line in `deploy/build.log` reports the rootfs numbers of every release
build.

## Configuration knobs

Everything is in `config/` (bash, sourced by pi-gen). Upstream variables are documented
in `pi-gen/README.md`. Our additions, all in `common.conf` unless noted:

| Variable | Default | Meaning |
| --- | --- | --- |
| `IMG_NAME` | `pi4-demo-dev` / `pi4-demo` (variant file) | image and work-dir name; CI appends the tag |
| `DEPLOY_COMPRESSION` | `zip` / `xz` (variant file) | `none`, `zip`, `gz` or `xz` |
| `RELEASE_SLIM` | `0` / `1` (variant file) | run stage-slim |
| `KERNEL_GIT_URL` | `https://github.com/raspberrypi/linux.git` | kernel source |
| `KERNEL_BRANCH` | `rpi-6.12.y` | branch to shallow-clone |
| `KERNEL_COMMIT` | empty | pin an exact commit |
| `KERNEL_DEFCONFIG` | `bcm2711_defconfig` | base config (Pi 4 family, 64-bit) |
| `KERNEL_IMG_NAME` | `kernel8-demo.img` | file name under `/boot/firmware` and `kernel=` value |
| `KERNEL_SRC_DIR` | `${BASE_DIR}/work/kernel/linux` | source/object tree, inside the work volume |
| `KERNEL_UPDATE` | `0` | `1` re-fetches the branch tip on each build |
| `KERNEL_JOBS` | `nproc` | make parallelism |

Engine (`scripts/build-image.sh`) environment: `CLEAN=1`, `CONTAINER_NAME`, `WORK_VOLUME`
(volume name or host path), `IMG_NAME`, `PI_GEN_RELEASE`, `DOCKER_PLATFORM`,
`PIGEN_DOCKER_OPTS`, `DOCKER`.

## Building without Docker

On a Debian/Ubuntu arm64 host with the packages from `Dockerfile` installed:

```sh
touch pi-gen/stage2/SKIP_IMAGES
sudo GIT_HASH=$(git rev-parse HEAD) pi-gen/build.sh -c "$PWD/config/release.conf"
```

## References

* pi-gen README (`pi-gen/README.md`): config variables, stage anatomy, SKIP workflow.
* Raspberry Pi kernel build guide: <https://www.raspberrypi.com/documentation/computers/linux_kernel.html>
* `config.txt` boot options (`kernel`, `auto_initramfs`, `[pi4]` filters): <https://www.raspberrypi.com/documentation/computers/config_txt.html>
