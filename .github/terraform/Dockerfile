# The Terraform version CI uses. Not built or run: the workflows read the tag below
# (the shared setup action, .github/actions/terraform-setup, and the lint job in
# terraform.yml), and Dependabot's docker updates open a pull request when HashiCorp
# publishes a newer one. In its own folder so Dependabot doesn't also scan fleet.Dockerfile,
# whose image has too many tags for it. Upgrade Terraform locally when it changes.
FROM hashicorp/terraform:1.17.1
