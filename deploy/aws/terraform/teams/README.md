# Disposable challenge instances

One private Fargate service per **team/challenge pair**, separate from CTFd.
The operator roster explicitly lists pairs such as `red/secrets-all-the-way-down`
and `red/nothing-is-ephemeral`. Either can be created, reset, or removed independently.

## Boundaries

Each pair owns an ECS service and task definition, ENI/security group, execution
role, log group, and ephemeral volumes. There is no task IAM role, ECS Exec,
Docker socket, host path, or shared challenge disk. Containers run as non-root
with capabilities dropped and hard resource limits. All teams playing the same
challenge receive the same pinned flags; different challenges use distinct
Secrets Manager secrets and separate seeded runtime images.

`catalog.tf` describes each bundle's containers, ports, volumes, and images.
Secrets All the Way Down contains Gitea, its seeder, and its own LocalStack.
Nothing Is Ephemeral contains a different LocalStack, seeded only with its
Terraform state bucket. Cloud readiness requires a completed, verified seed.

All containers in a task share its network boundary. Cooperation within a
multi-service challenge is intentional. Tasks accept only ALB ingress and have
outbound HTTPS access to the selected AWS endpoints, or existing NAT when
`allow_nat_egress = true`. NAT also gives challenge containers outbound HTTPS. IAM grants only the
bundle's runtime images, its secret, and that instance's logs.

## Player access

Supply an existing private Route53 zone associated with this VPC, a trusted
ACM certificate in this account/region, a domain, and the VPN IPv4 source ranges
actually seen by the ALB. For `ctf.example.com`, team `red` receives:

| Bundle | URLs |
|---|---|
| Secrets All the Way Down | `https://gitea-red.ctf.example.com`, `https://aws-red.ctf.example.com` |
| Nothing Is Ephemeral | `https://tfstate-red.ctf.example.com` |

The assigned team hostname remains `red.ctf.example.com`. Set the artifact and
metadata transport variables as described in the [operator guide](../../operator/README.md).

The shared internal ALB terminates HTTPS and forwards to exact instance targets.
Unknown hosts receive 404. The configuration rejects duplicate hostnames or more
than 60 endpoints, matching the default ALB security-group egress-rule budget.
With both current challenges this permits 20 teams; account quotas, subnet space,
and Fargate capacity still need checking.

**Endpoint ownership remains honor-system.** VPN users who know another team's
URL can visit it. Backend isolation does not authenticate player ownership.
An authenticated launch/access broker is separate future work.

Set `team_access = null` for closed backends. Reuse foundation outputs for the
VPC, private subnets, endpoint IDs and endpoint-client security group. Endpoint
policies, ingress, DNS and ACLs must permit ECR, S3 image pulls, Secrets Manager,
and CloudWatch Logs. With `allow_nat_egress = true`, endpoint IDs may be partial
or empty; existing NAT handles services without endpoints. Set the same option
in foundation. Company endpoint policies and ingress are not modified here.

## Secrets and images

Create two separate Secrets Manager JSON payloads through the approved operator
workflow. Terraform takes their ARNs and immutable version IDs, never payloads:

| Secret | Exact fields |
|---|---|
| `secrets-all-the-way-down` | `GITEA_ADMIN_PASSWORD`, `DEPLOY_PASSWORD`, `FLAG_PIPELINE`, `FLAG_CLOUD` |
| `nothing-is-ephemeral` | `FLAG_STATE_CURRENT`, `FLAG_STATE_PRIOR` |

Values must match the event's generated environment and CTFd metadata. Keep the
pinned versions for the event. Never upload the whole `.env`. `FLAG_LAYERS`
belongs only to the player artifact and CTFd. Optional per-challenge KMS keys
must permit the relevant execution roles; no platform key access is granted.

The operator publishes seven runtime images, including two different LocalStack
images. `images.localstack` is the pipeline challenge, and
`images.tfstate_localstack` is the state challenge. Local Nginx ingress images
are not published to AWS, where the ALB supplies ingress.

## Deployment and lifecycle

Use separate foundation, platform and teams state keys. Initialize this root,
copy `event.tfvars.example`, and supply the shared image manifest:

```bash
terraform init -backend-config=backend.hcl
terraform plan -var-file=event.tfvars -var-file=/absolute/path/images.tfvars.json -out=teams.tfplan
terraform apply teams.tfplan
```

Start with `instance_ids = []`, then use operator create/reset/status/destroy
commands with both a team and challenge argument. CTFd registration does not
provision infrastructure. Removing one pair must not remove its sibling or its
CTFd progress. Removing all pairs retains the ECS cluster and optional ALB.

Task replacement discards the pair's data and seeds from scratch. Services stop
the old task before starting the replacement and use circuit-breaker failure
detection without automatic rollback. Failed seeding must fail startup.
Infrastructure failures can also replace tasks. Image or secret changes affect
only instances of that challenge, so treat those changes as resets.

## Upgrading the former shared team stack

This is a breaking deployment contract. Old `team_ids` become explicit
`instance_ids`; one old secret becomes two secrets; endpoints are keyed by
`team/challenge` and return a `urls` map. Publish the new images first: the old
shared LocalStack image requires all flags and cannot run as an isolated bundle.

Do not apply this branch blindly to an existing event. The resource keys and
service names changed; review a normal full Terraform plan for replacement of
the disposable old team services. CTFd/foundation state must remain separate.
The single-instance operator intentionally rejects a migration plan that touches
old or unrelated resources. Do not use targeted or forced applies to bypass it.

Old local `self-ctf-challenges` containers also remain untouched. Coordinate their
retirement before reusing occupied host ports.

## Verification

`mise run terraform:check` validates and mock-tests all AWS roots, including
two teams with both bundles, secret separation, endpoint routing, selective
removal, and endpoint quota rejection. `mise run operator:check` checks lifecycle
guards and rejects sibling changes.

`mise run challenges:test` creates a fresh local CTFd and four challenge bundles,
runs both ctfcli solvers for each team, tests blocked cross-bundle TCP, checks
seed/flag separation, and resets one bundle while checking sibling data survives.
It deletes its disposable challenge fixtures and removes its CTFd containers and
networks, retaining the temporary fixture directory, logs, and platform volumes
for inspection. A failed seeder must fail startup and keep ingress stopped.

Local tests and mock plans do not verify real AWS permissions, routing or quotas.
Rehearse the deployment in the sandbox before an event. Automated exploit
healthchecks remain local under repository policy.
