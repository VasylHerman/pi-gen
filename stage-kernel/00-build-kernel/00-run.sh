#!/bin/bash -e
# Build a custom Raspberry Pi kernel (arm64, BCM2711 = Pi 4 / 400 / CM4) from source
# and install it into the image next to the stock Debian kernel.
#
# Runs on the build host (the Docker build container), not inside the chroot: the
# kernel is compiled with the host toolchain, then Image, DTBs, overlays and modules
# are copied into ${ROOTFS_DIR}. Follows the official procedure:
# https://www.raspberrypi.com/documentation/computers/linux_kernel.html
#
# Result in the image:
#   /boot/firmware/${KERNEL_IMG_NAME}      custom kernel (stock kernel8.img is kept)
#   /boot/firmware/bcm2711*.dtb, overlays/ replaced by the ones built from the same tree
#   /lib/modules/<release>/                modules (stripped) for the custom kernel
#   /boot/firmware/config.txt              [pi4] kernel=${KERNEL_IMG_NAME}
#   /etc/demo-kernel                       KEY=VALUE facts, consumed by stage-web
#   /usr/share/doc/demo-kernel/            the exact .config used
#
# The kernel is deliberately NOT registered as /boot/vmlinuz-<release>. That keeps
# `update-initramfs -k all` (run by export-image, enumerates /boot/vmlinuz-*) and the
# raspi-firmware kernel/initramfs hooks (which only understand the -rpi-v8 / -rpi-2712
# flavours) away from it. bcm2711_defconfig has MMC, USB storage and ext4 built in,
# so the kernel boots without an initramfs; auto_initramfs looks for a file named
# "initramfs8-demo", finds none, and simply loads no initramfs.

KERNEL_GIT_URL=${KERNEL_GIT_URL:-https://github.com/raspberrypi/linux.git}
KERNEL_BRANCH=${KERNEL_BRANCH:-rpi-6.12.y}
KERNEL_COMMIT=${KERNEL_COMMIT:-}
KERNEL_DEFCONFIG=${KERNEL_DEFCONFIG:-bcm2711_defconfig}
KERNEL_IMG_NAME=${KERNEL_IMG_NAME:-kernel8-demo.img}
KERNEL_SRC_DIR=${KERNEL_SRC_DIR:-${BASE_DIR}/work/kernel/linux}
KERNEL_UPDATE=${KERNEL_UPDATE:-0}
KERNEL_JOBS=${KERNEL_JOBS:-$(nproc)}

FRAGMENT="$(pwd)/files/demo.config"
FIRMWARE_DIR="${ROOTFS_DIR}/boot/firmware"
INFO_FILE="${ROOTFS_DIR}/etc/demo-kernel"
CONFIG_TXT="${FIRMWARE_DIR}/config.txt"

# ---- toolchain ----------------------------------------------------------------
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	CROSS_COMPILE=aarch64-linux-gnu-
elif [ "$(uname -m)" = "aarch64" ]; then
	CROSS_COMPILE=
else
	echo "No aarch64 compiler found. Install crossbuild-essential-arm64." >&2
	exit 1
fi

# LOCALVERSION= (set but empty) stops scripts/setlocalversion from appending "+" for
# an untagged tree; the visible suffix comes from CONFIG_LOCALVERSION in the fragment.
kmake() {
	make -C "${KERNEL_SRC_DIR}" -j"${KERNEL_JOBS}" \
		ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" LOCALVERSION= "$@"
}

# ---- source -------------------------------------------------------------------
if [ ! -f "${KERNEL_SRC_DIR}/Makefile" ]; then
	log "Cloning ${KERNEL_GIT_URL} branch ${KERNEL_BRANCH} into ${KERNEL_SRC_DIR}"
	mkdir -p "$(dirname "${KERNEL_SRC_DIR}")"
	git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_GIT_URL}" "${KERNEL_SRC_DIR}"
elif [ -d "${KERNEL_SRC_DIR}/.git" ] && [ "${KERNEL_UPDATE}" = "1" ]; then
	log "Updating kernel source to the tip of ${KERNEL_BRANCH}"
	git -C "${KERNEL_SRC_DIR}" fetch --depth=1 origin "${KERNEL_BRANCH}"
	git -C "${KERNEL_SRC_DIR}" checkout -q --detach FETCH_HEAD
else
	log "Reusing kernel source in ${KERNEL_SRC_DIR} (set KERNEL_UPDATE=1 to refresh)"
fi

