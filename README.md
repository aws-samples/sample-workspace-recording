# WorkSpaces Applications Session Recording Agent

This project records non-persistent Windows desktop sessions on **Amazon WorkSpaces Applications (AppStream 2.0 APIs)** with **ffmpeg gdigrab**. The recorder runs as `SYSTEM` on the interactive session desktop through PsExec, uploads completed segments to Amazon S3 with the fleet IAM role, and can use SSE-KMS encryption.

> The solution has been tested end to end with H.264 desktop recordings. See [`agent/REPRODUCE.md`](agent/REPRODUCE.md) for a complete deployment walkthrough.

## Architecture

The image contains a stable bootstrap layer, while mutable recording logic is distributed through S3:

| Layer | Location | Content | Change frequency |
| --- | --- | --- | --- |
| Stable bootstrap | Baked into the image | Session hooks, rendered seed config, ffmpeg, PsExec, AWS CLI v2 | Infrequent |
| Runtime layer | S3 under `agent-scripts/` | `record-agent.ps1` and rendered runtime `config.json` | Frequent |

Session flow:

1. WorkSpaces Applications runs `session-start.ps1` as `SYSTEM`.
2. The launcher uses the rendered seed config to download the latest recorder and runtime config from S3.
3. The launcher waits for an active user session.
4. PsExec starts `record-agent.ps1` as `SYSTEM` inside that session desktop.
5. ffmpeg records time-based segments and uploads completed files to S3.
6. `session-stop.ps1` writes a stop flag so the recorder flushes remaining segments before termination.

## Configuration security model

Configuration is split into four files:

| File | Git status | Purpose |
| --- | --- | --- |
| `agent/config.template.json` | Committed | JSON structure containing `${WSREC_*}` placeholders only |
| `agent/.env.example` | Committed | Safe example values and the complete variable list |
| `agent/.env` | Ignored | Real values for one AWS environment |
| `agent/config.runtime.json` | Ignored and generated | Fully typed JSON consumed by the image and uploaded to S3 as `config.json` |

JSON cannot load environment variables by itself. `agent/upload-agent-scripts.sh` safely parses `.env`, resolves every placeholder, restores number and Boolean types, validates required values, and writes `config.runtime.json`. It does not execute the `.env` file as shell code.

Create the local configuration:

```bash
cd agent
cp .env.example .env
# Edit .env for your AWS environment.
./upload-agent-scripts.sh --render-only
```

Never commit or distribute `agent/.env` or `agent/config.runtime.json`. They contain environment-specific resource identifiers. For actual passwords, tokens, or private keys, use AWS Secrets Manager or AWS Systems Manager Parameter Store instead of rendering them into JSON.

## Configuration variables

| Variable | Runtime field | Description |
| --- | --- | --- |
| `WSREC_S3_BUCKET` | `s3Bucket` | Recording bucket; must be in the configured Region |
| `WSREC_REGION` | `region` | AWS Region |
| `WSREC_FFMPEG_PATH` | `ffmpegPath` | ffmpeg path inside the image |
| `WSREC_AWS_PATH` | `awsPath` | AWS CLI path inside the image |
| `WSREC_AWS_PROFILE` | `awsProfile` | Fleet role profile, normally `appstream_machine_role` |
| `WSREC_SCRIPTS_PREFIX` | `scriptsPrefix` | S3 prefix for runtime files; the default IAM policy expects `agent-scripts` |
| `WSREC_LOCAL_DIR` | `localDir` | Local recording buffer and log directory |
| `WSREC_PSEXEC_PATH` | `psexecPath` | PsExec64 path inside the image |
| `WSREC_FRAME_RATE` | `frameRate` | Recording frame rate, positive integer |
| `WSREC_SEGMENT_SECONDS` | `segmentSeconds` | Segment duration in seconds |
| `WSREC_IDLE_THRESHOLD_SECONDS` | `idleThresholdSeconds` | Reserved; currently not used to stop recording |
| `WSREC_POLL_SECONDS` | `pollSeconds` | Main loop interval |
| `WSREC_QUIET_SECONDS` | `quietSeconds` | Minimum file quiet period before upload |
| `WSREC_SSE_KMS` | `sseKms` | `true` to request SSE-KMS during upload |
| `WSREC_KMS_KEY_ID` | `kmsKeyId` | Optional customer-managed KMS key ID or alias; may be empty to use bucket defaults |

