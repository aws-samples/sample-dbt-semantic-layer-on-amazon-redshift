#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — provision the Redshift Serverless demo stack (SemanticDemoRedshift)
# with AWS CDK. Resolves AWS account/region and the allowed CIDR from the
# environment (or your live AWS CLI config / public IP) so nothing is hardcoded.
#
# Env knobs (all optional):
#   CDK_DEFAULT_ACCOUNT  AWS account id   (default: aws sts get-caller-identity)
#   CDK_DEFAULT_REGION   AWS region       (default: AWS_REGION / aws configure / us-east-1)
#   ALLOWED_CIDR         ingress CIDR     (default: <your public IP>/32)
#   VPC_ID + SUBNET_IDS  target an existing VPC (comma-separated subnets); pass together

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="SemanticDemoRedshift"

# --- Resolve account/region (no hardcoded values) --------------------------
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

# app.py requires both of these in the environment.
export CDK_DEFAULT_ACCOUNT="$ACCOUNT"
export CDK_DEFAULT_REGION="$REGION"
echo "Using AWS account ${CDK_DEFAULT_ACCOUNT} in region ${CDK_DEFAULT_REGION}."

# --- Resolve the allowed CIDR ---------------------------------------------
if [[ -z "${ALLOWED_CIDR:-}" ]]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com)"
  ALLOWED_CIDR="${MY_IP}/32"
fi
echo "Allowing inbound 5439 from CIDR: ${ALLOWED_CIDR}"
if [[ "$ALLOWED_CIDR" != */32 ]]; then
  echo "WARNING: ${ALLOWED_CIDR} is broader than a single host (/32). This exposes" >&2
  echo "         the Redshift endpoint on port 5439 to a wider range. 0.0.0.0/0" >&2
  echo "         would expose it to the entire internet. Scope to your own /32." >&2
fi

# --- Python venv + CDK deps -----------------------------------------------
cd "$REPO_ROOT/infra"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck source=/dev/null
source .venv/bin/activate
pip install -r requirements.txt

# --- Build the CDK context args (safe quoting via array) ------------------
CDK_ARGS=(-c "allowed_cidr=${ALLOWED_CIDR}")
if [[ -n "${VPC_ID:-}" && -n "${SUBNET_IDS:-}" ]]; then
  CDK_ARGS+=(-c "vpc_id=${VPC_ID}" -c "subnet_ids=${SUBNET_IDS}")
  echo "Targeting VPC ${VPC_ID} with subnets ${SUBNET_IDS}."
elif [[ -n "${VPC_ID:-}" || -n "${SUBNET_IDS:-}" ]]; then
  echo "ERROR: VPC_ID and SUBNET_IDS must be set together (or neither)." >&2
  exit 1
fi

OUTPUTS_FILE="$REPO_ROOT/infra/cdk-outputs.json"
cdk deploy "${CDK_ARGS[@]}" --require-approval never --outputs-file "$OUTPUTS_FILE"

echo
echo "Deploy complete. Stack outputs written to: ${OUTPUTS_FILE}"
if command -v python3 >/dev/null 2>&1 && [[ -f "$OUTPUTS_FILE" ]]; then
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1])).get("'"$STACK_NAME"'",{});[print(f"  {k} = {v}") for k,v in d.items()]' "$OUTPUTS_FILE" || true
fi
echo
echo "Next: run the end-to-end test:"
echo "  ./scripts/e2e-test.sh"
echo "Remember to tear everything down when finished:"
echo "  ./scripts/destroy.sh --yes"
