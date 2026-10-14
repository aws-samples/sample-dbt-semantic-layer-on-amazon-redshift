#!/usr/bin/env bash
set -euo pipefail

# e2e-test.sh — end-to-end check that the dbt Semantic Layer returns the
# correct, grain-aware values for average_order_value against a live Redshift
# Serverless workgroup.
#
# By default it assumes the stack is already deployed, runs the dbt build and
# the MetricFlow queries, asserts the numeric results, and then LEAVES the
# stack up (printing the destroy command).
#
# Flags:
#   --deploy    run scripts/deploy.sh first
#   --destroy   run scripts/destroy.sh --yes at the very end
#
# Expected values (verified from dbt/seeds/raw_orders.csv + the metric defs):
#   average_order_value by day  -> 1000 (2026-01-05) and 100 (2026-01-06)
#   average_order_value by week -> 280  (both days fall in one Mon-start week)
# The secret password is only ever held in an env var; it is never written to disk.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="SemanticDemoRedshift"
WORKGROUP="semantic-demo-wg"
DATABASE="dev"
SCHEMA="semantic_demo"

DO_DEPLOY=0
DO_DESTROY=0
for arg in "$@"; do
  case "$arg" in
    --deploy)  DO_DEPLOY=1 ;;
    --destroy) DO_DESTROY=1 ;;
    *) echo "Unknown flag: $arg (expected --deploy and/or --destroy)" >&2; exit 1 ;;
  esac
done

# --- Resolve region (same precedence as deploy.sh) -------------------------
REGION="${CDK_DEFAULT_REGION:-}"
if [[ -z "$REGION" ]]; then REGION="${AWS_REGION:-}"; fi
if [[ -z "$REGION" ]]; then REGION="$(aws configure get region || true)"; fi
if [[ -z "$REGION" ]]; then REGION="us-east-1"; fi
export AWS_REGION="$REGION"

if [[ "$DO_DEPLOY" -eq 1 ]]; then
  echo "== Deploying stack first (--deploy) =="
  "$REPO_ROOT/scripts/deploy.sh"
fi

# --- Resolve stack outputs: prefer cdk-outputs.json, else CloudFormation ---
OUTPUTS_FILE="$REPO_ROOT/infra/cdk-outputs.json"
read_output() {
  local key="$1"
  if [[ -f "$OUTPUTS_FILE" ]]; then
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],{}).get(sys.argv[3],""))' \
      "$OUTPUTS_FILE" "$STACK_NAME" "$key"
  else
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" --output text
  fi
}

echo "== Resolving stack outputs for ${STACK_NAME} =="
HOST="$(read_output WorkgroupEndpointAddress)"
SECRET_NAME="$(read_output AdminSecretName)"
SECRET_ARN="$(read_output AdminSecretArn)"
if [[ -z "$HOST" || -z "$SECRET_NAME" || -z "$SECRET_ARN" ]]; then
  echo "FAIL: could not resolve stack outputs. Is ${STACK_NAME} deployed?" >&2
  exit 1
fi

# --- Fetch admin password into an env var ONLY (never to disk) -------------
REDSHIFT_PASSWORD="$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
  --query SecretString --output text \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')"

export REDSHIFT_HOST="$HOST"
export REDSHIFT_USER="admin"
export REDSHIFT_DBNAME="$DATABASE"
export REDSHIFT_SCHEMA="$SCHEMA"
export REDSHIFT_PASSWORD
# Use the committed profiles dir so we never touch ~/.dbt/profiles.yml.
export DBT_PROFILES_DIR="$REPO_ROOT/dbt/.dbtprofile"

# --- Ensure the target schema exists --------------------------------------
# dbt-redshift normally creates the target schema on `dbt run`, but we create it
# explicitly first via the Redshift Data API. This approach needs no local DB
# driver, authenticates with the admin secret (nothing written to disk), and
# makes the e2e robust if schema auto-creation is ever disabled.
echo "== Ensuring schema ${SCHEMA} exists =="
SID="$(aws redshift-data execute-statement \
  --workgroup-name "$WORKGROUP" --database "$DATABASE" --secret-arn "$SECRET_ARN" \
  --sql "CREATE SCHEMA IF NOT EXISTS ${SCHEMA}" --query Id --output text)"
while true; do
  STATUS="$(aws redshift-data describe-statement --id "$SID" --query Status --output text)"
  case "$STATUS" in
    FINISHED) break ;;
    FAILED|ABORTED)
      echo "FAIL: schema creation statement ended with status ${STATUS}" >&2
      aws redshift-data describe-statement --id "$SID" --query Error --output text >&2 || true
      exit 1 ;;
    *) sleep 2 ;;
  esac
done

# --- dbt venv + build ------------------------------------------------------
cd "$REPO_ROOT/dbt"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck source=/dev/null
source .venv/bin/activate
pip install "dbt-redshift==1.9.5" "dbt-metricflow==0.11.0"

dbt deps
dbt seed
dbt run
dbt parse
mf validate-configs

# --- Query the metric at two grains ---------------------------------------
echo "== average_order_value by day =="
DAY_OUT="$(mf query --metrics average_order_value --group-by metric_time__day --order metric_time__day 2>&1)"
echo "$DAY_OUT"

echo "== average_order_value by week =="
WEEK_OUT="$(mf query --metrics average_order_value --group-by metric_time__week 2>&1)"
echo "$WEEK_OUT"

# --- Assertions ------------------------------------------------------------
# The (^|[^0-9])N([^0-9]|$) form matches N, N.0, N.00 but NOT N inside a longer
# number (e.g. 100 inside 1000 is not matched because the next char is a digit).
# These tokens track the verified values 1000/100/280; adjust only if the real
# mf rendered format differs (e.g. thousands separators).
FAILED=0
if ! grep -Eq '(^|[^0-9])1000([^0-9]|$)' <<<"$DAY_OUT"; then
  echo "FAIL: day grain did not contain expected average_order_value 1000" >&2
  FAILED=1
fi
if ! grep -Eq '(^|[^0-9])100([^0-9]|$)' <<<"$DAY_OUT"; then
  echo "FAIL: day grain did not contain expected average_order_value 100" >&2
  FAILED=1
fi
if ! grep -Eq '(^|[^0-9])280([^0-9]|$)' <<<"$WEEK_OUT"; then
  echo "FAIL: week grain did not contain expected average_order_value 280" >&2
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo
  echo "FAIL: metric assertions did not match. Actual day output:" >&2
  echo "$DAY_OUT" >&2
  echo "Actual week output:" >&2
  echo "$WEEK_OUT" >&2
  exit 1
fi

echo
echo "PASS: average_order_value is 1000/100 by day and 280 by week."

# --- Teardown or leave up --------------------------------------------------
if [[ "$DO_DESTROY" -eq 1 ]]; then
  echo "== Tearing down stack (--destroy) =="
  "$REPO_ROOT/scripts/destroy.sh" --yes
else
  echo
  echo "Stack left running. Tear it down when finished to stop incurring charges:"
  echo "  ./scripts/destroy.sh --yes"
fi
