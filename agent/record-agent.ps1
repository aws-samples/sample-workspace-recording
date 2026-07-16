# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
<#
  WorkSpaces Applications screen recording agent - runs as SYSTEM attached to the SESSION DESKTOP.
  Launched by session-start.ps1 via:  PsExec -d -i <SessionId> -s powershell -File record-agent.ps1 ...

  Running as SYSTEM on the session desktop is what lets ffmpeg gdigrab capture the screen
  (a plain user-context / session-0 process cannot), and prevents the non-admin end user
  from stopping or tampering with the recording.

  Behavior: records the desktop continuously in time-segments; restarts ffmpeg on resolution
  change or crash; uploads finished segments to S3 (fleet role); on stop flag (from
  session-stop.ps1) stops gracefully and flushes remaining segments.

  NOTE: idle-based triggering (GetLastInputInfo) was intentionally removed for now -
  it is unreliable in this context and misses "watching but not typing". Revisit with
  WTSConnectState (Active/Disconnected) later. See PROGRESS.md.

  ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = 'C:\wsrec\config.json',
  [string]$SessionUserName = '',
  [string]$SessionId = ''
)
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $ConfigPath)) { $ConfigPath = 'C:\wsrec\config.json' }
$cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$Bucket     = $cfg.s3Bucket
$Region     = $cfg.region
$FfmpegPath = $cfg.ffmpegPath
$AwsPath    = if ($cfg.awsPath) { $cfg.awsPath } else { 'aws' }
$AwsProfile = if ($cfg.awsProfile) { $cfg.awsProfile } else { 'appstream_machine_role' }
$Fps        = if ($cfg.frameRate) { [int]$cfg.frameRate } else { 6 }
$SegmentSec = if ($cfg.segmentSeconds) { [int]$cfg.segmentSeconds } else { 300 }
$PollSec    = if ($cfg.pollSeconds) { [int]$cfg.pollSeconds } else { 5 }
$QuietSec   = if ($cfg.quietSeconds) { [int]$cfg.quietSeconds } else { 30 }
$UseKms     = [bool]$cfg.sseKms
$KmsKeyId   = $cfg.kmsKeyId

# SYSTEM context: use the configured fixed work dir (do NOT use %LOCALAPPDATA% - that is SYSTEM's, not the user's)
$WorkDir = if ($cfg.localDir) { [string]$cfg.localDir } else { 'C:\wsrec\buffer' }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$LogFile  = Join-Path $WorkDir 'agent.log'
$StopFlag = Join-Path $WorkDir '.stop'

function Write-Log([string]$m){ $l = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; try { Add-Content -Path $LogFile -Value $l } catch {} }

# Diagnostic: push agent.log to S3 so we can see recorder behavior even after the ephemeral instance is gone.
function Send-Log {
  if (-not (Test-Path $LogFile)) { return }
  $cp = @('s3','cp',$LogFile,("s3://{0}/{1}/agent.log" -f $Bucket, $Prefix),'--region',$Region,'--profile',$AwsProfile,'--only-show-errors')
  if ($UseKms) { $cp += '--sse'; $cp += 'aws:kms'; if ($KmsKeyId) { $cp += '--sse-kms-key-id'; $cp += $KmsKeyId } }
  try { & $AwsPath @cp 2>&1 | Out-Null } catch {}
}

# ---------- S3 key prefix (SYSTEM ctx: identity comes from launcher params, env fallback) ----------
$user = if ($SessionUserName) { $SessionUserName } elseif ($env:AppStream_UserName) { $env:AppStream_UserName } else { 'unknown' }
$sess = if ($SessionId) { $SessionId } elseif ($env:AppStream_Session_ID) { $env:AppStream_Session_ID } else { 'session' }
$comp = $env:COMPUTERNAME
$user = ($user -replace '[^A-Za-z0-9_.@=-]', '_')
$sess = ($sess -replace '[^A-Za-z0-9_.-]', '_')
$comp = ($comp -replace '[^A-Za-z0-9_.-]', '_')
$Prefix     = "recordings/$user/$(Get-Date -Format 'yyyy/MM/dd')/${comp}_${sess}"
$SegPattern = Join-Path $WorkDir 'rec_%Y%m%d-%H%M%S.mp4'

