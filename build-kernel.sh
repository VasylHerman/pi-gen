#!/usr/bin/env bash
# Build the custom kernel as a Debian package, without building an image.
#
#   ./build-kernel.sh            build; results land in ./deploy/ (.deb, Image, config, SHA256SUMS)
#   ./build-kernel.sh shell      root shell in the build environment with the kernel work volume
#   ./build-kernel.sh reset      delete the kernel work volume (source + object tree)
#
# This is what .github/workflows/kernel.yml runs. Image builds do not need it:
# stage-kernel either downloads the published package (KERNEL_SOURCE=deb) or runs the
# same kernel/build-kernel.sh itself (KERNEL_SOURCE=build).
#
# Environment:
#   KERNEL_UPDATE=1       re-fetch KERNEL_BRANCH and build its tip instead of KERNEL_COMMIT
#   KERNEL_JOBS           make parallelism (default: nproc)
#   CONTAINER_NAME        default: pigen_kernel;  WORK_VOLUME default: ${CONTAINER_NAME}_work
#   DOCKER_PLATFORM, DOCKER, IMAGE_TAG   see scripts/docker-env.sh
set -eu

# shellcheck source=scripts/docker-env.sh
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/scripts/docker-env.sh"

CMD=${1:-build}
CONTAINER_NAME=${CONTAINER_NAME:-pigen_kernel}
WORK_VOLUME=${WORK_VOLUME:-${CONTAINER_NAME}_work}

env_check

case "${CMD}" in
	reset)
		env_remove_volume "${WORK_VOLUME}"
		exit 0
		;;
	build|shell)
		;;
	*)
		sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac

env_assert_not_running "${CONTAINER_NAME}"
mkdir -p "${ROOT}/deploy"
env_build_image

run_container() {
	# Same mount points as an image build, so KERNEL_SRC_DIR from config/common.conf
	# (${BASE_DIR}/work/kernel/linux) resolves identically.
	env_run \
		--name "${CONTAINER_NAME}" \
		--volume "${WORK_VOLUME}:/build/pi-gen/work" \
		--volume "${ROOT}/deploy:/build/pi-gen/deploy" \
		-e "KERNEL_UPDATE=${KERNEL_UPDATE:-}" \
		-e "KERNEL_JOBS=${KERNEL_JOBS:-}" \
		"$@"
}

if [ "${CMD}" = "shell" ]; then
	run_container -it "${IMAGE_TAG}" bash
	exit 0
fi

echo "==> Building kernel package in container ${CONTAINER_NAME} (work volume: ${WORK_VOLUME})"
START=$(date +%s)
run_container "${IMAGE_TAG}" bash -e -o pipefail -c '
	export BASE_DIR=/build/pi-gen
	. /build/config/common.conf
	OUT_DIR=/build/pi-gen/deploy /build/kernel/build-kernel.sh
'
echo "==> Done in $(env_elapsed $(( $(date +%s) - START ))). Results in ${ROOT}/deploy:"
ls -lah "${ROOT}/deploy"
