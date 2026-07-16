# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
<#
  WorkSpaces Applications SessionTermination hook (SYSTEM ctx).
  Signals record-agent (running as SYSTEM on the session desktop) to stop and flush remaining
  segments to S3. record-agent deletes the stop flag once it has flushed and exited.
  ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
$ErrorActionPreference = 'SilentlyContinue'

$Base       = 'C:\wsrec'
$SeedConfig = Join-Path $Base 'config.json'
$RuntimeConfig = Join-Path $Base 'config.runtime.json'
$ConfigPath = if (Test-Path $RuntimeConfig) { $RuntimeConfig } else { $SeedConfig }
$cfg = $null
try { $cfg = Get-Content -Raw -Path $ConfigPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
$WorkDir = if ($cfg -and $cfg.localDir) { [string]$cfg.localDir } else { 'C:\wsrec\buffer' }
$Stop    = Join-Path $WorkDir '.stop'
$Log     = Join-Path $WorkDir 'bootstrap.log'
function Write-BLog([string]$m){ $l = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; try { Add-Content -Path $Log -Value $l } catch {} }

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Set-Content -Path $Stop -Value 'stop' -Force
Write-BLog "stop flag written; waiting for agent to stop ffmpeg + upload remaining segments"

# bounded wait (must fit within the session-scripts waitingTime). Agent removes .stop when done.
$max = 45; $w = 0
while ((Test-Path $Stop) -and $w -lt $max) { Start-Sleep -Seconds 2; $w += 2 }
if (Test-Path $Stop) { Write-BLog "flush wait timed out (${max}s); last segment may be incomplete" } else { Write-BLog "agent flushed and exited cleanly" }
