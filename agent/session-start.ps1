# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
<#
  WorkSpaces Applications SessionStart hook - LAUNCHER (runs as SYSTEM / session 0).
  Requires session-scripts config context = "system" (needed to run PsExec -s).

  Flow (mirrors AWS official aws-samples/appstream-session-recording script_a):
    1) Pull latest record-agent.ps1 + config.json from S3 (bootstrap; logic changes need no image rebuild).
    2) Wait for the user session to become Active; capture its SessionId (+ user name best-effort).
    3) PsExec -d -i <SessionId> -s  -> run record-agent.ps1 as SYSTEM ATTACHED TO THE SESSION DESKTOP,
       so ffmpeg gdigrab CAN capture the screen, and the non-admin user CANNOT stop/tamper with it.

  ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
$ErrorActionPreference = 'SilentlyContinue'

$Base    = 'C:\wsrec'
$Agent   = Join-Path $Base 'record-agent.ps1'
$Seed    = Join-Path $Base 'config.json'
$WorkDir = 'C:\wsrec\buffer'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$Log = Join-Path $WorkDir 'bootstrap.log'
function Write-BLog([string]$m){ $l = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; try { Add-Content -Path $Log -Value $l } catch {} }

Remove-Item (Join-Path $WorkDir '.stop') -Force -ErrorAction SilentlyContinue

$cfg     = Get-Content -Raw -Path $Seed | ConvertFrom-Json
$Bucket  = $cfg.s3Bucket
$Region  = $cfg.region
$AwsPath = if ($cfg.awsPath) { $cfg.awsPath } else { 'aws' }
$Prefix  = if ($cfg.scriptsPrefix) { $cfg.scriptsPrefix } else { 'agent-scripts' }
$PsExec  = if ($cfg.psexecPath) { $cfg.psexecPath } else { 'C:\wsrec\bin\PsExec64.exe' }
# On AppStream/WorkSpaces Applications the fleet IAM role creds are exposed via a NAMED profile,
# NOT the default credential chain. Plain 'aws' calls fail with 'Unable to locate credentials'.
$AwsProfile = if ($cfg.awsProfile) { $cfg.awsProfile } else { 'appstream_machine_role' }

Write-BLog "launcher start (SYSTEM ctx). pull from s3://$Bucket/$Prefix/ profile=$AwsProfile"

# 1) pull latest record-agent.ps1 + runtime config.json from S3 (fleet role via appstream_machine_role)
& $AwsPath s3 cp ("s3://{0}/{1}/record-agent.ps1" -f $Bucket, $Prefix) $Agent --region $Region --profile $AwsProfile --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-BLog "[WARN] pull record-agent.ps1 failed (exit $LASTEXITCODE); will use local copy if present" } else { Write-BLog "pulled record-agent.ps1" }

$RuntimeCfg = $Seed
$tmp = Join-Path $Base 'config.runtime.json'
& $AwsPath s3 cp ("s3://{0}/{1}/config.json" -f $Bucket, $Prefix) $tmp --region $Region --profile $AwsProfile --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { $RuntimeCfg = $tmp; Write-BLog "pulled runtime config.json" } else { Write-BLog "no S3 config.json; using baked seed" }

if (-not (Test-Path $Agent))  { Write-BLog "[ERROR] no record-agent.ps1 available; abort"; return }
if (-not (Test-Path $PsExec)) { Write-BLog "[ERROR] PsExec not found at $PsExec; abort"; return }

# 2) wait (up to ~60s) for an Active session; grab SessionId (+ user best-effort)
$SessionId = $null; $UserName = ''
for ($i = 0; $i -lt 60; $i++) {
  foreach ($r in @(query session 2>$null)) {
    if ($r -match '\bActive\b') {
      $t = ($r.Trim() -split '\s+')
      for ($k = 0; $k -lt $t.Count; $k++) {
        if ($t[$k] -eq 'Active') { $SessionId = $t[$k-1]; if ($k -ge 2) { $UserName = $t[$k-2] }; break }
      }
      break
    }
  }
  if ($SessionId) { break }
  Start-Sleep -Seconds 1
}
if (-not $SessionId) { Write-BLog "[ERROR] no Active session found after wait; abort"; return }
Write-BLog "active session id=$SessionId user=$UserName"

# 3) launch record-agent as SYSTEM attached to the session desktop (PsExec -i <id> -s)
$psPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$peArgs = @('-d','-i',$SessionId,'-s','-accepteula',$psPath,
            '-NonInteractive','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
            '-File',$Agent,'-ConfigPath',$RuntimeCfg,'-SessionUserName',$UserName,'-SessionId',$SessionId)
& $PsExec @peArgs 2>&1 | Out-Null
Write-BLog "launched record-agent via PsExec -i $SessionId -s (rc=$LASTEXITCODE)"
