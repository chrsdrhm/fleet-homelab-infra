# checks

Every lint check, test and guard for this repo lives here, so it's all in one place and can be removed in one go. CI runs the same scripts you can run locally.

| Check | File | Runs | What it does |
|---|---|---|---|
| Private values | `private-values/check.py` | Every PR (`run.sh`), optional local hooks | Fails if a change, file name, commit message, or PR title/body contains a private value. See [below](#private-values). |
| Terraform format and validation | `run.sh` | Every PR | `terraform fmt -check` and `terraform validate` for both roots. |
| Terraform tests | `tests/terraform/security.tftest.hcl` | Every PR | Plans the whole configuration against mocked providers (no AWS) and asserts the CI roles' trust and the apply role's denies, the read-only plan and scan roles, the nightly timer's permissions and time, the WAF rules, the public bucket's scope, the budget and the DNS delegation. |
| Checker self-test | `tests/test_private_values.py` | Every PR | Tests the private-values checker with phony values. |
| Sanitizer test | `tests/test_sanitize_markdown.py` | Every PR | Feeds `scripts/sanitize-markdown.sh` hostile Markdown (links, images, HTML, comments, autolinks, mentions) and checks nothing comes out live and the text reads the same. Claude's reviews pass through it before going anywhere public. |
| shellcheck | `run.sh` | Every PR | Lints the shell scripts and hooks. |
| actionlint | `run.sh` | Every PR | Lints the workflow files, including the shell in `run:` blocks. |
| zizmor | `run.sh`, `zizmor.yml` | Every PR | Security audit of the workflows. Official image, pinned by digest. |
| tflint | `run.sh`, `tflint.hcl` | Every PR | Lints our Terraform (not Fleet's modules) with the AWS ruleset. |
| Data-loss guard | `data-loss-guard.sh` | Every PR's plan, and the apply on merge | Flags a plan that would destroy or replace the database, a secret, a bucket, DNS, the certificate, the SES identity or the server key. The plan check fails unless the PR has the `allow-destroy` label. |
| SSO smoke check | `sso-smoke.sh` | After each `up` | If Fleet reports SSO on, checks that starting a login redirects to the identity provider. Warns, never fails the rebuild. |

All values in the tests and examples are placeholders: `123456789012` is the example account ID from AWS's documentation, `example.com` is reserved for documentation (RFC 2606), and the rest are made up.

## Running them locally

```bash
checks/install-tools.sh            # once: pinned actionlint and tflint into .check-tools/ (gitignored)
checks/run.sh                      # everything (zizmor needs Docker running; skipped otherwise)
checks/run.sh fmt test tflint      # just some
git config core.hooksPath checks/hooks   # optional: check every commit for private values
```

`install-tools.sh` verifies each download against its pinned SHA-256 checksum. Dependabot can't update these pins (or the zizmor digest in `run.sh`); bump a version and its checksum together by hand.

## The local hooks

The hooks in `checks/hooks/` (`pre-commit` and `commit-msg`) run the private-values check on every commit, before anything leaves your machine. CI only checks a pull request after the branch has already been pushed, so the hooks are what actually prevent a leak.

Git doesn't run hooks from a repo on its own; each clone has to opt in once:

```bash
git config core.hooksPath checks/hooks
```

That setting is saved in the clone's own `.git/config`, not in the repo, so every new clone needs it again. `.git/` is git's internal folder; VS Code and most file browsers hide it, and it is never committed or pushed. To check or change the setting, use `git config` rather than editing the file:

```bash
git config core.hooksPath                  # shows checks/hooks when the hooks are on
git config --local --list                  # every setting this clone has in .git/config
git config --unset core.hooksPath          # turn the hooks off
```

To skip the hooks for one commit, use `git commit --no-verify`. CI still runs the same check on the pull request.

## Removing them

Delete this folder. Nothing else breaks:

- The lint job falls back to `terraform fmt` and `terraform validate`
- The plan job skips the data-loss guard, and the apply on merge fails closed: any destroy or replace, not only of data-holding resources, then needs the `allow-destroy` label
- `scripts/up.sh` skips the SSO check

If the hooks were on, also run `git config --unset core.hooksPath`.

## Private values

The checker catches private values two ways, and never stores or prints one.

- **Patterns** (in `check.py`, safe to publish): AWS account IDs, Okta org names, URLs and app IDs, personal email addresses, and signed tokens (JWTs). They need no setup, so they also run on forks.
- **Hashes** for values no pattern can single out, such as a hostname. Only the SHA-256 hash of each value (lowercased) is kept, with a plain label like `fleet hostname`. There are two copies of the list:
  - `~/.config/fleet-homelab/private-hashes`: the source of truth, used by the hooks
  - The `PRIVATE_HASHES` secret: in both repos, in both the Actions and Dependabot stores, for CI

A hash fully hides a long random value such as a token. A guessable value such as a domain can still be confirmed by someone who hashes their guess, so treat the list as private, not secret-proof.

### Keeping the hash list current

| When | Do |
|---|---|
| You rotate the Cloudflare token, WAF header, license key or Okta key | `check.py --from-tfvars`, then `sync-hashes.sh` |
| The hostname, domain, state bucket, Okta org or AWS account changes | Same |
| You add an identifying value that isn't in the tfvars (e.g. a Roles Anywhere trust anchor ID) | `check.py --add "trust anchor id"` (prompts, no echo), then `sync-hashes.sh` |
| A value is gone for good | `check.py --remove "label"`, then `sync-hashes.sh` |
| You want to see what's covered | `check.py --list` (labels only) |
| The local file is lost | `check.py --from-tfvars`, then re-add any extras, then `sync-hashes.sh` |

Commands run from the infra repo root:

```bash
python3 checks/private-values/check.py --from-tfvars    # rebuild from terraform.tfvars, backend.hcl, okta/terraform.tfvars and the AWS account
python3 checks/private-values/check.py --list
checks/private-values/sync-hashes.sh                     # copy the list to all four PRIVATE_HASHES secrets
```

`--from-tfvars` replaces each value's old hash by label, so a rotated value's old hash is dropped. It keeps any extra entries you added with `--add`.

Always run `sync-hashes.sh` after a change. GitHub never shows a secret's value again, so this is the only way to update CI's copy.
