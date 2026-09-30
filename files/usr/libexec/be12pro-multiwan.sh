#!/bin/sh
# Persistent identities for three independent BE12 Pro WAN clients.
# Run --apply, then reload network from an existing management connection.
set -eu

PORT_NUMBERS="3 4 5"
APPLY_PENDING=0
die() { echo "be12pro-multiwan: $*" >&2; exit 1; }
board_name() { cat /tmp/sysinfo/board_name; }
sys_mac() { cat "/sys/class/net/$1/address" 2>/dev/null || true; }
canonical_mac() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
valid_mac() {
	printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || return 1
	[ "$1" != 00:00:00:00:00:00 ] || return 1
	[ $((0x${1%%:*} & 1)) -eq 0 ]
}
contains() {
	local needle="$1" item
	shift
	for item in "$@"; do [ "$item" != "$needle" ] || return 0; done
	return 1
}
device_section() {
	local port="$1" sections count=0 section result=""
	sections="$(uci -q show network | sed -n "s/^network\.\(.*\)\.name='$port'$/\1/p")"
	for section in $sections; do
		[ "$(uci -q get "network.$section" || true)" = device ] || continue
		count=$((count + 1)); result="$section"
	done
	[ "$count" -le 1 ] || die "multiple device sections define $port; consolidate them first"
	printf '%s\n' "$result"
}
candidate_mac() {
	local port="$1" wan="$2" section mac=""
	section="$(device_section "$port")"
	[ -z "$section" ] || mac="$(uci -q get "network.$section.macaddr" || true)"
	# Legacy interface-level overrides take precedence in netifd.
	local override="$(uci -q get "network.$wan.macaddr" || true)"
	[ -z "$override" ] || mac="$override"
	[ -n "$mac" ] || mac="$(sys_mac "$port")"
	canonical_mac "$mac"
}
derived_mac() {
	local base="$1" offset="$2" rest first second third nic
	first="${base%%:*}"; rest="${base#*:}"
	second="${rest%%:*}"; rest="${rest#*:}"
	third="${rest%%:*}"; rest="${rest#*:}"
	nic="$(printf '%s' "$rest" | tr -d ':')"
	nic=$(((0x$nic + offset) & 0xffffff))
	printf '%02x:%s:%s:%02x:%02x:%02x\n' \
		$(((0x$first | 2) & 254)) "$second" "$third" \
		$(((nic >> 16) & 255)) $(((nic >> 8) & 255)) $((nic & 255))
}
preflight() {
	local n wan port current line
	[ "$(board_name)" = tenda,be12-pro ] || die "this script is only for tenda,be12-pro"
	# Do not repurpose an unrelated interface or detach a management bridge.
	for n in $PORT_NUMBERS; do
		wan="wan$((n - 2))"; port="lan$n"
		current="$(uci -q get "network.$wan.device" || true)"
		[ -z "$current" ] || [ "$current" = "$port" ] || die "$wan uses $current, expected $port"
		current="$(uci -q get "network.${wan}6.device" || true)"
		case "$current" in ""|"$port"|"@$wan") ;; *) die "${wan}6 uses $current, expected $port" ;; esac
		device_section "$port" >/dev/null
		current="$(device_section "$port")"
		if [ -z "$current" ]; then
			[ -z "$(uci -q get "network.be12pro_$port" || true)" ] || die "be12pro_$port already exists with another device name"
		fi
		if uci -q show network | grep -E '\.ports=' | grep -Eq "(^|[ '])$port([ :']|$)"; then
			die "$port is still a bridge port; move it out of the bridge before applying"
		fi
	done
}
choose_macs() {
	local base reserved="" candidates chosen="" n mac count other offset
	base="$(canonical_mac "$(sys_mac eth0)")"
	valid_mac "$base" || die "eth0 has no valid base MAC"
	for other in eth0 eth1 eth2; do
		mac="$(canonical_mac "$(sys_mac "$other")")"
		[ -z "$mac" ] || reserved="$reserved $mac"
	done
	c3="$(candidate_mac lan3 wan1)"
	c4="$(candidate_mac lan4 wan2)"
	c5="$(candidate_mac lan5 wan3)"
	candidates="$c3 $c4 $c5"
	for n in $PORT_NUMBERS; do
		case "$n" in 3) mac="$c3" ;; 4) mac="$c4" ;; 5) mac="$c5" ;; esac
		count=0
		for other in $candidates; do [ "$other" != "$mac" ] || count=$((count + 1)); done
		if ! valid_mac "$mac" || [ "$count" -ne 1 ] || contains "$mac" $reserved $chosen; then
			offset="$n"
			while :; do
				mac="$(derived_mac "$base" "$offset")"
				if ! contains "$mac" $reserved $chosen $candidates; then break; fi
				offset=$((offset + 1))
				[ "$offset" -lt 1024 ] || die "could not allocate a unique MAC"
			done
		fi
		chosen="$chosen $mac"
		case "$n" in 3) m3="$mac" ;; 4) m4="$mac" ;; 5) m5="$mac" ;; esac
	done
}
backup_configs() {
	BACKUP="/etc/be12pro-backups/$(date +%Y%m%d-%H%M%S)-$$"
	mkdir -p "$BACKUP"
	cp /etc/config/network "$BACKUP/network"
	cp /etc/config/firewall "$BACKUP/firewall"
}
restore_configs() {
	cp "$BACKUP/network" /etc/config/network
	cp "$BACKUP/firewall" /etc/config/firewall
	uci -q revert network || true
	uci -q revert firewall || true
}
on_exit() {
	local rc="$1"
	if [ "$rc" -ne 0 ] && [ "$APPLY_PENDING" -eq 1 ]; then
		restore_configs
		echo "Configuration update failed; restored backup $BACKUP" >&2
	fi
}
apply_config() {
	local n port wan metric section mac hex zone networks unique="" item
	preflight
	choose_macs
	zone="$(uci -q show firewall | sed -n "s/^firewall\.\(.*\)\.name='wan'$/\1/p" | head -n 1)"
	[ -n "$zone" ] || die "firewall has no WAN zone"
	umask 077
	backup_configs
	APPLY_PENDING=1
	# Backups are complete before staging any UCI changes. No services restart here.
	for n in $PORT_NUMBERS; do
		port="lan$n"; wan="wan$((n - 2))"; metric="$(((n - 2) * 10))"
		case "$n" in 3) mac="$m3" ;; 4) mac="$m4" ;; 5) mac="$m5" ;; esac
		hex="$(printf '%s' "$mac" | tr -d ':')"
		section="$(device_section "$port")"
		if [ -z "$section" ]; then
			section="be12pro_$port"
			[ -z "$(uci -q get "network.$section" || true)" ] || die "$section already exists with another device name"
			uci -q set "network.$section=device"
		fi
		uci -q batch <<-EOF
			set network.$section.name='$port'
			set network.$section.macaddr='$mac'
			set network.$wan='interface'
			set network.$wan.device='$port'
			set network.$wan.proto='dhcp'
			set network.$wan.metric='$metric'
			set network.$wan.ipv6='0'
			set network.$wan.clientid='01$hex'
			set network.$wan.auto='1'
			set network.${wan}6='interface'
			set network.${wan}6.device='$port'
			set network.${wan}6.proto='dhcpv6'
			set network.${wan}6.metric='$metric'
			set network.${wan}6.reqaddress='try'
			set network.${wan}6.reqprefix='no'
			set network.${wan}6.delegate='0'
			set network.${wan}6.sendclientid='auto'
			set network.${wan}6.clientid='00030001$hex'
			set network.${wan}6.auto='1'
		EOF
		# A stale legacy override would otherwise undo the device MAC change.
		uci -q delete "network.$wan.macaddr" || true
		uci -q delete "network.${wan}6.macaddr" || true
		printf '%s -> %s/%s6, MAC=%s, metric=%s\n' "$port" "$wan" "$wan" "$mac" "$metric"
	done
	# Deduplicate the old WAN zone list, retaining unrelated working interfaces.
	networks="$(uci -q get "firewall.$zone.network" || true) wan1 wan16 wan2 wan26 wan3 wan36"
	for item in $networks; do
		case "$item" in
			wan|wan6) [ -n "$(uci -q get "network.$item" || true)" ] || continue ;;
		esac
		contains "$item" $unique || unique="$unique $item"
	done
	uci -q delete "firewall.$zone.network" || true
	for item in $unique; do uci -q add_list "firewall.$zone.network=$item"; done
	uci -q commit network
	uci -q commit firewall
	APPLY_PENDING=0
	echo "Saved. Backup: $BACKUP"
	echo "Apply to running devices with: /etc/init.d/network reload; /etc/init.d/firewall reload"
}
check_config() {
	local n port wan section expected actual seen="" errors=0
	preflight
	for n in $PORT_NUMBERS; do
		port="lan$n"; wan="wan$((n - 2))"; section="$(device_section "$port")"
		expected="$(canonical_mac "$(uci -q get "network.$section.macaddr" || true)")"
		actual="$(canonical_mac "$(sys_mac "$port")")"
		printf '%s: configured=%s active=%s IPv4=%s IPv6=%s\n' "$port" "$expected" "$actual" \
			"$(uci -q get "network.$wan.proto" || true)" "$(uci -q get "network.${wan}6.proto" || true)"
		if ! valid_mac "$expected" || contains "$expected" $seen || [ "$expected" != "$actual" ] ||
			[ "$(uci -q get "network.$wan.proto" || true)" != dhcp ] ||
			[ "$(uci -q get "network.${wan}6.proto" || true)" != dhcpv6 ] ||
			[ "$(uci -q get "network.${wan}6.clientid" || true)" != "00030001$(printf '%s' "$expected" | tr -d ':')" ]; then
			errors=$((errors + 1))
		fi
		seen="$seen $expected"
	done
	[ "$errors" -eq 0 ] || die "configuration or active MAC mismatch; apply/reload before testing"
}
main() {
	case "${1:---help}" in
		--apply)
			[ "$(id -u)" -eq 0 ] || die "run --apply as root"
			trap 'on_exit "$?"' 0
			apply_config
			;;
		--check) check_config ;;
		--help) echo "Usage: $0 --apply | --check" ;;
		*) die "unknown argument: $1" ;;
	esac
}
# Allows the host-side regression harness to replace hardware/backup functions.
[ "${BE12PRO_LIBRARY_ONLY:-0}" = 1 ] || main "$@"
