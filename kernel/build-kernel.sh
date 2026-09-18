#!/bin/bash -e
# Build the custom Raspberry Pi 4 kernel (arm64, BCM2711) as a Debian package.
#
# Runs on a Debian host with the packages from the Dockerfile: the build container via
# ./build-kernel.sh (CI and standalone use), or stage-kernel with KERNEL_SOURCE=build.
# Follows https://www.raspberrypi.com/documentation/computers/linux_kernel.html, then
# packages with the kernel's own `make bindeb-pkg`.
#
# Inputs (environment; config/common.conf sets the KERNEL_* ones):
#   KERNEL_GIT_URL KERNEL_BRANCH KERNEL_COMMIT KERNEL_DEFCONFIG KERNEL_SRC_DIR
#   KERNEL_UPDATE KERNEL_JOBS KERNEL_IMG_NAME
#   KERNEL_FRAGMENT   Kconfig fragment            (default: kernel/demo.config)
#   KERNEL_VERSION    Debian package version      (default: contents of kernel/VERSION)
#   OUT_DIR           where to put the results    (required)
#
# Outputs in OUT_DIR:
#   linux-image-<release>_<version>_arm64.deb   kernel, modules, DTBs and overlays
#   <KERNEL_IMG_NAME>                           the bare Image, for QEMU (run-qemu.sh)
#   config-<release>, overlays-README           the exact .config; the overlays README
#   kernel-release.env                          KEY="value" facts for stage-kernel and release notes
#   SHA256SUMS
#
# Version scheme: KERNEL_VERSION is "<upstream version>-demo.<N>", e.g. 6.12.110-demo.1.
# The upstream part must match the source tree (checked below); N is bumped whenever the
# fragment changes without the source moving. `uname -r` stays "<upstream>-v8-demo".

KERNEL_GIT_URL=${KERNEL_GIT_URL:-https://github.com/raspberrypi/linux.git}
KERNEL_BRANCH=${KERNEL_BRANCH:-rpi-6.12.y}
KERNEL_COMMIT=${KERNEL_COMMIT:-}
KERNEL_DEFCONFIG=${KERNEL_DEFCONFIG:-bcm2711_defconfig}
KERNEL_IMG_NAME=${KERNEL_IMG_NAME:-kernel8-demo.img}
KERNEL_UPDATE=${KERNEL_UPDATE:-0}
KERNEL_JOBS=${KERNEL_JOBS:-$(nproc)}

KERNEL_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
KERNEL_FRAGMENT=${KERNEL_FRAGMENT:-${KERNEL_DIR}/demo.config}
KERNEL_VERSION=${KERNEL_VERSION:-$(tr -d '[:space:]' < "${KERNEL_DIR}/VERSION")}
KERNEL_SRC_DIR=${KERNEL_SRC_DIR:-${KERNEL_DIR}/../work/kernel/linux}
: "${OUT_DIR:?OUT_DIR must be set}"

# pi-gen exports log(); provide the same shape when running standalone.
if ! type log >/dev/null 2>&1; then
	log() { date +"[%T] $*"; }
fi

case "${KERNEL_VERSION}" in
	*-demo.[0-9]*) ;;
	*) echo "ERROR: KERNEL_VERSION '${KERNEL_VERSION}' is not <upstream>-demo.<N>" >&2; exit 1 ;;
esac

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

if [ -n "${KERNEL_COMMIT}" ] && [ "${KERNEL_UPDATE}" != "1" ] && [ -d "${KERNEL_SRC_DIR}/.git" ]; then
	if [ "$(git -C "${KERNEL_SRC_DIR}" rev-parse HEAD)" != "${KERNEL_COMMIT}" ]; then
		log "Checking out pinned commit ${KERNEL_COMMIT}"
		git -C "${KERNEL_SRC_DIR}" fetch --depth=1 origin "${KERNEL_COMMIT}"
		git -C "${KERNEL_SRC_DIR}" checkout -q --detach "${KERNEL_COMMIT}"
	fi
fi

