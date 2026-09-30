#!/usr/bin/env python3
"""Check persistent identities, migration, failure handling and real config_generate behavior."""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("IMMORTALWRT_SOURCE", ROOT.parent / "immortalwrt"))
BASE_MAC = "50:da:9e:35:72:e0"


class MultiwanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        (self.dir / "mac").mkdir()
        for port in ("eth0", "lan3", "lan4", "lan5"):
            (self.dir / "mac" / port).write_text(BASE_MAC)
        for port, mac in [("eth1", "50:da:9e:35:72:e1"), ("eth2", "50:da:9e:35:72:e2")]:
            (self.dir / "mac" / port).write_text(mac)
        self.statefile = self.dir / "state.json"
        self.initial = {
            "network": {
                "globals": {"__type": "globals", "dhcp_default_duid": "0004existing-global-duid"},
                "lan": {"__type": "interface", "device": "br-lan", "proto": "static", "ipaddr": "192.168.1.1"},
                "@device[0]": {"__type": "device", "name": "br-lan", "type": "bridge", "ports": ["eth1"]},
                **{f"wan{n}": {"__type": "interface", "device": f"lan{n+2}", "proto": "dhcp"} for n in range(1, 4)},
            },
            "firewall": {
                "@zone[0]": {"__type": "zone", "name": "lan", "network": ["lan"]},
                "@zone[1]": {"__type": "zone", "name": "wan", "network": ["wan1", "wan2", "wan3", "wan1", "guestwan"], "input": "REJECT"},
            },
        }
        self.save(self.initial)
        (self.bin / "uci").write_text(f"#!{sys.executable}\nexec(compile(open({str(ROOT / 'tests/mock_uci.py')!r}).read(), 'mock_uci.py', 'exec'))\n")
        (self.bin / "uci").chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "MOCK_UCI_STATE": str(self.statefile),
                    "BE12PRO_LIBRARY_ONLY": "1", "TEST_DIR": str(self.dir)}
        self.wrapper = self.dir / "run.sh"
        self.wrapper.write_text(f"""#!/bin/sh
. '{ROOT / 'files/usr/libexec/be12pro-multiwan.sh'}'
board_name() {{ echo "${{TEST_BOARD:-tenda,be12-pro}}"; }}
sys_mac() {{ cat "$TEST_DIR/mac/$1" 2>/dev/null || true; }}
id() {{ echo 0; }}
backup_configs() {{
  BACKUP="$TEST_DIR/backup"
  mkdir -p "$BACKUP"
  uci export network > "$BACKUP/network"
  uci export firewall > "$BACKUP/firewall"
}}
restore_configs() {{
  uci import network < "$BACKUP/network"
  uci import firewall < "$BACKUP/firewall"
}}
main "$@"
""")

    def save(self, state):
        self.statefile.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.statefile.read_text())

    def run_helper(self, option="--apply", ok=True, **env):
        result = subprocess.run(["sh", str(self.wrapper), option], env={**self.env, **env}, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def assert_layout(self):
        data = self.state()
        net = data["network"]
        macs = [net[f"be12pro_lan{n}"]["macaddr"] for n in (3, 4, 5)]
        self.assertEqual(len(set(macs)), 3)
        self.assertNotIn(BASE_MAC, macs)
        for n, mac in enumerate(macs, 1):
            hexmac = mac.replace(":", "")
            v4, v6 = net[f"wan{n}"], net[f"wan{n}6"]
            self.assertEqual(v4["device"], f"lan{n+2}")
            self.assertEqual(v4["proto"], "dhcp")
            self.assertEqual(v6["proto"], "dhcpv6")
            self.assertEqual(v4["clientid"], "01" + hexmac)
            self.assertEqual(v6["clientid"], "00030001" + hexmac)
            self.assertEqual(v6["metric"], str(n * 10))
            self.assertEqual(v6["reqprefix"], "no")
        self.assertEqual(net["lan"], self.initial["network"]["lan"])
        self.assertEqual(net["@device[0]"], self.initial["network"]["@device[0]"])
        self.assertEqual(data["firewall"]["@zone[1]"]["input"], "REJECT")
        networks = data["firewall"]["@zone[1]"]["network"]
        self.assertEqual(len(networks), len(set(networks)))
        self.assertTrue({"guestwan", "wan1", "wan16", "wan2", "wan26", "wan3", "wan36"}.issubset(networks))

    def test_duplicate_hardware_macs_get_unique_persistent_identities(self):
        self.run_helper()
        self.assert_layout()
        old = self.state()
        self.run_helper()
        self.assertEqual(old, self.state(), "repeat apply must preserve DHCP identities")

    def test_unique_manual_macs_are_preserved_and_legacy_overrides_removed(self):
        state = copy.deepcopy(self.initial)
        for n in (1, 2, 3):
            state["network"][f"wan{n}"]["macaddr"] = f"02:ab:cd:ef:01:0{n}"
        self.save(state)
        self.run_helper()
        for n in (1, 2, 3):
            self.assertEqual(self.state()["network"][f"be12pro_lan{n+2}"]["macaddr"], f"02:ab:cd:ef:01:0{n}")
            self.assertNotIn("macaddr", self.state()["network"][f"wan{n}"])

    def test_generated_address_does_not_collide_with_a_later_manual_port(self):
        state = copy.deepcopy(self.initial)
        state["network"]["wan2"]["macaddr"] = "52:da:9e:35:72:e3"
        self.save(state)
        self.run_helper()
        self.assert_layout()
        self.assertEqual(self.state()["network"]["be12pro_lan4"]["macaddr"], "52:da:9e:35:72:e3")

    def test_existing_anonymous_device_section_is_reused(self):
        state = copy.deepcopy(self.initial)
        state["network"]["@device[1]"] = {"__type": "device", "name": "lan3", "mtu": "1500"}
        self.save(state)
        self.run_helper()
        net = self.state()["network"]
        self.assertNotIn("be12pro_lan3", net)
        self.assertEqual(net["@device[1]"]["mtu"], "1500")
        self.assertIn("macaddr", net["@device[1]"])

    def test_wrong_board_wrong_mapping_bridge_membership_refused_before_writes(self):
        self.run_helper(ok=False, TEST_BOARD="other,router")
        self.assertEqual(self.state(), self.initial)
        for modify in ("mapping", "bridge", "vlan"):
            state = copy.deepcopy(self.initial)
            if modify == "mapping":
                state["network"]["wan2"]["device"] = "eth1"
            else:
                state["network"]["@device[0]"]["ports"].append("lan3" if modify == "bridge" else "lan3:u*")
            self.save(state)
            self.run_helper(ok=False)
            self.assertEqual(self.state(), state)

    def test_duplicate_device_sections_refused_before_writes(self):
        state = copy.deepcopy(self.initial)
        for key in ("@device[1]", "@device[2]"):
            state["network"][key] = {"__type": "device", "name": "lan3"}
        self.save(state)
        self.run_helper(ok=False)
        self.assertEqual(self.state(), state)

    def test_commit_failure_restores_both_configs(self):
        result = self.run_helper(ok=False, MOCK_UCI_FAIL="commit firewall")
        self.assertIn("restored backup", result.stderr)
        self.assertEqual(self.state(), self.initial)

    def test_check_detects_unapplied_macs_and_wrong_duid(self):
        self.run_helper()
        self.run_helper("--check", ok=False)
        state = self.state()
        for n in (3, 4, 5):
            (self.dir / "mac" / f"lan{n}").write_text(state["network"][f"be12pro_lan{n}"]["macaddr"])
        self.run_helper("--check")
        state["network"]["wan26"]["clientid"] = state["network"]["wan16"]["clientid"]
        self.save(state)
        self.run_helper("--check", ok=False)

    @unittest.skipUnless((SOURCE / "package/base-files/files/bin/config_generate").exists(), "provide IMMORTALWRT_SOURCE")
    def test_real_config_generate_does_not_handle_explicit_dhcpv6_board_entry(self):
        text = (SOURCE / "package/base-files/files/bin/config_generate").read_text()
        function = text[text.index("generate_network() {"):text.index("\ngenerate_switch_vlans_ports()")]
        shell = """json_select() { :; }
json_get_vars() { device=lan3; protocol=dhcpv6; metric=10; }
json_get_values() { ports=''; }
""" + function + "\ngenerate_network wan16\n"
        result = subprocess.run(["sh", "-c", shell], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["network"]["wan16"]["proto"], "none")
        self.run_helper()
        self.assert_layout()


if __name__ == "__main__":
    unittest.main(verbosity=2)
