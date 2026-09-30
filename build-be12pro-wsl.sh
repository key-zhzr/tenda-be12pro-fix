#!/usr/bin/env bash
# Ubuntu/Debian WSL2: pinned ImmortalWrt + persistent three-WAN identities.
set -Eeuo pipefail
case "${1:-}" in
  --help|-h)
    cat <<'EOF'
Usage: bash build-be12pro-wsl.sh
Run as a normal Ubuntu/Debian WSL2 user, in the Linux filesystem.

Environment overrides:
  WORKROOT=$HOME/be12pro-multiwan-wsl  Dedicated build directory
  JOBS=4                            Parallel jobs (automatic RAM-aware default)
  PATCHSET=multiwan                  Quiet fix; multiwan-mdio-debug for traces
  SOURCE_REF=45474b1733debddfde8ce98ff2529b24cf9756ea
  CONTROL_REF=fix/multiwan-identity   PR branch; override with main after merge
  SKIP_DEPS=1                       Skip apt dependency installation
  PREPARE_ONLY=1                    Configure and verify, without firmware build
  CLEAN=1                           Rebuild toolchain with make dirclean
  RESET_SOURCE=1                    Discard tracked changes in the dedicated source
  EXTRA_PACKAGES='luci-app-ttyd ttyd' Additional required packages

Downloads, toolchain and ccache are reused on repeat runs. Changing a patch
variant/ref in a dirty tree requires RESET_SOURCE=1 or a new WORKROOT.
EOF
    exit 0 ;;
  '') ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
