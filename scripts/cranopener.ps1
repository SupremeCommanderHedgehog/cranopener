<#
.SYNOPSIS
  Run cranopener against the current directory.

.DESCRIPTION
  Runs an agent session against the current directory, which is mounted at
  /workspace inside the container.

  There are two moving parts. The GATEWAY is a LiteLLM pod, shared by every
  project and long-lived: it holds the provider credentials and routes model
  requests upstream. A SESSION is a single foreground container that joins
  that pod and exits when the agent is done. They are started by different
  mechanisms -- `podman kube play` for the gateway, `podman run` for the
  session -- because one is a service and the other is a one-shot process.

  Run with no arguments, this starts the gateway if it is not already up,
  waits for it to report healthy, and opens an interactive opencode session.
  With a task as arguments, it runs that task and exits with the agent's own
  status.

  Configuration lives in ~/.cranopener (override with CRANOPENER_HOME) and is
  created by scripts/install.ps1. Credentials are read from the environment --
  PROVIDER_A_API_KEY and friends -- and are never read from a file.

.PARAMETER Direct
  Bypass the gateway entirely and use opencode's stock providers, reading
  ANTHROPIC_API_KEY / OPENAI_API_KEY from your environment. No pod is started
  and none is required.

  Cannot be combined with -Down, which acts only on the gateway, or with a
  provider-A model, which only the gateway can serve.

.PARAMETER Down
  Stop and remove the shared gateway, then exit. This targets the shared
  gateway whatever directory you run it from, and it also stops any session
  currently joined to it -- including another project's.

  Worth running when you finish for the day. The gateway holds live provider
  credentials for every project, and `podman inspect` prints a container's
  environment in plaintext, so leaving it up leaves those credentials
  readable by anything that can reach the podman socket. They die with the
  pod.

.PARAMETER Model
  The model to run, named exactly as the gateway's config.yaml names it --
  for example provider-a/some-model. Omit it and opencode uses whatever its
  own config selects.

  Always give the GATEWAY's name for the model, never a harness's. Each
  harness needs the id in its own dialect: litellm wants a leading transport
  segment, opencode wants its provider id in front. Both are derived from
  what you type here, so one string works for either.

  With -Direct there is no gateway, so name a model one of opencode's stock
  providers serves instead: anthropic/some-model.

  The model also chooses the harness. A provider-A model runs under OpenHands,
  everything else under opencode. That is derived rather than exposed as a
  flag, because a flag can be set to contradict the model: opencode driving a
  provider that does not do tool calling does not fail, it runs to its
  iteration limit having never called a tool.

.PARAMETER Remaining
  Everything else on the command line, passed through to the agent untouched.
  Under opencode that is its own grammar, verb included. Under OpenHands the
  whole list is the task, and it is required -- there is no interactive mode
  on that path.

.EXAMPLE
  cranopener

  Start the gateway if needed and open an interactive opencode session.

.EXAMPLE
  cranopener -Direct

  The same, but against opencode's stock providers with no gateway involved.

.EXAMPLE
  cranopener -Down

  Stop the shared gateway. Do this at the end of the day.

.EXAMPLE
  cranopener run "fix the failing test"

  Run a task under opencode. `run` is opencode's own verb.

.EXAMPLE
  cranopener -Model provider-a/some-model "fix the failing test"

  Run a task under OpenHands. Note there is NO `run` verb here: on this path
  the whole argument list becomes the task, so a leading `run` would become
  part of the instruction. The launcher refuses that combination rather than
  spending an iteration budget on a corrupted task and reporting success.
#>
# PositionalBinding = $false is load-bearing: a positional [string]$Model would
# claim position 0 and bind Model='run'. See docs/hazards.md.
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Direct,
    [switch]$Down,
    [string]$Model,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'

# Pinned, not redundant: this script drives control flow from $LASTEXITCODE,
# which `Stop` would turn into terminating errors. See docs/hazards.md.
$PSNativeCommandUseErrorActionPreference = $false

$Install = if ($env:CRANOPENER_HOME) { $env:CRANOPENER_HOME }
           else { Join-Path $env:USERPROFILE '.cranopener' }

