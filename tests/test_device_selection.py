"""Unit coverage for the device-selection regression harness.

`just verify` runs tests/device-selection.py against the built image and treats
a clean exit as proof that driver auto-selection is right. Every refusal in
that script is therefore the only thing standing between a selection
regression and a green merge queue, yet a real image only ever exercises the
success path. These cases replace the app with a scripted `drivers` listing so
each refusal is proven to fire: no image, no podman, no Gutenprint.
"""
import contextlib
import importlib.util
import io
import shlex
import subprocess
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "device_selection", Path(__file__).resolve().parent / "device-selection.py")
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)

EPSON_ID = "MFG:EPSON;MDL:Stylus Photo R300;DES:EPSON Stylus Photo R300;"
CANON_ID = "MFG:Canon;MDL:iP4000;CMD:BJL,BJRaster3,BSCCe;"
EPSON_ROW = ["epson--stylus-photo-r-300--en",
             "Epson Stylus Photo R300 - CUPS+Gutenprint v5.3.5",
             "MFG:EPSON;MDL:Stylus Photo R300;"]
CANON_ROW = ["canon--ip-4000--en",
             "Canon PIXMA iP4000 - CUPS+Gutenprint v5.3.5",
             "MFG:Canon;MDL:iP4000;"]
INVENTORY = [EPSON_ROW, CANON_ROW,
             ["hp--deskjet-500--en", "HP DeskJet 500 - CUPS+Gutenprint v5.3.5", ""]]


def listing(rows):
    return "".join(shlex.join(row) + "\n" for row in rows)


def device_id_of(args):
    """Return the device ID passed with -o, or None for the full inventory."""
    if "-o" not in args:
        return None
    value = args[args.index("-o") + 1]
    prefix = "device-id='"
    assert value.startswith(prefix) and value.endswith("'"), value
    return value[len(prefix):-1]


class FakeApp:
    """Answer `<command> drivers [-o device-id=...]` from a lookup table."""

    def __init__(self, inventory=INVENTORY, overrides=None):
        self.inventory = inventory
        self.overrides = overrides or {}
        self.calls = []

    def selected(self, device_id):
        if device_id in self.overrides:
            return self.overrides[device_id]
        if device_id.startswith("MFG:HiveUnknown;"):
            return []
        if device_id.startswith("MFG:EPSON;"):
            return [EPSON_ROW]
        if device_id.startswith("MFG:Canon;"):
            return [CANON_ROW]
        raise AssertionError(f"unexpected device ID {device_id!r}")

    def __call__(self, args, **kwargs):
        self.calls.append((list(args), kwargs))
        device_id = device_id_of(args)
        rows = self.inventory if device_id is None else self.selected(device_id)
        stdout = rows if isinstance(rows, str) else listing(rows)
        return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")


def run_main(app, argv=("device-selection.py", "--", "app")):
    out = io.StringIO()
    with mock.patch.object(selection.subprocess, "run", app), \
            mock.patch("sys.argv", list(argv)), \
            contextlib.redirect_stdout(out):
        selection.main()
    return out.getvalue()


class DriversTests(unittest.TestCase):
    def test_inventory_call_passes_no_device_id(self):
        app = FakeApp()
        with mock.patch.object(selection.subprocess, "run", app):
            rows = selection.drivers(["podman", "run", "img"])
        self.assertEqual(rows, INVENTORY)
        args, kwargs = app.calls[0]
        self.assertEqual(args, ["podman", "run", "img", "drivers"])
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["timeout"], 120)

    def test_device_id_is_quoted_so_spaces_survive_option_parsing(self):
        app = FakeApp()
        with mock.patch.object(selection.subprocess, "run", app):
            selection.drivers(["app"], EPSON_ID)
        args, _ = app.calls[0]
        self.assertEqual(args, ["app", "drivers", "-o", f"device-id='{EPSON_ID}'"])

    def test_blank_lines_are_ignored(self):
        app = FakeApp(inventory="\n" + listing([EPSON_ROW]) + "   \n")
        with mock.patch.object(selection.subprocess, "run", app):
            self.assertEqual(selection.drivers(["app"]), [EPSON_ROW])

    def test_row_without_three_fields_is_rejected(self):
        for bad in ('only-a-name\n', 'name "desc"\n', 'a b c d\n'):
            with self.subTest(stdout=bad):
                app = FakeApp(inventory=bad)
                with mock.patch.object(selection.subprocess, "run", app), \
                        self.assertRaisesRegex(RuntimeError, "Unexpected driver listing"):
                    selection.drivers(["app"])

    def test_failing_app_propagates(self):
        def boom(args, **_kwargs):
            raise subprocess.CalledProcessError(1, args)
        with mock.patch.object(selection.subprocess, "run", boom), \
                self.assertRaises(subprocess.CalledProcessError):
            selection.drivers(["app"])


