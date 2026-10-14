#!/usr/bin/env python3
import ipaddress
import os

import aws_cdk as cdk

from stacks.redshift_serverless_stack import RedshiftServerlessStack


def _is_truthy(value):
    """Return True only for an explicit opt-in (true/1/yes/on, any case)."""
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


app = cdk.App()

# Account and region are required from the environment. This sample does not
# bake in any account id — set both before synth/deploy, e.g.:
#   export CDK_DEFAULT_ACCOUNT=123456789012
#   export CDK_DEFAULT_REGION=us-east-1
account = os.environ.get("CDK_DEFAULT_ACCOUNT")
region = os.environ.get("CDK_DEFAULT_REGION")
if not account or not region:
    raise SystemExit(
        "CDK_DEFAULT_ACCOUNT and CDK_DEFAULT_REGION must both be set. "
        "Export them before running CDK, for example:\n"
        "  export CDK_DEFAULT_ACCOUNT=123456789012\n"
        "  export CDK_DEFAULT_REGION=us-east-1"
    )

env = cdk.Environment(account=account, region=region)

# Context inputs (all optional at the CLI; app.py applies the sentinel default).
allowed_cidr = app.node.try_get_context("allowed_cidr") or "0.0.0.0/32"
vpc_id = app.node.try_get_context("vpc_id")          # may be None
subnet_ids = app.node.try_get_context("subnet_ids")  # may be None (CSV string)

if allowed_cidr == "0.0.0.0/32":
    print(
        "WARNING: allowed_cidr not set; using unroutable sentinel 0.0.0.0/32. "
        "Pass -c allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32 to "
        "allow your IP on 5439."
    )

# Reject an overly-broad ingress CIDR (any /0, e.g. 0.0.0.0/0 or ::/0) unless the
# user explicitly opts in with -c allow_wide_cidr=true. A /0 opens the public
# Redshift endpoint on 5439 to the entire internet.
allow_wide_cidr = app.node.try_get_context("allow_wide_cidr")
try:
    _network = ipaddress.ip_network(allowed_cidr, strict=False)
except ValueError:
    raise SystemExit(
        f"allowed_cidr={allowed_cidr!r} is not a valid CIDR. Pass a value like "
        "-c allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32 to scope "
        "inbound 5439 to your own IP."
    )
if _network.prefixlen == 0 and not _is_truthy(allow_wide_cidr):
    raise SystemExit(
        f"allowed_cidr={allowed_cidr!r} opens the public Redshift endpoint on "
        "5439 to the ENTIRE internet. Scope it to your own /32, for example:\n"
        "  -c allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32\n"
        "If you really intend an internet-wide CIDR, opt in explicitly with "
        "-c allow_wide_cidr=true."
    )

RedshiftServerlessStack(
    app,
    "SemanticDemoRedshift",
    env=env,
    allowed_cidr=allowed_cidr,
    vpc_id=vpc_id,
    subnet_ids=subnet_ids,
)

app.synth()
