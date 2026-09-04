# AWS Terraform

This directory is the Terraform root for the AWS deployment. The first change
establishes the runtime contract that its ECS task definitions will consume;
AWS resources will be added in reviewable stages after that contract passes the
local end-to-end solver.

The target shape is:

- one stateful CTFd platform on EC2 with EBS-backed data
- one disposable ECS Fargate task per team
- reusable challenge images in ECR
- event flags injected into tasks at runtime
- private team DNS names emitted as Terraform outputs

The Terraform implementation must not become a second challenge definition.
It will reference the images and environment contract owned by each challenge.
