# Redshift Serverless demo infra (CDK v2, Python)

This CDK app provisions the Redshift Serverless **namespace** and **workgroup**
used by the demo, replacing the console clicks. The workgroup is publicly
accessible but its security group only allows inbound `5439` from a single CIDR
you pass in. The admin password is generated into AWS Secrets Manager and
referenced by the namespace as a CloudFormation dynamic reference, so the
plaintext never lands in the template.

The target account and region come from your environment — this app does not
bake in any account id. Set both before you synth or deploy.

## Setup

```bash
cd infra
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export CDK_DEFAULT_ACCOUNT=123456789012   # your AWS account id
export CDK_DEFAULT_REGION=us-east-1       # your region
```

`app.py` requires both `CDK_DEFAULT_ACCOUNT` and `CDK_DEFAULT_REGION`; it exits
with a helpful message if either is unset.

## Deploy

Lock inbound `5439` to your current public IP:

```bash
cdk deploy -c allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32
```

> **Security warning:** `allowed_cidr` controls who can reach the workgroup on
> `5439`. Passing a wide CIDR such as `0.0.0.0/0` exposes the Redshift
> endpoint to the entire internet. Always scope it to your own `/32`. If you
> omit `allowed_cidr`, the app defaults to the unroutable sentinel
> `0.0.0.0/32` (and prints a warning) so nothing is accidentally left open.

The default-deploy path looks up the default VPC and picks one public subnet in
each of three AZs. To target a specific VPC/subnets, pass both context keys
together (the `vpc-...`/`subnet-...` values below are placeholders — substitute
your own):

```bash
cdk deploy -c allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32 \
           -c vpc_id=vpc-xxxxxxxx \
           -c subnet_ids=subnet-aaa,subnet-bbb,subnet-ccc
```

## Synth without AWS credentials

`cdk synth` succeeds with **no credentials** when you supply dummy
`vpc_id`/`subnet_ids` context (this uses `from_vpc_attributes`, which performs
no AWS lookup). The values below are illustrative placeholders:

```bash
cdk synth -c allowed_cidr=10.0.0.0/32 \
          -c vpc_id=vpc-00000000000000000 \
          -c subnet_ids=subnet-aaa,subnet-bbb,subnet-ccc
```

Without the dummy context the lookup path runs and requires live credentials.

## Read the admin password

```bash
aws secretsmanager get-secret-value \
  --secret-id SemanticDemoRedshift/redshift-admin \
  --query SecretString --output text \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])'
```

The stack outputs (`WorkgroupEndpointAddress`, `WorkgroupPort`, `DatabaseName`,
`AdminUsername`, `AdminSecretName`, `AdminSecretArn`) map directly to the dbt
env vars used by [`../dbt/profiles.example.yml`](../dbt/profiles.example.yml).

## Teardown

```bash
cdk destroy
```
