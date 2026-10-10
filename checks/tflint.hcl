# tflint: our own Terraform only. Remote modules (Fleet's) are not inspected
# (call_module_type defaults to "local"). The AWS ruleset is pinned; tflint --init
# downloads it and verifies its signature.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
