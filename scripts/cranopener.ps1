<#
.SYNOPSIS
  Run cranopener against the current directory.

.DESCRIPTION
  The gateway is a long-lived pod shared by every project; an agent session is
  a single foreground container that joins it. Those are different kinds of
  thing, so they use different mechanisms -- `podman kube play` for the
  gateway, `podman run` for the session. Compose forced both into one file
  because it could describe both; kube YAML describes the first well and the
  second badly.

.PARAMETER Direct
  Bypass the gateway and use opencode's stock providers. No pod is involved.

.PARAMETER Down
  Stop and remove the shared gateway, then exit.

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

# Not redundant, despite appearances. This script drives control flow from
# $LASTEXITCODE -- `podman pod exists` returns 1 for "no" rather than failing,
# `podman inspect` returns non-zero for a container that has not been created
# yet, and a non-zero opencode exit is a result to forward, not an error. When
# a caller's profile sets this to $true, `Stop` above turns all three into
# terminating errors: the gateway path dies on a fresh machine, the readiness
# poll dies in its first pass, and a failing agent run raises instead of
# returning its code. Pin it so behaviour does not depend on the caller.
$PSNativeCommandUseErrorActionPreference = $false

$Install = if ($env:CRANOPENER_HOME) { $env:CRANOPENER_HOME }
           else { Join-Path $env:USERPROFILE '.cranopener' }

if (-not (Test-Path $Install)) {
    throw "cranopener is not installed at $Install. Run scripts/install.ps1 first."
}

. (Join-Path $PSScriptRoot 'lib/launcher-lib.ps1')

$PodName     = 'cranopener-gateway'
$GatewayCtr  = "$PodName-litellm"
$Image       = 'ghcr.io/supremecommanderhedgehog/cranopener:latest'
$GatewayYaml = Join-Path $Install 'gateway.yaml'

# Volume sources are Windows paths and `podman run -v` splits on ':', so they
# need the forward-slash form. This is NOT the /mnt translation hostPath needs;
# see ConvertTo-VmPath.
$InstallP  = ConvertTo-PodmanPath $Install
$here      = (Get-Location).Path
$workspace = ConvertTo-PodmanPath $here
$project   = ConvertTo-ProjectName $here

Write-Host "cranopener: $project -> $workspace" -ForegroundColor DarkGray

if ($Down) {
    # The gateway is shared, so this is not a per-project operation. Say so
    # before doing it -- `kube down` removes the pod along with any agent
    # container joined to it, including another project's live session.
    Write-Host 'The gateway is shared by every project. Bringing it down also stops' -ForegroundColor Yellow
    Write-Host 'any session currently joined to it.' -ForegroundColor Yellow
    podman kube down $GatewayYaml
    exit $LASTEXITCODE
}

# Every file mounted into a container must exist first. A missing bind source
# fails with an opaque mount error naming a path inside the VM, or is created
# as an empty root-owned directory that then has to be cleaned up by hand.
$required = @('certs/extra-roots.pem')
if (-not $Direct) { $required += @('litellm/config.yaml', 'gateway.yaml') }

foreach ($rel in $required) {
    $p = Join-Path $Install $rel
    if (-not (Test-Path $p)) {
        throw "missing $p -- see the next steps printed by install.ps1"
    }
    if ((Get-Item $p).Length -gt 0) { continue }
    if ($rel -eq 'certs/extra-roots.pem') {
        throw "$p is empty. It must be a COMPLETE CA bundle -- system roots plus any corporate roots. SSL_CERT_FILE replaces the default trust store rather than adding to it, so an empty bundle means the gateway trusts nothing and every upstream call fails looking like a provider outage."
    }
    throw "$p is empty."
}

