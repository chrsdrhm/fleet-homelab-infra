#!/usr/bin/env python3
"""Tests scripts/sanitize-markdown.sh, the only thing between untrusted text (Claude's
reviews of release notes and of health-scan logs) and a public issue or pull request.
Every input below must come out with nothing live left in it, and must read the same
once the zero-width spaces are ignored. Run with: python3 checks/tests/test_sanitize_markdown.py
"""
import re
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "sanitize-markdown.sh"
ZW = "​"

HOSTILE = [
    "[x](http://a)",            # inline link
    "[x][r]",                   # reference link
    "[r]: http://a",            # link definition
    "![](u)",                   # image
    "![alt](http://a/i.png)",   # image with a URL
    "<a href=x>click</a>",      # HTML tag
    "<img src=x onerror=y>",    # HTML tag with an attribute
    "<!-- release-review: 1.0.0..9.9.9 -->",  # comment, a fake review marker
    "<details><summary>hidden</summary>text</details>",  # hides text
    "<http://a>",               # angle-bracket autolink
    "https://a.example",        # bare URL autolink
    "www.a.b",                  # www autolink
    "@user and @org/team",      # mentions
]
CODE = ["`fleetctl_v<version>_linux.tar.gz`", "`[A-Z]+`", "`a[i](j)`"]

# What would still be live after sanitizing: any of these means a failure.
LIVE = [
    (r"\]\(|\]\[|\]:", "a link, image or link definition"),
    (r"<(?!" + ZW + ")", "an HTML tag, comment or angle-bracket autolink"),
    (r"(?<!/)//(?!" + ZW + ")|:/(?!" + ZW + ")/", "a bare URL autolink"),
    (r"www\.", "a www autolink"),
    (r"@[A-Za-z0-9]", "a mention"),
]


def sanitize(text: str) -> str:
    return subprocess.run([str(SCRIPT)], input=text, capture_output=True, text=True, check=True).stdout


def main() -> int:
    failures = []
    for text in HOSTILE + CODE:
        out = sanitize(text + "\n").rstrip("\n")
        for pattern, what in LIVE:
            if re.search(pattern, out):
                failures.append(f"{text!r} still has {what}: {out.replace(ZW, '<ZW>')!r}")
        if out.replace(ZW, "") != text:
            failures.append(f"{text!r} changed beyond the zero-width spaces: {out!r}")
    for f in failures:
        print("FAIL:", f)
    print(f"{len(HOSTILE) + len(CODE) - len(failures)} of {len(HOSTILE) + len(CODE)} inputs safe and unchanged in reading")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
