"""Packaging contract for the CUPS-style USB backends of the OCI image.

These tests run without Rockcraft or a container engine.  They exercise the
real permission helper against a fixture that reproduces the modes the
upstream builds install, and they pin the Rockcraft wiring so that the
dye-sublimation backend and the vendor quirk tables cannot silently drop out
of the image again.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARDEN = ROOT / "scripts/harden-usb-backends.sh"
PAYLOAD_CHECK = ROOT / "tests/check-usb-backend-payload.sh"
ROCKCRAFT = ROOT / "rockcraft.yaml"

BACKEND_DIR = "usr/lib/gutenprint-printer-app/backend"
BACKENDS = ("usb", "gutenprint53+usb")
QUIRK_TABLES = ("org.cups.usb-quirks", "net.sf.gimp-print.usb-quirks")
# The gutenprint part relocates these two out of the CUPS tree; the cups part
# copies its own backend and quirk table straight into the backend directory.
GUTENPRINT_PAYLOAD = ("gutenprint53+usb", "net.sf.gimp-print.usb-quirks")


def rockcraft_part(name):
    """Return the indented body of a top-level entry of rockcraft.yaml."""
    lines = ROCKCRAFT.read_text().splitlines()
    try:
        start = lines.index(f"  {name}:")
    except ValueError:  # pragma: no cover - guards a broken fixture
        raise AssertionError(f"rockcraft.yaml has no {name!r} part") from None
    body = []
    for line in lines[start + 1:]:
        stripped = line.lstrip()
        # Several parts carry "ext:updatesnap" comments at column 0, so only
        # a genuine top-level key ends the part.
        if stripped and not stripped.startswith("#") and len(line) - len(stripped) <= 2:
            break
        body.append(line)
    return "\n".join(body)


class HardenUSBBackendsTest(unittest.TestCase):
    """The helper must make the shipping backends usable by the run user."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backend_dir = self.root / BACKEND_DIR
        self.backend_dir.mkdir(parents=True)

    def install(self, name, mode):
        path = self.backend_dir / name
        path.write_text(f"# {name}\n")
        path.chmod(mode)
        return path

    def install_payload(self, backends=(("usb", 0o755), ("gutenprint53+usb", 0o700))):
        for name, mode in backends:
            self.install(name, mode)
        for name in QUIRK_TABLES:
            self.install(name, 0o644)

    def harden(self, root=None, check=True):
        return subprocess.run(
            ["sh", str(HARDEN), str(root if root is not None else self.root)],
            text=True, capture_output=True, check=check,
        )

    def assert_mode(self, name, expected):
        mode = (self.backend_dir / name).stat().st_mode
        self.assertEqual(oct(mode & 0o7777), oct(expected),
                         f"{name} has mode {oct(mode & 0o7777)}")

    def test_dyesub_backend_becomes_executable_and_setuid(self):
        # Gutenprint installs this backend mode 700 (src/cups/Makefile.am
        # install-exec-hook), which "_daemon_" cannot even execute.
        self.install_payload()
        self.harden()
        for name in BACKENDS:
            self.assert_mode(name, 0o4755)
            self.assertTrue(os.access(self.backend_dir / name, os.X_OK))
            self.assertTrue((self.backend_dir / name).stat().st_mode & 0o001,
                            f"{name} is not executable by the run user")

    def test_mode_700_backend_is_made_other_executable(self):
        self.install_payload(backends=(("usb", 0o755), ("gutenprint53+usb", 0o700)))
        self.harden()
        self.assert_mode("gutenprint53+usb", 0o4755)

    def test_quirk_tables_stay_readable(self):
        self.install_payload()
        for name in QUIRK_TABLES:
            (self.backend_dir / name).chmod(0o600)
        self.harden()
        for name in QUIRK_TABLES:
            self.assert_mode(name, 0o644)

    def test_is_idempotent(self):
        self.install_payload()
        self.harden()
        self.harden()
        for name in BACKENDS:
            self.assert_mode(name, 0o4755)

    def test_missing_backend_fails_loudly(self):
        self.install_payload(backends=(("usb", 0o755),))
        result = self.harden(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gutenprint53+usb", result.stderr)
        self.assertIn("missing", result.stderr)

    def test_missing_quirk_table_fails_loudly(self):
        self.install_payload()
        (self.backend_dir / "net.sf.gimp-print.usb-quirks").unlink()
        result = self.harden(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("net.sf.gimp-print.usb-quirks", result.stderr)

    def test_requires_an_image_root(self):
        result = subprocess.run(["sh", str(HARDEN)], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage", result.stderr)


def rockcraft_list(part_body, key):
    """Return the entries of a list-valued key inside a part body."""
    entries = []
    inside = False
    for line in part_body.splitlines():
        stripped = line.strip()
        if not inside:
            inside = stripped == f"{key}:"
            continue
        if stripped and len(line) - len(line.lstrip()) <= 4:
            break
        if stripped.startswith("- "):
            entries.append(stripped[2:].strip())
    return entries


class RockcraftWiringTest(unittest.TestCase):
    """Pin the packaging so the payload cannot be dropped silently."""

    def test_utils_part_applies_the_permission_helper(self):
        utils = rockcraft_part("utils")
        self.assertIn("harden-usb-backends.sh", utils,
                      "the utils part no longer hardens the USB backends")
        self.assertTrue(HARDEN.is_file())

    def test_gutenprint_part_ships_backend_and_quirks(self):
        gutenprint = rockcraft_part("gutenprint")
        for name in GUTENPRINT_PAYLOAD:
            self.assertIn(f"{BACKEND_DIR}/{name}", gutenprint,
                          f"{name} is not organized into the backend directory")

        primed = [p for p in rockcraft_list(gutenprint, "prime")
                  if not p.startswith("-")]
        self.assertTrue(
            any(BACKEND_DIR == p or BACKEND_DIR.startswith(p.rstrip("/") + "/")
                for p in primed),
            f"the backend directory {BACKEND_DIR} is not primed: {primed}")

    def test_cups_part_ships_its_quirk_table(self):
        cups = rockcraft_part("cups")
        self.assertIn("org.cups.usb-quirks", cups)
        self.assertIn(BACKEND_DIR, cups)
        primed = [p for p in rockcraft_list(cups, "prime")
                  if not p.startswith("-")]
        self.assertIn(f"{BACKEND_DIR}/*", primed)


class PayloadCheckTest(unittest.TestCase):
    """The image-level checker must accept the payload and reject a broken one.

    The fixture uses a real ELF binary so that the library-resolution and
    discovery branches actually run.  It is owned by the test user, so the
    ownership requirement keeps these runs from passing overall - only a
    container image can do that.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.backend_dir = Path(self.temp.name) / "backend"
        self.backend_dir.mkdir()

    def install(self, name, mode):
        path = self.backend_dir / name
        shutil.copy2("/bin/true", path)
        path.chmod(mode)
        return path

    def install_payload(self, mode=0o4755, backends=BACKENDS):
        for name in backends:
            self.install(name, mode)
        for name in QUIRK_TABLES:
            (self.backend_dir / name).write_text("# quirks\n")

    def check(self):
        return subprocess.run(
            ["sh", str(PAYLOAD_CHECK)], text=True, capture_output=True,
            env={**os.environ, "USB_BACKEND_DIR": str(self.backend_dir)},
        )

    def test_reports_missing_payload(self):
        if Path("/usr/lib/gutenprint-printer-app/backend").exists():
            self.skipTest("host happens to provide the image payload")
        result = subprocess.run(["sh", str(PAYLOAD_CHECK)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("gutenprint53+usb", result.stderr)
        self.assertIn("missing", result.stderr)

    def test_resolves_libraries_and_discovers_safely(self):
        self.install_payload()
        result = self.check()
        self.assertIn("resolves all", result.stdout)
        self.assertIn("exited 0 during discovery", result.stdout)
        # A mode of 4755 must be accepted as set-user-ID; only the ownership
        # requirement, which needs a real image, may fail here.
        self.assertNotIn("set-user-ID", result.stderr)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not owned by root", result.stderr)

    def test_reports_a_backend_without_the_setuid_bit(self):
        self.install_payload(mode=0o755)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("set-user-ID", result.stderr)

    def test_reports_a_backend_that_is_not_executable(self):
        self.install_payload(mode=0o600)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not executable", result.stderr)

    def test_reports_a_missing_backend(self):
        self.install_payload(backends=("usb",))
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("gutenprint53+usb", result.stderr)
        self.assertIn("missing", result.stderr)

    def test_reports_a_missing_quirk_table(self):
        self.install_payload()
        (self.backend_dir / "org.cups.usb-quirks").unlink()
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("org.cups.usb-quirks", result.stderr)


if __name__ == "__main__":
    unittest.main()