class MainTests(unittest.TestCase):
    def test_correct_selection_passes(self):
        out = run_main(FakeApp())
        self.assertIn("PASS: Epson Stylus Photo R300: epson--stylus-photo-r-300--en", out)
        self.assertIn("PASS: Canon PIXMA iP4000: canon--ip-4000--en", out)
        self.assertIn("PASS: unknown PCL devices select no driver", out)

    def test_every_unknown_pcl_command_set_is_probed(self):
        app = FakeApp()
        run_main(app)
        probed = [device_id_of(args) for args, _ in app.calls]
        unknown = [d for d in probed if d and d.startswith("MFG:HiveUnknown;")]
        self.assertEqual(
            unknown,
            [f"MFG:HiveUnknown;MDL:Unsupported PCL device;CMD:{c};"
             for c in ("PCL", "PCL5", "PCL5c", "PCLXL", "PCL6", "PCL,PCL5c,PCLXL")])

    def test_empty_inventory_fails_instead_of_passing_vacuously(self):
        with self.assertRaisesRegex(RuntimeError, "No drivers registered"):
            run_main(FakeApp(inventory=[]))

    def test_unknown_pcl_device_that_selects_a_driver_fails(self):
        generic = ["generic-pcl--en", "Generic PCL - CUPS+Gutenprint", ""]
        for command_set in ("PCL", "PCLXL", "PCL,PCL5c,PCLXL"):
            device_id = f"MFG:HiveUnknown;MDL:Unsupported PCL device;CMD:{command_set};"
            with self.subTest(command_set=command_set), \
                    self.assertRaisesRegex(RuntimeError, "Unsupported device"):
                run_main(FakeApp(overrides={device_id: [generic]}))

    def test_supported_model_must_select_exactly_one_driver(self):
        for rows in ([], [EPSON_ROW, EPSON_ROW]):
            with self.subTest(count=len(rows)), \
                    self.assertRaisesRegex(RuntimeError, "Expected one Epson Stylus Photo R300"):
                run_main(FakeApp(overrides={EPSON_ID: rows}))

    def test_selected_driver_must_be_in_the_inventory(self):
        app = FakeApp(inventory=[r for r in INVENTORY if r is not CANON_ROW])
        with self.assertRaisesRegex(RuntimeError, "Expected registered Canon PIXMA iP4000"):
            run_main(app)

    def test_selected_driver_must_be_the_models_own_ppd(self):
        wrong = ["epson--stylus-photo-r-2400--en", "Epson Stylus Photo R2400", ""]
        app = FakeApp(inventory=INVENTORY + [wrong], overrides={EPSON_ID: [wrong]})
        with self.assertRaisesRegex(RuntimeError, "Expected registered Epson"):
            run_main(app)

    def test_simplified_driver_is_rejected(self):
        simplified = ["canon--ip-4000--en-simple",
                      "Canon PIXMA iP4000 - CUPS+Gutenprint v5.3.5 Simplified", ""]
        app = FakeApp(inventory=INVENTORY + [simplified], overrides={CANON_ID: [simplified]})
        with self.assertRaisesRegex(RuntimeError, "Expected registered Canon"):
            run_main(app)

    def test_advertising_pcl_must_not_change_a_supported_selection(self):
        pcl_id = "MFG:Canon;MDL:iP4000;CMD:PCL,PCL5c,PCLXL;"
        app = FakeApp(overrides={pcl_id: []})
        with self.assertRaisesRegex(RuntimeError, "PCL command set changed selection for Canon"):
            run_main(app)

    def test_pcl_probe_keeps_the_model_and_replaces_only_the_command_set(self):
        app = FakeApp()
        run_main(app)
        probed = {device_id_of(args) for args, _ in app.calls}
        self.assertIn("MFG:EPSON;MDL:Stylus Photo R300;DES:EPSON Stylus Photo R300;"
                      "CMD:PCL,PCL5c,PCLXL;", probed)
        self.assertIn("MFG:Canon;MDL:iP4000;CMD:PCL,PCL5c,PCLXL;", probed)


class CommandLineTests(unittest.TestCase):
    def test_container_command_after_separator_is_used_verbatim(self):
        app = FakeApp()
        run_main(app, ["device-selection.py", "--", "podman", "run", "--rm", "img"])
        self.assertTrue(all(args[:4] == ["podman", "run", "--rm", "img"] for args, _ in app.calls))

    def test_bare_path_is_used_as_the_command(self):
        app = FakeApp()
        run_main(app, ["device-selection.py", "/opt/app"])
        self.assertTrue(all(args[0] == "/opt/app" for args, _ in app.calls))

    def test_no_command_defaults_to_the_installed_app(self):
        app = FakeApp()
        run_main(app, ["device-selection.py"])
        self.assertTrue(all(args[0] == "gutenprint-printer-app" for args, _ in app.calls))

    def test_separator_without_command_is_a_usage_error(self):
        app = FakeApp()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            run_main(app, ["device-selection.py", "--"])
        self.assertEqual(caught.exception.code, 2)
        self.assertEqual(app.calls, [])


if __name__ == "__main__":
    unittest.main()