[[ $(uname -s) == Linux ]] || die 'Compile inside Ubuntu/Debian WSL2.'
[[ $(id -u) != 0 ]] || die 'Use your normal WSL user; sudo is used only for apt.'
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fi
SOURCE_REPO=${SOURCE_REPO:-https://github.com/immortalwrt/immortalwrt.git}
SOURCE_REF=${SOURCE_REF:-45474b1733debddfde8ce98ff2529b24cf9756ea}
CONTROL_REPO=${CONTROL_REPO:-https://github.com/key-zhzr/tenda-be12pro-fix.git}
CONTROL_REF=${CONTROL_REF:-fix/multiwan-identity}
PATCHSET=${PATCHSET:-multiwan}
WORKROOT=${WORKROOT:-$HOME/be12pro-multiwan-wsl}
case "$WORKROOT" in *[[:space:]]*) die 'WORKROOT must not contain spaces.' ;; esac
mkdir -p "$WORKROOT"
WORKROOT=$(cd "$WORKROOT" && pwd -P)
case "$WORKROOT" in /mnt/*) die 'Build in the WSL Linux filesystem, outside /mnt/.' ;; esac
SRC="$WORKROOT/source"; CONTROL="$WORKROOT/control"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$WORKROOT/logs"
LOGFILE="$WORKROOT/logs/build-$STAMP.log"
exec > >(tee -a "$LOGFILE") 2>&1
trap 'rc=$?; printf "Build failed (%s). Log: %s\n" "$rc" "$LOGFILE" >&2; exit "$rc"' ERR
if [[ ${SKIP_DEPS:-0} != 1 ]]; then
  command -v apt-get >/dev/null || die 'This script requires Ubuntu/Debian apt-get.'
  deps=(build-essential clang flex bison gawk gettext git libncurses-dev
    libssl-dev python3 python3-pyelftools python3-setuptools rsync swig unzip
    zlib1g-dev file wget curl ccache libelf-dev time patch perl ca-certificates
    zstd bzip2 xz-utils gperf help2man pkgconf cmake autoconf automake libtool
    autopoint device-tree-compiler python3-ply python3-docutils
    libgmp-dev libmpc-dev libmpfr-dev)
  if [[ $(uname -m) == x86_64 ]]; then deps+=(gcc-multilib g++-multilib); fi
  sudo apt-get update
  sudo apt-get install -y "${deps[@]}"
fi
for tool in git python3 make ccache; do command -v "$tool" >/dev/null || die "Missing dependency: $tool"; done
if [[ -z ${JOBS:-} ]]; then
  cpus=$(nproc)
  available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  ram_jobs=$((available_kb / 1500000))
  ((ram_jobs > 0)) || ram_jobs=1
  JOBS=$((cpus < ram_jobs ? cpus : ram_jobs))
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer.'
free_kb=$(df -Pk "$WORKROOT" | awk 'END {print $4}')
if [[ ! -d "$SRC/build_dir" ]] && ((free_kb < 25 * 1024 * 1024)); then
  die 'A first build needs at least 25 GiB of free disk space (40+ GiB recommended).'
fi
checkout_ref() {
  local dir="$1" url="$2" ref="$3" desired cloned=0
  if [[ ! -d "$dir/.git" ]]; then
    git clone --depth=1 --filter=blob:none --no-checkout "$url" "$dir"
    cloned=1
  fi
  [[ $(git -C "$dir" remote get-url origin) == "$url" ]] || die "Unexpected origin in $dir"
  git -C "$dir" fetch --no-tags --depth=1 origin "$ref"
  desired=$(git -C "$dir" rev-parse FETCH_HEAD)
  if [[ "$cloned" == 1 ]]; then
    git -C "$dir" checkout --detach "$desired"
    return
  fi
  if [[ ${RESET_SOURCE:-0} == 1 && "$dir" == "$SRC" ]]; then
    git -C "$dir" reset --hard HEAD
    # Only generated payload paths; no blanket git clean in the user's build tree.
    rm -f "$dir/target/linux/mediatek/filogic/base-files/usr/libexec/be12pro-multiwan.sh" \
      "$dir/target/linux/mediatek/filogic/base-files/usr/bin/be12pro-netcheck.sh" \
      "$dir/target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-be12pro-multiwan"
  fi
  if [[ $(git -C "$dir" rev-parse HEAD) != "$desired" ]]; then
    [[ -z $(git -C "$dir" status --porcelain --untracked-files=no) ]] || die "Tracked changes in $dir; use a new WORKROOT or RESET_SOURCE=1."
    git -C "$dir" checkout --detach "$desired"
  elif [[ -z $(git -C "$dir" ls-files | head -n 1) ]]; then
    git -C "$dir" checkout --detach "$desired"
  fi
}
log "Preparing source and control repositories; jobs=$JOBS"
checkout_ref "$SRC" "$SOURCE_REPO" "$SOURCE_REF"
checkout_ref "$CONTROL" "$CONTROL_REPO" "$CONTROL_REF"
SOURCE_SHA=$(git -C "$SRC" rev-parse HEAD)
CONTROL_SHA=$(git -C "$CONTROL" rev-parse HEAD)
if [[ -f "$WORKROOT/last-variant" && $(cat "$WORKROOT/last-variant") != "$PATCHSET" ]]; then
  [[ ${RESET_SOURCE:-0} == 1 ]] || die 'Patch variant changed; rerun with RESET_SOURCE=1.'
fi
bash "$CONTROL/scripts/prepare-source.sh" "$SRC" "$PATCHSET"
cd "$SRC"
if [[ ${CLEAN:-0} == 1 ]]; then make dirclean; fi
export CCACHE_DIR=${CCACHE_DIR:-$WORKROOT/ccache}
export CCACHE_COMPRESS=true CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-6G}
mkdir -p "$CCACHE_DIR"
ccache -M "$CCACHE_MAXSIZE"
./scripts/feeds update -a
./scripts/feeds install -a
bash "$CONTROL/scripts/configure-build.sh" "$SRC"
PREPARE_HASH=$(
  { git diff --binary; cat "$CONTROL/files/usr/libexec/be12pro-multiwan.sh" \
      "$CONTROL/files/usr/bin/be12pro-netcheck.sh" "$CONTROL/files/etc/uci-defaults/99-be12pro-multiwan"; \
    printf '%s\n' "$SOURCE_SHA" "$PATCHSET"; } | sha256sum | cut -d' ' -f1
)
if [[ -f "$WORKROOT/last-prepare-hash" && $(cat "$WORKROOT/last-prepare-hash") != "$PREPARE_HASH" ]]; then
  log 'Target source changed: cleaning kernel/rootfs while retaining the toolchain.'
  make target/linux/clean
fi
printf '%s\n' "$PREPARE_HASH" > "$WORKROOT/last-prepare-hash"
printf '%s\n' "$PATCHSET" > "$WORKROOT/last-variant"
if [[ ${PREPARE_ONLY:-0} == 1 ]]; then
  log "Prepared: $SRC (source=$SOURCE_SHA control=$CONTROL_SHA)"
  exit 0
fi
log 'Downloading build sources'
make download -j"$JOBS"
log 'Building BE12 Pro images'
if ! make -j"$JOBS"; then
  log 'Retrying serially with V=s to report the first actionable build error.'
  make -j1 V=s
fi
OUT="$SRC/bin/targets/mediatek/filogic"
DEST="$WORKROOT/output-$STAMP"
mkdir -p "$DEST"
find "$OUT" -maxdepth 1 -type f \
  \( -name '*tenda_be12-pro*' -o -name 'profiles.json' \) -exec cp -v {} "$DEST/" \;
find "$DEST" -maxdepth 1 -name '*initramfs*' | grep -q . || die 'Initramfs image missing.'
find "$DEST" -maxdepth 1 -name '*sysupgrade*' | grep -q . || die 'Sysupgrade image missing.'
./scripts/diffconfig.sh > "$DEST/build.diffconfig"
cp .config "$DEST/build.config"
cp "$LOGFILE" "$DEST/build.log"
{
  printf 'source_repo=%s\nsource_ref=%s\nsource_sha=%s\n' "$SOURCE_REPO" "$SOURCE_REF" "$SOURCE_SHA"
  printf 'control_repo=%s\ncontrol_ref=%s\ncontrol_sha=%s\n' "$CONTROL_REPO" "$CONTROL_REF" "$CONTROL_SHA"
  printf 'patchset=%s\nprepare_hash=%s\njobs=%s\n' "$PATCHSET" "$PREPARE_HASH" "$JOBS"
  for feed in feeds/*; do
    [[ -d "$feed/.git" ]] || continue
    printf 'feed_%s=%s\n' "${feed##*/}" "$(git -C "$feed" rev-parse HEAD)"
  done
  printf '\nFresh multiwan defaults: eth1/eth2 unconfigured; lan3/4/5 are dual-stack WANs.\n'
  printf 'A reset/-n image has no wired management LAN; retain your existing LAN/Wi-Fi configuration.\n'
} > "$DEST/BUILD_INFO.txt"
(cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
ccache --show-stats || true
log "Build complete: $DEST"
log "Log: $LOGFILE"
