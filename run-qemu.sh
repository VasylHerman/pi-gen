#!/usr/bin/env bash
# Boot a built image under QEMU (no Raspberry Pi needed).
#
#   ./run-qemu.sh                 newest deploy/*.img (extracts deploy/*.zip or *.img.xz if needed)
#   ./run-qemu.sh path/to.img     a specific image
#
# Uses the `virt` machine with the custom kernel from deploy/kernel8-demo.img: the
# Kconfig fragment adds virtio disk/NIC, which is what makes this possible (the stock
# Pi kernel cannot boot here). QEMU's own raspi4b model boots the kernel too, but has
# no Ethernet/USB emulation, so the web server would be unreachable.
#
# Ports:  http://localhost:8080  ->  nginx      ssh -p 2222 pi@localhost  (raspberry)
# Console is on this terminal; quit with Ctrl-a x.
#
# Environment:
#   SNAPSHOT=0    write changes back to the .img (default: discard, image stays pristine)
#   MEM=2G SMP=4  guest size
#   KERNEL=...    kernel Image (default deploy/kernel8-demo.img)
#   HEADLESS=1    no console on this terminal: serial goes to SERIAL_LOG (default
#                 deploy/qemu-serial.log), the PID to PIDFILE; used by scripts/qemu-smoke-test.sh
#   ACCEL=...     override the accelerator choice, e.g. "-accel tcg -cpu cortex-a72"
set -eu

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
DEPLOY="${DIR}/deploy"
KERNEL=${KERNEL:-${DEPLOY}/kernel8-demo.img}
MEM=${MEM:-2G}
SMP=${SMP:-4}
SNAPSHOT=${SNAPSHOT:-1}

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
	echo "qemu-system-aarch64 not found (macOS: brew install qemu)" >&2
	exit 1
fi

newest() {
	ls -t "$@" 2>/dev/null | head -n1 || true
}

IMG=${1:-}
if [ -z "${IMG}" ]; then
	IMG=$(newest "${DEPLOY}"/*.img)
fi
if [ -z "${IMG}" ]; then
	ARCHIVE=$(newest "${DEPLOY}"/*.zip "${DEPLOY}"/*.img.xz "${DEPLOY}"/*.img.gz)
	if [ -z "${ARCHIVE}" ]; then
		echo "No image in ${DEPLOY}. Run ./build-dev.sh or ./build-release.sh first." >&2
		exit 1
	fi
	echo "==> Extracting ${ARCHIVE}"
	case "${ARCHIVE}" in
		*.zip) unzip -o -q "${ARCHIVE}" '*.img' -d "${DEPLOY}" ;;
		*.xz) xz -dk "${ARCHIVE}" ;;
		*.gz) gunzip -k "${ARCHIVE}" ;;
	esac
	IMG=$(newest "${DEPLOY}"/*.img)
fi
if [ ! -f "${KERNEL}" ]; then
	echo "Kernel ${KERNEL} not found; stage-kernel copies it into deploy/ during a build" >&2
	exit 1
fi

# Hardware acceleration when the host CPU matches the guest (Apple Silicon: HVF,
# Linux arm64 with /dev/kvm: KVM), otherwise TCG emulation.
if [ -z "${ACCEL:-}" ]; then
	ACCEL="-accel tcg -cpu cortex-a72"
	case "$(uname -s)-$(uname -m)" in
		Darwin-arm64) ACCEL="-accel hvf -cpu host" ;;
		Linux-aarch64) [ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host" ;;
	esac
fi

EXTRA=""
[ "${SNAPSHOT}" = "1" ] && EXTRA="-snapshot"
if [ "${HEADLESS:-0}" = "1" ]; then
	SERIAL_LOG=${SERIAL_LOG:-${DEPLOY}/qemu-serial.log}
	PIDFILE=${PIDFILE:-${DEPLOY}/qemu.pid}
	EXTRA="${EXTRA} -display none -monitor none -serial file:${SERIAL_LOG} -pidfile ${PIDFILE}"
	echo "==> Booting ${IMG} headless with ${KERNEL} (${ACCEL#-accel }); serial: ${SERIAL_LOG}, pid: ${PIDFILE}"
else
	EXTRA="${EXTRA} -nographic"
	echo "==> Booting ${IMG} with ${KERNEL} (${ACCEL#-accel }; snapshot=${SNAPSHOT})"
	echo "    http://localhost:8080   ssh -p 2222 pi@localhost   quit: Ctrl-a x"
fi
# shellcheck disable=SC2086
exec qemu-system-aarch64 \
	-M virt -m "${MEM}" -smp "${SMP}" ${ACCEL} \
	-kernel "${KERNEL}" \
	-append "console=ttyAMA0,115200 root=/dev/vda2 rootfstype=ext4 rootwait rw fsck.repair=yes" \
	-drive "if=none,file=${IMG},format=raw,id=hd0" \
	-device virtio-blk-pci,drive=hd0 \
	-netdev user,id=net0,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
	-device virtio-net-pci,netdev=net0 \
	-device virtio-rng-pci \
	${EXTRA}
