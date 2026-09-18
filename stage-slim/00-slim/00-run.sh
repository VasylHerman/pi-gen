#!/bin/bash -e
# Release only: strip the Raspberry Pi OS Lite base down to what a Wi-Fi/Bluetooth-
# capable nginx server needs. A no-op unless RELEASE_SLIM=1 (config/release.conf), so
# the dev and release variants share the same STAGE_LIST and this stage carries
# EXPORT_IMAGE for both.
#
# What goes: compilers, stock kernels and headers, GPIO/camera/media tooling, Wi-Fi
# firmware for other vendors, docs, man pages, non-English locales, the kernels and
# initramfs files those packages left in /boot/firmware. What stays is listed in
# files/keep-packages and verified at the end.
#
# Not touched: /var/lib/apt/lists. export-image/02-set-sources runs `apt-get update`
# and `dist-upgrade` in the image after this stage, so deleting the lists here would
# only be undone; 99-slim at least drops the translation files.

if [ "${RELEASE_SLIM:-0}" != "1" ]; then
	log "RELEASE_SLIM is not 1: keeping the full image (dev variant)"
	exit 0
fi

read_list() {
	sed -f "${SCRIPT_DIR}/remove-comments.sed" < "$1"
}
KEEP=$(read_list files/keep-packages)
PURGE=$(read_list files/purge-packages)

rootfs_size() {
	du -sxm "${ROOTFS_DIR}" | cut -f1
}
BEFORE=$(rootfs_size)

# ---- dpkg / apt policy for everything installed from now on ---------------------
install -d -m 755 "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d" "${ROOTFS_DIR}/etc/apt/apt.conf.d"
install -m 644 files/01-nodoc "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d/01-nodoc"
install -m 644 files/99-slim "${ROOTFS_DIR}/etc/apt/apt.conf.d/99-slim"

# ---- purge --------------------------------------------------------------------------
# Only installed packages can be marked or purged; expand the lists inside the chroot.
on_chroot <<EOF
set -e
installed() {
	dpkg-query -W -f '\${Package} \${db:Status-Abbrev}\n' "\$@" 2>/dev/null | awk '\$2 ~ /^i/ {print \$1}'
}
KEEP_INSTALLED=\$(installed ${KEEP})
PURGE_INSTALLED=\$(installed ${PURGE})
apt-mark manual \${KEEP_INSTALLED} >/dev/null
echo "Purging: \${PURGE_INSTALLED}" | tr '\n' ' '; echo
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold purge --auto-remove \${PURGE_INSTALLED}
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
apt-get clean

# Verify nothing we rely on was taken by --auto-remove.
MISSING=""
for pkg in ${KEEP}; do
	dpkg-query -W -f '\${db:Status-Abbrev}' "\$pkg" 2>/dev/null | grep -q '^i' || MISSING="\$MISSING \$pkg"
done
if [ -n "\$MISSING" ]; then
	echo "ERROR: keep-packages missing after purge:\$MISSING" >&2
	exit 1
fi
EOF

# ---- files no package owns any more, or that only the removed kernels used --------
# Docs/man/locales already installed (01-nodoc only affects future installs).
find "${ROOTFS_DIR}/usr/share/doc" -type f ! -name copyright -delete
find "${ROOTFS_DIR}/usr/share/doc" -type d -empty -delete
rm -rf "${ROOTFS_DIR}/usr/share/man/"* "${ROOTFS_DIR}/usr/share/info/"*
find "${ROOTFS_DIR}/usr/share/locale" -mindepth 1 -maxdepth 1 -type d ! -name 'en*' -exec rm -rf {} +

# Modules of any kernel other than the custom one.
CUSTOM_KREL=$(sed -n 's/^KERNEL_RELEASE="\(.*\)"$/\1/p' "${ROOTFS_DIR}/etc/demo-kernel")
[ -n "${CUSTOM_KREL}" ] || { echo "ERROR: /etc/demo-kernel has no KERNEL_RELEASE" >&2; exit 1; }
find "${ROOTFS_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d ! -name "${CUSTOM_KREL}" -exec rm -rf {} +

# Boot partition: stock kernels/initramfs (the raspi-firmware hooks remove kernel8.img
# on purge but leave others), Pi 5 kernel, device trees for other boards, and the
# start*.elf/fixup*.dat/bootcode.bin variants used only by Pi 1-3. Pi 4 boots with
# start4*.elf + fixup4*.dat + bcm2711-*.dtb. A later `apt upgrade` of raspi-firmware
# restores the blobs; harmless.
FW="${ROOTFS_DIR}/boot/firmware"
rm -f "${FW}"/kernel8.img "${FW}"/kernel7*.img "${FW}"/kernel.img "${FW}"/kernel_2712.img \
	"${FW}"/initramfs* "${FW}"/bootcode.bin \
	"${FW}"/start.elf "${FW}"/start_*.elf "${FW}"/fixup.dat "${FW}"/fixup_*.dat \
	"${FW}"/bcm2708*.dtb "${FW}"/bcm2709*.dtb "${FW}"/bcm2710*.dtb "${FW}"/bcm2712*.dtb
CUSTOM_IMG=$(sed -n 's/^kernel=\(.*\)$/\1/p' "${FW}/config.txt" | tail -n1)
if [ -z "${CUSTOM_IMG}" ] || [ ! -f "${FW}/${CUSTOM_IMG}" ]; then
	echo "ERROR: config.txt does not select an existing kernel (kernel=${CUSTOM_IMG:-unset})" >&2
	exit 1
fi

AFTER=$(rootfs_size)
PKGS=$(dpkg-query --admindir="${ROOTFS_DIR}/var/lib/dpkg" -W | wc -l)
log "stage-slim: rootfs ${BEFORE} MB -> ${AFTER} MB, ${PKGS} packages, kernel ${CUSTOM_KREL} (${CUSTOM_IMG})"
