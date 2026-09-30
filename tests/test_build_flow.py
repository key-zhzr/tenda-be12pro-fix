#!/usr/bin/env python3
"""Exercise checkout/retry/variant/package logic with local git and mocked Linux build tools.

This is a build-flow regression check, not a firmware compilation.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("IMMORTALWRT_SOURCE", ROOT.parent / "immortalwrt"))
SOURCE_FILES = [
    "target/linux/mediatek/files-6.18/drivers/net/dsa/an8855.c",
    "target/linux/mediatek/files-6.18/drivers/net/dsa/an8855.h",
    "target/linux/mediatek/files-6.18/drivers/net/mdio/mdio-an8855.c",
    "target/linux/mediatek/files-6.18/drivers/net/phy/air_an8855.c",
    "target/linux/mediatek/filogic/base-files/etc/board.d/02_network",
]


def run(*args, cwd=None, env=None, check=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if check and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


def executable(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)
    path.chmod(0o755)


def commit_repo(path):
    run("git", "init", "-q", "-b", "main", cwd=path)
    run("git", "add", ".", cwd=path)
    run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture", cwd=path)
    return run("git", "rev-parse", "HEAD", cwd=path).stdout.strip()


@unittest.skipUnless((SOURCE / ".git").exists(), "provide IMMORTALWRT_SOURCE")
class BuildFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.tmp.name)
        cls.source = cls.dir / "origin-source"
        cls.source.mkdir()
        for name in SOURCE_FILES:
            dest = cls.source / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            # Read the clean pinned original, regardless of local applied patches.
            dest.write_text(run("git", "show", f"HEAD:{name}", cwd=SOURCE).stdout)
        executable(cls.source / "scripts/feeds", "#!/bin/sh\nexit 0\n")
        executable(cls.source / "scripts/diffconfig.sh", "#!/bin/sh\ncat .config\n")
        cls.source_sha = commit_repo(cls.source)
        cls.control = cls.dir / "origin-control"
        cls.control.mkdir()
        for folder in ("scripts", "patches", "files"):
            shutil.copytree(ROOT / folder, cls.control / folder)
        shutil.copy(ROOT / "build-be12pro-wsl.sh", cls.control)
        cls.control_sha = commit_repo(cls.control)
        cls.bin = cls.dir / "bin"
        cls.bin.mkdir()
        executable(cls.bin / "uname", "#!/bin/sh\necho Linux\n")
        executable(cls.bin / "id", "#!/bin/sh\necho 1000\n")
        executable(cls.bin / "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 500000000 0 500000000 0%% /\\n'\n")
        executable(cls.bin / "ccache", "#!/bin/sh\nexit 0\n")
        executable(cls.bin / "sudo", '#!/bin/sh\nexec "$@"\n')
        executable(cls.bin / "apt-get", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_APT_LOG"\n')
        executable(cls.bin / "make", """#!/usr/bin/env python3
import os, sys
from pathlib import Path
with open(os.environ['TEST_MAKE_LOG'], 'a') as f: f.write(' '.join(sys.argv[1:]) + '\\n')
if 'defconfig' in sys.argv:
    path=Path('.config')
    omit=os.environ.get('MOCK_MISSING_PACKAGE', 'luci-i18n-smartdns-zh-cn')
    path.write_text(''.join(line for line in path.read_text().splitlines(True) if line != 'CONFIG_PACKAGE_'+omit+'=y\\n'))