Write-Log "agent started (SYSTEM/session-desktop) user=$user sess=$sess ffmpeg=$FfmpegPath prefix=$Prefix"
if (-not (Test-Path $FfmpegPath)) { Write-Log "[ERROR] ffmpeg not found: $FfmpegPath" }
Send-Log

function Get-Resolution {
  try { return ((Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    ForEach-Object { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" }) -join ',') } catch { return '' }
}

$script:ff  = $null
$script:res = Get-Resolution

function Start-Recorder {
  if ($script:ff -and -not $script:ff.HasExited) { return }
  if (-not (Test-Path $FfmpegPath)) { Write-Log "[ERROR] ffmpeg missing, cannot record"; return }
  $a = "-hide_banner -loglevel warning -f gdigrab -framerate $Fps -i desktop " +
       "-c:v libx264 -preset veryfast -pix_fmt yuv420p -crf 28 " +
       "-f segment -segment_time $SegmentSec -reset_timestamps 1 -strftime 1 `"$SegPattern`""
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FfmpegPath; $psi.Arguments = $a
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.CreateNoWindow = $true
  try { $script:ff = [System.Diagnostics.Process]::Start($psi); Write-Log "recording started (pid $($script:ff.Id))" }
  catch { Write-Log "[ERROR] failed to start ffmpeg: $($_.Exception.Message)"; $script:ff = $null }
}

function Stop-Recorder {
  if ($script:ff -and -not $script:ff.HasExited) {
    try { $script:ff.StandardInput.Write('q'); $script:ff.StandardInput.Flush() } catch {}
    if (-not $script:ff.WaitForExit(10000)) { try { $script:ff.Kill() } catch {} }
    Write-Log "recording stopped"
  }
  $script:ff = $null
}

function Invoke-Flush {
  param([switch]$All)
  foreach ($f in (Get-ChildItem -Path $WorkDir -Filter 'rec_*.mp4' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
    if (-not $All -and ((Get-Date) - $f.LastWriteTime).TotalSeconds -lt $QuietSec) { continue }
    $key = "$Prefix/$($f.Name)"
    $cp  = @('s3','cp',$f.FullName,"s3://$Bucket/$key",'--region',$Region,'--profile',$AwsProfile,'--only-show-errors')
    if ($UseKms) { $cp += '--sse'; $cp += 'aws:kms'; if ($KmsKeyId) { $cp += '--sse-kms-key-id'; $cp += $KmsKeyId } }
    try {
      & $AwsPath @cp
      if ($LASTEXITCODE -eq 0) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; Write-Log "uploaded: $key" }
      else { Write-Log "[WARN] upload failed (exit $LASTEXITCODE): $($f.Name)" }
    } catch { Write-Log "[WARN] upload error: $($f.Name) -> $($_.Exception.Message)" }
  }
}

# ---------- Main loop: continuous segmented recording ----------
Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
Write-Log "entering main loop bucket=$Bucket"
try {
  Start-Recorder
  while (-not (Test-Path $StopFlag)) {
    $now = Get-Resolution
    if ($now -and $script:res -and $now -ne $script:res) {
      Write-Log "resolution changed ($script:res -> $now), restarting recorder"
      Stop-Recorder; $script:res = $now; Start-Recorder
    }
    if (-not $script:ff -or $script:ff.HasExited) { Write-Log "ffmpeg not running, (re)starting"; Start-Recorder }
    Invoke-Flush
    Send-Log
    Start-Sleep -Seconds $PollSec
  }
  Write-Log "stop flag detected, exiting"
}
finally {
  Stop-Recorder
  Start-Sleep -Seconds 2
  Invoke-Flush -All
  Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
  Write-Log "agent exited"
  Send-Log
}