if (-not $Direct) {
    podman pod exists $PodName 2>$null
    $podExists = ($LASTEXITCODE -eq 0)

    if ($podExists) {
        # A kube play that fails partway -- a bad hostPath is the usual cause --
        # still creates the pod. The next attempt then fails with "pod already
        # exists" and neither error names the real problem. Clear the husk.
        podman container exists $GatewayCtr 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "clearing an incomplete $PodName pod from a previous failure" -ForegroundColor Yellow
            podman pod rm -f $PodName | Out-Null
            $podExists = $false
        }
    }

    if (-not $podExists) {
        # Credentials come from this process's environment and are never
        # written to disk. They are piped rather than passed as arguments
        # because argv is visible in process listings.
        $passthrough = @(
            'PROVIDER_A_API_KEY', 'PROVIDER_B_API_KEY', 'PROVIDER_C_API_KEY',
            'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY'
        )
        $values = @{}
        foreach ($n in $passthrough) {
            $values[$n] = [Environment]::GetEnvironmentVariable($n)
        }

        # The gateway is the only container making outbound TLS calls. Both of
        # these REPLACE the default trust store rather than adding to it, which
        # is why the bundle above must be complete.
        $names = $passthrough + @('SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE')
        $values['SSL_CERT_FILE'] = '/etc/ssl/certs/extra-roots.pem'
        $values['REQUESTS_CA_BUNDLE'] = '/etc/ssl/certs/extra-roots.pem'

        $block = New-GatewayEnvBlock -Names $names -Values $values -Indent 6

        $template = Get-Content $GatewayYaml -Raw
        # \r? before the anchor: .NET's multiline '$' asserts before '\n'
        # only, so without it a CRLF copy of the template does not match and
        # the launcher reports a missing marker that is plainly visible in the
        # file. The installed copy is written by install.ps1, and PowerShell's
        # Set-Content emits CRLF by default. install.ps1 preserves LF; this is
        # the second line of defence, because a hand-edit in Notepad is not
        # something install.ps1 can prevent.
        $marker = [regex]'(?m)^[ \t]*env:[ \t]*\[\][ \t]*#[ \t]*__CRANOPENER_GATEWAY_ENV__[ \t]*\r?$'
        if (-not $marker.IsMatch($template)) {
            throw "$GatewayYaml has no __CRANOPENER_GATEWAY_ENV__ marker. Without it the gateway starts with no credentials and fails at the provider looking like an auth problem."
        }
        # A MatchEvaluator rather than a replacement string: -replace would
        # interpret '$' sequences in a credential as capture-group references.
        $manifest = $marker.Replace(
            $template,
            [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block },
            1)

        $manifest | podman kube play -
        if ($LASTEXITCODE -ne 0) { throw "failed to start the gateway" }
    }

    # `kube play` returns once the pod is created, not once it serves. Without
    # this the first prompt of a fresh session fails with ECONNREFUSED -- a
    # hard failure in an unattended run rather than something anyone retries.
    #
    # Read the pod's own healthcheck rather than probing from here. The obvious
    # approach -- `exec ... python3 -c "<urlopen>"` -- builds a *Windows*
    # command line, and Defender's heuristic scores inline Python that opens a
    # URL as a downloader: Trojan:Win32/Commando.A!ml, killed once per poll. It
    # surfaces as "fork/exec ... Access is denied", which reads like an
    # argument-quoting bug and is not one. Any probe the launcher runs is a
    # Windows command line and is subject to this.
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $status = podman inspect --format '{{.State.Health.Status}}' $GatewayCtr 2>$null
        if ($status -eq 'healthy') { $ready = $true; break }
        if ($status -eq 'unhealthy') {
            throw "gateway reported unhealthy. Check: podman logs $GatewayCtr"
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        throw "gateway did not become ready within 90s. Check: podman logs $GatewayCtr"
    }
}

$config = if ($Direct) { 'opencode.direct.json' } else { 'opencode.proxied.json' }

# A TTY only when there is a terminal on both ends. The opencode TUI needs one
# to draw, so an interactive session must keep it -- but `-t` allocates a pty
# unconditionally, and against a redirected stream that pty does two damaging
# things. Piped stdin never reaches EOF, so the container hangs forever: this
# project exists substantially for unattended runs, and AGENTS.md opens by
# saying anything that waits for input waits forever. Redirected stdout gets
# the pty's CR injection, so captured output arrives as CRLF and anything
# parsing it sees trailing '\r' on every line. Neither is hypothetical; both
# were reproduced against podman.
$tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { '-i' }
       else { '-it' }

$runArgs = @(
    'run', $tty, '--rm',
    # kube play sets no labels of its own, so this is what keeps `podman ps`
    # readable across projects -- the job COMPOSE_PROJECT_NAME used to do.
    '--label', "cranopener.project=$project",
    '-v', "${workspace}:/workspace",
    '-v', "$InstallP/certs/extra-roots.pem:/etc/ssl/certs/extra-roots.pem:ro",
    '-v', "$InstallP/opencode/${config}:/home/opencode/.config/opencode/opencode.json:ro",
    '-v', "$InstallP/opencode/AGENTS.md:/home/opencode/.config/opencode/AGENTS.md:ro",
    # Config comes from the mounts above, so seeding has nothing to do. Left
    # unset, the entrypoint tries to populate a directory podman created
    # root-owned for those mounts and warns on every launch -- noise that reads
    # like a fault and sends people chasing it.
    '--env', 'CRANOPENER_SEED_SRC=/nonexistent',
    # Additive, unlike the gateway's SSL_CERT_FILE. opencode needs the
    # corporate roots for git, npm, and gh.
    '--env', 'NODE_EXTRA_CA_CERTS=/etc/ssl/certs/extra-roots.pem'
)

if (-not $Direct) { $runArgs += @('--pod', $PodName) }

# `--env NAME` with no value is podman's pass-through form: it takes the value
# from this process rather than putting it on a command line other users can
# read.
foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY') {
    if ([Environment]::GetEnvironmentVariable($n)) { $runArgs += @('--env', $n) }
}
if ($Direct) {
    foreach ($n in 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY') {
        if ([Environment]::GetEnvironmentVariable($n)) { $runArgs += @('--env', $n) }
    }
}

# NO_PROXY is computed rather than passed through, so it has to carry a value.
# It is not a credential, so argv is fine. In proxied mode the gateway is
# reached over the pod's shared network namespace -- without localhost here a
# corporate proxy could be asked to route it.
$noProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
if (-not $Direct) {
    $noProxy = if ($noProxy) { "$noProxy,localhost,127.0.0.1" } else { 'localhost,127.0.0.1' }
}
if ($noProxy) { $runArgs += @('--env', "NO_PROXY=$noProxy") }

$runArgs += $Image

# The image is ENTRYPOINT entrypoint.sh + CMD opencode, and entrypoint.sh ends
# in `exec "$@"`. Passing bare arguments would run `exec run ...` and die with
# "run: command not found", so the binary is named explicitly. With no
# arguments the image's own CMD applies.
if ($Remaining) { $runArgs += @('opencode') + $Remaining }

podman @runArgs
exit $LASTEXITCODE
