#!/usr/bin/env python3
"""Self-test for checks/private-values/check.py, using phony values only.

Every "private" value below is made up. Each one is assembled at runtime from two
pieces, so this file does not itself contain anything the checker would flag (it runs
on its own pull requests too). Run with: python3 checks/tests/test_private_values.py
"""
import hashlib
import importlib.util
import io
import os
import sys
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("cpv", os.path.join(HERE, "..", "private-values", "check.py"))
cpv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpv)

# Phony values, split so the literals never appear whole in this file.
ACCOUNT = "9876" + "54321098"
OKTA_ORG = "trial-" + "4242424"
OKTA_HOST = "acme-corp.ok" + "ta.com"
OKTA_ID = "0oa" + "Ab3dEf5hIj7kLm9nO"
EMAIL = "jane.doe@" + "gmail.com"
JWT = "eyJ" + "hbGciOiJIUzI1NiJ9" + ".eyJ" + "zdWIiOiJwaG9ueSJ9" + ".c2lnbmF0dXJl" + "LXBob255"
HOSTNAME = "fleet." + "phony-lab.dev"
BUCKET = "phony-" + "state-bucket"
HEADER = "f00d" + "c0ffee" * 9
HASHES = {hashlib.sha256(v.lower().encode()).hexdigest() for v in (HOSTNAME, BUCKET, HEADER)}


def run(text, hashes=HASHES):
    err = io.StringIO()
    with redirect_stderr(err):
        code = cpv.check("test input", text, hashes)
    return code, err.getvalue()


class Patterns(unittest.TestCase):
    def flagged(self, text, rule):
        code, out = run(text, set())
        self.assertEqual(code, 1, f"expected {rule!r} to be flagged")
        self.assertIn(rule, out)

    def clean(self, text):
        code, out = run(text, set())
        self.assertEqual(code, 0, f"expected no finding, got: {out}")

    def test_account_id(self):
        self.flagged(f"account {ACCOUNT}", "AWS account ID")
        self.flagged(f"arn:aws:iam::{ACCOUNT}:role/x", "AWS account ID")
        self.clean("arn:aws:iam::123456789012:role/x")  # AWS's documented example
        self.clean("https://github.com/o/r/actions/runs/1/job/" + "1142" + "83005335")
        self.clean("id=" + "6457" + "314797278624365")  # longer numbers are not account IDs
        self.clean('"zh:' + "0f3a" + "123456789012" + "ab9c" + '"')  # 12 digits inside a hex hash
        self.flagged(f"fleet-homelab-tfstate-{ACCOUNT}", "AWS account ID")  # bucket names

    def test_okta(self):
        self.flagged(f"org {OKTA_ORG}", "Okta org name")
        self.flagged(f"https://{OKTA_HOST}/app/x", "Okta org URL")
        self.flagged(f"client {OKTA_ID}", "Okta app or client ID")
        self.clean('okta_org_name = "trial-0000000"')
        self.clean("see https://developer.okta.com/docs")
        self.clean('okta_client_id = "0oaXXXXXXXXXXXXXXXXX"')

    def test_email(self):
        self.flagged(f"mail {EMAIL}", "email address")
        self.clean("budget@example.com")
        self.clean("Co-Authored-By: Claude <noreply@anthropic.com>")
        self.clean("1+octo@users.noreply.github.com")
        self.clean("Signed-off-by: dependabot[bot] <support@github.com>")

    def test_jwt(self):
        self.flagged(f"license {JWT}", "signed token (JWT)")


class Hashes(unittest.TestCase):
    def test_listed_values_are_found_in_context(self):
        for text in (
            f"https://{HOSTNAME}/healthz",
            f"FLEET_URL={HOSTNAME.upper()}",  # case-insensitive
            f"arn:aws:s3:::{BUCKET}/terraform.tfstate",
            f"x-fleet-ci: {HEADER}",
            f"bucket = \"{BUCKET}\"",
        ):
            code, out = run(text)
            self.assertEqual(code, 1, f"not flagged: {text}")
            self.assertIn("a listed private value", out)

    def test_partial_matches_are_not_flagged(self):
        for text in ("fleet.phony-lab.devx", "notfleet.phony-lab.dev.example", "phony-state", "f00dc0ffee"):
            self.assertEqual(run(text)[0], 0, f"false positive: {text}")

    def test_output_never_contains_the_value(self):
        text = "\n".join([HOSTNAME, BUCKET, HEADER, ACCOUNT, OKTA_ORG, OKTA_HOST, OKTA_ID, EMAIL, JWT])
        code, out = run(text)
        self.assertEqual(code, 1)
        for value in (HOSTNAME, BUCKET, HEADER, ACCOUNT, OKTA_ORG, OKTA_HOST, OKTA_ID, EMAIL, JWT):
            self.assertNotIn(value.lower(), out.lower())

    def test_clean_text_passes(self):
        self.assertEqual(run("terraform plan -var-file=terraform.tfvars\nPlan: 0 to add")[0], 0)


