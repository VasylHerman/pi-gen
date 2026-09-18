# Shared Docker plumbing for scripts/build-image.sh and ./build-kernel.sh. Source it,
# then call env_check, env_build_image and env_run. No bash arrays: macOS ships bash 3.2.
#
#   ROOT             repository root (directory above scripts/)
#   DOCKER           docker command (default: docker)
#   IMAGE_TAG        build-environment image tag (default: pi-gen-demo)
#   DOCKER_PLATFORM  default: the Docker server's native platform (linux/arm64 on Apple
#                    Silicon). This wins over a DOCKER_DEFAULT_PLATFORM in your shell: an
#                    emulated amd64 container would compile the kernel under qemu, slowly.

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER=${DOCKER:-docker}
IMAGE_TAG=${IMAGE_TAG:-pi-gen-demo}

env_check() {
	case "${ROOT}" in
		*" "*)
			echo "debootstrap does not support paths containing spaces: ${ROOT}" >&2
			exit 1
			;;
	esac

	if [ ! -f "${ROOT}/pi-gen/build.sh" ]; then
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
}

# Refuse to start when a container of that name is already running.
env_assert_not_running() {
	if [ -n "$(${DOCKER} ps -q --filter "name=^$1\$")" ]; then
		echo "A build is already running in container $1. Aborting." >&2
		exit 1
	fi
}

# Delete a Docker work volume; refuses host paths (used by CI), which are not ours to delete.
env_remove_volume() {
	case "$1" in
		/*) echo "WORK_VOLUME is a host path; remove it yourself: sudo rm -rf $1" >&2; exit 1 ;;
	esac
	${DOCKER} volume rm -f "$1" >/dev/null
	echo "Removed work volume $1"
}

# Git hash for /etc/rpi-issue: .git is not copied into the container.
env_git_hash() {
	git -C "${ROOT}" rev-parse HEAD 2>/dev/null \
		|| git -C "${ROOT}/pi-gen" rev-parse HEAD 2>/dev/null \
		|| echo unknown
}

env_build_image() {
	echo "==> Building build-environment image ${IMAGE_TAG}"
	${DOCKER} build --platform "${DOCKER_PLATFORM}" -t "${IMAGE_TAG}" "${ROOT}"
}

# env_run <docker run args...> <image> <command...>
# Privileged (pi-gen needs loop devices and chroot), removed on exit, native platform.
env_run() {
	${DOCKER} run --rm --privileged --platform "${DOCKER_PLATFORM}" "$@"
}

# Extra `docker run` options that hand a host ccache directory to the kernel build when
# CCACHE_DIR is set (absolute path). CI persists that directory with actions/cache.
# Unset: the build uses a directory inside the work volume. Output is meant to be
# word-split by the caller.
env_ccache_opts() {
	if [ -n "${CCACHE_DIR:-}" ]; then
		case "${CCACHE_DIR}" in
			/*) mkdir -p "${CCACHE_DIR}"; echo "--volume ${CCACHE_DIR}:/ccache -e CCACHE_DIR=/ccache" ;;
			*) echo "CCACHE_DIR must be an absolute path: ${CCACHE_DIR}" >&2; exit 1 ;;
		esac
	fi
}

# Seconds -> "N min M s"
env_elapsed() {
	echo "$(( $1 / 60 )) min $(( $1 % 60 )) s"
}
