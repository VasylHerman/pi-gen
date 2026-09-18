# Raspberry Pi 4 custom-kernel demo image

A [pi-gen](https://github.com/RPi-Distro/pi-gen) based build system that produces a
bootable Raspberry Pi OS Lite (Bookworm, 64-bit) image for the Raspberry Pi 4 with:

* a **kernel built from source** (`raspberrypi/linux`, `rpi-6.12.y`, `bcm2711_defconfig`
  plus a Kconfig fragment) installed as `/boot/firmware/kernel8-demo.img` and selected
  in `config.txt`, with the stock Debian kernel left in place as a fallback;
* **nginx** serving a static demo page (`index.html` + SVG image) on port 80, with a
  small service that publishes live `uname`/system facts as `/sysinfo.json` so the
  page can show that the custom kernel is the one running.

This is a demo project. The image ships a fixed user/password and SSH enabled; see
`config` before reusing any of this for something real.

## Layout

```
.
├── .github/workflows/release.yml  tag push -> build on arm64 runner -> GitHub release
├── build.sh                 Docker wrapper: builds the environment, runs pi-gen, collects deploy/
├── Dockerfile               Debian Bookworm + pi-gen deps + kernel toolchain
├── config                   pi-gen config (image name, user, STAGE_LIST, KERNEL_* knobs)
├── pi-gen/                  upstream pi-gen, git submodule, branch bookworm-arm64 (unmodified)
├── run-qemu.sh              boots deploy/*.img in qemu-system-aarch64 (virt machine, HVF/KVM)
├── stage-kernel/            builds and installs the custom kernel
│   └── 00-build-kernel/
│       ├── 00-run.sh        clone → defconfig + fragment → build → install into rootfs
│       └── files/demo.config  Kconfig fragment (LOCALVERSION, /proc/config.gz)
└── stage-web/               EXPORT_IMAGE lives here: this stage becomes the image
    └── 00-nginx/
        ├── 00-packages      nginx-light
        ├── 01-run.sh        copy www/, bake build facts, install service, enable units
        └── files/           nginx site, demo-sysinfo script + unit, www/index.html, www/pi-demo.svg
```

`STAGE_LIST` in `config` runs upstream `stage0 stage1 stage2` (= Raspberry Pi OS Lite)
and then the two stages above. pi-gen itself is not patched; the only thing the
Dockerfile adds inside the submodule is `stage2/SKIP_IMAGES` so that only the final
stage is exported.

## Prerequisites

* Docker Desktop (tested on Apple Silicon; the container is native arm64 there). On an
  amd64 host the Dockerfile adds `qemu-user-static` and `crossbuild-essential-arm64`
  and the wrapper registers binfmt, which needs a Linux host kernel with `binfmt_misc`.
* Roughly 25 GB free in Docker's disk image: stage rootfs copies (~2 GB each), the
  kernel source and object tree (~10 GB), and the exported image.
* Time: the first build takes 1–2 hours (debootstrap, apt, kernel compile). Later
  runs are incremental.

Clone with the submodule:

```sh
git clone --recurse-submodules <this repo>
# or, in an existing checkout:
git submodule update --init
```

## Build

```sh
./build.sh
```

Output: `deploy/<date>-pi4-demo.zip` (an `.img` inside; set `DEPLOY_COMPRESSION=none`
in `config` for a raw `.img`) plus `build.log`. Flash the image with Raspberry Pi
Imager or `dd`, boot a Pi 4 / 400 / CM4, and open <http://pi-demo.local/>.

Verify on the board:

```sh
ssh pi@pi-demo.local          # password: raspberry (demo only)
uname -r                      # 6.12.xx-v8-demo
zcat /proc/config.gz | grep LOCALVERSION
grep kernel= /boot/firmware/config.txt
cat /etc/demo-kernel          # release, branch, commit, build date
curl -s http://localhost/sysinfo.json
```

### Releases from CI

`.github/workflows/release.yml` builds the image on GitHub's arm64 runner and publishes
a release whenever a version tag is pushed:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The release carries `image_<date>-pi4-demo-v1.0.0.zip`, `kernel8-demo.img` (for
`run-qemu.sh`), the `.info` package list, `build.log` and `SHA256SUMS`. The tag is baked
into the image name, `/etc/rpi-issue` and the demo page via `IMG_NAME` and
`PI_GEN_RELEASE`, which `config` accepts from the environment. A manual run from the
Actions tab (workflow_dispatch) builds and uploads the same files as a workflow artifact
without creating a release. Expect 30 to 45 minutes on the 4-vCPU runner.

### Running without a board (QEMU)

```sh
brew install qemu        # macOS; QEMU >= 8 with the arm64 system emulator
./run-qemu.sh            # boots the newest deploy/*.img, console in this terminal
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

All state lives in the Docker volume `pigen_demo_work`, so every run resumes where the
last one stopped: debootstrap output is reused, kernel compilation is incremental, and
stage scripts re-run on the existing rootfs. The standard pi-gen workflow applies:

| Goal | Command |
| --- | --- |
| Re-run after a failed or interrupted build | `./build.sh` |
| Change only the web content | `touch stage-kernel/SKIP` (and `pi-gen/stage{0,1,2}/SKIP`), then `CLEAN=1 ./build.sh` |
| Rebuild the kernel from the current source tree | `touch pi-gen/stage{0,1,2}/SKIP; CLEAN=1 ./build.sh` |
| Pull the newest commits on `KERNEL_BRANCH` | set `KERNEL_UPDATE=1` in `config` for one run |
| Start from scratch | `./build.sh reset && ./build.sh` |
| Poke around the build environment | `./build.sh shell` |

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

* The stock `linux-image-rpi-v8` package stays installed. To boot it instead, comment
  out the `kernel=` line in `/boot/firmware/config.txt`.
* The custom kernel is *not* registered as `/boot/vmlinuz-<release>`. `update-initramfs
  -k all` (run by pi-gen's export step) enumerates that path, and the `raspi-firmware`
  hooks only know the `-rpi-v8` / `-rpi-2712` flavours, so keeping the kernel out of
  `/boot` keeps both mechanisms from touching it. `bcm2711_defconfig` has MMC, USB
  storage and ext4 built in and boots without an initramfs; `auto_initramfs=1` looks
  for `initramfs8-demo`, finds nothing, and loads none.
* The DTBs and overlays in `/boot/firmware` are the ones built from the custom tree
  (same 6.12 series as the stock kernel, so both kernels boot with them). A later
  `apt upgrade` of the stock kernel package will rewrite them from the stock package;
  that is fine for the stock kernel and normally fine for ours, but pin
  `KERNEL_COMMIT` if you want to be sure what you tested is what you ship.

## Configuration knobs

Everything is in `config` (bash, sourced by pi-gen). Upstream variables are documented
in `pi-gen/README.md`. Our additions:

| Variable | Default | Meaning |
| --- | --- | --- |
| `KERNEL_GIT_URL` | `https://github.com/raspberrypi/linux.git` | kernel source |
| `KERNEL_BRANCH` | `rpi-6.12.y` | branch to shallow-clone |
| `KERNEL_COMMIT` | empty | pin an exact commit |
| `KERNEL_DEFCONFIG` | `bcm2711_defconfig` | base config (Pi 4 family, 64-bit) |
| `KERNEL_IMG_NAME` | `kernel8-demo.img` | file name under `/boot/firmware` and `kernel=` value |
| `KERNEL_SRC_DIR` | `${BASE_DIR}/work/kernel/linux` | source/object tree, inside the work volume |
| `KERNEL_UPDATE` | `0` | `1` re-fetches the branch tip on each build |
| `KERNEL_JOBS` | `nproc` | make parallelism |

Wrapper (`build.sh`) environment: `CLEAN=1`, `CONTAINER_NAME`, `WORK_VOLUME` (volume
name or host path), `IMG_NAME`, `PI_GEN_RELEASE`, `DOCKER_PLATFORM`, `PIGEN_DOCKER_OPTS`,
`DOCKER`.

## Building without Docker

On a Debian/Ubuntu arm64 host with the packages from `Dockerfile` installed:

```sh
touch pi-gen/stage2/SKIP_IMAGES
sudo GIT_HASH=$(git rev-parse HEAD) pi-gen/build.sh -c "$PWD/config"
```

## References

* pi-gen README (`pi-gen/README.md`): config variables, stage anatomy, SKIP workflow.
* Raspberry Pi kernel build guide: <https://www.raspberrypi.com/documentation/computers/linux_kernel.html>
* `config.txt` boot options (`kernel`, `auto_initramfs`, `[pi4]` filters): <https://www.raspberrypi.com/documentation/computers/config_txt.html>
