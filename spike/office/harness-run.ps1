<#
.SYNOPSIS
  The real-harness half of step 4, with its prerequisites checked first.

.DESCRIPTION
  probe.sh step 4 measures whether the MODEL keeps emitting parseable tool
  calls across a flattened conversation. That is the question a trip cannot
  answer twice, and it runs over curl from the WSL2 VM.

  This is the other half: the same task through the actual OpenHands harness,
  in a container, against the gateway. It is a separate script because it needs
  an entirely different machine's worth of software -- pwsh, podman, the built
  image, and an installed ~/.cranopener -- and until 2026-08-08 that fact was
  hidden inside a block of text probe.sh printed at the end of a run. Two
  office visits produced no step 4 as a result.

  Everything is checked before anything is started. At the office the failure
  that costs a month is not "this did not work", it is "this did not work and
  I found out forty minutes in".

.PARAMETER Model
  The model id as the gateway names it -- the same string you would pass to
  cranopener -Model. Required, because the harness follows from the id.

.PARAMETER Task
  What to ask the agent to do. Defaults to a task that needs several turns and
  leaves evidence on disk.

.PARAMETER OutFile
  Where to tee the transcript. Defaults to 04-harness-run.log beside this
  script's output directory.

.EXAMPLE
  pwsh -File spike\office\harness-run.ps1 -Model provider-a/some-model
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Model,
    [string]$Task = 'add a failing test, then make it pass',
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# podman reports "no" as a non-zero exit rather than as a failure, and the
# checks below read exit codes deliberately.
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Launcher = Join-Path $RepoRoot 'scripts\cranopener.ps1'
$Install  = if ($env:CRANOPENER_HOME) { $env:CRANOPENER_HOME }
            else { Join-Path $env:USERPROFILE '.cranopener' }
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'out\04-harness-run.log' }

# --- prerequisites, all of them, before anything starts --------------------
# Collected rather than thrown one at a time: finding out about these one run
# at a time is how a visit gets spent. Same reason probe.sh reports every
# missing PROBE_ variable at once.
$missing = @()

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    $missing += 'podman is not on PATH'
} else {
    podman info *> $null
    if ($LASTEXITCODE -ne 0) {
        $missing += 'podman is installed but not answering -- is the machine started? (podman machine start)'
    }
}

if (-not (Test-Path $Launcher)) {
    $missing += "the launcher is missing at $Launcher"
}

if (-not (Test-Path $Install)) {
    $missing += "cranopener is not installed at $Install -- run scripts\install.ps1"
} else {
    # Mirrors the launcher's own list for the proxied path. Checked here too,
    # because the launcher checks them after it has already started a pod.
    foreach ($rel in @('certs/extra-roots.pem', 'litellm/config.yaml', 'gateway.yaml')) {
        $p = Join-Path $Install ($rel -replace '/', '\')
        if (-not (Test-Path $p)) { $missing += "missing $p" }
        elseif ((Get-Item $p).Length -eq 0) { $missing += "$p is empty" }
    }
}

$image = if ($env:CRANOPENER_IMAGE) { $env:CRANOPENER_IMAGE }
         else { 'ghcr.io/supremecommanderhedgehog/cranopener:latest' }
if ($missing.Count -eq 0) {
    podman image exists $image
    if ($LASTEXITCODE -ne 0) {
        $missing += "no local image $image -- pull it before the visit, it is several GB"
    }
}

if ($missing.Count -gt 0) {
    Write-Host 'harness-run.ps1: not ready to run. Nothing was started.' -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'probe.sh step 4 does not need any of this -- it measures the model' -ForegroundColor Yellow
    Write-Host 'over curl and has probably already answered the question this was' -ForegroundColor Yellow
    Write-Host 'going to answer. This script adds the real harness on top.' -ForegroundColor Yellow
    exit 2
}

# --- run it ----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null

Write-Host "model:  $Model"
Write-Host "task:   $Task"
Write-Host "log:    $OutFile"
Write-Host ''
Write-Host 'Keep the log whatever happens. It is the only record of this step,' -ForegroundColor Yellow
Write-Host 'and the next chance to produce one is a month away.' -ForegroundColor Yellow
Write-Host ''

# No `run` verb: on the OpenHands path the whole argument list is the task, and
# the launcher refuses the combination rather than absorbing it.
& $Launcher -Model $Model $Task 2>&1 | Tee-Object -FilePath $OutFile
$rc = $LASTEXITCODE

Write-Host ''
Write-Host "exit status: $rc"
if ($rc -ne 0) {
    Write-Host 'Non-zero is a real finding on this path, not noise: the adapter takes' -ForegroundColor Yellow
    Write-Host 'its verdict from the event stream because the CLI underneath exits 0' -ForegroundColor Yellow
    Write-Host 'even when every request failed. Read the log for which bound stopped it.' -ForegroundColor Yellow
    Write-Host 'If it was the iteration cap, raise CRANOPENER_MAX_ITERATIONS and rerun --' -ForegroundColor Yellow
    Write-Host 'a run stopped by the cap looks a lot like a run that gave up.' -ForegroundColor Yellow
}
exit $rc
