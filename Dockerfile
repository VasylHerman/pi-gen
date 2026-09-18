# Build environment for the Raspberry Pi 4 custom-kernel demo image.
#
# Contains everything pi-gen needs (debootstrap, loop devices, chroot tooling —
# see pi-gen/depends and pi-gen/Dockerfile) plus the kernel build and Debian
# packaging toolchain used by kernel/build-kernel.sh (debhelper satisfies the
# Build-Depends that `make bindeb-pkg` generates). Built and run by
# scripts/build-image.sh (via ./build-dev.sh, ./build-release.sh) and ./build-kernel.sh;
# not meant to be used directly.
#
# On an arm64 host (Apple Silicon, Pi, Graviton) the arm64 chroot runs natively and
# the kernel is built with the native gcc (Debian still provides the
# aarch64-linux-gnu-gcc name). On amd64 hosts qemu-user-static + binfmt handle the
# chroot and crossbuild-essential-arm64 provides the cross compiler.
# qemu-user-static is installed on every host because pi-gen/depends lists
# qemu-arm-static unconditionally and its dependency check would fail without it.
# scripts/build-image.sh passes --platform explicitly; the FROM image must match the
# Docker server's native architecture or the whole build runs under emulation.
ARG BASE_IMAGE=debian:bookworm
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -y update && \
    apt-get -y install --no-install-recommends \
        git parted quilt coreutils debootstrap zerofree zip \
        dosfstools e2fsprogs libarchive-tools libcap2-bin rsync grep udev xz-utils \
        curl xxd file kmod bc ca-certificates fdisk gpg pigz arch-test \
        qemu-user-static binfmt-support \
        build-essential bison flex libssl-dev libelf-dev libncurses-dev python3 cpio \
        debhelper \
    && if [ "$(dpkg --print-architecture)" != "arm64" ]; then \
        apt-get -y install --no-install-recommends crossbuild-essential-arm64; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# Repo layout is preserved: /build/pi-gen is the upstream submodule, /build/stage-*
# are our stages, /build/config/<variant>.conf the pi-gen configs.
COPY . /build/

# Only export the final image (stage-web has EXPORT_IMAGE); skip the intermediate
# stage2 "lite" image that upstream would also export.
RUN touch /build/pi-gen/stage2/SKIP_IMAGES

VOLUME [ "/build/pi-gen/work", "/build/pi-gen/deploy" ]
WORKDIR /build/pi-gen