if (-not (Test-Path $Install)) {
    throw "cranopener is not installed at $Install. Run scripts/install.ps1 first."
}

. (Join-Path $PSScriptRoot 'lib/launcher-lib.ps1')

$PodName     = 'cranopener-gateway'
$GatewayCtr  = "$PodName-litellm"
# Overridable: harness-run.ps1 pre-flights CRANOPENER_IMAGE, so hardcoding
# here would let that preflight pass on an image this never runs.
$Image       = if ($env:CRANOPENER_IMAGE) { $env:CRANOPENER_IMAGE }
               else { 'ghcr.io/supremecommanderhedgehog/cranopener:latest' }
$GatewayYaml = Join-Path $Install 'gateway.yaml'

# Forward-slash form for `podman run -v`, which splits on ':'. NOT the /mnt
# translation hostPath needs -- see ConvertTo-VmPath and docs/hazards.md.
$InstallP  = ConvertTo-PodmanPath $Install
$here      = (Get-Location).Path
$workspace = ConvertTo-PodmanPath $here
$project   = ConvertTo-ProjectName $here

Write-Host "cranopener: $project -> $workspace" -ForegroundColor DarkGray

# Contradictory: honouring either one would tear down a shared gateway on
# behalf of someone who asked not to touch it.
if ($Down -and $Direct) {
    throw '-Direct and -Down cannot be combined: -Down always acts on the shared gateway, and -Direct means no gateway is involved. Run cranopener -Down on its own to stop it.'
}

# Derived, never asked for: a harness flag could contradict the model.
$harness = Get-HarnessForModel $Model

# Provider A is served only by the gateway, so -Direct asks for a model no
# route can reach. Checked before anything starts.
if ($Direct -and $harness -eq 'openhands') {
    throw "-Direct cannot be used with -Model $Model. That model is served only by the gateway, and -Direct bypasses the gateway entirely, so there is nothing to reach. Drop -Direct to run it through the gateway, or name a model your stock providers serve."
}

# Checked before the gateway starts: bringing up a shared pod for a session
# that cannot run is a 90-second way to say no. The decision lives in
# launcher-lib.ps1 so test-launcher.ps1 can pin it without podman.
# Why a leading `run` is refused rather than stripped: docs/hazards.md.
if ($harness -eq 'openhands') {
    $objection = Get-OpenHandsTaskObjection -Remaining $Remaining -Model $Model
    if ($objection) { throw $objection }
}

if ($Down) {
    # -Down returns before the $required loop below, so validate here rather
    # than let podman report a path the user never typed.
    if (-not (Test-Path $GatewayYaml)) {
        throw "missing $GatewayYaml, so there is no gateway to bring down -- see the next steps printed by install.ps1"
    }
    # Not a per-project operation: `kube down` also removes any agent container
    # joined to the pod, including another project's live session.
    Write-Host 'The gateway is shared by every project. Bringing it down also stops' -ForegroundColor Yellow
    Write-Host 'any session currently joined to it.' -ForegroundColor Yellow
    podman kube down $GatewayYaml
    exit $LASTEXITCODE
}

# Bind sources must exist first: podman otherwise fails with a path inside the
# VM, or creates an empty root-owned directory to clean up by hand.
$required = @('certs/extra-roots.pem')
if (-not $Direct) { $required += @('litellm/config.yaml', 'gateway.yaml') }

foreach ($rel in $required) {
    $p = Join-Path $Install $rel
    if (-not (Test-Path $p)) {
        throw "missing $p -- see the next steps printed by install.ps1"
    }
    if ((Get-Item $p).Length -eq 0) {
        if ($rel -eq 'certs/extra-roots.pem') {
            throw "$p is empty. It must be a COMPLETE CA bundle -- system roots plus any corporate roots. SSL_CERT_FILE replaces the default trust store rather than adding to it, so an empty bundle means the gateway trusts nothing and every upstream call fails looking like a provider outage."
        }
        throw "$p is empty."
    }

    if ($rel -ne 'certs/extra-roots.pem') { continue }

    # Raw bytes, not text: a UTF-16 bundle decodes back to a clean
    # "-----BEGIN CERTIFICATE-----" and contains no usable certificates at all.
    # See docs/hazards.md.
    $head = [System.IO.File]::ReadAllBytes($p)[0..26]
    if ([System.Text.Encoding]::ASCII.GetString($head) -ne '-----BEGIN CERTIFICATE-----') {
        throw "$p does not begin with -----BEGIN CERTIFICATE-----. It is not a usable PEM bundle: a UTF-16 file (Windows PowerShell's `>` writes UTF-16LE) or captured error text both land here. Rebuild it with the command install.ps1 prints."
    }
}

