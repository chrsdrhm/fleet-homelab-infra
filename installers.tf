resource "aws_s3_bucket" "software_installers" {
  bucket = "fleet-homelab-software-installers-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "software_installers" {
  bucket                  = aws_s3_bucket.software_installers.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "software_installers_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.software_installers.arn, "${aws_s3_bucket.software_installers.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "software_installers" {
  bucket = aws_s3_bucket.software_installers.id
  policy = data.aws_iam_policy_document.software_installers_bucket.json
}

data "aws_iam_policy_document" "software_installers_task" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject*", "s3:PutObject*", "s3:ListBucket*", "s3:DeleteObject",
      "s3:CreateMultipartUpload", "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts", "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.software_installers.arn, "${aws_s3_bucket.software_installers.arn}/*"]
  }
}

resource "aws_iam_policy" "software_installers" {
  name   = "fleet-homelab-software-installers"
  policy = data.aws_iam_policy_document.software_installers_task.json
}
