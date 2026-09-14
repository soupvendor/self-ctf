# AWS Terraform

An existing VPC and private subnets, one stateful CTFd host on EC2, and one
disposable ECS Fargate service per team/challenge pair. Challenge definitions and runtime images
stay provider-neutral; this directory owns only their AWS deployment.

## Stages

- [x] Portable challenge runtime images and environment contract
- [x] Foundation configuration: existing network validation, endpoint access, ECR
- [x] Platform configuration: CTFd EC2 host, encrypted EBS, and backup/restore
- [x] Per-team Fargate tasks, ephemeral data, and automatic seeding
- [x] Runtime secret injection and least-privilege execution roles; no team task role
- [x] Company-VPN HTTPS access, private DNS, and endpoint outputs (honor-system team ownership)
- [x] Operator commands for image publishing and team create/reset/status/destroy
- [ ] Two-team AWS rehearsal: isolation, solvers, reset, and platform recovery

`foundation/`, [`platform/`](platform/README.md), [`teams/`](teams/README.md), and
[operator commands](../operator/README.md) are implemented, but have not been
applied to AWS. The next step is a small rehearsal, not a live event.
Each configuration uses separate state; resetting a team must not affect CTFd.

## Foundation setup

Requires `mise install`, AWS credentials for the target account, and:

- An existing VPC with DNS support and DNS hostnames enabled.
- At least two private subnets, exactly one per availability zone. No automatic
  public IPv4 addresses or direct internet-gateway routes. Explicit subnet route
  tables and implicit use of the VPC's main route table are both supported.
- A company-managed S3 state bucket with versioning, encryption, and public access
  blocked. The operator needs the [S3 backend permissions](https://developer.hashicorp.com/terraform/language/backend/s3#permissions-required),
  including access to the state object's `.tflock` file. State uses encryption
  and native S3 locking; the bucket is not created here.

From the repository root:

```bash
cd deploy/aws/terraform/foundation
cp event.tfvars.example event.tfvars
cp backend.hcl.example backend.hcl
```

Edit both copies with your account, region, VPC, subnet and endpoint IDs, tags,
and state location. Use a unique backend key per event, such as
`self-ctf/<event>/foundation.tfstate`. Use standard AWS credentials, not keys in
Terraform files:

```bash
export AWS_PROFILE=your-company-profile
terraform init -backend-config=backend.hcl
terraform plan -var-file=event.tfvars -out=foundation.tfplan
# After reviewing the plan with your network owner:
terraform apply foundation.tfplan
terraform output
```

The provider checks `aws_account_id` against the authenticated account. The
backend authenticates separately; verify its bucket/account too. State, plans,
`backend.hcl`, and `*.tfvars` are gitignored. Never put flags or platform
credentials in this foundation configuration. The current service naming
targets standard commercial AWS regions.

## Endpoint ownership

For private subnets with existing NAT connectivity, the examples use:

```hcl
allow_nat_egress        = true
create_missing_endpoints = false
existing_endpoint_ids  = { s3 = "vpce-REPLACE" }
```

Set `allow_nat_egress = true` in foundation, platform, and teams. Foundation's
`endpoint_ids` output can contain only S3, any valid subset, or be empty. Pass
that map to teams; platform's `ssm_endpoint_ids` can be `{}`. This creates no
endpoints and changes no routes. Workloads retain private addresses and internal
load balancers. Existing NAT routes, DNS, network ACLs and return traffic must
work; Terraform validates private subnet selection but does not prove connectivity.
NAT mode permits outbound TCP 443 to `0.0.0.0/0`, including from compromised
challenge containers. It does not add inbound access. Use company egress controls
if destination filtering is required.

With `allow_nat_egress = false` (the default), all five runtime endpoints are
required. Supply existing IDs, or set `create_missing_endpoints = true` to create
only missing services. For example, supplying only S3 with creation enabled creates
four interface endpoints and leaves S3 and its routes untouched. Platform also
requires existing `ssm` and `ssmmessages` endpoints in this mode.

Reused endpoints are read-only: Terraform never changes their policies, security
groups or route associations. They must match the VPC/service, have private DNS
for interface endpoints, and cover selected route tables for S3. Company interface
endpoint groups must permit HTTPS from `endpoint_client_security_group_id`;
SSM groups must permit HTTPS from the platform `host_security_group_id`.
Existing endpoint policies must authorize the deployment's runtime operations.

Created interface endpoints accept HTTPS only from the CTF client security group.
Their policies require the selected source VPC, account and event runtime role
names. ECR allows authentication and pulls from event repositories; Logs allows
stream creation and writes under the event team log groups; Secrets Manager allows
only `GetSecretValue` for exact `runtime_secret_arns` supplied to foundation.
List both platform and challenge secret ARNs there before creating that endpoint;
never include secret values. IAM roles further restrict each workload's resources.
These endpoint policies do not restrict requests that bypass the endpoint via NAT.
Image publishing must use a path outside these pull-only endpoints.

A created S3 gateway endpoint permits only regional ECR layer downloads from the
selected VPC. AWS-signed layer URLs require permitting the signing principal;
the policy therefore scopes the bucket and source VPC instead of the task role.
Creating it changes selected route tables and can block other S3 uses, including
SSM agent artifact downloads. Reuse the company S3 endpoint for shared subnets.
New interface endpoints incur AWS charges.

Foundation remains a small provisioning convenience for ECR and the outbound
client group. Platform and teams consume ordinary IDs and image digests rather
than Terraform remote state: an externally provisioned equivalent can replace
foundation. The supplied client group must belong to the VPC and have no ingress;
teams validates every rule against the selected connectivity mode. The bundled operator
commands currently use foundation outputs for identity checks and image publishing,
so skipping foundation requires your own deployment/publishing pipeline. For the
rehearsal, retain foundation with NAT enabled and endpoint creation disabled.


## Images and lifecycle

`ecr_repository_names` defaults to seven runtime images: CTFd, MariaDB, Redis,
Gitea, its seeder, and two independently seeded LocalStack images. The operator's `publish-images` command
mirrors upstream images and builds the three seeded runtime images, scans before pushing, and
writes immutable digest inputs for platform and teams. Private workloads do not
need public registries.

Repositories are event-namespaced, AES-256 encrypted, scanned on push, and use
immutable tags. They do not force-delete images or expire them automatically.
Never upload the flag-bearing player artifact or answer keys to runtime ECR.

Keep foundation resources for the entire event. Destroying this state removes
CTF-owned endpoints, their S3 route associations, security groups, and empty
repositories; nonempty repositories block deletion. Reused endpoints, the VPC,
subnets, route tables, and state bucket remain company-owned. Do not use
foundation destruction to reset a team.

## Checks

From the repository root:

```bash
mise run check
mise run terraform:check
```

The first includes Terraform formatting. The second initializes providers in a
separate cache, validates configuration, and runs native Terraform mock tests
without AWS credentials or a backend. CI runs these alongside the existing
fresh-instance challenge solvers. Mock tests do not verify live IAM, endpoint
reachability, network ACLs, or AWS quotas; those require the later AWS rehearsal.