""")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def env(self, root, **extra):
        return {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                "WORKROOT": str(root), "SOURCE_REPO": self.source.as_uri(), "SOURCE_REF": self.source_sha,
                "CONTROL_REPO": self.control.as_uri(), "CONTROL_REF": self.control_sha,
                "JOBS": "1", "SKIP_DEPS": "1", "PREPARE_ONLY": "1",
                "TEST_MAKE_LOG": str(self.dir / "make.log"),
                "TEST_APT_LOG": str(self.dir / "apt.log"), **extra}

    def builder(self, env, ok=True):
        result = run("bash", str(ROOT / "build-be12pro-wsl.sh"), env=env, check=False)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_first_checkout_repeat_and_variant_switch(self):
        root = self.dir / "build-repeat"
        env = self.env(root)
        first = self.builder(env)
        self.assertIn("Optional package unavailable", first.stdout)
        source = root / "source"
        network = (source / SOURCE_FILES[-1]).read_text()
        self.assertIn('"wan3" device "lan5" protocol "dhcp"', network)
        self.assertNotIn('"wan16" device', network)
        core = source / "target/linux/mediatek/filogic/base-files/usr/libexec/be12pro-multiwan.sh"
        self.assertTrue(core.stat().st_mode & 0o111)
        repeat = self.builder(env)
        self.assertIn("Already applied", repeat.stdout)
        refused = self.builder({**env, "PATCHSET": "multiwan-mdio-debug"}, ok=False)
        self.assertIn("Patch variant changed", refused.stdout)
        switched = self.builder({**env, "PATCHSET": "multiwan-mdio-debug", "RESET_SOURCE": "1"})
        self.assertIn("cleaning kernel", switched.stdout)
        self.assertIn("AN8855-RFT-MDIO:", (source / SOURCE_FILES[2]).read_text())
        self.assertIn("target/linux/clean", (self.dir / "make.log").read_text())

    def test_missing_core_package_fails_instead_of_silent_omission(self):
        result = self.builder(self.env(self.dir / "build-missing", MOCK_MISSING_PACKAGE="curl"), ok=False)
        self.assertIn("Required package unavailable: curl", result.stdout)

    def test_apt_ipv4_default_opt_out_and_dependency_skip(self):
        root = self.dir / "build-apt"
        env = self.env(root, SKIP_DEPS="0")
        env.pop("APT_FORCE_IPV4", None)
        apt_log = Path(env["TEST_APT_LOG"])
        self.builder(env)
        commands = apt_log.read_text().splitlines()
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0], "-o Acquire::ForceIPv4=true update")
        self.assertTrue(commands[1].startswith("-o Acquire::ForceIPv4=true install -y "))
        apt_log.write_text("")
        self.builder({**env, "APT_FORCE_IPV4": "0"})
        self.assertNotIn("ForceIPv4", apt_log.read_text())
        self.assertEqual(apt_log.read_text().splitlines()[0], "update")
        apt_log.unlink()
        self.builder({**env, "SKIP_DEPS": "1"})
        self.assertFalse(apt_log.exists())

    def test_deleted_pr_branch_retry_uses_main_and_recovers_unchecked_clone(self):
        origin = self.dir / "origin-control-retry"
        run("git", "clone", "-q", str(self.control), str(origin))
        root = self.dir / "build-retry"
        env = self.env(root, CONTROL_REPO=origin.as_uri(), CONTROL_REF="fix/multiwan-identity")
        failed = self.builder(env, ok=False)
        self.assertIn("couldn't find remote ref fix/multiwan-identity", failed.stdout)
        control = root / "control"
        self.assertFalse((control / ".git/index").exists())
        cache = root / "source/dl/keep-download"
        cache.parent.mkdir()
        cache.write_text("reusable download")
        # main can advance between the failed clone and the user's retry.
        (origin / "retry-marker").write_text("new main revision")
        run("git", "add", "retry-marker", cwd=origin)
        run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "-qm", "advance main", cwd=origin)
        desired = run("git", "rev-parse", "HEAD", cwd=origin).stdout.strip()
        env.pop("CONTROL_REF")  # Exercise the stable default, not an override.
        self.builder(env)
        self.assertEqual(run("git", "rev-parse", "HEAD", cwd=control).stdout.strip(), desired)
        self.assertEqual((control / "retry-marker").read_text(), "new main revision")
        self.assertEqual(cache.read_text(), "reusable download")

    def test_all_patch_variants_apply_and_are_idempotent(self):
        for variant in ("multiwan", "multiwan-mdio-debug", "vendorfix", "vendorfix-noeee", "vendorfix-mdio-debug"):
            with self.subTest(variant=variant):
                source = self.dir / f"variant-{variant}"
                run("git", "clone", "-q", str(self.source), str(source))
                run("bash", str(ROOT / "scripts/prepare-source.sh"), str(source), variant)
                run("bash", str(ROOT / "scripts/prepare-source.sh"), str(source), variant)
                run("git", "diff", "--check", cwd=source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
