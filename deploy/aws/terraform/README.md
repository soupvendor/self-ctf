# AWS Terraform

An existing VPC and private subnets, one stateful CTFd host on EC2, and one
disposable ECS Fargate stack per team. Challenge definitions and runtime images
stay provider-neutral; this directory owns only their AWS deployment.

## Stages

- [x] Portable challenge runtime images and environment contract
- [x] Foundation configuration: existing network validation, endpoint access, ECR
- [x] Platform configuration: CTFd EC2 host, encrypted EBS, and backup/restore
- [x] Per-team Fargate tasks, ephemeral data, and automatic seeding (closed backends)
- [x] Runtime secret injection and least-privilege execution roles; no team task role
- [ ] Company-VPN access, enforced team authorization, HTTPS, private DNS, and endpoint outputs
- [ ] Operator commands for image publishing and team create/reset/status/destroy
- [ ] Two-team AWS rehearsal: isolation, solvers, reset, and platform recovery

`foundation/`, [`platform/`](platform/README.md), and the closed
[`teams/`](teams/README.md) backends are implemented, but have not been applied
to AWS. Team access is still pending, so this is not yet a complete AWS CTF.
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

Set `existing_endpoint_ids` for company-managed `ecr.api`, `ecr.dkr`, `logs`,
`secretsmanager`, and `s3` endpoints. Terraform reads but does not manage or
destroy them. The default is reuse-only: all five IDs are required unless you
set `create_missing_endpoints = true`. With that opt-in, only omitted services
are created. Never omit an existing private-DNS endpoint for the same service.

Reused endpoints must be available in the selected VPC and region. Interface
endpoints need private DNS; the S3 gateway endpoint must cover every selected
subnet's route table. Your network owner must also ensure:

- The reused interface endpoint security groups allow inbound TCP 443 from the
  output `endpoint_client_security_group_id` (or an existing permitted source).
  This configuration does not edit company security groups.
- Endpoint policies permit the eventual ECR pulls, log writes, and secret reads.
  Network ACLs and DNS forwarding must permit the corresponding traffic.

The client security group grants only TCP 443 egress to endpoint security groups
and the regional S3 prefix list, with no inbound rules. Future workloads will
attach it alongside their own restricted ingress groups. Security groups are
additive: an additional allow-all egress group would defeat this restriction.
This foundation alone is not proof of team isolation; that is tested when
compute and player access are added.

Creating an S3 gateway endpoint **changes shared subnet route tables**. Its
policy preserves general S3 access so it does not break unrelated workloads;
IAM and bucket policies still apply. Prefer reusing the company's endpoint.
New interface endpoints also incur per-AZ hourly and data-processing charges.
See [AWS's ECR endpoint requirements](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html).

## Images and lifecycle

`ecr_repository_names` defaults to the six runtime images: CTFd, MariaDB, Redis,
Gitea, its seeder, and seeded LocalStack. Upstream images will be mirrored so
private workloads do not need public registries. This stage creates repositories
only; publishing and digest selection follow with compute provisioning.

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
