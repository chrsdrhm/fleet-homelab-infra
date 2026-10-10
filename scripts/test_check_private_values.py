#!/usr/bin/env python3
"""Self-test for check-private-values.py, using phony values only.

Every "private" value below is made up. Each one is assembled at runtime from two
pieces, so this file does not itself contain anything the checker would flag (it runs
on its own pull requests too). Run with: python3 scripts/test_check_private_values.py
"""
import hashlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("cpv", os.path.join(HERE, "check-private-values.py"))
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


class HashesFile(unittest.TestCase):
    def test_load_ignores_comments_and_junk(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("# comment\n\nnot-a-hash\n" + next(iter(HASHES)) + "\n")
        try:
            self.assertEqual(len(cpv.load_hashes(f.name)), 1)
        finally:
            os.unlink(f.name)

    def test_missing_file_means_patterns_only(self):
        self.assertEqual(cpv.load_hashes("/nonexistent/private-hashes"), set())


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
