# Disposable team stacks

One private ECS Fargate service per team, separate from the stateful CTFd host.
Optional `team_access` adds an internal HTTPS load balancer and private DNS.
Players use the existing company VPN; no player helper or additional VPN is
required. **Team endpoint ownership is honor-system**, not authenticated:
players on the shared VPN can visit another team's endpoint. Separate task
storage and restricted task networking contain damage to a backend, but do not
stop deliberate cross-team access through the load balancer.

This configuration still needs a two-team AWS rehearsal before a live event.

## Player access

Supply an existing private Route53 zone associated with this VPC, an ACM
certificate in this account/region, a domain, and the VPN source IPv4 CIDRs
actually seen by the ALB (account for company VPN NAT). For domain
`ctf.example.com`, team `red` gets:

- Assigned team hostname: `red.ctf.example.com` (an identifier, not a DNS record).
- Gitea: `https://gitea-red.ctf.example.com`.
- LocalStack: `https://aws-red.ctf.example.com`.

A certificate for `*.ctf.example.com` covers both endpoints. Company DNS must
resolve the private zone for VPN clients, and their browsers, Git, and AWS CLI
must trust the certificate chain. Both endpoints use port 443. TLS terminates
at the ALB; forwarding inside the private VPC is HTTP on ports 3000/4566,
restricted to the ALB security group. Unknown hostnames receive 404; direct
player access to task ports is not permitted.

Omit `team_access` or set it to `null` for closed backends. With access enabled,
the configuration caps teams at 30 to fit the default 60 ALB security-group
egress rules. Check Fargate vCPU, subnet address, and load-balancer quotas before
provisioning; the cap does not guarantee account capacity.

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

1. Use [operator image publishing](../../operator/README.md) to mirror Gitea and
   publish the existing seeders to foundation ECR. Supply Linux amd64 digests.
   Never push the player artifact or answer keys to runtime ECR.
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
terraform plan -var-file=event.tfvars -var-file=/absolute/path/images.tfvars.json -out=teams.tfplan
# Review the plan before provisioning billable resources.
terraform apply teams.tfplan
terraform output
```

Start with the example's empty `team_ids`; then use the
[operator commands](../../operator/README.md) and their managed roster to add
teams. `team_ids` are stable operator-assigned identifiers, not CTFd team registration
automation. Adding an ID creates a stack; removing one destroys its service,
task definition, role, security group, and logs. An empty set removes all teams
but retains the cluster and optional load balancer. Changing shared images or secret version replaces
every team's task, so avoid it mid-event unless a full reset is intended.

The operator's `reset` command replaces one task and verifies the new ECS
deployment completed. It does not touch CTFd scores, accounts, or other teams. Destroying this teams
state deletes its logs and ephemeral challenge data, not company networks,
endpoints, ECR images, source secrets, or platform state.

## Verification and next boundary

`mise run terraform:check` validates all three roots and runs native mock tests,
including two-team definitions, secret references, IAM, seeding dependencies,
and rejection of unsafe networking. Existing CI runs the fresh-instance
three-flag solver through `ctf challenge healthcheck` against local Compose.
Neither proves live Fargate startup, volume ownership, endpoint permissions,
or cross-team isolation; those remain part of the AWS rehearsal.

The challenge artifact must be built with the HTTPS transport settings in the
operator guide. Terraform configures the matching runtime handoff automatically
when `team_access` is enabled. Local Compose retains its HTTP defaults.
