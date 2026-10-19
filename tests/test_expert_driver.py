"""Unit coverage for tests/expert-driver.py, the image tests' driver picker.

socket-print.sh, coexistence.sh, service-advertisements.sh, appliance.sh,
vendor-options-payload.sh and device-settings-web-admin.sh all add their
printer with the driver this script picks from the live `drivers` listing.
Those suites only run against a built image, so these cases drive the
picker's contract directly with hand-built listings.
"""
import subprocess
import sys
import unittest
from pathlib import Path

PICKER = Path(__file__).resolve().parent / "expert-driver.py"

LISTING = "\n".join([
    'epson--stylus-photo-r-18000--en "Epson Stylus Photo R18000 (en)" ""',
    'epson--stylus-photo-r-1800--de "Epson Stylus Photo R1800 (de)" ""',
    'epson--stylus-photo-r-1800-simplified--en "Epson Stylus Photo R1800 Simplified (en)" ""',
    'epson--stylus-photo-r-1800--en "Epson Stylus Photo R1800 (en)" "MFG:EPSON;MDL:Stylus Photo R1800;"',
    '"epson--stylus-photo-r-800--en" "Epson Stylus Photo R800 (en)" ""',
    "",
])


def pick(model, listing=LISTING):
    return subprocess.run([sys.executable, str(PICKER), *model], input=listing,
                          capture_output=True, text=True, timeout=30)


class ExpertDriverTests(unittest.TestCase):
    def test_picks_exact_english_description(self):
        result = pick(["Epson Stylus Photo R1800"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "epson--stylus-photo-r-1800--en\n")

    def test_strips_quotes_from_driver_name(self):
        result = pick(["Epson Stylus Photo R800"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "epson--stylus-photo-r-800--en\n")

    def test_missing_model_fails_with_listing(self):
        result = pick(["Epson Stylus Photo R2400"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("no expert 'Epson Stylus Photo R2400' driver", result.stderr)
        self.assertIn("epson--stylus-photo-r-1800--en", result.stderr)

    def test_malformed_row_fails(self):
        result = pick(["Epson Stylus Photo R1800"], "epson--x \"Epson Stylus Photo R1800 (en)\"\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected driver listing row", result.stderr)

    def test_unsafe_driver_name_fails(self):
        result = pick(["Epson Stylus Photo R1800"],
                      'epson;rm "Epson Stylus Photo R1800 (en)" ""\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not [a-z0-9-]", result.stderr)

    def test_empty_listing_fails(self):
        result = pick(["Epson Stylus Photo R1800"], "")
        self.assertEqual(result.returncode, 1)

    def test_usage(self):
        self.assertEqual(pick([]).returncode, 2)
        self.assertEqual(pick(["a", "b"]).returncode, 2)
        self.assertEqual(pick([""]).returncode, 2)


if __name__ == "__main__":
    unittest.main()
