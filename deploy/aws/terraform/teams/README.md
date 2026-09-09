# Disposable team backends

One private ECS Fargate service per team, separate from the stateful CTFd host.
This is **backend-only**: no listener, DNS, VPN ingress, or player endpoint is
created. Do not use it for a live event yet. Company VPN access, HTTPS, and
enforced team authorization are the next stage; a shared VPN CIDR alone cannot
distinguish teams. No additional VPN is planned.

## Runtime

Each team gets one Linux amd64 task (default 1 vCPU / 4 GiB):

- Gitea uses SQLite and two task-local volumes. Its health check gates seeding.
- The nonessential Gitea seeder shares those volumes and exits after verifying
  the planted repository. Essential LocalStack starts only after seeder success.
- LocalStack's health check requires the planted Secrets Manager secret to exist.

Containers run as UID/GID 1000 with all capabilities dropped and hard memory
limits. Gitea's upstream rootless image declares and owns the two mounted paths;
[Fargate copies their contents and permissions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/bind-mounts.html).
No host path, Docker socket, persistent challenge disk, ECS Exec, or task IAM
role is configured. The execution role is for ECS image pulls, secret injection,
and that team's logs; [its credentials are not exposed to containers](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html).

Replacement loses all team data and seeds from scratch. Deployments stop the
old task before starting its replacement, avoiding two divergent copies of a
team. Failed deployments trip the circuit breaker without rolling back to old
configuration. Terraform waits for steady state; inspect stopped tasks and
seeder logs if it fails. Automatic AZ rebalancing is disabled to avoid elective
resets. Infrastructure failures can still replace tasks.

## Inputs and setup

Use the same account, region, event name, existing VPC, and private subnets as
the applied foundation. Use **one separate teams state per event**; never reuse
the platform or foundation backend key.

Before applying:

1. Mirror `gitea/gitea:1.27.1-rootless` and publish the existing `gitea-seed` and
   `localstack-seeded` runtime builds to foundation ECR repositories. Supply
   Linux amd64 digests; image publishing commands are a later stage. Never push
   the player artifact or answer keys to runtime ECR.
2. Create a separate Secrets Manager **JSON** secret through your approved
   secret-management workflow, containing exactly `GITEA_ADMIN_PASSWORD`,
   `DEPLOY_PASSWORD`, `FLAG_PIPELINE`, and `FLAG_CLOUD`. Values must match the
   event's generated `.env`, artifact, and CTFd flags. Never upload the whole
   `.env` or include platform credentials. `DEPLOY_USER` is the nonsecret
   `deploy_user` input; `FLAG_LAYERS` stays in the artifact/CTFd, not the tasks.
3. Supply the secret ARN and immutable version ID. All teams use that version,
   including newly created and reset teams. Keep it available for the event
   (retain a staging label if rotating other versions). Terraform never reads
   or stores the payload. An optional customer-managed key must permit each
   output execution-role ARN in company key policy; do not grant platform key
   access.
4. Confirm endpoint policies, endpoint ingress, and subnet ACLs allow ECR,
   CloudWatch Logs, Secrets Manager, and S3 pulls. The configuration validates
   endpoints, route coverage, and every rule on the foundation client group;
   any inbound rule or non-endpoint outbound rule is rejected. The operator
   needs read access to VPC endpoints and security-group rules as well as
   provisioning permissions and permission to pass the execution roles.

Endpoint security groups must be dedicated to endpoints: any other ENI carrying
one becomes reachable on 443 too. AWS DNS is not blocked by security groups;
DNS filtering, if required, needs a company-managed DNS firewall. These checks
are not a substitute for a live network isolation test.

```bash
cd deploy/aws/terraform/teams
cp event.tfvars.example event.tfvars
cp backend.hcl.example backend.hcl
# Edit both copies; use a unique event backend key and standard AWS credentials.
export AWS_PROFILE=your-company-profile
terraform init -backend-config=backend.hcl
terraform plan -var-file=event.tfvars -out=teams.tfplan
# Review the plan before provisioning billable resources.
terraform apply teams.tfplan
terraform output
```

`team_ids` are stable operator-assigned identifiers, not CTFd team registration
automation. Adding an ID creates a stack; removing one destroys its service,
task definition, role, security group, and logs. An empty set removes all teams
but retains the cluster. Changing shared images or secret version replaces
every team's task, so avoid it mid-event unless a full reset is intended.

Until the operator command stage, use the AWS console or standard AWS CLI with
the output cluster/service names. To reset **one disposable team**:

```bash
aws ecs update-service --cluster devops-ctf-teams --service red --force-new-deployment
aws ecs wait services-stable --cluster devops-ctf-teams --services red
```

This does not touch CTFd scores, accounts, or other teams. Destroying this teams
state deletes its logs and ephemeral challenge data, not company networks,
endpoints, ECR images, source secrets, or platform state.

## Verification and next boundary

`mise run terraform:check` validates all three roots and runs native mock tests,
including two-team definitions, secret references, IAM, seeding dependencies,
and rejection of unsafe networking. Existing CI runs the fresh-instance
three-flag solver through `ctf challenge healthcheck` against local Compose.
Neither proves live Fargate startup, volume ownership, endpoint permissions,
or cross-team isolation; those remain part of the AWS rehearsal.

There is deliberately no `player_ipv4_cidrs` input here: nothing player-facing
exists yet. The next access layer must allow the company VPN CIDR **and** enforce
team authorization before forwarding to a team's backend. It must also update
the artifact/solver transport contract for HTTPS. Current backend-only Gitea
uses a loopback root URL and the existing internal ports 3000/4566; these are
not advertised as usable player endpoints.
