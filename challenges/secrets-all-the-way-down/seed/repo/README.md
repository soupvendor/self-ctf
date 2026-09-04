# internal-deploy

Deployment automation for the internal platform. Owned by the platform team.

CI runs on every push to `main` and deploys to the internal cloud environment.

> Runbook: if a deploy fails auth, check that the pipeline's AWS credentials in
> `.gitea/workflows/deploy.yml` still match the ones in the cloud account.