class Maintenance(unittest.TestCase):
    """--from-tfvars, --add, --remove and --list, against phony files in a temp folder."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        self.hashes = os.path.join(self.root, "private-hashes")
        os.makedirs(os.path.join(self.root, "okta"))
        with open(os.path.join(self.root, "terraform.tfvars"), "w") as f:
            f.write(f'fleet_subdomain = "{HOSTNAME}"\nwaf_ci_header_value = "{HEADER}"\ngithub_owner = "octo"\n')
        with open(os.path.join(self.root, "backend.hcl"), "w") as f:
            f.write(f'bucket = "{BUCKET}"\n')
        # No AWS during tests: pretend the CLI returns a phony account ID.
        self.real_run = cpv.subprocess.run
        cpv.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout=ACCOUNT + "\n")

    def tearDown(self):
        cpv.subprocess.run = self.real_run
        self.dir.cleanup()

    def quiet(self, *argv, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        old = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with redirect_stdout(out), redirect_stderr(err):
                cpv.main(list(argv) + ["--hashes", self.hashes])
        finally:
            sys.stdin = old
        return out.getvalue() + err.getvalue()

    def test_from_tfvars_labels_and_never_stores_plaintext(self):
        out = self.quiet("--from-tfvars", self.root)
        entries = cpv.load_hashes(self.hashes)
        self.assertEqual(
            sorted(entries.values()),
            ["aws account id", "fleet hostname", "terraform state bucket", "waf ci header value"],
        )
        with open(self.hashes) as f:
            stored = f.read().lower()
        for value in (HOSTNAME, HEADER, BUCKET, ACCOUNT):
            self.assertNotIn(value.lower(), stored)
            self.assertNotIn(value.lower(), out.lower())
        self.assertEqual(oct(os.stat(self.hashes).st_mode & 0o777), "0o600")
        # The rebuilt list catches the values.
        with redirect_stderr(io.StringIO()):
            self.assertEqual(cpv.check("t", f"https://{HOSTNAME}/", set(entries)), 1)

    def test_rotation_replaces_the_old_hash(self):
        self.quiet("--from-tfvars", self.root)
        old = set(cpv.load_hashes(self.hashes))
        with open(os.path.join(self.root, "terraform.tfvars"), "w") as f:
            f.write(f'fleet_subdomain = "{HOSTNAME}"\nwaf_ci_header_value = "{HEADER[::-1]}"\n')
        self.quiet("--from-tfvars", self.root)
        new = cpv.load_hashes(self.hashes)
        self.assertEqual(len(new), 4)
        self.assertNotIn(cpv.digest(HEADER), new)
        self.assertIn(cpv.digest(HEADER[::-1]), new)
        self.assertTrue(old - set(new))

    def test_add_list_remove(self):
        out = self.quiet("--add", "grafana workspace id", stdin="g-" + "0123abcd99\n")
        self.assertNotIn("0123abcd99", out)
        listed = self.quiet("--list")
        self.assertIn("grafana workspace id", listed)
        self.assertNotIn("0123abcd99", listed)
        self.quiet("--remove", "grafana workspace id")
        self.assertNotIn("grafana workspace id", self.quiet("--list"))


class HashesFile(unittest.TestCase):
    def test_load_ignores_comments_and_junk(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("# comment\n\nnot-a-hash\n" + next(iter(HASHES)) + "  fleet hostname\n")
        try:
            self.assertEqual(list(cpv.load_hashes(f.name).values()), ["fleet hostname"])
        finally:
            os.unlink(f.name)

    def test_missing_file_means_patterns_only(self):
        self.assertEqual(cpv.load_hashes("/nonexistent/private-hashes"), {})


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