The S3 recording key format is:

```text
recordings/<user>/<yyyy>/<MM>/<dd>/<host>_<session>/rec_<timestamp>.mp4
```

## Repository layout

| File | Purpose |
| --- | --- |
| `agent/config.template.json` | Public configuration template with placeholders |
| `agent/.env.example` | Public local-configuration example |
| `agent/upload-agent-scripts.sh` | Renders the runtime config and publishes mutable files to S3 |
| `agent/record-agent.ps1` | Records, rotates, uploads, and removes completed local segments |
| `agent/session-start.ps1` | Baked launcher that downloads runtime files and starts the recorder |
| `agent/session-stop.ps1` | Baked termination hook that requests a graceful flush |
| `agent/appstream-session-scripts-config.json` | Session script configuration written into the image |
| `agent/image-setup.ps1` | Installs bootstrap files, ffmpeg, PsExec, and AWS CLI in Image Builder |
| `infra/workspaces-recording.yaml` | CloudFormation for S3, KMS, IAM, fleet, and stack resources |
| `agent/REPRODUCE.md` | Complete deployment and verification walkthrough |

## Publish runtime files

`upload-agent-scripts.sh` always renders and validates `config.runtime.json` first. By default it then uploads:

- `record-agent.ps1` as `s3://<bucket>/<prefix>/record-agent.ps1`
- `config.runtime.json` as `s3://<bucket>/<prefix>/config.json`

```bash
cd agent
./upload-agent-scripts.sh
```

Additional modes:

```bash
./upload-agent-scripts.sh --render-only  # Generate and validate; no AWS call
./upload-agent-scripts.sh --no-config    # Upload only record-agent.ps1
```

The local `.env` file is never uploaded.

## Build the image

Generate the runtime config before packaging the `agent/` directory:

```bash
cd agent
./upload-agent-scripts.sh --render-only
zip -r /tmp/agent.zip . -x '*.md' '.env' '.env.example'
```

After copying the package into a Windows Image Builder, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\image-setup.ps1
```

`image-setup.ps1` requires `config.runtime.json` and copies it to `C:\wsrec\config.json` as the seed configuration. It never needs `.env`.

## Important operational details

- All AWS CLI calls in the session use `--profile appstream_machine_role` because fleet role credentials are exposed through that named profile.
- ffmpeg must run as `SYSTEM` in the interactive session desktop through `PsExec -i <SessionId> -s`; session 0 cannot capture the desktop.
- PowerShell scripts remain ASCII-only for compatibility with Windows PowerShell 5.1.
- The default IAM policy grants `s3:GetObject` under `agent-scripts/*`. Changing `WSREC_SCRIPTS_PREFIX` also requires updating the CloudFormation policy.
- The current recorder runs continuously during the session; the idle threshold field is reserved for a future trigger implementation.
- `localDir` is consumed by start, stop, and recorder scripts so all components use the same stop flag and log directory.

## Security and production considerations

- Inform users and obtain any consent required by applicable workplace-monitoring and privacy laws.
- Define retention, access review, audit, legal hold, and break-glass procedures before production use.
- Consider S3 Object Lock, CloudTrail S3 data events, private subnets, S3/KMS endpoints, and least-privilege IAM.
- Restrict write access to the runtime script prefix because its PowerShell code executes as `SYSTEM` in every session.
- Treat generated runtime configuration as environment-sensitive even when it contains identifiers rather than credentials.

## Troubleshooting

### Missing `.env`

Copy `agent/.env.example` to `agent/.env`, populate every variable, and rerun the render command from `agent/`.

### Rendered type error

Numbers and `WSREC_SSE_KMS` must use unquoted dotenv values such as `60` and `true`. The renderer rejects invalid types and non-positive intervals.

### Bootstrap cannot download runtime files

Confirm the baked seed config contains the correct bucket, Region, script prefix, AWS CLI path, and fleet profile. Bootstrap-related values require rebuilding the image when changed.

### No recordings appear

Check the configured local directory for `bootstrap.log` and `agent.log`, verify fleet IAM permissions for S3/KMS, and confirm that ffmpeg and PsExec exist in the baked image.

## Additional documentation

- [Complete deployment walkthrough](agent/REPRODUCE.md)
- [Project status and production-readiness checklist](PROGRESS.md)
- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
