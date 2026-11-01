// Starts the nightly check: dispatches terraform.yml with action=nightly on main (plan
// Task 37). EventBridge Scheduler calls it at 2:17am Chicago time, because GitHub's own
// schedule often starts hours late. It signs in as a GitHub App (Actions read and write,
// installed on this repo only) whose client ID and private key are SSM parameters, set
// by hand: neither is in Terraform state or the repo. No dependencies: the JWT is signed
// with node:crypto, and the AWS SDK comes with the Lambda runtime.
import { createSign } from "node:crypto";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

const { REPO, CLIENT_ID_PARAMETER, KEY_PARAMETER } = process.env;
const ssm = new SSMClient({});

const parameter = async (name, decrypt) =>
  (await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: decrypt }))).Parameter.Value;

const base64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

// A JWT that signs in as the app itself, valid for ten minutes (GitHub's limit), back-
// dated a minute against clock drift.
function appJwt(clientId, privateKey) {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${base64url({ alg: "RS256", typ: "JWT" })}.${base64url({ iat: now - 60, exp: now + 540, iss: clientId })}`;
  return `${unsigned}.${createSign("RSA-SHA256").update(unsigned).sign(privateKey, "base64url")}`;
}

async function github(path, token, method = "GET", body) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "user-agent": "fleet-homelab-nightly",
      "x-github-api-version": "2022-11-28",
      ...(body && { "content-type": "application/json" }),
    },
    body: body && JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`GitHub ${method} ${path} returned HTTP ${response.status}: ${await response.text()}`);
  }
  return response.status === 204 ? null : response.json();
}

export async function handler() {
  const [clientId, privateKey] = await Promise.all([
    parameter(CLIENT_ID_PARAMETER, false),
    parameter(KEY_PARAMETER, true),
  ]);
  const jwt = appJwt(clientId, privateKey);
  const installation = await github(`/repos/${REPO}/installation`, jwt);
  // A token for this one repo with Actions write only, whatever else the app is given.
  const { token } = await github(`/app/installations/${installation.id}/access_tokens`, jwt, "POST", {
    repositories: [REPO.split("/")[1]],
    permissions: { actions: "write" },
  });
  try {
    await github(`/repos/${REPO}/actions/workflows/terraform.yml/dispatches`, token, "POST", {
      ref: "main",
      inputs: { action: "nightly" },
    });
    console.log("Started the nightly check (terraform.yml, action=nightly).");
  } finally {
    await github("/installation/token", token, "DELETE").catch(() => {});
  }
}
