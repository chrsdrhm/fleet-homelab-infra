#!/usr/bin/env python3
"""Fails if text contains a private value, without ever storing or printing one.

Two kinds of checks:
  - Patterns (below, safe to publish): AWS account IDs, Okta org names and app IDs,
    personal email addresses, and signed tokens (JWTs, such as a Fleet license key).
  - Hashes: values no pattern can single out (the Fleet hostname, the domain, the state
    bucket, keys and tokens) are listed only as SHA-256 hashes of their lowercase form,
    each with a plain label ("fleet hostname"), in a file outside the repo (local hooks)
    or the PRIVATE_HASHES secret (CI). The text is split into candidate pieces (every
    run of ./@/-/_-separated segments of each token), and each piece's hash is compared.

Reports the input line and rule that matched, never the text.

  check.py LABEL < text            check text; exit 1 on a match
  check.py --list                  list the labels in the hash list (never values)
  check.py --from-tfvars [DIR]     (re)build the hash list from the infra repo's gitignored
                                   files in DIR (default .) and the AWS account ID
  check.py --add LABEL             add or replace one value (prompted, not echoed)
  check.py --remove LABEL          remove one value
  Any of them: --hashes FILE (default $FLEET_HOMELAB_PRIVATE_HASHES or
  ~/.config/fleet-homelab/private-hashes). After changing the list, run
  sync-hashes.sh (infra repo) so CI uses the same list.
"""
import getpass
import hashlib
import os
import re
import subprocess
import sys

DEFAULT_HASHES = os.environ.get(
    "FLEET_HOMELAB_PRIVATE_HASHES",
    os.path.expanduser("~/.config/fleet-homelab/private-hashes"),
)

# Where --from-tfvars finds each private value in the infra repo, and its label.
TFVARS_SOURCES = [
    ("terraform.tfvars", "fleet_subdomain", "fleet hostname"),
    ("terraform.tfvars", "cloudflare_zone_name", "apex domain"),
    ("terraform.tfvars", "budget_alert_email", "budget alert email"),
    ("terraform.tfvars", "fleet_license_key", "fleet license key"),
    ("terraform.tfvars", "cloudflare_api_token", "cloudflare api token"),
    ("terraform.tfvars", "waf_ci_header_value", "waf ci header value"),
    ("backend.hcl", "bucket", "terraform state bucket"),
    ("okta/terraform.tfvars", "okta_org_name", "okta org name"),
    ("okta/terraform.tfvars", "okta_client_id", "okta client id"),
    ("okta/terraform.tfvars", "okta_private_key_id", "okta key id"),
]
ACCOUNT_LABEL = "aws account id"

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
    """{hash: label} from lines of "<sha256>  <label>"; comments and junk are ignored."""
    entries = {}
    if not path or not os.path.isfile(path):
        return entries
    with open(path) as f:
        for line in f:
            m = re.fullmatch(r"\s*([0-9a-fA-F]{64})(?:\s+(.*?))?\s*", line.rstrip("\n"))
            if m:
                entries[m.group(1).lower()] = (m.group(2) or "").strip()
    return entries


def save_hashes(path, entries):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("# SHA-256 hashes (of the lowercase value) of private values, with plain labels.\n")
        f.write("# No plaintext. Maintain with checks/private-values/check.py; then run sync-hashes.sh.\n")
        for h, label in sorted(entries.items(), key=lambda e: (e[1], e[0])):
            f.write(f"{h}  {label}\n" if label else f"{h}\n")


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


def set_value(entries, label, value):
    """Replace any entry with this label by the value's hash."""
    for h in [h for h, l in entries.items() if l == label]:
        del entries[h]
    entries[digest(value)] = label


def read_value(prompt):
    if sys.stdin.isatty():
        return getpass.getpass(prompt).strip()
    return sys.stdin.readline().strip()


def tfvars_value(path, key):
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        for line in f:
            m = re.match(r'\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"', line)
            if m and m.group(1) == key and m.group(2):
                return m.group(2)
    return None


def from_tfvars(path, root):
    entries = load_hashes(path)
    found, missing = [], []
    for rel, key, label in TFVARS_SOURCES:
        value = tfvars_value(os.path.join(root, rel), key)
        if value:
            set_value(entries, label, value)
            found.append(label)
        else:
            missing.append(label)
    try:
        account = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"],
            capture_output=True, text=True, timeout=30,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        account = ""
    if re.fullmatch(r"[0-9]{12}", account):
        set_value(entries, ACCOUNT_LABEL, account)
        found.append(ACCOUNT_LABEL)
    else:
        missing.append(ACCOUNT_LABEL + " (AWS CLI not logged in; kept as it was)")
    save_hashes(path, entries)
    print(f"Updated {len(found)} value(s) from {os.path.abspath(root)} into {path}.")
    if missing:
        print("Not found, left unchanged: " + ", ".join(missing))
    print(f"{len(entries)} hash(es) in the list. Run sync-hashes.sh to update CI.")


def main(argv):
    path = DEFAULT_HASHES
    if "--hashes" in argv:
        i = argv.index("--hashes")
        path = argv[i + 1]
        del argv[i:i + 2]
    cmd = argv[0] if argv else ""
    if cmd == "--list":
        entries = load_hashes(path)
        for label in sorted(entries.values()):
            print(label or "(unlabelled)")
        print(f"{len(entries)} hash(es) in {path}", file=sys.stderr)
        return 0
    if cmd == "--from-tfvars":
        from_tfvars(path, argv[1] if len(argv) > 1 else ".")
        return 0
    if cmd in ("--add", "--remove"):
        if len(argv) < 2:
            sys.exit(f"Usage: check.py {cmd} LABEL")
        label = " ".join(argv[1:])
        entries = load_hashes(path)
        if cmd == "--remove":
            before = len(entries)
            entries = {h: l for h, l in entries.items() if l != label}
            save_hashes(path, entries)
            print(f"Removed {before - len(entries)} entry(ies) labelled {label!r}.")
            return 0
        value = read_value(f"Value for {label!r} (not echoed): ")
        if not value:
            sys.exit("Nothing entered.")
        set_value(entries, label, value)
        save_hashes(path, entries)
        print(f"Set {label!r}. {len(entries)} hash(es) in {path}. Run sync-hashes.sh to update CI.")
        return 0
    return check(cmd or "input", sys.stdin.read(), set(load_hashes(path)))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
