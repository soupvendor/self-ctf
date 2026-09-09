# AWS operator commands

Run from the repository root on Linux, macOS, or WSL with `mise install`, Docker
Engine/Compose, and your normal company AWS profile. These commands call the
official Terraform and AWS CLIs; they do not provision credentials or networks.

## Prepare an event

1. Initialize and apply the [foundation](../terraform/README.md). Initialize
   separate [platform](../terraform/platform/README.md) and
   [teams](../terraform/teams/README.md) backends for this event.
2. Generate one event `.env` with `mise run env:init`. Reuse its flags across
   CTFd and all teams; provision the separate platform/challenge Secrets Manager
   payloads described in those guides. Do not copy the whole `.env` to tasks.
3. Supply the platform AMI, certificates, private DNS zone, VPN CIDRs, and
   foundation outputs. Check company endpoint policies, DNS forwarding, IAM
   permissions, and AWS quotas before applying compute.
4. Publish images below, then pass the resulting digest manifest as an additional
   `-var-file` when planning platform and teams. The same manifest works for both.
   Apply teams initially with `team_ids = []` and the intended `team_access`.

Keep separate checkouts/configuration for separate events. An existing foundation
state needs a reviewed apply to add the new `deployment` output before using the
commands. Existing teams need the same output; adding HTTPS to already deployed
closed backends also replaces their tasks. Review that migration separately.

## Publish runtime images

Run on a workstation with access to upstream registries and ECR. The `.env`
loaded by mise supplies the configured secrets to the image leak scan.

```bash
export AWS_PROFILE=your-company-profile
mise run aws:operator --account 123456789012 --region us-east-1 --event devops-ctf \
  publish-images --tag rehearsal-1 --output deploy/aws/images.tfvars.json
```

This mirrors four upstream images, builds the two allowlisted runtime contexts
for Linux amd64, scans **all six before any push**, and writes ECR digest inputs.
The player artifact and answer keys are never published. ECR repositories must
have immutable tags. Choose a new tag and manifest filename for each release;
an existing manifest is not overwritten. If a push fails partway, images already
pushed remain in ECR; investigate and use a new release tag for the next attempt.

## Build the shared player artifact

For AWS HTTPS access, set these nonsecret values in the event's `.env` **before**
`mise run build`:

```dotenv
GITEA_SCHEME=https
GITEA_HOST_PREFIX=gitea-
GITEA_PORT=443
LOCALSTACK_SCHEME=https
LOCALSTACK_HOST_PREFIX=aws-
LOCALSTACK_PORT=443
```

The artifact contains `{team}` hostname placeholders, not a specific team's
address. Teams receive their assigned hostname from `team_endpoints` and recover
the scheme, hostname pattern, port, and credentials while solving. Terraform
supplies matching transport settings to the runtime seeders. Use the platform
guide to bootstrap CTFd and upload the artifact through the normal ctfcli flow.
These settings are for building AWS artifacts, not for starting local Compose
with two services bound to port 443; local development retains HTTP defaults.

## Manage one team

Copy `roster.tfvars.json.example` to `deploy/aws/roster.tfvars.json` and keep that
file as the authoritative team list. For an existing event, populate it with
the currently deployed IDs first. Team IDs are assigned by the operator; CTFd
self-registration does not automatically create infrastructure or map team IDs.

```bash
mise run aws:operator --account 123456789012 --region us-east-1 --event devops-ctf \
  create red --roster deploy/aws/roster.tfvars.json \
  --var-file deploy/aws/terraform/teams/event.tfvars \
  --var-file deploy/aws/images.tfvars.json

mise run aws:operator --account 123456789012 --region us-east-1 --event devops-ctf \
  status red

mise run aws:operator --account 123456789012 --region us-east-1 --event devops-ctf \
  reset red

mise run aws:operator --account 123456789012 --region us-east-1 --event devops-ctf \
  destroy red --roster deploy/aws/roster.tfvars.json \
  --var-file deploy/aws/terraform/teams/event.tfvars \
  --var-file deploy/aws/images.tfvars.json
```

`create` and `destroy` show a saved Terraform plan, reject unrelated resource
changes, and require a typed event/team confirmation. The roster is supplied
last, overriding any `team_ids` in other var-files. A local advisory lock prevents
two commands sharing this roster from running together; S3 state locking and
Terraform's stale-plan check protect concurrent state updates. Coordinate with
other operators; do not hand-edit the roster during an operation.

`reset` erases only that team's challenge data by replacing its task. It waits
for the **new** ECS deployment to complete and rejects task-definition drift.
It leaves CTFd accounts, scores, and solves unchanged. `destroy` additionally
deletes the team's logs, DNS records, and infrastructure. The shared ALB/cluster
remain after the last team is removed. Neither command destroys platform state.

Every command checks the requested account, region, and event against Terraform
outputs and STS identity. Configured AWS endpoint overrides are disabled so an
old LocalStack environment cannot silently redirect operator AWS commands.

If apply partially fails, the intended roster is deliberately retained. Inspect
AWS/Terraform state and make a fresh, reviewed `terraform plan`/`apply` using the
same event/image var-files and the roster **last**. Do not retry `create` by
deleting the team from the roster or use targeted/forced applies. Shared image,
secret, or infrastructure updates also require a separate reviewed Terraform
plan; a one-team command refuses to smuggle those changes into an operation.

## Before a live event

Run `mise run check`, `mise run terraform:check`, and `mise run operator:check`.
Then rehearse on AWS with two teams: verify VPN-only HTTPS/DNS, seeding, restricted
backend connectivity, one-team reset/removal, and platform backup/restore. Test
the solve flow manually on infrastructure you own; automated exploit healthchecks
remain restricted to local instances by repository policy. Local tests and mock
plans are not evidence that company IAM, routing, or quotas work in AWS.
