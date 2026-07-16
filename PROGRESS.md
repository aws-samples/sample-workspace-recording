# Project Status

This file summarizes the reusable implementation status of the WorkSpaces Applications session-recording project. It intentionally excludes account IDs, bucket names, KMS key IDs, user names, production image names, network IDs, and other environment-specific details.

## Current status

The core recording path has been validated end to end:

- Session hooks run as `SYSTEM`.
- `session-start.ps1` downloads the current recorder and runtime configuration from S3.
- PsExec launches ffmpeg in the active interactive session desktop.
- ffmpeg gdigrab records valid H.264 desktop video rather than a black screen.
- Completed segments upload to S3 with the fleet IAM role.
- `session-stop.ps1` requests a graceful flush before session termination.
- The recorder restarts after resolution changes or ffmpeg failure.

Deployment-specific status must be verified in the target AWS account; this repository does not claim that any public environment is currently running.

## Configuration model

Environment-specific values are no longer committed.

- `agent/config.template.json` contains `${WSREC_*}` placeholders.
- `agent/.env.example` documents safe example values.
- Local `agent/.env` contains real values and is ignored by Git.
- `agent/config.runtime.json` is generated, ignored, baked into the image as seed `C:\wsrec\config.json`, and uploaded to S3 with the object name `config.json`.
- `agent/upload-agent-scripts.sh` parses `.env` without executing it, restores JSON types, validates required values, and performs the upload.

Actual passwords, tokens, and private keys should be fetched from AWS Secrets Manager or Systems Manager Parameter Store rather than rendered into JSON.

## Architecture

### Stable image layer

- `session-start.ps1`
- `session-stop.ps1`
- Rendered seed configuration
- ffmpeg
- PsExec64
- AWS CLI v2
- WorkSpaces Applications session-script configuration

### Mutable S3 layer

- `record-agent.ps1`
- Rendered runtime `config.json`

The bootstrap pattern allows recorder logic and recording parameters to change without rebuilding the image. Bootstrap values used to locate S3 still require an image rebuild when changed.

## Important verified constraints

- Traditional ON_DEMAND and ALWAYS_ON fleets require session hooks to be baked into the image.
- Fleet IAM credentials are available through the named profile `appstream_machine_role`.
- ffmpeg must run as `SYSTEM` in the interactive session desktop through `PsExec -i <SessionId> -s`.
- Windows PowerShell 5.1 scripts should remain ASCII-only.
- Single-session fleets must omit `MaxSessionsPerInstance`; multi-session values must be between 2 and 50.
- Newly created fleets may require an explicit start operation.
- S3 and KMS resources use retention-oriented deletion policies.

## Open production-readiness work

- Add recording-coverage metrics, health checks, and alerts.
- Export bootstrap and recorder logs to a durable logging destination.
- Add bounded disk usage and retry/backoff for failed uploads.
- Move uploads away from the main recording loop if large transfers cause blocking.
- Add integrity verification for runtime PowerShell downloaded from S3.
- Restrict write access to the runtime script prefix.
- Validate performance and sizing for the selected fleet instance type.
- Use private networking, S3 gateway endpoints, and KMS endpoints where appropriate.
- Define notice, consent, retention, legal hold, access review, and audit procedures for each deployment jurisdiction.
- Evaluate a persistent desktop platform if users require retained files, applications, or settings between sessions.

## Validation checklist

Before declaring a deployment successful:

1. Validate CloudFormation and inspect the change set.
2. Verify the private image is available.
3. Verify fleet and stack state through independent AWS queries.
4. Confirm all five bootstrap/image dependencies exist in the image.
5. Confirm the S3 runtime prefix contains the recorder and rendered config.
6. Open a real streaming session and exercise normal desktop activity.
7. Confirm a completed video object exists in S3.
8. Download a sample and verify codec, dimensions, duration, and visible frame content.
9. Confirm logs do not contain upload, KMS, ffmpeg, or session-discovery failures.
10. Stop billable test resources when validation is complete.

## Key files

- `infra/workspaces-recording.yaml` — S3, KMS, IAM, fleet, stack, and association resources
- `agent/config.template.json` — public configuration template
- `agent/.env.example` — local environment example
- `agent/upload-agent-scripts.sh` — runtime config renderer and S3 publisher
- `agent/image-setup.ps1` — image bootstrap installer
- `agent/session-start.ps1` — session launcher
- `agent/session-stop.ps1` — termination and flush hook
- `agent/record-agent.ps1` — recorder and uploader
- `README.md` — project architecture, configuration, security, and operating guidance
- `agent/REPRODUCE.md` — deployment walkthrough
