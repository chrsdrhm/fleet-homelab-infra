# Image shown on Fleet's login button for the IdP (org_settings.sso_settings.idp_image_url).
# The browser of someone who has not logged in yet loads it, so it must be publicly
# readable. Kept deliberately tiny and separate from the (private) software-installers
# bucket: one object, read-only, no listing, no writes. Persistent: not part of teardown.
#
# The image itself is NOT in this repo (it is Okta's brand asset and this repo is
# public). Upload it by hand, tagged like everything else:
#   aws s3api put-object --bucket <idp_logo_bucket> --key idp-logo.png \
#     --body ~/Downloads/okta-logo.png --content-type image/png \
#     --cache-control "public, max-age=86400" --tagging "Project=fleet-lab&ManagedBy=manual"
locals {
  idp_logo_key = "idp-logo.png"
}

data "aws_region" "current" {}

resource "aws_s3_bucket" "idp_logo" {
  bucket = "fleet-homelab-idp-logo-${data.aws_caller_identity.current.account_id}"
}

# Only the two "public policy" settings are relaxed, and only on this bucket. ACLs stay
# blocked: access is granted by the one bucket-policy statement below and nothing else.
resource "aws_s3_bucket_public_access_block" "idp_logo" {
  bucket = aws_s3_bucket.idp_logo.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "idp_logo" {
  bucket = aws_s3_bucket.idp_logo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadLogoOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.idp_logo.arn}/${local.idp_logo_key}"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.idp_logo]
}

output "idp_logo_url" {
  description = "Public URL of the IdP logo. Goes in Fleet's SSO settings as the IdP image URL."
  value       = "https://${aws_s3_bucket.idp_logo.bucket}.s3.${data.aws_region.current.region}.amazonaws.com/${local.idp_logo_key}"
}