# One call, so Running and the health result cannot come from two different
# instants. $null when there is no such container. Shells out, so it stays
# here; the decision it feeds is pure and lives in launcher-lib.ps1.
function Get-GatewayState {
    $json = podman inspect --format '{{json .State}}' $GatewayCtr 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    return ($json | ConvertFrom-Json)
}

if (-not $Direct) {
    # Piped to `kube play`, not passed as arguments: argv is visible in process
    # listings. This buys lifetime, not secrecy -- see docs/hazards.md.
    $passthrough = @(
        'PROVIDER_A_API_KEY', 'PROVIDER_B_API_KEY', 'PROVIDER_C_API_KEY',
        'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY'
    )

    podman pod exists $PodName 2>$null
    $podExists = ($LASTEXITCODE -eq 0)

    if ($podExists) {
        # A kube play that failed partway still created the pod, and the next
        # attempt fails with "pod already exists". Clear the husk.
        podman container exists $GatewayCtr 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "clearing an incomplete $PodName pod from a previous failure" -ForegroundColor Yellow
            podman pod rm -f $PodName | Out-Null
            $podExists = $false
        }
    }

    $freshPod      = $false
    $startedNow    = $false
    $probeBaseline = ''

    if ($podExists) {
        # Existence is not liveness: `pod exists` returns 0 in any state, so
        # start it deliberately. See docs/hazards.md.
        $state = Get-GatewayState
        if ($null -eq $state -or -not $state.Running) {
            # Snapshot BEFORE starting: podman leaves .State.Health.Status
            # reading 'healthy' on a container it has stopped.
            $probeBaseline = Get-LastProbe $state
            Write-Host 'the gateway pod exists but is not running; starting it' -ForegroundColor Yellow
            podman pod start $PodName | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "failed to start the existing $PodName pod. Check: podman logs $GatewayCtr"
            }
            $startedNow = $true
        }
    }

    if (-not $podExists) {
        $freshPod = $true
        $values = @{}
        foreach ($n in $passthrough) {
            $values[$n] = [Environment]::GetEnvironmentVariable($n)
        }

        # Both REPLACE the default trust store rather than adding to it, which
        # is why the bundle above must be complete.
        $names = $passthrough + @('SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE')
        $values['SSL_CERT_FILE'] = '/etc/ssl/certs/extra-roots.pem'
        $values['REQUESTS_CA_BUNDLE'] = '/etc/ssl/certs/extra-roots.pem'

        $block = New-GatewayEnvBlock -Names $names -Values $values -Indent 6

        $template = Get-Content $GatewayYaml -Raw
        # \r? before the anchor: .NET's multiline '$' asserts before '\n' only,
        # so a CRLF copy (a Notepad edit) would not match. See docs/hazards.md.
        $marker = [regex]'(?m)^[ \t]*env:[ \t]*\[\][ \t]*#[ \t]*__CRANOPENER_GATEWAY_ENV__[ \t]*\r?$'
        if (-not $marker.IsMatch($template)) {
            throw "$GatewayYaml has no __CRANOPENER_GATEWAY_ENV__ marker. Without it the gateway starts with no credentials and fails at the provider looking like an auth problem."
        }
        # MatchEvaluator, not -replace: -replace reads '$' sequences in a
        # credential as capture-group references.
        $manifest = $marker.Replace(
            $template,
            [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block },
            1)

        $manifest | podman kube play -
        if ($LASTEXITCODE -ne 0) { throw "failed to start the gateway" }
    }

    # `kube play` returns once the pod is created, not once it serves, and a
    # fresh session would fail its first prompt with ECONNREFUSED.
    #
    # Read the pod's own healthcheck rather than probing from here: Defender
    # kills any probe this script runs. See docs/hazards.md.
    #
    # Readiness itself is Get-GatewayVerdict's decision, unit tested in
    # test-launcher.ps1. This loop owns only the timing and the messages.
    $deadline   = (Get-Date).AddSeconds(90)
    # A container just told to start may not have flipped yet. Past this it is
    # down or crash-looping, and saying so now beats waiting another 80s.
    $graceUntil = (Get-Date).AddSeconds(10)
    $ready = $false
    $state = $null
    while ((Get-Date) -lt $deadline) {
        $state = Get-GatewayState
        $verdict = Get-GatewayVerdict -State $state `
                                      -StartedNow $startedNow `
                                      -ProbeBaseline $probeBaseline `
                                      -PastGrace ((Get-Date) -gt $graceUntil)
        if ($verdict -eq 'ready') { $ready = $true; break }
        if ($verdict -eq 'not-running') {
            throw "the gateway container exists but is not running -- it may be crash-looping on a bad config. Check: podman logs $GatewayCtr"
        }
        if ($verdict -eq 'unhealthy') {
            throw "gateway reported unhealthy. Check: podman logs $GatewayCtr"
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        throw "gateway did not become ready within 90s. Check: podman logs $GatewayCtr"
    }

    # A pod this run did not create keeps the environment and config it
    # started with. Detect and report only: recreating a shared gateway would
    # kill another project's live session. See docs/hazards.md.
    if (-not $freshPod) {
        $stale = @()

        $envJson = podman inspect --format '{{json .Config.Env}}' $GatewayCtr 2>$null
        if ($LASTEXITCODE -eq 0 -and $envJson) {
            $live = @{}
            foreach ($entry in ($envJson | ConvertFrom-Json)) {
                $i = ([string]$entry).IndexOf('=')
                if ($i -ge 0) {
                    $live[([string]$entry).Substring(0, $i)] = ([string]$entry).Substring($i + 1)
                }
            }
            foreach ($n in $passthrough) {
                $want = [Environment]::GetEnvironmentVariable($n)
                if ($null -eq $want) { $want = '' }
                $have = if ($live.ContainsKey($n)) { $live[$n] } else { '' }
                # Names only. These are credentials and the list gets printed.
                if ($want -ne $have) { $stale += $n }
            }
        }

        # LiteLLM reads this hostPath mount once at startup, so a later edit is
        # live on disk and inert in the gateway.
        $cfg = Join-Path $Install 'litellm/config.yaml'
        try {
            $startedAt = [datetimeoffset]::Parse([string]$state.StartedAt)
            if ((Get-Item $cfg).LastWriteTimeUtc -gt $startedAt.UtcDateTime) {
                $stale += 'litellm/config.yaml (edited since the gateway started)'
            }
        } catch {
            # A timestamp we cannot read is not worth failing a session over.
        }

        if ($stale) {
            Write-Host ''
            Write-Host 'The running gateway does not match your current configuration:' -ForegroundColor Yellow
            foreach ($n in $stale) { Write-Host "  $n" -ForegroundColor Yellow }
            Write-Host 'It keeps the values it started with until it is replaced. To apply' -ForegroundColor Yellow
            Write-Host 'the current ones (this stops the gateway for EVERY project, so do' -ForegroundColor Yellow
            Write-Host 'not do it while another session is running):' -ForegroundColor Yellow
            Write-Host '  cranopener -Down' -ForegroundColor Yellow
            Write-Host '  cranopener' -ForegroundColor Yellow
            Write-Host ''
        }
    }
}

$config = if ($Direct) { 'opencode.direct.json' } else { 'opencode.proxied.json' }

# A TTY only when there is a terminal on both ends. Against a redirected
# stream, `-t` hangs an unattended run and CRLF-mangles captured output --
# both reproduced against podman. See docs/hazards.md.
$tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { '-i' }
       else { '-it' }

$runArgs = @(
    'run', $tty, '--rm',
    # NOT redundant with podman's default: `run --pod` inherits the gateway's
    # `restartPolicy: Always` and the session then restarts forever, at 100%
    # CPU, with --rm unable to fire. See docs/hazards.md.
    '--restart=no',
    # kube play sets no labels, so this keeps `podman ps` readable across
    # projects -- COMPOSE_PROJECT_NAME's old job.
    '--label', "cranopener.project=$project",
    '-v', "${workspace}:/workspace",
    '-v', "$InstallP/certs/extra-roots.pem:/etc/ssl/certs/extra-roots.pem:ro",
    '-v', "$InstallP/opencode/${config}:/home/opencode/.config/opencode/opencode.json:ro",
    '-v', "$InstallP/opencode/AGENTS.md:/home/opencode/.config/opencode/AGENTS.md:ro",
    # Config comes from the mounts above. Left unset, the entrypoint warns on
    # every launch about a root-owned directory it cannot seed.
    '--env', 'CRANOPENER_SEED_SRC=/nonexistent',
    # Additive, unlike the gateway's SSL_CERT_FILE. opencode needs the
    # corporate roots for git, npm, and gh.
    '--env', 'NODE_EXTRA_CA_CERTS=/etc/ssl/certs/extra-roots.pem'
)

if (-not $Direct) { $runArgs += @('--pod', $PodName) }

# `--env NAME` with no value: podman takes it from this process rather than
# from a command line other users can read.
foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY') {
    if ([Environment]::GetEnvironmentVariable($n)) { $runArgs += @('--env', $n) }
}
if ($Direct) {
    foreach ($n in 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY') {
        if ([Environment]::GetEnvironmentVariable($n)) { $runArgs += @('--env', $n) }
    }
}

if ($harness -eq 'openhands') {
    # The operator-facing subset of what run-openhands.sh reads. Which
    # variables those are, and why the rest are deliberately not forwarded,
    # is decided in Get-OpenHandsEnvNames -- test-launcher.ps1 holds both
    # halves against what the adapter actually reads.
    foreach ($n in (Get-OpenHandsEnvNames).Forward) {
        if ([Environment]::GetEnvironmentVariable($n)) { $runArgs += @('--env', $n) }
    }

    # The Python equivalents of NODE_EXTRA_CA_CERTS above, for the agent's own
    # git/pip/uv calls. Nothing on the LLM path needs them. These REPLACE the
    # trust store, which is why the bundle above is validated as complete.
    $runArgs += @(
        '--env', 'SSL_CERT_FILE=/etc/ssl/certs/extra-roots.pem',
        '--env', 'REQUESTS_CA_BUNDLE=/etc/ssl/certs/extra-roots.pem'
    )
}

# Computed, so it carries a value; not a credential, so argv is fine. Without
# localhost a corporate proxy could be asked to route the pod-local gateway.
$noProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
if (-not $Direct) {
    $noProxy = if ($noProxy) { "$noProxy,localhost,127.0.0.1" } else { 'localhost,127.0.0.1' }
}
if ($noProxy) { $runArgs += @('--env', "NO_PROXY=$noProxy") }

$runArgs += $Image

# entrypoint.sh ends in `exec "$@"`, so the binary is named explicitly --
# bare arguments would run `exec run ...`. With none, the image's CMD applies.
if ($harness -eq 'openhands') {
    # $Remaining is non-empty here; the refusal for a missing task is up with
    # the other contradictions, before the shared gateway is touched.
    # The adapter refuses a model id it cannot resolve rather than repairing
    # it, so Get-LitellmModelId adding the transport prefix is load-bearing.
    $runArgs += @('run-openhands.sh', (Get-LitellmModelId $Model)) + $Remaining
} else {
    # -Model must reach opencode with or without other arguments: gating this
    # on $Remaining would silently drop it and run whatever the config names.
    $openArgs = @()
    if ($Remaining) { $openArgs += $Remaining }
    # Qualified, not passed through -- the bare gateway id names a provider
    # opencode does not have. Measured both ways in docs/hazards.md.
    if ($Model) { $openArgs += @('--model', (Get-OpencodeModelId $Model -Direct:$Direct)) }
    if ($openArgs) { $runArgs += @('opencode') + $openArgs }
}

podman @runArgs
exit $LASTEXITCODE
