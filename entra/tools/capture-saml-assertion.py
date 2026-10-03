#!/usr/bin/env python3
"""Capture and decode the SAML assertion Entra sends for the Fleet app, without Fleet.

Why: the portal can't show what Entra actually emits (claim names, NameID value,
which certificate signed). This starts a one-shot listener on localhost, sends an
SP-initiated AuthnRequest, and prints what Entra posts back.

Usage (from entra/):
  1. terraform apply -var-file=terraform.tfvars -var 'debug_reply_urls=["http://localhost:8765/acs"]'
  2. TENANT=<tenant id> ENTITY_ID=https://<fleet_subdomain> python3 tools/capture-saml-assertion.py
  3. open http://localhost:8765/start and sign in; read /tmp/saml_result.json
  4. terraform apply -var-file=terraform.tfvars        # removes the localhost reply URL
Delete /tmp/saml_response.xml afterwards: it holds the signed assertion.
"""
import base64, zlib, uuid, datetime, urllib.parse, json, os, hashlib, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import xml.etree.ElementTree as ET

TENANT = os.environ["TENANT"]; ISSUER = os.environ["ENTITY_ID"]; PORT = 8765
ACS = f"http://localhost:{PORT}/acs"
NS = {"samlp": "urn:oasis:names:tc:SAML:2.0:protocol", "saml": "urn:oasis:names:tc:SAML:2.0:assertion", "ds": "http://www.w3.org/2000/09/xmldsig#"}

def authn_url():
    rid = "_" + uuid.uuid4().hex
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    req = (f'<samlp:AuthnRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" '
           f'ID="{rid}" Version="2.0" IssueInstant="{now}" AssertionConsumerServiceURL="{ACS}" '
           f'ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"><saml:Issuer>{ISSUER}</saml:Issuer></samlp:AuthnRequest>')
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw = c.compress(req.encode()) + c.flush()
    return f"https://login.microsoftonline.com/{TENANT}/saml2?SAMLRequest=" + urllib.parse.quote(base64.b64encode(raw).decode(), safe="")

def analyze(xml_bytes):
    root = ET.fromstring(xml_bytes)
    out = {"status": root.find("samlp:Status/samlp:StatusCode", NS).get("Value")}
    msg = root.find("samlp:Status/samlp:StatusMessage", NS)
    if msg is not None: out["status_message"] = msg.text
    out["issuer"] = (root.find("saml:Issuer", NS).text if root.find("saml:Issuer", NS) is not None else None)
    nid = root.find(".//saml:Subject/saml:NameID", NS)
    if nid is not None: out["name_id"] = {"value": nid.text, "format": nid.get("Format")}
    aud = root.find(".//saml:Audience", NS)
    out["audience"] = aud.text if aud is not None else None
    out["attributes"] = {a.get("Name"): [v.text for v in a.findall("saml:AttributeValue", NS)] for a in root.iter("{%s}Attribute" % NS["saml"])}
    out["signature_on_response"] = root.find("ds:Signature", NS) is not None
    out["signature_on_assertion"] = root.find("saml:Assertion/ds:Signature", NS) is not None
    out["signing_cert_sha1"] = [hashlib.sha1(base64.b64decode(c.text)).hexdigest().upper() for c in root.iter("{%s}X509Certificate" % NS["ds"])]
    return out

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(302); self.send_header("Location", authn_url()); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        form = urllib.parse.parse_qs(body)
        xml = base64.b64decode(form["SAMLResponse"][0])
        open("/tmp/saml_response.xml", "wb").write(xml)
        open("/tmp/saml_result.json", "w").write(json.dumps(analyze(xml), indent=2))
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<h3>Assertion captured. You can close this tab and return to the terminal.</h3>")
        threading.Thread(target=self.server.shutdown).start()

srv = HTTPServer(("127.0.0.1", PORT), H)
srv.timeout = 600
t = threading.Timer(600, srv.shutdown); t.daemon = True; t.start()
srv.serve_forever()
srv.server_close()
