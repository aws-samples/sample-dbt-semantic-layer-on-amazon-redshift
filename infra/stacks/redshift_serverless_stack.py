import json

from aws_cdk import (
    CfnOutput,
    Stack,
    aws_ec2 as ec2,
    aws_redshiftserverless as redshiftserverless,
    aws_secretsmanager as secretsmanager,
)
from constructs import Construct


class RedshiftServerlessStack(Stack):
    """Redshift Serverless namespace + workgroup for the semantic-layer demo.

    The admin password is generated into Secrets Manager and referenced by the
    namespace as a CloudFormation dynamic reference, so the plaintext never
    appears in the template. VPC resolution has two paths:

    - credential-free fallback (``vpc_id`` + ``subnet_ids`` context): uses
      ``ec2.Vpc.from_vpc_attributes`` which performs no AWS lookup, so
      ``cdk synth`` succeeds with no credentials.
    - real-deploy lookup (neither supplied): ``ec2.Vpc.from_lookup`` against the
      default VPC, which requires live credentials.
    """

    prefix = "semantic-demo"
    admin_username = "admin"

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        allowed_cidr,
        vpc_id=None,
        subnet_ids=None,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # --- Admin password secret ---------------------------------------
        secret = secretsmanager.Secret(
            self,
            "RedshiftAdminSecret",
            secret_name=f"{construct_id}/redshift-admin",
            generate_secret_string=secretsmanager.SecretStringGenerator(
                secret_string_template=json.dumps({"username": self.admin_username}),
                generate_string_key="password",
                password_length=32,
                exclude_punctuation=False,
                # Redshift admin password forbids / @ " space and ' — exclude them.
                exclude_characters="\"@/\\ '",
            ),
        )

        # --- VPC resolution (the fallback switch) ------------------------
        # subnet_ids arrives as a comma-separated string from context; split + trim.
        subnet_id_list = (
            [s.strip() for s in subnet_ids.split(",") if s.strip()]
            if subnet_ids
            else []
        )

        # Enforce the all-or-nothing contract before choosing a path.
        if bool(vpc_id) != bool(subnet_id_list):
            raise ValueError(
                "vpc_id and subnet_ids must be supplied together: pass both "
                "-c vpc_id=<id> and -c subnet_ids=<id1,id2,id3>, or neither "
                "(to use the default-VPC lookup on a real deploy)."
            )

        if vpc_id and subnet_id_list:
            # Credential-free path: no AWS calls, no context lookup.
            if len(subnet_id_list) < 3:
                raise ValueError(
                    "subnet_ids must list >= 3 subnets in distinct AZs for Redshift "
                    "Serverless; got fewer."
                )
            region = self.region  # concrete here because app.py sets an explicit env
            # from_vpc_attributes requires availability_zones and public_subnet_ids
            # to be the SAME length and index-aligned. Build one synthetic AZ per
            # supplied subnet, cycling through a..f, so any count stays consistent.
            suffixes = "abcdef"
            azs = [
                f"{region}{suffixes[i % len(suffixes)]}"
                for i in range(len(subnet_id_list))
            ]
            vpc = ec2.Vpc.from_vpc_attributes(
                self,
                "Vpc",
                vpc_id=vpc_id,
                availability_zones=azs,
                public_subnet_ids=subnet_id_list,
            )
            selected_subnet_ids = subnet_id_list
        else:
            # Real-deploy path: needs account/region + live creds.
            vpc = ec2.Vpc.from_lookup(self, "DefaultVpc", is_default=True)
            public = vpc.select_subnets(subnet_type=ec2.SubnetType.PUBLIC)
            # On a fresh checkout with no cached cdk.context.json, CDK runs an
            # initial synth pass with a DUMMY lookup result (availability zones
            # 'dummy1a'/'dummy1b' and placeholder subnet ids) BEFORE it performs
            # the real environment lookup. The AZ-count check must not fire on
            # that dummy pass, or synth crashes before the real lookup can run.
            # Detect the dummy pass and skip validation; CDK re-synthesises with
            # real data afterwards.
            is_dummy_lookup = any(
                "dummy" in az for az in vpc.availability_zones
            )
            # Redshift Serverless requires subnets in >= 3 AZs.
            by_az = {}
            for sn in public.subnets:
                by_az.setdefault(sn.availability_zone, sn)
            if not is_dummy_lookup and len(by_az) < 3:
                raise ValueError(
                    "Default VPC exposes subnets in fewer than 3 AZs in this region. "
                    "Re-run with -c vpc_id=<id> -c subnet_ids=<id1,id2,id3> pointing at "
                    "a VPC with >= 3 AZs, or deploy in us-east-1 (6 AZs)."
                )
            selected = list(by_az.values())[:3]
            selected_subnet_ids = [s.subnet_id for s in selected]

        # --- Security group ----------------------------------------------
        sg = ec2.SecurityGroup(
            self,
            "RedshiftSg",
            vpc=vpc,
            description="Redshift Serverless demo - inbound 5439 from allowed CIDR only",
            allow_all_outbound=True,
        )
        sg.add_ingress_rule(
            ec2.Peer.ipv4(allowed_cidr),
            ec2.Port.tcp(5439),
            "Redshift SQL from the allowed CIDR",
        )

        # --- Namespace + workgroup (L1) ----------------------------------
        namespace = redshiftserverless.CfnNamespace(
            self,
            "Namespace",
            namespace_name=f"{self.prefix}-ns",
            db_name="dev",
            admin_username=self.admin_username,
            admin_user_password=secret.secret_value_from_json("password").unsafe_unwrap(),
        )

        workgroup = redshiftserverless.CfnWorkgroup(
            self,
            "Workgroup",
            workgroup_name=f"{self.prefix}-wg",
            namespace_name=namespace.namespace_name,
            publicly_accessible=True,
            subnet_ids=selected_subnet_ids,
            security_group_ids=[sg.security_group_id],
            base_capacity=8,  # smallest base RPU keeps the demo cheap
        )
        workgroup.add_dependency(namespace)

        # --- Outputs (each description names the matching dbt env var) ---
        CfnOutput(
            self,
            "WorkgroupEndpointAddress",
            value=workgroup.attr_workgroup_endpoint_address,
            description="Redshift workgroup endpoint host -> dbt env var REDSHIFT_HOST",
        )
        CfnOutput(
            self,
            "WorkgroupPort",
            value="5439",
            description="Redshift SQL port -> dbt profile port (5439)",
        )
        CfnOutput(
            self,
            "DatabaseName",
            value="dev",
            description="Redshift database name -> dbt env var REDSHIFT_DBNAME",
        )
        CfnOutput(
            self,
            "AdminUsername",
            value=self.admin_username,
            description="Redshift admin user -> dbt env var REDSHIFT_USER",
        )
        CfnOutput(
            self,
            "AdminSecretName",
            value=secret.secret_name,
            description="Secrets Manager secret name holding the admin password "
            "-> source for dbt env var REDSHIFT_PASSWORD",
        )
        CfnOutput(
            self,
            "AdminSecretArn",
            value=secret.secret_arn,
            description="Secrets Manager secret ARN holding the admin password "
            "-> source for dbt env var REDSHIFT_PASSWORD",
        )
