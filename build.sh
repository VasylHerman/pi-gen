#!/usr/bin/env bash
# Build the Raspberry Pi 4 custom-kernel demo image inside Docker.
#
#   ./build.sh            build the image; output lands in ./deploy/
#   ./build.sh shell      root shell in the build environment with the same volumes
#   ./build.sh reset      delete the cached work volume (kernel source + stage rootfs)
#
# Environment:
#   CLEAN=1               pi-gen: rebuild the rootfs of every stage that has no SKIP file
#   CONTAINER_NAME        default: pigen_demo
#   WORK_VOLUME           default: ${CONTAINER_NAME}_work (persists between runs)
#   PIGEN_DOCKER_OPTS     extra arguments for `docker run`
#   DOCKER_PLATFORM       default: the Docker server's native platform (linux/arm64 on
#                         Apple Silicon). Set explicitly to override. This wins over a
#                         DOCKER_DEFAULT_PLATFORM in your shell: an emulated amd64
#                         container would compile the kernel under qemu, very slowly.
#
# The work volume makes every run incremental: debootstrap output, stage rootfs
# copies and the kernel source/object tree survive, so a re-run after a failure or a
# change in stage-web takes minutes, not hours. See README.md for the SKIP workflow.
#
# Modelled on pi-gen/build-docker.sh. No bash arrays: macOS ships bash 3.2.
set -eu

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
DOCKER=${DOCKER:-docker}
CONTAINER_NAME=${CONTAINER_NAME:-pigen_demo}
WORK_VOLUME=${WORK_VOLUME:-${CONTAINER_NAME}_work}
IMAGE_TAG=${IMAGE_TAG:-pi-gen-demo}
PIGEN_DOCKER_OPTS=${PIGEN_DOCKER_OPTS:-}
CMD=${1:-build}

case "${DIR}" in
	*" "*)
		echo "debootstrap does not support paths containing spaces: ${DIR}" >&2
		exit 1
		;;
esac

if [ ! -f "${DIR}/pi-gen/build.sh" ]; then
	echo "pi-gen submodule is missing. Run: git submodule update --init" >&2
	exit 1
fi

if ! ${DOCKER} info >/dev/null 2>&1; then
	echo "Cannot talk to Docker. Is Docker Desktop running?" >&2
	exit 1
fi

if [ -z "${DOCKER_PLATFORM:-}" ]; then
	case "$(${DOCKER} info --format '{{.Architecture}}')" in
		aarch64|arm64) DOCKER_PLATFORM=linux/arm64 ;;
		x86_64|amd64) DOCKER_PLATFORM=linux/amd64 ;;
		*) echo "Unsupported Docker server architecture; set DOCKER_PLATFORM" >&2; exit 1 ;;
	esac
fi
if [ -n "${DOCKER_DEFAULT_PLATFORM:-}" ] && [ "${DOCKER_DEFAULT_PLATFORM}" != "${DOCKER_PLATFORM}" ]; then
	echo "Note: ignoring DOCKER_DEFAULT_PLATFORM=${DOCKER_DEFAULT_PLATFORM}, using native ${DOCKER_PLATFORM}"
fi

case "${CMD}" in
	reset)
		${DOCKER} volume rm -f "${WORK_VOLUME}" >/dev/null
		echo "Removed work volume ${WORK_VOLUME}"
		exit 0
		;;
	build|shell)
		;;
	*)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac

if [ -n "$(${DOCKER} ps -q --filter "name=^${CONTAINER_NAME}\$")" ]; then
	echo "A build is already running in container ${CONTAINER_NAME}. Aborting." >&2
	exit 1
fi

# pi-gen/build.sh records GIT_HASH in /etc/rpi-issue and would otherwise run
# `git rev-parse` inside the container, where .git is not present.
GIT_HASH=$(git -C "${DIR}" rev-parse HEAD 2>/dev/null \
	|| git -C "${DIR}/pi-gen" rev-parse HEAD 2>/dev/null \
	|| echo unknown)

mkdir -p "${DIR}/deploy"

echo "==> Building build-environment image ${IMAGE_TAG}"
${DOCKER} build --platform "${DOCKER_PLATFORM}" -t "${IMAGE_TAG}" "${DIR}"

# shellcheck disable=SC2086
run_container() {
	${DOCKER} run --rm --privileged \
		--platform "${DOCKER_PLATFORM}" \
		--name "${CONTAINER_NAME}" \
		--volume "${WORK_VOLUME}:/build/pi-gen/work" \
		--volume "${DIR}/deploy:/build/pi-gen/deploy" \
		-e "GIT_HASH=${GIT_HASH}" \
		-e "CLEAN=${CLEAN:-}" \
		${PIGEN_DOCKER_OPTS} \
		"$@"
}

if [ "${CMD}" = "shell" ]; then
	run_container -it "${IMAGE_TAG}" bash
	exit 0
fi

echo "==> Running pi-gen in container ${CONTAINER_NAME} (work volume: ${WORK_VOLUME})"
START=$(date +%s)
run_container "${IMAGE_TAG}" bash -e -o pipefail -c '
	if [ "$(uname -m)" != "aarch64" ]; then
		# Non-arm64 host: register qemu-aarch64 with the host kernel for the chroot.
		dpkg-reconfigure qemu-user-static
		mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
	fi
	cd /build/pi-gen
	./build.sh -c /build/config
	cp -f work/*/build.log deploy/ 2>/dev/null || true
'
echo "==> Done in $(( ($(date +%s) - START) / 60 )) min. Images in ${DIR}/deploy:"
ls -lah "${DIR}/deploy"
