# Raspberry Pi 4 custom-kernel demo image

A [pi-gen](https://github.com/RPi-Distro/pi-gen) based build system that produces a
bootable Raspberry Pi OS (Bookworm, 64-bit) image for the Raspberry Pi 4 with:

* a **kernel built from source** (`raspberrypi/linux`, `rpi-6.12.y`, `bcm2711_defconfig`
  plus a Kconfig fragment), packaged as a Debian package and installed as
  `/boot/firmware/kernel8-demo.img`, selected in `config.txt`;
* **nginx** serving a static demo page (`index.html` + SVG image) on port 80, with a
  small service that publishes live `uname`/system facts as `/sysinfo.json` so the
  page can show that the custom kernel is the one running.

Two artifacts, two pipelines:

| | Kernel | Image |
| --- | --- | --- |
| Source of truth | `kernel/`: `kernel.conf` (source commit, defconfig), `demo.config`, `VERSION` | `stage-*`, `config/` |
| Build locally | `./build-kernel.sh` | `./build-dev.sh`, `./build-release.sh` |
| CI | `kernel.yml`: every change under `kernel/` is built and boot-tested; merging to `main` publishes release `kernel-v<VERSION>` | `release.yml`: a `v*` tag builds the release image with the published kernel package, boot-tests it, publishes |
| Output | `linux-image-<release>_<version>_arm64.deb` | `image_<date>-pi4-demo[-<tag>].img.xz` |

Two image variants come out of the same stages:

| | `./build-dev.sh` | `./build-release.sh` |
| --- | --- | --- |
| Base | complete Raspberry Pi OS Lite (pi-gen stage2) | the same, then `stage-slim` removes what the server does not need |
| Kernel | built here from `kernel/` (`KERNEL_SOURCE=build`); stock Debian kernel kept as fallback | the published package (`KERNEL_SOURCE=deb`); custom kernel only |
| Extras | compilers, gdb, GPIO/camera/media tooling, all Wi-Fi firmware, docs, man pages | none of those; Wi-Fi (on-board Broadcom) and Bluetooth stay |
| Output | `deploy/image_<date>-pi4-demo-dev.zip`, ~666 MB | `deploy/image_<date>-pi4-demo.img.xz`, ~158 MB ([details](#image-size)) |
| Use | bench work, kernel and image development | flashing devices, CI releases |

This is a demo project. Both images ship a fixed user/password and SSH enabled; see
`config/common.conf` before reusing any of this for something real.

## Layout

```
.
├── .github/
│   ├── actions/prepare-runner/  composite action: reclaim disk, pick the work directory
│   └── workflows/
│       ├── kernel.yml           kernel/ changed -> build .deb, boot-test; on main -> release kernel-v<VERSION> if the Image is new
│       └── release.yml          tag v* -> release image with the published kernel -> boot-test -> release
├── build-kernel.sh              kernel package only, in Docker (what kernel.yml runs)
├── build-dev.sh / build-release.sh  one-line wrappers: scripts/build-image.sh <variant>
├── scripts/
│   ├── docker-env.sh            shared Docker plumbing (platform, image, run)
│   ├── build-image.sh           the image engine: runs pi-gen for one variant
│   └── qemu-smoke-test.sh       boots an image headless, checks nginx and uname -r
├── Dockerfile                   Debian Bookworm + pi-gen deps + kernel build/packaging toolchain
├── config/
│   ├── common.conf              everything shared: user, locale, STAGE_LIST; sources kernel/kernel.conf
│   ├── dev.conf                 IMG_NAME=pi4-demo-dev, zip, RELEASE_SLIM=0, KERNEL_SOURCE=build
│   └── release.conf             IMG_NAME=pi4-demo, xz,  RELEASE_SLIM=1, KERNEL_SOURCE=deb
├── kernel/                      every kernel input, so kernel.yml triggers on this directory
│   ├── kernel.conf              KERNEL_* knobs: source URL/branch/COMMIT, defconfig, tree location
│   ├── VERSION                  package version: <upstream>-demo.<N>, e.g. 6.12.110-demo.1
│   ├── demo.config              Kconfig fragment (LOCALVERSION, /proc/config.gz, virtio)
│   └── build-kernel.sh          clone at KERNEL_COMMIT -> config -> make bindeb-pkg -> .deb + Image
├── pi-gen/                      upstream pi-gen, git submodule, branch bookworm-arm64 (unmodified)
├── run-qemu.sh                  boots deploy/*.img in qemu-system-aarch64 (virt machine, HVF/KVM)
├── stage-kernel/00-install-kernel/  download or build the .deb, install it, set up /boot/firmware
├── stage-web/00-nginx/          nginx-light, demo page, live sysinfo service
└── stage-slim/00-slim/          EXPORT_IMAGE lives here; no-op unless RELEASE_SLIM=1
```

`STAGE_LIST` in `config/common.conf` runs upstream `stage0 stage1 stage2` (= Raspberry Pi
OS Lite) and then `stage-kernel stage-web stage-slim`, identical for both variants; the
variant files only set the image name, the compression, `RELEASE_SLIM` and
`KERNEL_SOURCE`. pi-gen itself is not patched; the only thing the Dockerfile adds inside
the submodule is `stage2/SKIP_IMAGES` so that only the final stage is exported.

## Prerequisites

* Docker Desktop (tested on Apple Silicon; the container is native arm64 there). On an
  amd64 host the Dockerfile adds `qemu-user-static` and `crossbuild-essential-arm64`
  and the engine registers binfmt, which needs a Linux host kernel with `binfmt_misc`.
* Roughly 20 GB free in Docker's disk image per image variant: stage rootfs copies
  (~1.8 GB each), the kernel source and object tree (~3 GB), and the exported image.
* Time: about 10 minutes for a full dev build on an M-series Mac, 6 of them the kernel
  compile; a release build that downloads the kernel package takes about 5. Later runs
  are incremental.

Clone with the submodule:

```sh
git clone --recurse-submodules https://github.com/VasylHerman/pi-gen-demo.git
# or, in an existing checkout:
git submodule update --init
```

## Build

```sh
./build-release.sh     # production image, kernel from the published package
./build-dev.sh         # developer image, kernel built here
./build-kernel.sh      # only the kernel package (.deb), no image
```

All three accept `shell` (root shell in the build environment with the same volumes)
and `reset` (delete the cached work volume). Output lands in `deploy/`: the compressed
image, `kernel8-demo.img` (for QEMU), the kernel `.deb` and `kernel-release.env`, the
`.info` package list and `build.log`. Set `DEPLOY_COMPRESSION=none` in the variant file
for a raw `.img`.

Flash the image with Raspberry Pi Imager or `dd`, boot a Pi 4 / 400 / CM4, and open
<http://pi-demo.local/>. Verify on the board:

```sh
ssh pi@pi-demo.local          # password: raspberry (demo only)
uname -r                      # 6.12.xx-v8-demo
zcat /proc/config.gz | grep LOCALVERSION
grep kernel= /boot/firmware/config.txt
cat /etc/demo-kernel          # release, package version, commit, build date
apt show linux-image-$(uname -r)
curl -s http://localhost/sysinfo.json
```

### Releases from CI

Two workflows, both on GitHub's arm64 runner.

**Kernel** (`.github/workflows/kernel.yml`). Any pull request that touches `kernel/`,
the Dockerfile or the kernel scripts builds the package, boots it in QEMU against the
rootfs of the newest image release, and uploads it as a workflow artifact. When such a
change is merged to `main`, the workflow decides by the reproducible kernel `Image`
whether there is anything to publish: release `kernel-v<kernel/VERSION>` missing, create
it (tag included); release present with the identical `Image` hash, nothing changed,
skip; release present with a different hash, fail with "bump `kernel/VERSION`". So a
toolchain or workflow edit that leaves the kernel byte-identical costs nothing, and a
fragment or `KERNEL_COMMIT` change cannot be published under an old version. About 25
minutes.

**Image** (`.github/workflows/release.yml`):

```sh
git tag v1.0.0
git push origin v1.0.0
```

checks that release `kernel-v<kernel/VERSION>` exists, runs `./build-release.sh` (which
downloads and installs that package), boots the result in QEMU, then publishes
`image_<date>-pi4-demo-v1.0.0.img.xz`, `kernel8-demo.img` (for `run-qemu.sh`), the `.info`
package list, `build.log` and `SHA256SUMS`. The tag is baked into the image name,
`/etc/rpi-issue` and the demo page via `IMG_NAME` and `PI_GEN_RELEASE`. A manual run from
the Actions tab (workflow_dispatch) builds and uploads the same files as a workflow
artifact without creating a release. About 15 minutes.

Procedure for a kernel change, end to end: edit `kernel/demo.config` and/or
`KERNEL_COMMIT` in `kernel/kernel.conf`, bump `kernel/VERSION`, open a PR, merge, wait
for `kernel-v…` to appear, tag the image.

### Running without a board (QEMU)

```sh
brew install qemu        # macOS; QEMU >= 8 with the arm64 system emulator
./run-qemu.sh            # boots the newest deploy/*.img (extracts the zip/xz if needed)
```

Then open <http://localhost:8080/> or `ssh -p 2222 pi@localhost`. Quit with `Ctrl-a x`.

This uses the `virt` machine and the custom kernel (`deploy/kernel8-demo.img`): the
Kconfig fragment adds virtio disk/NIC drivers, so the very same kernel boots on the Pi
and in QEMU, while the stock Debian kernel cannot boot here at all. On Apple Silicon the
guest runs under HVF at near-native speed. By default the image is opened with
`-snapshot`, so first-boot changes are discarded; use `SNAPSHOT=0` to persist them. In
QEMU the page reports the model as `linux,dummy-virt` and no CPU temperature; everything
else, including the `uname -r` check, is real.

`scripts/qemu-smoke-test.sh <image> [expected uname -r]` does the same headless and
exits non-zero unless nginx answers on the expected kernel; the workflows run it before
publishing anything.

QEMU also ships a `raspi4b` machine that boots the kernel with the real
`bcm2711-rpi-4-b.dtb`, but it emulates no Ethernet or USB, so it is only useful for
watching the kernel come up on the serial console.

### Iterating

Each build keeps its state in a Docker volume (`pigen_dev_work`, `pigen_release_work`,
`pigen_kernel_work`), so every run resumes where the last one stopped: debootstrap
output is reused, kernel compilation is incremental, and stage scripts re-run on the
existing rootfs. The standard pi-gen workflow applies (shown for dev; same for release):

| Goal | Command |
| --- | --- |
| Re-run after a failed or interrupted build | `./build-dev.sh` |
| Change the fragment and see it boot | edit `kernel/demo.config`; `touch pi-gen/stage{0,1,2}/SKIP; CLEAN=1 ./build-dev.sh` (kernel rebuild is incremental) |
| Change only the web content or the slim lists | `touch stage-kernel/SKIP pi-gen/stage{0,1,2}/SKIP`, then `CLEAN=1 ./build-dev.sh` |
| Try the published kernel in a dev image | `KERNEL_SOURCE=deb ./build-dev.sh` |
| See what the kernel branch tip is | `KERNEL_UPDATE=1 ./build-kernel.sh`, read `deploy/kernel-release.env` |
| Start from scratch | `./build-dev.sh reset && ./build-dev.sh` |
| Poke around the build environment | `./build-dev.sh shell` |

`SKIP` in a stage directory means "do not run this stage, reuse its rootfs from the work
volume". `CLEAN=1` deletes and recreates the rootfs of every stage that is *not*
skipped. Remove the `SKIP` files before a release build. (`SKIP` files inside `pi-gen/`
are ignored by its `.gitignore`; the ones in `stage-*` are not, so do not commit them.)

## The custom kernel

`kernel/build-kernel.sh` follows the official
[kernel build documentation](https://www.raspberrypi.com/documentation/computers/linux_kernel.html)
and then packages the result with the kernel's own `make bindeb-pkg`:

1. shallow-clone `KERNEL_GIT_URL` and check out `KERNEL_COMMIT` into the work volume;
2. `make bcm2711_defconfig`, merge `kernel/demo.config` with `scripts/kconfig/merge_config.sh`,
   `make olddefconfig`, then fail if any fragment option was dropped or if
   `kernel/VERSION` does not start with the tree's own version;
3. `make bindeb-pkg` with `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`,
   `KDEB_PKGVERSION=<kernel/VERSION>` and the `nokernelheaders` build profile, giving
   `linux-image-<release>_<version>_arm64.deb` with the kernel, stripped modules, DTBs
   and overlays;
4. collect into the output directory: the `.deb`, the bare `Image` as `kernel8-demo.img`
   (QEMU), the `.config`, the overlays `README`, `kernel-release.env` and `SHA256SUMS`.

`stage-kernel/00-install-kernel/00-run.sh` then, in either variant:

1. obtains that output: `KERNEL_SOURCE=deb` downloads release `kernel-v<VERSION>` from
   `KERNEL_DEB_REPO` and verifies `SHA256SUMS`; `KERNEL_SOURCE=build` runs
   `kernel/build-kernel.sh` on the spot. Both are cached in the work volume;
2. installs the package in the chroot with `apt-get install`;
3. copies `/boot/vmlinuz-<release>` to `/boot/firmware/kernel8-demo.img`, the
   `bcm2711*.dtb` and `overlays/*.dtbo` from `/usr/lib/linux-image-<release>/` into
   `/boot/firmware/`, appends a `[pi4] kernel=kernel8-demo.img [all]` block to
   `config.txt`, writes `/etc/demo-kernel`, and copies the kernel and the `.deb` into
   `deploy/`.

The fragment sets `CONFIG_LOCALVERSION="-v8-demo"` (so `uname -r` shows the build is
custom), enables `CONFIG_IKCONFIG_PROC` (so `/proc/config.gz` exists on the board) and
adds virtio block/net plus the generic PCI host so the kernel also boots under QEMU.
Add your own options there; the post-`olddefconfig` check tells you if Kconfig refused
one.

### Kernel versioning

* **Package version** is `kernel/VERSION`, `<upstream version>-demo.<N>`. The upstream
  part must match the source tree (checked at build time); `N` is bumped whenever the
  fragment or `KERNEL_COMMIT` changes on the same upstream version. Debian compares
  versions numerically, so `demo.2` upgrades `demo.1` on a device with
  `apt install ./linux-image-….deb`; a commit hash would not order.
* **Source revision.** `KERNEL_COMMIT` in `kernel/kernel.conf` pins the exact
  `raspberrypi/linux` commit; nothing builds from a moving branch tip. To move: run
  `KERNEL_UPDATE=1 ./build-kernel.sh`, read the new hash and Linux version from
  `deploy/kernel-release.env`, pin the hash, bump `kernel/VERSION`. The hash is recorded
  in `/etc/demo-kernel`, on the demo page and in both releases' notes.
* **Version string.** `uname -r` is `<upstream version><LOCALVERSION>`, e.g.
  `6.12.110-v8-demo`: upstream stable version, the Raspberry Pi `-v8` flavour, and
  `-demo` for "this configuration". It is also the package name
  (`linux-image-6.12.110-v8-demo`) and the modules directory. Keep it independent of the
  image tag.
* **Reproducible.** `KBUILD_BUILD_VERSION`, `KBUILD_BUILD_TIMESTAMP` (the commit date),
  `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST` and `SOURCE_DATE_EPOCH` are fixed, so `uname -v`
  reads `#1 SMP PREEMPT <commit date>` and two builds of the same commit and fragment
  produce the same `Image`. The toolchain is Debian Bookworm's gcc 12 from the build
  container.
* **With a fork.** Once you carry code patches, fork `raspberrypi/linux`, tag it
  `v6.12.110-demo.1` (upstream version, your suffix, your revision), and set
  `KERNEL_GIT_URL` to the fork and `KERNEL_BRANCH` to the tag (`git clone --branch`
  accepts tags). The tag, `kernel/VERSION` and `uname -r` then share the same digits.

Design notes:

* In the dev image the stock `linux-image-rpi-v8` package stays installed. To boot it
  instead, comment out the `kernel=` line in `/boot/firmware/config.txt`. The release
  image has no stock kernel.
* Our version string ends in `-v8-demo`, not `-rpi-v8`, so `raspi-firmware`'s kernel
  and initramfs hooks report "unsupported … skipping" and leave `/boot/firmware` to
  `stage-kernel`. That is intended: the custom kernel must not displace `kernel8.img`.
  After copying, the package's `/boot/vmlinuz-<release>` is removed so that pi-gen's
  export step (`update-initramfs -k all`, which enumerates `/boot/vmlinuz-*`) does not
  generate an initramfs nobody loads. `bcm2711_defconfig` has MMC, USB storage and ext4
  built in and boots without one; `auto_initramfs=1` looks for `initramfs8-demo`, finds
  nothing, and loads none.
* The DTBs and overlays in `/boot/firmware` come from the custom package (same 6.12
  series as the stock kernel, so both kernels boot with them). In the dev image a later
  `apt upgrade` of the stock kernel package rewrites them from the stock package;
  normally fine.
* To update a running device without reflashing: `sudo apt install ./linux-image-….deb`
  from the kernel release, then copy `/boot/vmlinuz-<release>` to
  `/boot/firmware/kernel8-demo.img` and the DTBs as `stage-kernel` does.

## The release image

`stage-slim/00-slim/00-run.sh` runs only when `RELEASE_SLIM=1`. It never touches
pi-gen; it works on the finished rootfs:

1. installs a dpkg `path-exclude` policy (no docs, man pages or non-English message
   catalogs for anything installed later, licenses kept) and an apt policy (no
   translation lists, no Recommends);
2. marks every package in `files/keep-packages` plus the custom kernel package (read
   from `/etc/demo-kernel`) as manually installed, purges `files/purge-packages` with
   `--auto-remove`, runs `autoremove --purge`, and fails the build if anything from the
   keep-list disappeared;
3. deletes already-installed docs, man pages and non-English locales, the modules of
   every kernel except the custom one, and from `/boot/firmware` the stock kernels,
   initramfs files, Pi 5 kernel, other boards' device trees and the Pi 1-3 firmware
   variants;
4. logs the rootfs size before and after (`grep stage-slim deploy/build.log`).

Adjust the two lists to taste. Things that look removable but are not: `initramfs-tools`
and `linux-base` (pi-gen's export step calls `update-initramfs`), `python3` (a
dependency of `rpi-eeprom`), `binutils` (also `rpi-eeprom`), `kms++-utils` (`raspinfo`,
hence `raspi-config`), `lua5.1` (`raspi-config`), and `/var/lib/apt/lists` (the export
step re-runs `apt-get update`, so deleting them here only gets undone).

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

Image settings are in `config/` (bash, sourced by pi-gen), kernel settings in
`kernel/kernel.conf` (sourced by `config/common.conf` and by `kernel/build-kernel.sh`).
Upstream pi-gen variables are documented in `pi-gen/README.md`. Our additions:

| Variable | Default | Meaning |
| --- | --- | --- |
| `IMG_NAME` | `pi4-demo-dev` / `pi4-demo` (variant file) | image and work-dir name; CI appends the tag |
| `DEPLOY_COMPRESSION` | `zip` / `xz` (variant file) | `none`, `zip`, `gz` or `xz` |
| `RELEASE_SLIM` | `0` / `1` (variant file) | run stage-slim |
| `KERNEL_SOURCE` | `build` / `deb` (variant file) | build the kernel package here, or download release `kernel-v<VERSION>` |
| `KERNEL_DEB_REPO` | `VasylHerman/pi-gen-demo` (`kernel.conf`) | GitHub repository holding the kernel releases |
| `KERNEL_GIT_URL` | `https://github.com/raspberrypi/linux.git` (`kernel.conf`, as are all `KERNEL_*` below) | kernel source |
| `KERNEL_BRANCH` | `rpi-6.12.y` | branch to shallow-clone |
| `KERNEL_COMMIT` | `9c40c75f…` (6.12.110) | exact commit to build; empty = branch tip |
| `KERNEL_DEFCONFIG` | `bcm2711_defconfig` | base config (Pi 4 family, 64-bit) |
| `KERNEL_IMG_NAME` | `kernel8-demo.img` | file name under `/boot/firmware` and `kernel=` value |
| `KERNEL_SRC_DIR` | `${BASE_DIR}/work/kernel/linux` | source/object tree, inside the work volume |
| `KERNEL_UPDATE` | `0` | `1` builds the branch tip instead of `KERNEL_COMMIT` (one-off) |
| `KERNEL_JOBS` | `nproc` | make parallelism |

Wrapper environment (`scripts/build-image.sh`, `build-kernel.sh`): `CLEAN=1`,
`CONTAINER_NAME`, `WORK_VOLUME` (volume name or host path), `IMG_NAME`, `PI_GEN_RELEASE`,
`KERNEL_SOURCE`, `KERNEL_UPDATE`, `DOCKER_PLATFORM`, `PIGEN_DOCKER_OPTS`, `DOCKER`.

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
