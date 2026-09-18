#!/bin/bash -e
# Install the custom kernel into the image from its Debian package.
#
# Runs on the build host (the Docker build container), not inside the chroot. Two ways
# to obtain the package, selected by KERNEL_SOURCE (config/<variant>.conf):
#   deb     download the release "kernel-v<kernel/VERSION>" of KERNEL_DEB_REPO on GitHub,
#           published by .github/workflows/kernel.yml, and verify its SHA256SUMS;
#           with GITHUB_TOKEN set the download goes through the API (private repos)
#   build   run kernel/build-kernel.sh here (developer loop: edit the fragment, rebuild)
# Both land in the same directory layout, and everything after that is identical, so
# dev and release images are provisioned the same way.
#
# Result in the image:
#   linux-image-<release> package               kernel, modules, DTBs, overlays (dpkg-owned)
#   /boot/firmware/${KERNEL_IMG_NAME}            copy of the kernel (stock kernel8.img is kept)
#   /boot/firmware/bcm2711*.dtb, overlays/       from the package
#   /boot/firmware/config.txt                    [pi4] kernel=${KERNEL_IMG_NAME}
#   /etc/demo-kernel                             KEY="value" facts, consumed by stage-web
# and, outside the image, a copy of the kernel in ${DEPLOY_DIR} for run-qemu.sh.
#
# Our version string ends in -v8-demo, not -rpi-v8, so raspi-firmware's kernel hooks
# say "unsupported ... skipping" and leave the boot partition to us, which is intended:
# the custom kernel must not displace kernel8.img. The package's /boot/vmlinuz-<release>
# is removed after copying so that pi-gen's export step (`update-initramfs -k all`,
# which enumerates /boot/vmlinuz-*) does not generate an initramfs nobody loads.
# bcm2711_defconfig has MMC, USB storage and ext4 built in and boots without one.

KERNEL_SOURCE=${KERNEL_SOURCE:-build}
KERNEL_DEB_REPO=${KERNEL_DEB_REPO:-VasylHerman/pi-gen-demo}
KERNEL_IMG_NAME=${KERNEL_IMG_NAME:-kernel8-demo.img}

KERNEL_DIR=$(realpath "${BASE_DIR}/../kernel")
KERNEL_VERSION=$(tr -d '[:space:]' < "${KERNEL_DIR}/VERSION")
PKG_DIR="${BASE_DIR}/work/kernel/pkg/${KERNEL_VERSION}-${KERNEL_SOURCE}"
FIRMWARE_DIR="${ROOTFS_DIR}/boot/firmware"
INFO_FILE="${ROOTFS_DIR}/etc/demo-kernel"
CONFIG_TXT="${FIRMWARE_DIR}/config.txt"

# ---- obtain the package ---------------------------------------------------------------
case "${KERNEL_SOURCE}" in
	deb)
		RELEASE_TAG="kernel-v${KERNEL_VERSION}"
		if [ -f "${PKG_DIR}/SHA256SUMS" ] && (cd "${PKG_DIR}" && sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1); then
			log "Using cached kernel package ${RELEASE_TAG} from ${PKG_DIR}"
		else
			# Two download paths. Without a token, the public release URL. With GITHUB_TOKEN
			# (a private repository, or CI's github.token), the REST API: assets of private
			# releases are only served through /releases/assets/<id> with an Authorization
			# header. The engine forwards GITHUB_TOKEN into the container; locally,
			# `export GITHUB_TOKEN=$(gh auth token)` is enough.
			ASSET_JSON="${PKG_DIR}/.release.json"
			fetch_asset() {   # fetch_asset <name> <destination>
				if [ -n "${GITHUB_TOKEN:-}" ]; then
					local id
					id=$(python3 -c 'import json,sys
for a in json.load(open(sys.argv[1]))["assets"]:
    if a["name"] == sys.argv[2]:
        print(a["id"]); break' "${ASSET_JSON}" "$1")
					[ -n "${id}" ] || { echo "ERROR: release ${RELEASE_TAG} has no asset $1" >&2; return 1; }
					curl -fsSL --retry 3 \
						-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/octet-stream" \
						-o "$2" "https://api.github.com/repos/${KERNEL_DEB_REPO}/releases/assets/${id}"
				else
					curl -fsSL --retry 3 -o "$2" \
						"https://github.com/${KERNEL_DEB_REPO}/releases/download/${RELEASE_TAG}/$1"
				fi
			}
			rm -rf "${PKG_DIR}"
			mkdir -p "${PKG_DIR}"
			if [ -n "${GITHUB_TOKEN:-}" ]; then
				log "Downloading kernel package ${RELEASE_TAG} from ${KERNEL_DEB_REPO} (authenticated, GitHub API)"
				curl -fsSL --retry 3 \
					-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
					-o "${ASSET_JSON}" "https://api.github.com/repos/${KERNEL_DEB_REPO}/releases/tags/${RELEASE_TAG}" || true
			else
				log "Downloading kernel package ${RELEASE_TAG} from ${KERNEL_DEB_REPO} (public release URL)"
			fi
			if ! fetch_asset SHA256SUMS "${PKG_DIR}/SHA256SUMS" 2>/dev/null; then
				echo "ERROR: cannot fetch GitHub release ${RELEASE_TAG} from ${KERNEL_DEB_REPO}." >&2
				echo "       - not published yet? merge the kernel change so .github/workflows/kernel.yml publishes it" >&2
				echo "       - private repository? set GITHUB_TOKEN (e.g. export GITHUB_TOKEN=\$(gh auth token))" >&2
				echo "       - or build locally with KERNEL_SOURCE=build" >&2
				exit 1
			fi
			awk '{print $2}' "${PKG_DIR}/SHA256SUMS" | while read -r f; do
				fetch_asset "${f}" "${PKG_DIR}/${f}"
			done
			rm -f "${ASSET_JSON}"
			(cd "${PKG_DIR}" && sha256sum --quiet -c SHA256SUMS)
		fi
		;;
	build)
		log "Building kernel package ${KERNEL_VERSION} (KERNEL_SOURCE=build)"
		OUT_DIR="${PKG_DIR}" "${KERNEL_DIR}/build-kernel.sh"
		;;
	*)
		echo "ERROR: KERNEL_SOURCE must be 'deb' or 'build', got '${KERNEL_SOURCE}'" >&2
		exit 1
		;;
