"""Keep the Pages short installer identical to the canonical bootstrap."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "scripts" / "install.sh"
PUBLISHED = ROOT / "docs" / "install.sh"
README = ROOT / "README.md"
USAGE = ROOT / "docs" / "USAGE.md"

SHORT_COMMAND = "curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash"
PINNED_URL = "https://raw.githubusercontent.com/TobyNoSkillSon/Vella/v0.8.8/scripts/install.sh"


class PagesInstallerTests(unittest.TestCase):
    def test_published_installer_matches_canonical_source(self):
        self.assertTrue(CANONICAL.is_file())
        self.assertTrue(PUBLISHED.is_file())
        self.assertEqual(PUBLISHED.read_bytes(), CANONICAL.read_bytes())

    def test_published_installer_bash_syntax(self):
        for path in (CANONICAL, PUBLISHED):
            with self.subTest(script=path.name):
                result = subprocess.run(
                    ["bash", "-n", str(path)],
                    capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_published_installer_keeps_release_safety(self):
        text = PUBLISHED.read_text()
        self.assertIn('VERSION="0.8.8"', text)
        for marker in (
            "VELLA_SOURCE_SHA256",
            "Source checksum mismatch",
            "Source archive exceeds installer bounds",
            "Unsafe source archive entry",
            "must use HTTPS",
            "--proto '=https'",
            "--proto-redir '=https'",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, text)

    def test_readme_points_to_short_stable_url(self):
        text = README.read_text()
        self.assertIn(SHORT_COMMAND, text)
        self.assertIn("currently serves **v0.8.8**", text)

    def test_usage_retains_inspect_pinned_alternative(self):
        text = USAGE.read_text()
        self.assertIn(PINNED_URL, text)
        self.assertIn('installer="$(mktemp)"', text)
        self.assertIn('bash < "$installer"', text)
        for flag in ("--fail", "--location", "--proto '=https'", "--proto-redir '=https'"):
            with self.subTest(flag=flag):
                self.assertIn(flag, text)


if __name__ == "__main__":
    unittest.main()
