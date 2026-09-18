#!/usr/bin/env bash
# Engine shared by ./build-dev.sh and ./build-release.sh: builds the Raspberry Pi 4
# image inside Docker for one variant.
#
#   scripts/build-image.sh <variant> [build]   build; output lands in ./deploy/
#   scripts/build-image.sh <variant> shell     root shell in the build environment, same volumes
#   scripts/build-image.sh <variant> reset     delete the variant's cached work volume
#
# <variant> selects config/<variant>.conf (dev, release). Each variant gets its own
# container name and work volume, so both can be built side by side.
#
# Environment:
#   CLEAN=1               pi-gen: rebuild the rootfs of every stage that has no SKIP file
#   CONTAINER_NAME        default: pigen_<variant>
#   WORK_VOLUME           default: ${CONTAINER_NAME}_work (persists between runs); a Docker
#                         volume name, or an absolute host path (used by CI to pick a disk)
#   IMG_NAME, PI_GEN_RELEASE, KERNEL_SOURCE, KERNEL_UPDATE
#                         passed through to pi-gen; the config falls back to its defaults
#   GITHUB_TOKEN          forwarded for KERNEL_SOURCE=deb downloads from a private
#                         repository; defaults to `gh auth token` when gh is logged in
#   CCACHE_DIR            host directory for the kernel compiler cache (KERNEL_SOURCE=build);
#                         default: inside the work volume
#   DOCKER_PLATFORM, DOCKER, IMAGE_TAG   see scripts/docker-env.sh
#   PIGEN_DOCKER_OPTS     extra arguments for `docker run`
#
# The work volume makes every run incremental: debootstrap output, stage rootfs
# copies and the kernel source/object tree survive, so a re-run after a failure or a
# change in stage-web takes minutes, not hours. See README.md for the SKIP workflow.
#
# Modelled on pi-gen/build-docker.sh.
set -eu

# shellcheck source=scripts/docker-env.sh
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/docker-env.sh"

VARIANT=${1:-}
CMD=${2:-build}

variants() {
	(cd "${ROOT}/config" && ls -- *.conf | sed 's/\.conf$//' | grep -v '^common$' | tr '\n' ' ')
}

if [ -z "${VARIANT}" ] || [ ! -f "${ROOT}/config/${VARIANT}.conf" ]; then
	echo "Usage: $0 <variant> [build|shell|reset]    variants: $(variants)" >&2
	exit 1
fi

CONFIG_IN_CONTAINER="/build/config/${VARIANT}.conf"
CONTAINER_NAME=${CONTAINER_NAME:-pigen_${VARIANT}}
WORK_VOLUME=${WORK_VOLUME:-${CONTAINER_NAME}_work}
PIGEN_DOCKER_OPTS=${PIGEN_DOCKER_OPTS:-}

env_check

case "${CMD}" in
	reset)
		env_remove_volume "${WORK_VOLUME}"
		exit 0
		;;
	build|shell)
		;;
	*)
		sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac

env_assert_not_running "${CONTAINER_NAME}"
mkdir -p "${ROOT}/deploy"

# KERNEL_SOURCE=deb downloads a GitHub release; for a private repository that needs a
# token. Use the gh CLI's login when the developer has one and nothing is set.
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
	GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi

env_build_image

# shellcheck disable=SC2086,SC2046
run_container() {
	env_run \
		--name "${CONTAINER_NAME}" \
		--volume "${WORK_VOLUME}:/build/pi-gen/work" \
		--volume "${ROOT}/deploy:/build/pi-gen/deploy" \
		-e "GIT_HASH=$(env_git_hash)" \
		-e "CLEAN=${CLEAN:-}" \
		-e "IMG_NAME=${IMG_NAME:-}" \
		-e "PI_GEN_RELEASE=${PI_GEN_RELEASE:-}" \
		-e "KERNEL_SOURCE=${KERNEL_SOURCE:-}" \
		-e "KERNEL_UPDATE=${KERNEL_UPDATE:-}" \
		-e "GITHUB_TOKEN=${GITHUB_TOKEN:-}" \
		-e "PIGEN_CONFIG=${CONFIG_IN_CONTAINER}" \
		$(env_ccache_opts) \
		${PIGEN_DOCKER_OPTS} \
		"$@"
}

if [ "${CMD}" = "shell" ]; then
	run_container -it "${IMAGE_TAG}" bash
	exit 0
fi

echo "==> Running pi-gen (${VARIANT}) in container ${CONTAINER_NAME} (work volume: ${WORK_VOLUME})"
START=$(date +%s)
run_container "${IMAGE_TAG}" bash -e -o pipefail -c '
	if [ "$(uname -m)" != "aarch64" ]; then
		# Non-arm64 host: register qemu-aarch64 with the host kernel for the chroot.
		dpkg-reconfigure qemu-user-static
		mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
	fi
	cd /build/pi-gen
	./build.sh -c "${PIGEN_CONFIG}"
	cp -f work/*/build.log deploy/ 2>/dev/null || true
'
echo "==> Done in $(env_elapsed $(( $(date +%s) - START ))). Images in ${ROOT}/deploy:"
ls -lah "${ROOT}/deploy"
