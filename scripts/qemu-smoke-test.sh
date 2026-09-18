#!/usr/bin/env bash
# Boot an image headless in QEMU and check that nginx answers on the expected kernel.
#
#   scripts/qemu-smoke-test.sh <image.img | image.img.xz | image.zip> [expected uname -r]
#
# Uses run-qemu.sh in HEADLESS mode (same machine, kernel and port forwards), polls
# http://localhost:8080/sysinfo.json, and fails if the guest does not answer within
# TIMEOUT seconds or reports a different kernel_release. Used by the workflows; works
# locally too. KERNEL selects the kernel Image (default deploy/kernel8-demo.img).
set -eu

IMAGE=${1:?usage: $0 <image> [expected-kernel-release]}
EXPECTED=${2:-}
TIMEOUT=${TIMEOUT:-600}
PORT=${PORT:-8080}

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LOG=$(mktemp -t qemu-smoke.XXXXXX)
PIDFILE="${LOG}.pid"
trap 'if [ -f "${PIDFILE}" ]; then kill "$(cat "${PIDFILE}")" 2>/dev/null || true; fi; rm -f "${LOG}" "${PIDFILE}"' EXIT

# Decompress by streaming into a new file: `xz -dk` would try to copy owner and group
# from the archive, which fails (exit 2) when deploy/ files were written by the build
# container as root and this runs as another user, as on a CI runner.
case "${IMAGE}" in
	*.xz) xz -dc "${IMAGE}" > "${IMAGE%.xz}"; IMAGE=${IMAGE%.xz} ;;
	*.gz) gzip -dc "${IMAGE}" > "${IMAGE%.gz}"; IMAGE=${IMAGE%.gz} ;;
	*.zip) unzip -o -q "${IMAGE}" '*.img' -d "$(dirname "${IMAGE}")"; IMAGE=$(ls -t "$(dirname "${IMAGE}")"/*.img | head -n1) ;;
esac

echo "==> booting ${IMAGE} headless (timeout ${TIMEOUT}s)"
HEADLESS=1 SERIAL_LOG="${LOG}" PIDFILE="${PIDFILE}" "${DIR}/run-qemu.sh" "${IMAGE}" &
QEMU_WRAPPER=$!

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
	if json=$(curl -sf -m 3 "http://localhost:${PORT}/sysinfo.json" 2>/dev/null); then
		break
	fi
	if ! kill -0 "${QEMU_WRAPPER}" 2>/dev/null; then
		echo "ERROR: QEMU exited before the guest answered" >&2
		tail -n 40 "${LOG}" >&2
		exit 1
	fi
	if [ "$(date +%s)" -ge "${deadline}" ]; then
		echo "ERROR: no HTTP answer from the guest after ${TIMEOUT}s" >&2
		tail -n 60 "${LOG}" >&2
		exit 1
	fi
	sleep 3
done

release=$(printf '%s' "${json}" | sed -n 's/.*"kernel_release": *"\([^"]*\)".*/\1/p')
echo "==> guest answered: kernel_release=${release}"
curl -sf -m 5 -o /dev/null "http://localhost:${PORT}/" || { echo "ERROR: index.html not served" >&2; exit 1; }
curl -sf -m 5 -o /dev/null "http://localhost:${PORT}/pi-demo.svg" || { echo "ERROR: pi-demo.svg not served" >&2; exit 1; }

if [ -n "${EXPECTED}" ] && [ "${release}" != "${EXPECTED}" ]; then
	echo "ERROR: expected kernel ${EXPECTED}, guest runs ${release}" >&2
	exit 1
fi
echo "==> smoke test passed"
