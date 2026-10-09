"""Turns a `terraform plan` log into a short, redacted Markdown summary for a PR comment.

Only the plan line and the addresses of changing resources are kept. Quoted for_each
keys are replaced (they can hold hostnames), every value passed in R1..R9 is masked,
and the script refuses to print anything if a 12-digit number (an account ID) remains.
"""
import os
import re
import sys

ACTIONS = {
    "will be created": "create",
    "will be updated in-place": "update",
    "will be destroyed": "destroy",
    "must be replaced": "replace",
    "will be replaced": "replace",
    "will be read during apply": "read",
}

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
secrets = [v for k, v in os.environ.items() if re.fullmatch(r"R\d", k) and v]

changes, headline = [], None
pattern = re.compile(r"^\s*# (\S.*?) (" + "|".join(map(re.escape, ACTIONS)) + r")")
for line in text.splitlines():
    match = pattern.match(line)
    if match:
        address = re.sub(r'\["[^"]*"\]', '["…"]', match.group(1))
        changes.append((ACTIONS[match.group(2)], address))
    elif headline is None and (line.startswith("Plan:") or line.startswith("No changes.")):
        headline = line.strip()

code = os.environ.get("EXITCODE", "")
run_url = os.environ.get("RUN_URL", "")
out = ["<!-- terraform-plan -->", "### Terraform plan", ""]
if code == "1":
    out.append("**The plan failed.** The error is in the masked run log, not here, because error text can include identifiers.")
else:
    out.append(f"**{headline or 'No plan line found.'}**")
    if changes:
        out += ["", "| Action | Resource |", "|---|---|"]
        out += [f"| {action} | `{address}` |" for action, address in changes[:100]]
        if len(changes) > 100:
            out.append(f"| … | {len(changes) - 100} more |")
out += ["", f"Full plan, with secret values masked: [run log]({run_url})."]
body = "\n".join(out) + "\n"

for value in secrets:
    body = body.replace(value, "***")
# Safety net for values nobody passed in: an AWS account ID is 12 digits.
if re.search(r"(?<!\d)\d{12}(?!\d)", body):
    sys.exit("refusing to post: the summary contains a 12-digit number (an AWS account ID?)")
sys.stdout.write(body)
