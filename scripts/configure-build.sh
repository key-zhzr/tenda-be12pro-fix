#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE=${1:?Usage: configure-build.sh SOURCE}
cd "$SOURCE"
CORE_PACKAGES=(luci luci-ssl luci-app-firewall luci-proto-ipv6 odhcp6c
  luci-app-sqm sqm-scripts kmod-sched-cake kmod-ifb tc-full
  mwan3 luci-app-mwan3 curl ca-bundle ethtool tcpdump ip-full ip-bridge)
OPTIONAL_PACKAGES=(smartdns luci-app-smartdns bash jq bind-dig htop nano openssh-sftp-server
  luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-sqm-zh-cn
  luci-i18n-mwan3-zh-cn luci-i18n-smartdns-zh-cn)
cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_tenda_be12-pro=y
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_IPV6=y
CONFIG_CCACHE=y
EOF
for pkg in "${CORE_PACKAGES[@]}" "${OPTIONAL_PACKAGES[@]}"; do
  printf 'CONFIG_PACKAGE_%s=y\n' "$pkg" >> .config
done
set -f
for pkg in ${EXTRA_PACKAGES:-}; do
  [[ "$pkg" =~ ^[A-Za-z0-9_+.-]+$ ]] || { echo "Invalid package: $pkg" >&2; exit 1; }
  printf 'CONFIG_PACKAGE_%s=y\n' "$pkg" >> .config
done
make defconfig
for key in TARGET_mediatek_filogic_DEVICE_tenda_be12-pro TARGET_ROOTFS_INITRAMFS IPV6; do
  grep -Fqx "CONFIG_$key=y" .config || { echo "Missing target option: $key" >&2; exit 1; }
done
for pkg in "${CORE_PACKAGES[@]}" ${EXTRA_PACKAGES:-}; do
  grep -Fqx "CONFIG_PACKAGE_$pkg=y" .config || { echo "Required package unavailable: $pkg" >&2; exit 1; }
done
for pkg in "${OPTIONAL_PACKAGES[@]}"; do
  grep -Fqx "CONFIG_PACKAGE_$pkg=y" .config || printf 'Optional package unavailable: %s\n' "$pkg"
done
./scripts/diffconfig.sh
