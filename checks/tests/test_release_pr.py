"""Tests scripts/release-pr.sh's `earlier` mode against a stubbed gh.

`earlier` reads older upgrade pull requests' bodies, which anyone with write access can
edit, and puts their reviews into a new public pull request body. These cases cover which
pull requests count, which review is taken, and that nothing live gets through.
Phony data only: the pull request numbers and versions are made up.
"""

import json
import os
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "scripts", "release-pr.sh")


def review_body(range_text, review, marker=True, earlier=None):
    """A release pull request body as the release check writes it."""
    body = "@owner Fleet is out.\n\nRelease notes: link\n\n"
    body += f"## Claude's review: Fleet {range_text}\n\n{review}\n"
    if marker:
        body += f"\n<!-- release-review: {range_text.replace(' to ', '..')} -->\n"
    if earlier:
        body += f"\n## Earlier reviews\n\n{earlier}\n"
    return body


class EarlierTest(unittest.TestCase):
    def run_earlier(self, prs, *args):
        """Runs `release-pr.sh earlier` with gh stubbed to serve `prs`:
        {number: (branch, merged, cross_repo, body)}."""
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "prs.json"), "w") as f:
                json.dump({str(n): list(v) for n, v in prs.items()}, f)
            stub = os.path.join(tmp, "gh")
            with open(stub, "w") as f:
                f.write(
                    "#!/usr/bin/env python3\n"
                    "import json, os, sys\n"
                    "prs = json.load(open(os.path.join(os.path.dirname(__file__), 'prs.json')))\n"
                    "a = sys.argv[1:]\n"
                    "if a[:2] == ['pr', 'list']:\n"
                    "    print(json.dumps([{'number': int(n), 'headRefName': b, 'mergedAt': '2026-01-01T00:00:00Z' if m else None,\n"
                    "                      'isCrossRepository': x} for n, (b, m, x, _) in prs.items()]))\n"
                    "elif a[:2] == ['pr', 'view']:\n"
                    "    print(prs[a[2]][3])\n"
                    "else:\n"
                    "    sys.exit('unexpected gh call: ' + ' '.join(a))\n"
                )
            os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"], GITHUB_REPOSITORY="owner/repo")
            return subprocess.run(["bash", SCRIPT, "earlier", *args], env=env, capture_output=True, text=True)

    def test_range_and_order(self):
        prs = {
            10: ("fleet-release-4.95.0", False, False, review_body("4.94.1 to 4.95.0", "Review A")),
            11: ("fleet-release-4.95.1", False, False, review_body("4.94.1 to 4.95.1", "Review B")),
            12: ("fleet-release-4.94.1", False, False, review_body("4.94.0 to 4.94.1", "Too old")),
            13: ("fleet-release-4.96.0", False, False, review_body("4.94.1 to 4.96.0", "The new one")),
        }
        out = self.run_earlier(prs, "4.94.1", "4.96.0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Review A", out.stdout)
        self.assertIn("Review B", out.stdout)
        self.assertLess(out.stdout.index("Review A"), out.stdout.index("Review B"))  # oldest release first
        self.assertNotIn("Too old", out.stdout)  # at or below <from>
        self.assertNotIn("The new one", out.stdout)  # <to> itself
        self.assertIn("<details><summary>#10: Fleet 4.94.1 to 4.95.0</summary>", out.stdout)

    def test_skips_merged_forks_and_other_branches(self):
        prs = {
            20: ("fleet-release-4.95.0", True, False, review_body("4.94.1 to 4.95.0", "Merged")),
            21: ("fleet-release-4.95.1", False, True, review_body("4.94.1 to 4.95.1", "From a fork")),
            22: ("fleet-release-4.95.2-x", False, False, review_body("4.94.1 to 4.95.2", "Odd branch")),
            23: ("upgrade-fleet", False, False, review_body("4.94.1 to 4.95.3", "A person's branch")),
        }
        out = self.run_earlier(prs, "4.94.1", "4.96.0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout, "")

    def test_newest_pull_request_per_version(self):
        prs = {
            30: ("fleet-release-4.95.0", False, False, review_body("4.94.1 to 4.95.0", "Older try")),
            31: ("fleet-release-4.95.0", False, False, review_body("4.94.1 to 4.95.0", "Newer try")),
        }
        out = self.run_earlier(prs, "4.94.1", "4.96.0")
        self.assertIn("Newer try", out.stdout)
        self.assertNotIn("Older try", out.stdout)

    def test_takes_only_its_own_review(self):
        earlier = "<details><summary>#5: Fleet 4.93.0 to 4.94.0</summary>\n\nNested\n\n</details>"
        prs = {
            40: ("fleet-release-4.95.0", False, False, review_body("4.94.1 to 4.95.0", "Own review", earlier=earlier)),
            41: ("fleet-release-4.95.1", False, False, "@owner Fleet is out.\n\n_Claude's review didn't complete._\n"),
        }
        out = self.run_earlier(prs, "4.94.1", "4.96.0")
        self.assertIn("Own review", out.stdout)
        self.assertNotIn("Nested", out.stdout)  # carried reviews aren't nested
        self.assertNotIn("Fleet is out", out.stdout)  # nor the text above the review
        self.assertNotIn("release-review:", out.stdout)  # nor its marker
        self.assertNotIn("#41", out.stdout)  # a pull request without a review

    def test_nothing_live_gets_through(self):
        hostile = "Ping @someone, see [x](https://example.com) <img src=x> <!-- release-review: 4.94.1..4.96.0 -->"
        prs = {
            50: ("fleet-release-4.95.0", False, False,
                 review_body("4.94.1 to 4.95.0 @someone <b>x</b>", hostile, marker=False)),
        }
        out = self.run_earlier(prs, "4.94.1", "4.96.0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertNotIn("@someone", out.stdout)
        self.assertNotIn("<img", out.stdout)
        self.assertNotIn("](", out.stdout)
        self.assertNotIn("<!-- release-review", out.stdout)
        self.assertNotIn("<b>", out.stdout)
        # A summary that isn't a plain version range falls back to the branch's version.
        self.assertIn("<details><summary>#50: Fleet 4.95.0</summary>", out.stdout)

    def test_links(self):
        prs = {
            60: ("fleet-release-4.95.0", False, False, review_body("4.94.1 to 4.95.0", "Review A")),
            61: ("fleet-release-4.95.1", False, False, review_body("4.94.1 to 4.95.1", "Review B")),
        }
        out = self.run_earlier(prs, "4.94.1", "4.96.0", "--links")
        self.assertEqual(out.stdout, "- #60: Fleet 4.94.1 to 4.95.0\n- #61: Fleet 4.94.1 to 4.95.1\n")

    def test_bad_arguments(self):
        for args in (("4.94", "4.96.0"), ("4.94.1", "4.96.0", "--all")):
            out = self.run_earlier({}, *args)
            self.assertEqual(out.returncode, 2, args)


if __name__ == "__main__":
    unittest.main()