KERNEL_GIT_HASH=$(git -C "${KERNEL_SRC_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)

# ---- reproducible build stamps --------------------------------------------------
# `uname -v` embeds a build counter, date, user and host (scripts/mkcompile_h). Fix all
# four so the same source revision and config produce a byte-identical kernel: counter
# 1 instead of the object tree's .version, the commit date instead of wall-clock time,
# neutral names instead of root@<container id>. SOURCE_DATE_EPOCH does the same for
# the file timestamps inside the .deb.
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP=$(git -C "${KERNEL_SRC_DIR}" log -1 --format=%cD 2>/dev/null || date -u -R)
SOURCE_DATE_EPOCH=$(git -C "${KERNEL_SRC_DIR}" log -1 --format=%ct 2>/dev/null || date +%s)
export KBUILD_BUILD_USER=pi-gen-demo
export KBUILD_BUILD_HOST=build
export DEBFULLNAME="pi-gen-demo"
export DEBEMAIL="pi-gen-demo@localhost"

# ---- configure ----------------------------------------------------------------
log "Configuring kernel: ${KERNEL_DEFCONFIG} + $(basename "${KERNEL_FRAGMENT}")"
kmake "${KERNEL_DEFCONFIG}"
# -m: merge only, do not run `make alldefconfig`; olddefconfig below resolves deps.
(
	cd "${KERNEL_SRC_DIR}"
	ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
		scripts/kconfig/merge_config.sh -m .config "${KERNEL_FRAGMENT}"
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
done < "${KERNEL_FRAGMENT}"

UPSTREAM=$(kmake -s kernelversion)
case "${KERNEL_VERSION}" in
	"${UPSTREAM}-demo."*) ;;
	*)
		echo "ERROR: kernel/VERSION is ${KERNEL_VERSION} but the source tree is Linux ${UPSTREAM}" >&2
		echo "       (KERNEL_COMMIT ${KERNEL_GIT_HASH}); update one of them." >&2
		exit 1
		;;
esac

# ---- build + package --------------------------------------------------------------
log "Building kernel ${UPSTREAM} package ${KERNEL_VERSION} with ${KERNEL_JOBS} jobs"
# bindeb-pkg runs the (incremental) build, then dpkg-buildpackage. The nokernelheaders
# profile drops the linux-headers package, which nothing here needs and which would
# require a cross gcc even on a native host.
DEB_BUILD_PROFILES=pkg.linux-upstream.nokernelheaders \
	kmake KDEB_PKGVERSION="${KERNEL_VERSION}" KDEB_CHANGELOG_DIST=bookworm KDEB_COMPRESS=xz bindeb-pkg

KREL=$(kmake -s kernelrelease)
DEB_NAME="linux-image-${KREL}_${KERNEL_VERSION}_arm64.deb"
DEB_PATH="$(dirname "${KERNEL_SRC_DIR}")/${DEB_NAME}"
if [ ! -f "${DEB_PATH}" ]; then
	echo "ERROR: expected package not produced: ${DEB_PATH}" >&2
	exit 1
fi

# ---- collect ------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}"/linux-image-*.deb "${OUT_DIR}"/config-* "${OUT_DIR}/SHA256SUMS"
install -m 644 "${DEB_PATH}" "${OUT_DIR}/${DEB_NAME}"
install -m 644 "${KERNEL_SRC_DIR}/arch/arm64/boot/Image" "${OUT_DIR}/${KERNEL_IMG_NAME}"
install -m 644 "${KERNEL_SRC_DIR}/.config" "${OUT_DIR}/config-${KREL}"
install -m 644 "${KERNEL_SRC_DIR}/arch/arm64/boot/dts/overlays/README" "${OUT_DIR}/overlays-README"
cat > "${OUT_DIR}/kernel-release.env" <<EOF
KERNEL_RELEASE="${KREL}"
KERNEL_VERSION="${KERNEL_VERSION}"
KERNEL_PACKAGE="linux-image-${KREL}"
KERNEL_DEB="${DEB_NAME}"
KERNEL_IMAGE="${KERNEL_IMG_NAME}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG}"
KERNEL_GIT_URL="${KERNEL_GIT_URL}"
KERNEL_BRANCH="${KERNEL_BRANCH}"
KERNEL_COMMIT="${KERNEL_GIT_HASH}"
KERNEL_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
(cd "${OUT_DIR}" && sha256sum "${DEB_NAME}" "${KERNEL_IMG_NAME}" "config-${KREL}" overlays-README kernel-release.env > SHA256SUMS)

log "Built ${DEB_NAME} (${KREL}) from ${KERNEL_GIT_HASH}: $(du -h "${OUT_DIR}/${DEB_NAME}" | cut -f1)"