if [ -n "${KERNEL_COMMIT}" ] && [ -d "${KERNEL_SRC_DIR}/.git" ]; then
	if [ "$(git -C "${KERNEL_SRC_DIR}" rev-parse HEAD)" != "${KERNEL_COMMIT}" ]; then
		log "Checking out pinned commit ${KERNEL_COMMIT}"
		git -C "${KERNEL_SRC_DIR}" fetch --depth=1 origin "${KERNEL_COMMIT}"
		git -C "${KERNEL_SRC_DIR}" checkout -q --detach "${KERNEL_COMMIT}"
	fi
fi

KERNEL_GIT_HASH=$(git -C "${KERNEL_SRC_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)

# ---- configure ----------------------------------------------------------------
log "Configuring kernel: ${KERNEL_DEFCONFIG} + $(basename "${FRAGMENT}")"
kmake "${KERNEL_DEFCONFIG}"
# -m: merge only, do not run `make alldefconfig`; olddefconfig below resolves deps.
(
	cd "${KERNEL_SRC_DIR}"
	ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
		scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}"
)
kmake olddefconfig >/dev/null

while IFS= read -r line; do
	case "${line}" in
		"# CONFIG_"*" is not set"|CONFIG_*) ;;
		*) continue ;;
	esac
	if ! grep -qxF -- "${line}" "${KERNEL_SRC_DIR}/.config"; then
		echo "ERROR: fragment option was dropped by Kconfig: ${line}" >&2
		exit 1
	fi
done < "${FRAGMENT}"

# ---- build --------------------------------------------------------------------
log "Building kernel with ${KERNEL_JOBS} jobs (first run takes a while; later runs are incremental)"
kmake Image modules dtbs
KREL=$(kmake -s kernelrelease)
log "Built kernel ${KREL} from ${KERNEL_GIT_HASH}"

# ---- install ------------------------------------------------------------------
# Re-run on an existing rootfs: drop the modules of a previous custom build.
if [ -f "${INFO_FILE}" ]; then
	OLD_KREL=$(sed -n 's/^KERNEL_RELEASE="\(.*\)"$/\1/p' "${INFO_FILE}")
	if [ -n "${OLD_KREL}" ] && [ "${OLD_KREL}" != "${KREL}" ]; then
		rm -rf "${ROOTFS_DIR}/lib/modules/${OLD_KREL}"
	fi
fi

kmake INSTALL_MOD_PATH="${ROOTFS_DIR}" INSTALL_MOD_STRIP=1 modules_install >/dev/null
# These symlinks point at build-host paths and are useless on the target.
rm -f "${ROOTFS_DIR}/lib/modules/${KREL}/build" "${ROOTFS_DIR}/lib/modules/${KREL}/source"

install -m 644 "${KERNEL_SRC_DIR}/arch/arm64/boot/Image" "${FIRMWARE_DIR}/${KERNEL_IMG_NAME}"
install -m 644 "${KERNEL_SRC_DIR}"/arch/arm64/boot/dts/broadcom/bcm2711*.dtb "${FIRMWARE_DIR}/"
install -d -m 755 "${FIRMWARE_DIR}/overlays"
install -m 644 "${KERNEL_SRC_DIR}"/arch/arm64/boot/dts/overlays/*.dtb* "${FIRMWARE_DIR}/overlays/"
install -m 644 "${KERNEL_SRC_DIR}/arch/arm64/boot/dts/overlays/README" "${FIRMWARE_DIR}/overlays/"

install -d -m 755 "${ROOTFS_DIR}/usr/share/doc/demo-kernel"
install -m 644 "${KERNEL_SRC_DIR}/.config" "${ROOTFS_DIR}/usr/share/doc/demo-kernel/config-${KREL}"

# Boot the custom kernel on Pi 4 family boards. Block is replaced on re-runs.
sed -i '/^# BEGIN stage-kernel$/,/^# END stage-kernel$/d' "${CONFIG_TXT}"
cat >> "${CONFIG_TXT}" <<EOF
# BEGIN stage-kernel
[pi4]
# Custom kernel ${KREL} built by stage-kernel from ${KERNEL_GIT_URL} ${KERNEL_BRANCH}.
# Comment out the kernel= line to fall back to the stock Debian kernel8.img.
kernel=${KERNEL_IMG_NAME}
[all]
# END stage-kernel
EOF

cat > "${INFO_FILE}" <<EOF
KERNEL_RELEASE="${KREL}"
KERNEL_IMAGE="${KERNEL_IMG_NAME}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG}"
KERNEL_GIT_URL="${KERNEL_GIT_URL}"
KERNEL_BRANCH="${KERNEL_BRANCH}"
KERNEL_COMMIT="${KERNEL_GIT_HASH}"
KERNEL_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
chmod 644 "${INFO_FILE}"

log "Installed ${KERNEL_IMG_NAME} (${KREL}), $(find "${ROOTFS_DIR}/lib/modules/${KREL}" -name '*.ko*' | wc -l) modules"
