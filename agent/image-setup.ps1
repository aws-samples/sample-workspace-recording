# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
<#
  Run on the WorkSpaces Applications Image Builder (as Administrator) to bake in the recorder.
  Steps:
    1. Create C:\wsrec and copy agent files
    2. Ensure ffmpeg is in place (C:\wsrec\ffmpeg\bin\ffmpeg.exe)
    2b. Bake in PsExec64.exe (C:\wsrec\bin) - needed to run the recorder as SYSTEM on the session desktop
    3. Ensure AWS CLI v2 is installed (auto-install if missing; bootstrap needs it to pull from S3)
    4. Write the AppStream session-scripts config to C:\AppStream\SessionScripts\config.json
  Then use Image Assistant to create the image, and deploy infra/workspaces-recording.yaml with the image name.

  Usage: copy this agent/ folder to the Image Builder, then run this script from that folder.
  ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
  [string]$FfmpegDownloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"   # Windows ffmpeg build zip; auto-download+extract
)
$ErrorActionPreference = 'Stop'

$Base = 'C:\wsrec'
$Src  = $PSScriptRoot
$FfmpegExe = Join-Path $Base 'ffmpeg\bin\ffmpeg.exe'

Write-Host "== 1) deploy agent files to $Base =="
# Bootstrap model: bake only the stable shell (session-start.ps1/session-stop.ps1)
# and a rendered seed config. record-agent.ps1 is pulled from S3 at each session start.
# Generate config.runtime.json locally from config.template.json + .env before packaging
# this folder for the Image Builder. The .env file must never be copied or uploaded.
$RuntimeConfig = Join-Path $Src 'config.runtime.json'
if (-not (Test-Path $RuntimeConfig)) {
  throw "config.runtime.json not found. Run ./upload-agent-scripts.sh --render-only locally before packaging agent/."
}
New-Item -ItemType Directory -Force -Path $Base | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Base 'ffmpeg\bin') | Out-Null
foreach ($f in @('session-start.ps1','session-stop.ps1')) {
  Copy-Item (Join-Path $Src $f) -Destination $Base -Force
  Write-Host "  copied $f"
}
Copy-Item $RuntimeConfig -Destination (Join-Path $Base 'config.json') -Force
Write-Host "  copied rendered config.runtime.json as seed config.json"

Write-Host "== 2) ensure ffmpeg =="
if (-not (Test-Path $FfmpegExe)) {
  if ($FfmpegDownloadUrl) {
    Write-Host "  downloading ffmpeg: $FfmpegDownloadUrl"
    $zip = Join-Path $env:TEMP 'ffmpeg.zip'
    Invoke-WebRequest -Uri $FfmpegDownloadUrl -OutFile $zip
    $tmp = Join-Path $env:TEMP 'ffmpeg_extract'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem -Path $tmp -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
    if (-not $found) { throw "ffmpeg.exe not found inside the downloaded archive" }
    Copy-Item $found.FullName -Destination $FfmpegExe -Force
    Write-Host "  ffmpeg in place: $FfmpegExe"
  } else {
    Write-Warning "  ffmpeg not present. Put ffmpeg.exe at $FfmpegExe, or re-run with -FfmpegDownloadUrl <url>."
  }
} else {
  Write-Host "  ffmpeg already present: $FfmpegExe"
}

Write-Host "== 2b) bake in PsExec (run recorder as SYSTEM on the session desktop) =="
$BinDir    = Join-Path $Base 'bin'
$PsExecExe = Join-Path $BinDir 'PsExec64.exe'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
if (-not (Test-Path $PsExecExe)) {
  Write-Host "  downloading Sysinternals PSTools..."
  $pz = Join-Path $env:TEMP 'PSTools.zip'
  Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/PSTools.zip' -OutFile $pz
  $pt = Join-Path $env:TEMP 'PSTools'
  Remove-Item $pt -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -Path $pz -DestinationPath $pt -Force
  $pe = Get-ChildItem -Path $pt -Recurse -Filter 'PsExec64.exe' | Select-Object -First 1
  if (-not $pe) { throw "PsExec64.exe not found inside PSTools.zip" }
  Copy-Item $pe.FullName -Destination $PsExecExe -Force
  Write-Host "  PsExec in place: $PsExecExe"
} else {
  Write-Host "  PsExec already present: $PsExecExe"
}

Write-Host "== 3) ensure AWS CLI v2 (bootstrap needs it to pull scripts from S3) =="
$awsOk = $false
try { $null = (& aws --version 2>&1); if ($LASTEXITCODE -eq 0) { $awsOk = $true } } catch {}
if ($awsOk) {
  Write-Host "  AWS CLI already installed: $(& aws --version 2>&1)"
} else {
  Write-Host "  AWS CLI not found; installing AWS CLI v2 (silent MSI)..."
  $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
  Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile $msi
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "AWS CLI MSI install failed (exit $($p.ExitCode))" }
  $awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
  if (Test-Path $awsExe) { Write-Host "  installed: $(& $awsExe --version 2>&1)" }
  else { throw "AWS CLI MSI ran but aws.exe not found at $awsExe" }
}

Write-Host "== 4) write AppStream session-scripts config =="
$sess = 'C:\AppStream\SessionScripts'
New-Item -ItemType Directory -Force -Path $sess | Out-Null
Copy-Item (Join-Path $Src 'appstream-session-scripts-config.json') -Destination (Join-Path $sess 'config.json') -Force
Write-Host "  wrote $sess\config.json"

Write-Host ""
Write-Host "IMPORTANT: record-agent.ps1 and the rendered runtime config are pulled from S3 at runtime."
Write-Host "  On the deployment machine, create agent/.env from .env.example and run:"
Write-Host "    ./upload-agent-scripts.sh    (renders config.runtime.json, then uploads the script + runtime config)"
Write-Host "  The local .env file is never uploaded."
Write-Host "  The fleet IAM role needs s3:GetObject on agent-scripts/* and kms:Decrypt (see infra/workspaces-recording.yaml)."
Write-Host ""
Write-Host "Done. Verify the rendered seed at C:\wsrec\config.json, then create the image with Image Assistant."
Write-Host "NOTE: create-image requires at least one application in the catalog, so add a placeholder first:"
Write-Host '  $ia = "C:\Program Files\Amazon\Photon\ConsoleImageBuilder\image-assistant.exe"'
Write-Host '  & $ia add-application --name Notepad --display-name Notepad --absolute-app-path "C:\Windows\System32\notepad.exe"'
Write-Host '  & $ia create-image --name wsrec-win2022-agent'
