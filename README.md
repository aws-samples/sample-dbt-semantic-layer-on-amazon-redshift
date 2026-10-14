# dbt Semantic Layer on Amazon Redshift Serverless

Companion sample code for the AWS Big Data Blog post on building a dbt Semantic
Layer with [MetricFlow](https://docs.getdbt.com/docs/build/about-metricflow) on
[Amazon Redshift Serverless](https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html).

## What this demonstrates

This sample shows how to define a metric **once** with the dbt Semantic Layer
(MetricFlow) and have it stay correct at any time grain, instead of baking a
single aggregation into a table that silently breaks when you re-slice it. The
worked example is a non-additive metric, `average_order_value`. With five seeded
orders, a naive pre-aggregated daily table reads back as **`$550`** when you
roll it up to the week — the average of the daily averages. The semantic layer
recomputes the ratio (`SUM(amount) / COUNT(orders)`) at whatever grain you ask
for, returning the correct **`$280`** at week grain while still returning
`$1,000` and `$100` at day grain. One definition, correct at every grain.

## Quick start (scripts)

The fastest path is the three convenience scripts in [`scripts/`](scripts/)
(the detailed manual runbook below still works if you prefer to run each step
yourself):

```bash
./scripts/deploy.sh        # provision the Redshift Serverless stack with CDK
./scripts/e2e-test.sh      # build the dbt project and assert the metric values
./scripts/destroy.sh --yes # tear everything down when you are finished
```

Or via `make`: `make deploy`, `make test`, `make destroy`.

`e2e-test.sh` also accepts `--deploy` (deploy first) and `--destroy` (tear down
at the end), so `./scripts/e2e-test.sh --deploy --destroy` runs the whole cycle.

**Env-var knobs** (all optional — the scripts resolve sensible defaults):

- `ALLOWED_CIDR` — ingress CIDR allowed on port `5439`. Defaults to your
  detected public IP as a `/32`. Anything broader than `/32` prints a warning.
- `CDK_DEFAULT_ACCOUNT` / `CDK_DEFAULT_REGION` — AWS account and region.
  Auto-resolved from your AWS CLI (`sts get-caller-identity`, `configure get
  region`, defaulting to `us-east-1`) when unset.
- `VPC_ID` + `SUBNET_IDS` — target an existing VPC instead of the default one.
  `SUBNET_IDS` is a comma-separated list of ≥ 3 subnets in distinct AZs. Pass
  both together or neither.

**Prerequisites:** configured AWS credentials plus the CDK and AWS CLIs — see
[Prerequisites](#prerequisites) below.

> **Cost note:** `deploy.sh` creates an Amazon Redshift Serverless workgroup,
> which **incurs charges while it exists**. Run `./scripts/destroy.sh --yes`
> as soon as you are done to stop the meter.

## Architecture

- **`infra/`** — an AWS CDK v2 (Python) app that provisions an Amazon Redshift
  Serverless **namespace** and **workgroup**. The admin password is generated
  into AWS Secrets Manager and referenced as a CloudFormation dynamic reference,
  so no plaintext credential lands in the template. The workgroup's security
  group only allows inbound `5439` from a CIDR you supply.
- **`dbt/`** — a dbt project that seeds the sample orders, builds a gold
  `fct_orders` model, and defines the semantic model and metrics that MetricFlow
  computes. The project/profile name is `semantic_demo`.

The CDK stack outputs (`WorkgroupEndpointAddress`, `WorkgroupPort`,
`DatabaseName`, `AdminUsername`, `AdminSecretName`, `AdminSecretArn`) map
directly to the environment variables the dbt profile reads.

## Prerequisites

- An AWS account, with credentials configured for it.
- [AWS CDK CLI](https://docs.aws.amazon.com/cdk/v2/guide/cli.html) 2.x
  (`cdk --version`).
- Python 3.9–3.12 and `pip`.
- The [AWS CLI](https://docs.aws.amazon.com/cli/) (`aws --version`).
- Your current public IP, used to lock the Redshift security group:
  ```bash
  curl -s https://checkip.amazonaws.com
  ```

## 1. Deploy the Redshift workgroup with CDK

```bash
cd infra
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export CDK_DEFAULT_ACCOUNT=123456789012   # your AWS account id
export CDK_DEFAULT_REGION=us-east-1       # your region

cdk deploy -c allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32
```

> **Security warning:** `allowed_cidr` controls who can reach the workgroup on
> `5439`. Scope it to your own `/32`. A wide CIDR such as `0.0.0.0/0` exposes
> the Redshift endpoint to the entire internet. If you omit `allowed_cidr`, the
> app defaults to the unroutable sentinel `0.0.0.0/32` (and prints a warning).

When the deploy finishes, note the stack outputs (`WorkgroupEndpointAddress`,
`WorkgroupPort`, `DatabaseName`, `AdminUsername`, `AdminSecretName`,
`AdminSecretArn`). See [`infra/README.md`](infra/README.md) for more detail,
including how to target a specific VPC/subnets and how to synth without
credentials.

## 2. Set up the dbt environment

Use a separate virtual environment for dbt:

```bash
cd ../dbt
python3 -m venv .venv && source .venv/bin/activate
pip install "dbt-redshift>=1.9,<2.0" "dbt-metricflow>=0.8"
```

> dbt-core **≥ 1.9 is required**: the time spine is registered with the 1.9
> `time_spine:` YAML (and `columns[].granularity`), which older dbt-core
> versions reject during `dbt parse`. `dbt-redshift>=1.9` pulls in a compatible
> dbt-core; `dbt-metricflow` provides the `mf` CLI.

Copy the profile template and point it at your workgroup via environment
variables filled from the CDK outputs + Secrets Manager:

```bash
cp profiles.example.yml ~/.dbt/profiles.yml

export REDSHIFT_HOST=<WorkgroupEndpointAddress output>
export REDSHIFT_USER=admin                     # AdminUsername output
export REDSHIFT_DBNAME=dev                      # DatabaseName output
export REDSHIFT_SCHEMA=semantic_demo
export REDSHIFT_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id <AdminSecretName output> --query SecretString --output text \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
```

Create the schema (for example in Redshift Query Editor v2):

```sql
CREATE SCHEMA IF NOT EXISTS semantic_demo;
```

Confirm the connection:

```bash
dbt deps
dbt debug
```

## 3. Seed and build the model

```bash
dbt seed
dbt run
```

Then check the five seeded rows:

```sql
SELECT * FROM semantic_demo.fct_orders;
```

## 4. Query the metric at two grains

List the metrics:

```bash
dbt parse
mf validate-configs
mf list metrics
```

Day grain — returns `$1,000` for 2026-01-05 and `$100` for 2026-01-06:

```bash
mf query --metrics average_order_value --group-by metric_time__day --order metric_time__day
```

Week grain — the same metric, the question that broke the pre-aggregated table:

```bash
mf query --metrics average_order_value --group-by metric_time__week
```

The week figure comes back as **`$280`** (recomputed as `SUM(amount) /
COUNT(orders)` at the week grain), not the naive `$550`.

## 5. Clean up

```sql
DROP SCHEMA IF EXISTS semantic_demo CASCADE;
```

```bash
cd infra && cdk destroy
```

## Security note

This repository is a **demonstration** and is **not production-hardened**. It is
meant to illustrate the dbt Semantic Layer on Redshift Serverless as simply as
possible. Before adapting any of it for real workloads, review at least the
following:

- **Scope network access.** The workgroup is publicly accessible with inbound
  `5439` limited to the CIDR you pass. Scope `allowed_cidr` to your own `/32`,
  or better, use private access (deploy to private subnets and reach the
  workgroup over a VPN/Direct Connect or a bastion) instead of public access.
- **Use a least-privilege database user.** The demo connects dbt as the admin
  user. Create a dedicated, least-privilege database user/role for dbt instead
  of using the admin credential.
- **Enable logging and auditing.** Turn on Redshift audit/connection logging and
  monitor access to the workgroup.
- **Pin dependencies.** Pin the Python, CDK, and dbt/adapter versions to known
  good releases for reproducible, reviewable builds.

## Reference

- AWS Big Data Blog post: *link TBD* (will be added once the post is published).

## License

This sample is licensed under the Apache License 2.0. See the [LICENSE](LICENSE)
and [NOTICE](NOTICE) files.
