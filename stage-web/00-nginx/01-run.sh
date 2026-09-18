#!/bin/bash -e
# Serve the demo page on port 80: copy the static content (index.html + SVG image)
# into nginx's web root, bake build-time facts into the page, and install a small
# service that publishes live system facts as /sysinfo.json for the page to poll.

WWW_DIR="${ROOTFS_DIR}/var/www/html"
KERNEL_INFO="${ROOTFS_DIR}/etc/demo-kernel"

install -d -m 755 "${WWW_DIR}"
rm -f "${WWW_DIR}/index.nginx-debian.html"
install -m 644 files/www/index.html files/www/pi-demo.svg "${WWW_DIR}/"

# Facts recorded by stage-kernel (KEY="value" lines). Live values come from sysinfo.json.
KERNEL_RELEASE=unknown
KERNEL_BRANCH=unknown
KERNEL_COMMIT=unknown
KERNEL_IMAGE=unknown
if [ -f "${KERNEL_INFO}" ]; then
	# shellcheck disable=SC1090
	. "${KERNEL_INFO}"
fi
sed -i \
	-e "s|@@KERNEL_RELEASE@@|${KERNEL_RELEASE}|g" \
	-e "s|@@KERNEL_BRANCH@@|${KERNEL_BRANCH}|g" \
	-e "s|@@KERNEL_COMMIT@@|${KERNEL_COMMIT:0:12}|g" \
	-e "s|@@KERNEL_IMAGE@@|${KERNEL_IMAGE}|g" \
	-e "s|@@IMG_NAME@@|${IMG_NAME}|g" \
	-e "s|@@IMG_DATE@@|${IMG_DATE}|g" \
	"${WWW_DIR}/index.html"

install -m 644 files/nginx-default "${ROOTFS_DIR}/etc/nginx/sites-available/default"
install -m 755 files/demo-sysinfo "${ROOTFS_DIR}/usr/local/sbin/demo-sysinfo"
install -m 644 files/demo-sysinfo.service "${ROOTFS_DIR}/etc/systemd/system/demo-sysinfo.service"

on_chroot <<EOF
systemctl enable nginx.service
systemctl enable demo-sysinfo.service
EOF
