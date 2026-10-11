# Instructions for AI assistants

Rules for any AI assistant working in or reviewing this repo (Claude Code, GitHub Copilot and others). People should start with the [README](README.md) and the [setup guide](docs/setup.md).

## What this repo is

Terraform for a homelab Fleet Premium deployment on AWS (`us-east-1`), built from Fleet's own `fleet-terraform` modules and torn down between sessions to keep costs low.
- **Fleet's configuration:** lives in the separate `fleet-homelab-gitops` repo.
- **Design and history:** [`docs/specs/`](docs/specs/fleet-homelab-aws-design.md) is the current design; [`docs/plans/`](docs/plans/fleet-homelab-aws-deployment.md) records how each part was built, task by task.
- **Checks:** all lint checks, tests and guards are in [`checks/`](checks/README.md).

## Fleet's own approach (prefer it)

This project follows Fleet's documented approach wherever it can. Before changing or reviewing something, check what Fleet does, and call out deviations.

- [Fleet docs](https://fleetdm.com/docs) and [guides](https://fleetdm.com/guides).
- [`fleet-terraform`](https://github.com/fleetdm/fleet-terraform): the modules this repo uses, pinned to release tags. Read the module source before assuming what an input does.
- [Deploying Fleet](https://fleetdm.com/docs/deploy/deploy-fleet) and the [reference architectures](https://fleetdm.com/docs/deploy/reference-architectures), for sizing (this repo's smaller sizing is explained in the spec).
- [Fleet server configuration](https://fleetdm.com/docs/configuration/fleet-server-configuration), for the environment variables set in `fleet.tf`.
- For anything in the GitOps repo: [Fleet's GitOps reference](https://fleetdm.com/docs/configuration/yaml-files), and Fleet's own GitOps setup for its company devices, [`fleetdm/fleet/it-and-security`](https://github.com/fleetdm/fleet/tree/main/it-and-security).

## Hard rules

- **No private or identifying values, anywhere.** That covers files, commit messages, branch names, and PR titles, bodies and comments. Private values include the real hostname or domain, the AWS account ID (and ARNs or bucket names that contain it), Okta org names, IDs and URLs, email addresses, and any credential.
  - Use placeholders: `fleet.example.com`, `example.com`, `123456789012`, `<aws-account-id>`.
  - In tests and examples, label placeholders as placeholders.
  - Real values live only in gitignored files (`terraform.tfvars`, `backend.hcl`, `okta/terraform.tfvars`) and in GitHub secrets.
- **Never create a plaintext copy of a private value:** no extra files, secrets, logs or scan lists. The private-values check stores only hashes.
- **Never change identity-provider group membership** (Okta, or any other IdP), in Terraform or by hand. Membership is set by a person.
- **Every change goes through a pull request.** `main` has no bypass. Branch from an up-to-date `origin/main`, and before adding commits to an existing branch, check that its pull request is still open. Merges are the owner's call.
- **Ask before anything that costs money or destroys data.** That includes `scripts/up.sh` and `scripts/down.sh` (the stack bills by the hour while up), `terraform apply` or `destroy`, and the `allow-destroy` label.

## How to work here

- **Run the checks before pushing:** `checks/run.sh` (after `checks/install-tools.sh` once). It runs the same checks as CI.
- **Apply `oidc.tf` and `okta/` locally, never from CI:** the CI roles can't change themselves, and Okta is applied from a person's machine.
- **Keep the docs matching the code:**
  - **The spec** says what the design is now.
  - **The plan** is a record. Add a dated note when something changes, and state rules, not incident stories.
  - **User-facing pages** (the READMEs, `docs/setup.md`) use rounded figures (about $0.25 an hour, $15 a month on average). The spec and plan keep exact figures.
- **Use the data-loss guard:** a plan that destroys or replaces stateful resources (the database, secrets, buckets, DNS, the certificate) fails its check on purpose. Don't work around it; explain the change and let the owner decide on `allow-destroy`.

## When reviewing a pull request

Focus on, in order:
1. Private or identifying values, anywhere in the change.
2. Security: IAM scope, the CI trust policies, workflow permissions, untrusted input in `run:` steps, unpinned actions.
3. Anything that loses data across a teardown (see "What survives a teardown" in the README).
4. Departures from Fleet's documented approach, unless the spec explains them.
5. Docs that no longer match the code.

Skip style nits that the linters already enforce.