esac

# shellcheck disable=SC1091
. "${PKG_DIR}/kernel-release.env"   # KERNEL_RELEASE KERNEL_PACKAGE KERNEL_DEB KERNEL_COMMIT ...
KREL=${KERNEL_RELEASE}

# ---- install the package in the image ------------------------------------------------
# Re-run on an existing rootfs with a different release: drop the previous package.
if [ -f "${INFO_FILE}" ]; then
	OLD_PKG=$(sed -n 's/^KERNEL_PACKAGE="\(.*\)"$/\1/p' "${INFO_FILE}")
	if [ -n "${OLD_PKG}" ] && [ "${OLD_PKG}" != "${KERNEL_PACKAGE}" ]; then
		on_chroot <<EOF
DEBIAN_FRONTEND=noninteractive apt-get -y purge "${OLD_PKG}" || true
EOF
	fi
fi

# Not /tmp: on_chroot mounts a fresh tmpfs there. apt's own archive directory is
# excluded from stage copies and from the exported image by pi-gen anyway (-D: recreate it).
install -D -m 644 "${PKG_DIR}/${KERNEL_DEB}" "${ROOTFS_DIR}/var/cache/apt/archives/${KERNEL_DEB}"
on_chroot <<EOF
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install "/var/cache/apt/archives/${KERNEL_DEB}"
rm -f "/var/cache/apt/archives/${KERNEL_DEB}"
EOF

# ---- boot partition -----------------------------------------------------------------
PKG_LIB="${ROOTFS_DIR}/usr/lib/linux-image-${KREL}"
install -m 644 "${ROOTFS_DIR}/boot/vmlinuz-${KREL}" "${FIRMWARE_DIR}/${KERNEL_IMG_NAME}"
install -m 644 "${PKG_LIB}"/broadcom/bcm2711*.dtb "${FIRMWARE_DIR}/"
install -d -m 755 "${FIRMWARE_DIR}/overlays"
install -m 644 "${PKG_LIB}"/overlays/*.dtbo "${FIRMWARE_DIR}/overlays/"
install -m 644 "${PKG_DIR}/overlays-README" "${FIRMWARE_DIR}/overlays/README"
# See header: keep update-initramfs away from this kernel, and drop the initramfs the
# package's postinst already generated (the initramfs-tools hook creates one even with
# update_initramfs=no); auto_initramfs would not load it anyway.
rm -f "${ROOTFS_DIR}/boot/vmlinuz-${KREL}" "${ROOTFS_DIR}/boot/initrd.img-${KREL}"

# Boot the custom kernel on Pi 4 family boards. Block is replaced on re-runs.
sed -i '/^# BEGIN stage-kernel$/,/^# END stage-kernel$/d' "${CONFIG_TXT}"
cat >> "${CONFIG_TXT}" <<EOF
# BEGIN stage-kernel
[pi4]
# Custom kernel ${KREL} (${KERNEL_PACKAGE} ${KERNEL_VERSION}) from ${KERNEL_GIT_URL} ${KERNEL_COMMIT}.
# Comment out the kernel= line to fall back to the stock Debian kernel8.img.
kernel=${KERNEL_IMG_NAME}
[all]
# END stage-kernel
EOF

# ---- facts for stage-web, stage-slim and the release notes ----------------------
{
	cat "${PKG_DIR}/kernel-release.env"
	echo "KERNEL_SOURCE=\"${KERNEL_SOURCE}\""
	echo "KERNEL_IMAGE=\"${KERNEL_IMG_NAME}\""
} > "${INFO_FILE}"
chmod 644 "${INFO_FILE}"

mkdir -p "${DEPLOY_DIR}"
install -m 644 "${PKG_DIR}/${KERNEL_IMG_NAME}" "${DEPLOY_DIR}/${KERNEL_IMG_NAME}"
install -m 644 "${PKG_DIR}/${KERNEL_DEB}" "${DEPLOY_DIR}/${KERNEL_DEB}"
install -m 644 "${PKG_DIR}/kernel-release.env" "${DEPLOY_DIR}/kernel-release.env"

log "Installed ${KERNEL_PACKAGE} ${KERNEL_VERSION} (${KERNEL_SOURCE}) as ${KERNEL_IMG_NAME}, $(find "${ROOTFS_DIR}/usr/lib/modules/${KREL}" -name '*.ko*' | wc -l) modules"
