#!/usr/bin/env python3
"""Fails if text contains a private value, without ever storing or printing one.

Two kinds of checks:
  - Patterns (below, safe to publish): AWS account IDs, Okta org names and app IDs,
    personal email addresses, and signed tokens (JWTs, such as a Fleet license key).
  - Hashes: values no pattern can single out (the Fleet hostname, the domain, the state
    bucket, keys and tokens) are listed only as SHA-256 hashes of their lowercase form,
    in a file outside the repo (local hooks) or the PRIVATE_HASHES secret (CI). The
    text is split into candidate pieces (hostnames, URL parts, and every run of
    ./@/-/_-separated segments), and each piece's hash is compared with the list.

Reports the input line and rule that matched, never the text.

  check-private-values.py LABEL [--hashes FILE] < text     check text (exit 1 on a match)
  check-private-values.py --add [--hashes FILE]             add a value's hash (prompts, no echo)

Default hashes file: $FLEET_HOMELAB_PRIVATE_HASHES or ~/.config/fleet-homelab/private-hashes.
"""
import getpass
import hashlib
import os
import re
import sys

DEFAULT_HASHES = os.environ.get(
    "FLEET_HOMELAB_PRIVATE_HASHES",
    os.path.expanduser("~/.config/fleet-homelab/private-hashes"),
)

# (rule name, compiled pattern, values allowed through: documented placeholders)
PATTERNS = [
    (
        "AWS account ID",
        # 12 digits standing alone (not inside a longer number or a hex hash, such as
        # the lock file's); GitHub job and run IDs in links are not account IDs.
        re.compile(r"(?<![0-9A-Za-z])(?<!/job/)(?<!/runs/)[0-9]{12}(?![0-9A-Za-z])"),
        {"123456789012", "000000000000"},
    ),
    ("Okta org name", re.compile(r"\btrial-[0-9]{5,}\b"), {"trial-0000000", "trial-1234567"}),
    (
        "Okta org URL",
        re.compile(r"\b[a-z0-9-]+\.okta(?:preview|-emea)?\.com\b", re.IGNORECASE),
        {"developer.okta.com", "help.okta.com", "support.okta.com", "saml-doc.okta.com",
         "www.okta.com", "login.okta.com", "example.okta.com", "trial-0000000.okta.com"},
    ),
    ("Okta app or client ID", re.compile(r"\b0oa[0-9A-Za-z]{17}\b"), {"0oaXXXXXXXXXXXXXXXXX"}),
    (
        "email address",
        re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}"),
        None,  # allowed by domain, below
    ),
    ("signed token (JWT)", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), set()),
]
ALLOWED_EMAIL_DOMAINS = {"example.com", "example.org", "example.net", "github.com", "anthropic.com"}  # github.com: noreply and Dependabot sign-offs

TOKEN = re.compile(r"[A-Za-z0-9._@+-]+")
SEPARATORS = re.compile(r"([._@-])")


def load_hashes(path):
    if not path or not os.path.isfile(path):
        return set()
    with open(path) as f:
        return {
            line.strip().lower()
            for line in f
            if re.fullmatch(r"\s*[0-9a-fA-F]{64}\s*", line)
        }


def digest(value):
    return hashlib.sha256(value.lower().encode()).hexdigest()


def pieces(token):
    """Every run of consecutive segments, keeping the separators between them."""
    parts = SEPARATORS.split(token)  # [seg, sep, seg, sep, seg, ...]
    segs = parts[0::2]
    seps = parts[1::2]
    for i in range(len(segs)):
        run = segs[i]
        if run:
            yield run
        for j in range(i + 1, len(segs)):
            run += seps[j - 1] + segs[j]
            yield run


def email_allowed(match):
    domain = match.split("@", 1)[1].lower()
    return any(domain == d or domain.endswith("." + d) for d in ALLOWED_EMAIL_DOMAINS)


def check(label, text, hashes):
    found = []
    for n, line in enumerate(text.splitlines(), 1):
        for name, pattern, allowed in PATTERNS:
            for m in pattern.finditer(line):
                value = m.group(0)
                if allowed is None:
                    if not email_allowed(value):
                        found.append((n, name))
                elif value.lower() not in {a.lower() for a in allowed}:
                    found.append((n, name))
        if hashes:
            for tok in TOKEN.findall(line):
                if any(digest(p) in hashes for p in pieces(tok)):
                    found.append((n, "a listed private value"))
                    break
    for n, name in sorted(set(found)):
        print(f"Private value in {label}, line {n}: {name}.", file=sys.stderr)
    return 1 if found else 0


def add(path):
    value = getpass.getpass("Value to add (not echoed): ").strip()
    if not value:
        sys.exit("Nothing entered.")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    existing = load_hashes(path)
    h = digest(value)
    if h in existing:
        print("Already listed.")
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(h + "\n")
    print(f"Added. {len(existing) + 1} hash(es) in {path}. Run scripts/sync-private-hashes.sh to update CI.")


def main(argv):
    hashes_path = DEFAULT_HASHES
    if "--hashes" in argv:
        i = argv.index("--hashes")
        hashes_path = argv[i + 1]
        del argv[i:i + 2]
    if argv[:1] == ["--add"]:
        add(hashes_path)
        return 0
    label = argv[0] if argv else "input"
    return check(label, sys.stdin.read(), load_hashes(hashes_path))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
