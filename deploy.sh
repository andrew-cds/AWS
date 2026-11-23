#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--plan-only | --yes]

Deploy the JWKS and SAML metadata hosting infrastructure using your current
AWS credentials (including AWS_PROFILE or exported environment credentials).

  --plan-only  Initialise, validate, and preview changes without applying.
  --yes        Apply the generated plan without interactive confirmation.
  -h, --help   Show this help.
EOF
}

plan_only=false
auto_approve=false
for argument in "$@"; do
  case "$argument" in
    --plan-only) plan_only=true ;;
    --yes) auto_approve=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Error: unknown argument: %s\n' "$argument" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$plan_only" == true && "$auto_approve" == true ]]; then
  printf 'Error: --plan-only and --yes cannot be combined.\n' >&2
  exit 1
fi

for tool in terraform aws; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$tool" >&2
    exit 1
  fi
done

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$script_directory/terraform/jwks_hosting"

printf 'Checking AWS deployment identity (infrastructure region: ca-central-1)...\n'
AWS_PAGER="" aws sts get-caller-identity --region ca-central-1 --output json

umask 077
plan_directory="$(mktemp -d "${TMPDIR:-/tmp}/jwks-deploy.XXXXXX")"
plan_file="$plan_directory/tfplan"
trap 'rm -f -- "$plan_file"; rmdir -- "$plan_directory"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

terraform init -input=false
terraform validate
terraform plan -input=false -out="$plan_file"

if [[ "$plan_only" == true ]]; then
  printf 'Preview complete. No changes were applied; the temporary plan will be removed.\n'
  exit 0
fi

# Applying a saved Terraform plan bypasses Terraform's own approval prompt.
if [[ "$auto_approve" != true ]]; then
  printf '\nType yes to apply the plan above: '
  if ! IFS= read -r approval || [[ "$approval" != yes ]]; then
    printf '\nDeployment cancelled; no changes were applied.\n' >&2
    exit 1
  fi
fi

terraform apply -input=false "$plan_file"
printf '\nDeployment complete. Published URLs:\n'
terraform output all_jwks_urls
terraform output all_saml_metadata_urls
