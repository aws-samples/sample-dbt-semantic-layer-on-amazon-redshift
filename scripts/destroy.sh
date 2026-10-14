#!/usr/bin/env bash
set -euo pipefail

# destroy.sh — DESTRUCTIVE teardown of the Redshift Serverless demo stack.
#
# This deletes the Redshift Serverless workgroup and namespace (and the data in
# the warehouse) along with the admin secret. It is GATED: it refuses to run
# unless you explicitly opt in with `--yes` or FORCE=1. It never auto-confirms
# (no `yes |`, no piped `y`).
#
# Usage:
#   ./scripts/destroy.sh --yes      # or:  FORCE=1 ./scripts/destroy.sh
#
# Env knobs (all optional):
#   VPC_ID + SUBNET_IDS  optionally target an existing VPC on teardown (pass together)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="SemanticDemoRedshift"

CONFIRMED=0
if [[ "${1:-}" == "--yes" || "${FORCE:-}" == "1" ]]; then
  CONFIRMED=1
fi

if [[ "$CONFIRMED" -ne 1 ]]; then
  cat >&2 <<EOF
This will DESTROY the "${STACK_NAME}" stack, including:
  - Redshift Serverless workgroup  'semantic-demo-wg'
  - Redshift Serverless namespace  'semantic-demo-ns'
  - Admin secret                   '${STACK_NAME}/redshift-admin'

Dropping the warehouse permanently deletes the data it holds.

This action is not reversible. Re-run with --yes (or FORCE=1) to proceed:
  ./scripts/destroy.sh --yes
EOF
  exit 1
fi

# --- Resolve account/region (app.py requires them, even to destroy) --------
ACCOUNT="${CDK_DEFAULT_ACCOUNT:-}"
if [[ -z "$ACCOUNT" ]]; then
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
fi

REGION="${CDK_DEFAULT_REGION:-}"
if [[ -z "$REGION" ]]; then
  REGION="${AWS_REGION:-}"
fi
if [[ -z "$REGION" ]]; then
  REGION="$(aws configure get region || true)"
fi
if [[ -z "$REGION" ]]; then
  REGION="us-east-1"
fi
export CDK_DEFAULT_ACCOUNT="$ACCOUNT"
export CDK_DEFAULT_REGION="$REGION"
echo "Destroying ${STACK_NAME} in account ${CDK_DEFAULT_ACCOUNT}, region ${CDK_DEFAULT_REGION}."

cd "$REPO_ROOT/infra"
if [[ -d .venv ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
else
  echo "NOTE: infra/.venv not found; CDK deps may need installing (run deploy.sh first)." >&2
fi

# --- Optionally target a specific VPC/subnets (mirror deploy.sh) ----------
# cdk destroy also synthesises the app, so forward the same optional context
# keys deploy.sh accepts. Pass both together, or neither.
CDK_ARGS=()
if [[ -n "${VPC_ID:-}" && -n "${SUBNET_IDS:-}" ]]; then
  CDK_ARGS+=(-c "vpc_id=${VPC_ID}" -c "subnet_ids=${SUBNET_IDS}")
  echo "Targeting VPC ${VPC_ID} with subnets ${SUBNET_IDS}."
elif [[ -n "${VPC_ID:-}" || -n "${SUBNET_IDS:-}" ]]; then
  echo "ERROR: VPC_ID and SUBNET_IDS must be set together (or neither)." >&2
  exit 1
fi

# --force only skips CDK's own interactive y/N prompt — our explicit gate above
# is the real confirmation, so this does not bypass human intent.
cdk destroy "${CDK_ARGS[@]+"${CDK_ARGS[@]}"}" --force

rm -f "$REPO_ROOT/infra/cdk-outputs.json"
echo "Teardown complete. Removed infra/cdk-outputs.json."
