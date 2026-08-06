<#
.SYNOPSIS
  Run cranopener against the current directory.

.DESCRIPTION
  Compose resolves relative volume paths against the compose file's directory
  rather than the shell's, derives its project name from that same directory,
  and does not allocate a terminal for `up`. All three break the ergonomics of
  the original `docker run -it --rm -v "$PWD:/workspace"`.

  This wrapper restores them: cd into a project, type cranopener, and you are
  in it against that directory.

.PARAMETER Direct
  Bypass the gateway entirely and use opencode's stock providers.

.EXAMPLE
  cranopener
  cranopener -Direct
  cranopener run "fix the failing test"
#>
[CmdletBinding()]
param(
    [switch]$Direct,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'

$Install = if ($env:CRANOPENER_HOME) { $env:CRANOPENER_HOME }
           else { Join-Path $env:USERPROFILE '.cranopener' }

if (-not (Test-Path $Install)) {
    throw "cranopener is not installed at $Install. Run scripts/install.ps1 first."
}

. (Join-Path $PSScriptRoot 'lib/launcher-lib.ps1')

$here = (Get-Location).Path
$env:CRANOPENER_WORKSPACE = ConvertTo-ComposePath $here
$env:COMPOSE_PROJECT_NAME = ConvertTo-ProjectName $here

$composeFile = if ($Direct) { 'compose.direct.yaml' } else { 'compose.yaml' }
$composePath = Join-Path $Install $composeFile

if (-not (Test-Path $composePath)) {
    throw "missing $composePath"
}

# The certificate bundle is mounted by both stacks. Compose would otherwise
# fail with an opaque mount error naming a path inside the VM.
$certPath = Join-Path $Install 'certs/dod-roots.pem'
if (-not (Test-Path $certPath)) {
    throw "missing $certPath. Place the corporate root bundle there, or an empty file if none is needed."
}

Write-Host "cranopener: $env:COMPOSE_PROJECT_NAME -> $env:CRANOPENER_WORKSPACE" `
    -ForegroundColor DarkGray

# The gateway runs detached; opencode runs in the foreground so it gets a real
# terminal. `compose up` would multiplex logs and leave the TUI nowhere to draw.
if (-not $Direct) {
    podman compose -f $composePath up -d litellm
    if ($LASTEXITCODE -ne 0) { throw "failed to start the gateway" }
}

$runArgs = @('compose', '-f', $composePath, 'run', '--rm', 'opencode')
if ($Remaining) { $runArgs += $Remaining }

podman @runArgs
exit $LASTEXITCODE
