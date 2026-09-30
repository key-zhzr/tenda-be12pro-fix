#!/usr/bin/env bash
set -Eeuo pipefail
CONTROL=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${1:?Usage: prepare-source.sh SOURCE [VARIANT]}
VARIANT=${2:-multiwan}
cd "$SOURCE"
apply_one() {
  local patch="$CONTROL/patches/$1"
  if git apply --reverse --check "$patch" 2>/dev/null; then
    printf 'Already applied: %s\n' "$1"
  else
    git apply --check "$patch"
    git apply "$patch"
  fi
}
case "$VARIANT" in
  multiwan|multiwan-mdio-debug|vendorfix|vendorfix-noeee|vendorfix-mdio-debug) ;;
  *) echo "Unknown variant: $VARIANT" >&2; exit 1 ;;
esac
apply_one 0001-an8855-vendor-fixes-rft.patch
case "$VARIANT" in
  vendorfix-noeee) apply_one 0002-an8855-disable-eee-rft.patch ;;
  *mdio-debug) apply_one 0003-an8855-mdio-phy-debug-rft.patch ;;
esac
case "$VARIANT" in
  multiwan*)
    apply_one 0004-be12pro-multiwan-defaults.patch
    for file in usr/libexec/be12pro-multiwan.sh usr/bin/be12pro-netcheck.sh etc/uci-defaults/99-be12pro-multiwan; do
      destination="target/linux/mediatek/filogic/base-files/$file"
      mkdir -p "$(dirname "$destination")"
      install -m 0755 "$CONTROL/files/$file" "$destination"
    done
    ;;
esac
git diff --check
git diff --stat
