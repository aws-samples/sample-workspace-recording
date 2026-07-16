# AGENTS.md — Project Guidance

## Project summary

This repository implements session recording for Amazon WorkSpaces Applications (AppStream 2.0 APIs). A PowerShell agent runs as `SYSTEM` on the interactive Windows session desktop, records with ffmpeg, and uploads encrypted segments to Amazon S3 using the fleet IAM role.

Do not place account IDs, user names, bucket names, KMS key IDs, production image names, or other environment-specific identifiers in committed files.

## Operating principles

1. Never invent tool output or deployment state.
2. Treat AWS API responses and console state as authoritative external evidence.
3. Independently verify critical milestones such as CloudFormation status, fleet state, image availability, and S3 objects.
4. Clearly separate verified facts from assumptions.
5. Confirm destructive actions before deleting retained S3 or KMS resources.

## Configuration model

The public repository contains:

- `config.template.json`: JSON structure with `${WSREC_*}` placeholders.
- `.env.example`: safe example values and the complete variable list.

Local/deployment-only files are ignored by Git:

- `.env`: real values for one AWS environment.
- `config.runtime.json`: strongly typed JSON generated from the template and `.env`.

`upload-agent-scripts.sh` parses `.env` without executing it, validates all values, generates `config.runtime.json`, and uploads the generated file to S3 with the object name `config.json`. Never upload `.env`.

Bootstrap values needed to locate S3 must exist in the rendered seed configuration baked into the image. Changes to those values require regenerating the config and rebuilding the image.

## Session bootstrap architecture

- The image contains `session-start.ps1`, `session-stop.ps1`, rendered seed `C:\wsrec\config.json`, ffmpeg, PsExec, and AWS CLI v2.
- Runtime `record-agent.ps1` and rendered `config.json` are stored under the configured S3 script prefix.
- `session-start.ps1` runs as `SYSTEM`, downloads runtime files, waits for an active session, and launches the recorder with `PsExec -i <SessionId> -s`.
- `record-agent.ps1` records segmented video and uploads completed files.
- `session-stop.ps1` writes a stop flag in the configured local directory and waits for the recorder to flush.

The default CloudFormation IAM policy grants runtime reads under `agent-scripts/*`. If `WSREC_SCRIPTS_PREFIX` changes, update the IAM policy too.

## Verified platform constraints

- Traditional ON_DEMAND and ALWAYS_ON fleets require session scripts to be baked into the image.
- Fleet IAM credentials are exposed through the named profile `appstream_machine_role`; AWS CLI calls in the session must use that profile.
- ffmpeg gdigrab must run in the interactive session desktop. Session 0 cannot capture it.
- Windows PowerShell 5.1 scripts should remain ASCII-only.
- `MaxSessionsPerInstance` is valid only from 2 to 50. The template omits it for single-session fleets.
- A newly created fleet may be stopped and must be started explicitly.
- Low service quotas can prevent a fleet from starting even when no detailed fleet error is returned.
- S3 and KMS resources use retention-oriented deletion policies; do not assume stack deletion removes stored recordings.

## Validation expectations

Before reporting success:

- Validate JSON templates and generated configuration.
- Run `bash -n` on shell scripts.
- Parse PowerShell scripts when `pwsh` or Windows PowerShell is available.
- Validate CloudFormation with `cfn-lint` or an equivalent schema-aware tool.
- Verify fleet, stack, image, and S3 states with independent AWS queries.
- Scan committed files for account IDs, ARNs, bucket names, KMS IDs, emails, and environment-specific resource names.

## Security expectations

- Never commit `.env` or `config.runtime.json`.
- Store passwords, tokens, and private keys in AWS Secrets Manager or Systems Manager Parameter Store, not in rendered JSON.
- Restrict write access to the runtime script prefix because its code executes as `SYSTEM`.
- Apply least-privilege IAM and audit access to recordings.
- Address notice, consent, retention, legal hold, and privacy requirements for the jurisdictions where the solution is deployed.
