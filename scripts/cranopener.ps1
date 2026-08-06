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

.PARAMETER Down
  Stop and remove this project's stack, then exit. The gateway is otherwise
  left running between invocations so repeated runs do not pay its startup
  cost -- but it holds the real provider credentials, so it should not be left
  running indefinitely across projects you are no longer working in.

.EXAMPLE
  cranopener
  cranopener -Direct
  cranopener run "fix the failing test"
  cranopener -Down
#>
[CmdletBinding()]
param(
    [switch]$Direct,
    [switch]$Down,
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

Write-Host "cranopener: $env:COMPOSE_PROJECT_NAME -> $env:CRANOPENER_WORKSPACE" `
    -ForegroundColor DarkGray

if ($Down) {
    podman compose -f $composePath down
    exit $LASTEXITCODE
}

# Every file the selected stack bind-mounts must exist first. A missing bind
# source fails with an opaque mount error naming a path inside the VM, or --
# worse -- gets auto-created as an empty root-owned directory that then has to
# be cleaned up by hand.
$required = @('certs/extra-roots.pem')
if (-not $Direct) { $required += 'litellm/config.yaml' }

foreach ($rel in $required) {
    $p = Join-Path $Install $rel
    if (-not (Test-Path $p)) {
        throw "missing $p -- see the next steps printed by install.ps1"
    }
    # SSL_CERT_FILE and REQUESTS_CA_BUNDLE *replace* the default trust store
    # rather than adding to it, so an empty bundle does not mean "no extra
    # roots" -- it means the gateway trusts nothing and every upstream call
    # fails looking like a provider outage.
    if ((Get-Item $p).Length -eq 0) {
        throw "$p is empty. It must be a complete CA bundle (system roots plus any corporate roots), not a placeholder."
    }
}

# The gateway runs detached; opencode runs in the foreground so it gets a real
# terminal. `compose up` would multiplex logs and leave the TUI nowhere to draw.
if (-not $Direct) {
    podman compose -f $composePath up -d litellm
    if ($LASTEXITCODE -ne 0) { throw "failed to start the gateway" }

    # `up -d` returns once the container is created, not once it serves. The
    # gateway takes seconds to load config and bind :4000, and without this
    # the first prompt of a fresh session fails with ECONNREFUSED -- a hard
    # failure in an unattended run rather than something anyone retries.
    # Read the compose healthcheck rather than running a probe of our own.
    #
    # The obvious approach -- `compose exec litellm python3 -c "<urlopen>"` --
    # runs through docker-compose.exe as a *Windows* process, and Windows
    # Defender's command-line heuristic scores inline Python that opens a URL
    # as a downloader: Trojan:Win32/Commando.A!ml, killed once per poll. It
    # surfaces as "fork/exec ... Access is denied", which reads like an
    # argument-quoting bug and is not one.
    #
    # The healthcheck runs the same probe inside the container, where Defender
    # does not see it. Reading its result keeps readiness defined in one place
    # and never builds a Windows command line that looks like a stager.
    $filter = "label=com.docker.compose.project=$env:COMPOSE_PROJECT_NAME"
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $name = podman ps --filter $filter `
                          --filter 'label=com.docker.compose.service=litellm' `
                          --format '{{.Names}}' | Select-Object -First 1
        if ($name) {
            $status = podman inspect --format '{{.State.Health.Status}}' $name 2>$null
            if ($status -eq 'healthy') { $ready = $true; break }
            if ($status -eq 'unhealthy') {
                throw "gateway reported unhealthy. Check: podman logs $name"
            }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        throw "gateway did not become ready within 90s. Check: podman compose -f `"$composePath`" logs litellm"
    }
}

# `compose run SERVICE ARGS` replaces the image's CMD rather than appending to
# it. The image is ENTRYPOINT entrypoint.sh + CMD opencode, and entrypoint.sh
# ends in `exec "$@"` -- so passing bare args would run `exec run ...` and die
# with "run: command not found". The binary has to be named explicitly.
$runArgs = @('compose', '-f', $composePath, 'run', '--rm', 'opencode')
if ($Remaining) { $runArgs += @('opencode') + $Remaining }

podman @runArgs
exit $LASTEXITCODE
