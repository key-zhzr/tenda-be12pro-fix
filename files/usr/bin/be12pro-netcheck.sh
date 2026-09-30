#!/bin/sh
# Read-only, simultaneous three-port validation. No ifdown/ifup or portal login.
set -u
case "${1:-}" in
	--help) echo "Usage: $0 [duration_seconds, default 60, range 10..300]"; exit 0 ;;
esac
DURATION="${1:-60}"
case "$DURATION" in ''|*[!0-9]*) echo "Duration must be an integer" >&2; exit 1 ;; esac
[ "$DURATION" -ge 10 ] && [ "$DURATION" -le 300 ] || exit 1
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = tenda,be12-pro ] || exit 1
umask 077
DIR="/tmp/be12pro-netcheck-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$DIR" || exit 1
PIDS=""; FINISHED=0
snapshot() {
	local stage="$1" p n wan opt
	{
		date; cat /proc/uptime; uname -a
		ubus call system board
		for p in eth0 lan3 lan4 lan5; do
			echo "===== $p ====="
			ip -s link show dev "$p"
			ip addr show dev "$p"
			for opt in address carrier operstate speed duplex carrier_changes carrier_up_count carrier_down_count; do
				printf '%s=' "$opt"; cat "/sys/class/net/$p/$opt" 2>/dev/null || echo unavailable
			done
			if command -v ethtool >/dev/null 2>&1; then ethtool "$p"; ethtool -S "$p"; fi
		done
		ip -4 route; ip -6 route; ip -4 rule; ip -6 rule
		for n in 1 2 3; do
			wan="wan$n"
			ifstatus "$wan"; ifstatus "${wan}6"
			# Capture only relevant identity/protocol fields, never portal credentials.
			for p in "$wan" "${wan}6"; do
				for opt in device proto metric macaddr ipv6 clientid sendclientid reqaddress reqprefix auto; do
					printf '%s.%s=' "$p" "$opt"; uci -q get "network.$p.$opt" || true
				done
			done
		done
	} > "$DIR/state-$stage.txt" 2>&1
	dmesg | grep -E 'AN8855|an8855|mdio|lan3|lan4|lan5|duplicate address' > "$DIR/dmesg-$stage.txt"
}
finish() {
	[ "$FINISHED" -eq 0 ] || return
	FINISHED=1
	for p in $PIDS; do kill -INT "$p" 2>/dev/null || true; done
	for p in $PIDS; do wait "$p" 2>/dev/null || true; done
	snapshot after
	tar -czf "$DIR.tar.gz" -C /tmp "$(basename "$DIR")"
	sha256sum "$DIR.tar.gz"
	echo "Report: $DIR.tar.gz"
}
trap 'finish' 0
trap 'exit 130' INT TERM HUP
snapshot before
HELPER=/usr/libexec/be12pro-multiwan.sh
[ -f "$HELPER" ] || HELPER="$(dirname "$0")/be12pro-multiwan.sh"
sh "$HELPER" --check > "$DIR/config-check.txt" 2>&1 || true
if command -v tcpdump >/dev/null 2>&1; then
	for p in lan3 lan4 lan5; do
		# At most 200 control packets per port; no application or login traffic.
		tcpdump -p -U -n -i "$p" -s 512 -c 200 -w "$DIR/$p.pcap" \
			'arp or icmp6 or (udp and (port 67 or port 68 or port 546 or port 547))' \
			> "$DIR/tcpdump-$p.txt" 2>&1 &
		PIDS="$PIDS $!"
	done
fi
echo "Observing all ports for $DURATION seconds. Interfaces stay in their current state."
i=0
while [ "$i" -lt "$DURATION" ]; do
	{
		printf '%s' "$(cut -d' ' -f1 /proc/uptime)"
		for p in lan3 lan4 lan5; do
			printf ' %s[MAC=%s carrier=%s state=%s]' "$p" \
				"$(cat /sys/class/net/$p/address 2>/dev/null)" \
				"$(cat /sys/class/net/$p/carrier 2>/dev/null)" \
				"$(cat /sys/class/net/$p/operstate 2>/dev/null)"
		done
		echo
	} >> "$DIR/timeline.txt"
	sleep 1
	i=$((i + 1))
done
for p in lan3 lan4 lan5; do
	{
		echo "===== $p gateway probes ====="
		gw="$(ip -4 route show dev "$p" | awk '$1 == "default" && $2 == "via" {print $3; exit}')"
		[ -z "$gw" ] || ping -I "$p" -c 2 -W 1 "$gw"
		gw="$(ip -6 route show dev "$p" | awk '$1 == "default" && $2 == "via" {print $3; exit}')"
		[ -z "$gw" ] || ping -6 -I "$p" -c 2 -W 1 "$gw"
		ip -4 neigh show dev "$p"; ip -6 neigh show dev "$p"
	} > "$DIR/probes-$p.txt" 2>&1
done
