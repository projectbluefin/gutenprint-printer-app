"""Unit coverage for the vendor-option picker used by device-settings-web-admin.sh.

tests/device-settings-web-admin.sh asks pick-vendor-option.py which setting to
flip through the real web form, then asserts the server reports it back. The
picker is therefore what decides whether that suite proves anything: a name it
must never return (the CSRF `session` field, or an IPP-mapped setting PAPPL
renders on every page) turns the suite into a false pass or a false failure,
and the `selected` option is what the suite compares against afterwards.

The image build only ever drives the picker with one real PPD's page, so these
cases drive its contract directly with hand-built HTML: no image, no server.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PICKER = Path(__file__).resolve().parent / "pick-vendor-option.py"


def select(name, *options):
    """Render <select name=...> with ("value", selected) option pairs."""
    body = "\n".join(
        '      <option value="%s"%s>%s</option>' % (value, " selected" if sel else "", value)
        for value, sel in options)
    return '    <select name="%s">\n%s\n    </select>\n' % (name, body)


def page(*selects):
    return "<html><body><form>\n%s</form></body></html>\n" % "".join(selects)


class PickVendorOptionTests(unittest.TestCase):
    def pick(self, html, encoding="utf-8"):
        with tempfile.NamedTemporaryFile(suffix=".html") as handle:
            handle.write(html.encode(encoding) if isinstance(html, str) else html)
            handle.flush()
            return subprocess.run(
                [sys.executable, str(PICKER), handle.name],
                capture_output=True, text=True)

    def assert_picked(self, html, name, default, alternative):
        result = self.pick(html)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [name, default, alternative])

    def assert_no_candidate(self, html):
        result = self.pick(html)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout, "")

    def test_picks_vendor_select_with_alternative(self):
        self.assert_picked(
            page(select("StpBrightness", ("1000", True), ("1200", False))),
            "StpBrightness", "1000", "1200")

    def test_default_is_the_selected_option_not_the_first(self):
        self.assert_picked(
            page(select("StpInkType", ("CMYK", False), ("RGB", True), ("Gray", False))),
            "StpInkType", "RGB", "CMYK")

    def test_default_falls_back_to_first_option_when_none_is_selected(self):
        self.assert_picked(
            page(select("StpDither", ("Adaptive", False), ("Ordered", False))),
            "StpDither", "Adaptive", "Ordered")

    def test_skips_the_csrf_session_field(self):
        # Flipping `session` would forge the POST token instead of a setting.
        self.assert_no_candidate(
            page(select("session", ("tokenA", True), ("tokenB", False))))

    def test_skips_ipp_mapped_settings(self):
        # Issue #11 is about non-IPP settings; PAPPL renders these on every
        # page, so picking one would not prove the Gutenprint PPD path.
        ipp_names = (
            "media-source", "media-type", "orientation-requested",
            "print-color-mode", "print-quality", "print-content-optimize",
            "printer-resolution", "output-bin", "sides", "copies",
            "print-scaling", "print-darkness", "print-speed",
        )
        for name in ipp_names:
            with self.subTest(name=name):
                self.assert_no_candidate(
                    page(select(name, ("one", True), ("two", False))))

    def test_ipp_settings_do_not_mask_a_later_vendor_select(self):
        self.assert_picked(
            page(select("print-quality", ("4", True), ("5", False)),
                 select("session", ("token", True), ("other", False)),
                 select("StpGamma", ("1.0", True), ("1.5", False))),
            "StpGamma", "1.0", "1.5")

    def test_skips_select_with_a_single_option(self):
        self.assert_picked(
            page(select("StpResolution", ("360dpi", True)),
                 select("StpInkSet", ("Photo", True), ("Matte", False))),
            "StpInkSet", "Photo", "Matte")

    def test_skips_select_whose_options_all_share_one_value(self):
        # Two <option>s but one distinct value: there is nothing to flip to.
        self.assert_picked(
            page(select("StpDuplicate", ("same", True), ("same", False)),
                 select("StpColorCorrection", ("None", True), ("Accurate", False))),
            "StpColorCorrection", "None", "Accurate")

    def test_reports_no_candidate_on_a_page_without_selects(self):
        self.assert_no_candidate("<html><body><p>no form here</p></body></html>")

    def test_tolerates_undecodable_bytes_in_the_page(self):
        # PAPPL renders PPD strings that are not always valid UTF-8; the
        # picker must still find the option rather than abort on decoding.
        html = page(select("StpMediaType", ("Plain", True), ("Glossy", False)))
        raw = html.encode("utf-8").replace(b"<html>", b"<html><!-- \xff -->")
        result = self.pick(raw)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["StpMediaType", "Plain", "Glossy"])

    def test_rejects_wrong_argument_count(self):
        for args in ([], [str(PICKER), "extra"]):
            with self.subTest(args=args):
                result = subprocess.run(
                    [sys.executable, str(PICKER)] + args,
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("usage: pick-vendor-option.py", result.stderr)


if __name__ == "__main__":
    unittest.main()
