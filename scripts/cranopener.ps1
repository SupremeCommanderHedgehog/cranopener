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
  Cannot be combined with -Down, which always acts on the shared gateway.

.PARAMETER Down
  Stop and remove the shared gateway, then exit. This always targets the
  shared gateway, whatever directory it is run from.

  Worth running when you finish for the day. The gateway holds the real
  provider credentials for every project, and it is shared and long-lived by
  design, so leaving it up keeps those credentials live in a container whose
  environment `podman inspect` prints in plaintext. Do not leave it running
  indefinitely across projects you are no longer working in.

.PARAMETER Model
  The model to run, named exactly as the gateway's config.yaml names it --
  e.g. provider-a/some-model. Omitted, opencode runs with whatever its own
  config selects.

  Always the gateway's name for it, never a harness's. Each harness needs the
  id in its own dialect -- litellm wants a transport prefix, opencode wants its
  provider id -- and both are added here, so the same string works for either.
  With -Direct there is no gateway, so the model is whatever opencode's own
  stock providers call it: anthropic/some-model.

  This also selects the harness: a provider-A model runs under OpenHands,
  everything else under opencode. Deliberately not a separate flag. A flag can
  be set to contradict the model, and opencode against a provider that refuses
  the `tools` parameter fails on its first tool call with an error that reads
  as a gateway outage rather than as a misconfiguration.

.EXAMPLE
  cranopener
  cranopener -Direct
  cranopener -Down

.EXAMPLE
  cranopener run "fix the failing test"

  `run` is opencode's verb, and it belongs only to models that run under
  opencode.

.EXAMPLE
  cranopener -Model provider-a/some-model "fix the failing test"

  No verb. A provider-A model runs under OpenHands, where the whole argument
  list is the task -- `run` would silently become the first word of the prompt,
  so the launcher refuses it rather than spending a full iteration budget on a
  corrupted instruction and reporting success.
#>
# PositionalBinding = $false, and it is load-bearing. Parameters are positional
# by default in declaration order, so a plain [string]$Model silently claims
# position 0 -- and every documented invocation of this script passes the agent
# command there. `cranopener run "fix the failing test"` then binds Model='run'
# and forwards `--model run` to opencode, which is a broken run dressed up as a
# configured one. Named-only is the only form that cannot do that. $Remaining
# still collects everything unbound, which is what makes the arguments flow
# through untouched.
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Direct,
    [switch]$Down,
    [string]$Model,
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

# -Direct promises no pod is involved and -Down acts only on the pod, so the
# combination asks for two contradictory things. Silently honouring one of
# them would tear down a gateway other projects are using on behalf of someone
# who asked not to touch it.
if ($Down -and $Direct) {
    throw '-Direct and -Down cannot be combined: -Down always acts on the shared gateway, and -Direct means no gateway is involved. Run cranopener -Down on its own to stop it.'
}

# Derived, never asked for. See the .PARAMETER Model note above: a harness flag
# could be set to contradict the model, and that contradiction is the failure
# this whole arrangement exists to make unrepresentable.
$harness = Get-HarnessForModel $Model

# Same shape of contradiction as -Direct/-Down above, for the same reason.
# Provider A exists only as a model_list entry in the gateway's config -- it is
# not a stock opencode provider and nothing outside the gateway serves it. So
# -Direct, which promises no gateway, asks for a model that cannot be reached
# by any route. Refusing here costs a line; allowing it costs a failure at an
# endpoint the operator did not know they were not talking to. Checked before
# anything is started, because the alternative is diagnosing this from podman's
# output.
if ($Direct -and $harness -eq 'openhands') {
    throw "-Direct cannot be used with -Model $Model. That model is served only by the gateway, and -Direct bypasses the gateway entirely, so there is nothing to reach. Drop -Direct to run it through the gateway, or name a model your stock providers serve."
}

# The task itself, checked up here with the other contradictions rather than at
# the point of use: everything between the two starts a gateway pod shared with
# every other project, and bringing that up for a session that was never going
# to run is a slow way to say no -- on a machine with no engine, a 90-second
# way.
#
# Two objections, and the second is the one that costs money. There is no
# interactive mode on this path, so a missing task is unrunnable; and there is
# no verb either, so the `run` that every opencode example above builds into the
# hand would be absorbed into the prompt and the run would proceed against an
# instruction nobody wrote. The decision is in launcher-lib.ps1 so
# test-launcher.ps1 can pin it without podman.
if ($harness -eq 'openhands') {
    $objection = Get-OpenHandsTaskObjection -Remaining $Remaining -Model $Model
    if ($objection) { throw $objection }
}

if ($Down) {
    # Validated here rather than by the $required loop below, which -Down
    # returns before reaching. Without this a Direct-only or half-finished
    # install gets podman's raw "no such file" naming a path the user never
    # typed, instead of a message that says what to do about it.
    if (-not (Test-Path $GatewayYaml)) {
        throw "missing $GatewayYaml, so there is no gateway to bring down -- see the next steps printed by install.ps1"
    }
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
    if ((Get-Item $p).Length -eq 0) {
        if ($rel -eq 'certs/extra-roots.pem') {
            throw "$p is empty. It must be a COMPLETE CA bundle -- system roots plus any corporate roots. SSL_CERT_FILE replaces the default trust store rather than adding to it, so an empty bundle means the gateway trusts nothing and every upstream call fails looking like a provider outage."
        }
        throw "$p is empty."
    }

    if ($rel -ne 'certs/extra-roots.pem') { continue }

    # Non-empty is not the same as usable, and both ways this has actually gone
    # wrong produce a plausible-looking file that the size check waves through:
    # a shell redirect capturing an error message, and Windows PowerShell 5.1's
    # `>` writing UTF-16LE (a 435KB bundle from which OpenSSL reads zero
    # certificates). Either one fails later at TLS handshake, which presents as
    # a provider outage rather than a broken file.
    #
    # Read raw bytes rather than text: PowerShell decodes the UTF-16 BOM and
    # hands back a perfectly clean "-----BEGIN CERTIFICATE-----", so a
    # text-level check reports success on a bundle with no trust anchors.
    $head = [System.IO.File]::ReadAllBytes($p)[0..26]
    if ([System.Text.Encoding]::ASCII.GetString($head) -ne '-----BEGIN CERTIFICATE-----') {
        throw "$p does not begin with -----BEGIN CERTIFICATE-----. It is not a usable PEM bundle: a UTF-16 file (Windows PowerShell's `>` writes UTF-16LE) or captured error text both land here. Rebuild it with the command install.ps1 prints."
    }
}

# Read the gateway container's whole state in one call, so Running and the
# health result cannot come from two different instants. $null when there is no
# such container.
#
# This one shells out, so it stays here. What it feeds -- Get-GatewayVerdict,
# Get-LastProbe -- is a pure decision and lives in launcher-lib.ps1 where
# test-launcher.ps1 can pin it.
function Get-GatewayState {
    $json = podman inspect --format '{{json .State}}' $GatewayCtr 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    return ($json | ConvertFrom-Json)
}

if (-not $Direct) {
    # Piped to `kube play` rather than passed as arguments because argv is
    # visible in process listings. That is a real benefit but a narrow one:
    # these values do not stay out of sight afterwards, because podman records
    # a container's environment in its state inside the machine, where `podman
    # inspect cranopener-gateway-litellm` prints them in plaintext. What this
    # buys over `kind: Secret` is lifetime, not secrecy -- these die with the
    # pod, a secret persists until someone runs `podman secret rm`.
    $passthrough = @(
        'PROVIDER_A_API_KEY', 'PROVIDER_B_API_KEY', 'PROVIDER_C_API_KEY',
        'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY'
    )

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

    $freshPod      = $false
    $startedNow    = $false
    $probeBaseline = ''

    if ($podExists) {
        # Existence is not liveness. `podman pod exists` returns 0 for a pod in
        # any state, and so does `container exists`, so after a `podman machine
        # stop`, a host reboot, or a manual `podman pod stop` every check above
        # passes on a gateway that is not running. `compose up -d` restarted a
        # stopped container for free; this has to do it deliberately. Starting
        # is the only option -- replaying the manifest would fail on the pod
        # name that already exists.
        $state = Get-GatewayState
        if ($null -eq $state -or -not $state.Running) {
            # Snapshot the last probe BEFORE starting. podman does not clear
            # .State.Health.Status when a container stops, so it goes on
            # reading 'healthy' for a gateway that is not running; comparing
            # against this proves the verdict the poll acts on was produced
            # after the start, not left over from before the stop.
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
    #
    # What counts as ready is decided by Get-GatewayVerdict, not here -- it is a
    # pure function of the container state and is unit tested in
    # test-launcher.ps1. Two of its properties are the ones that cost real
    # debugging: .State.Running gates everything, because podman leaves
    # .State.Health.Status reading 'healthy' on a container it has stopped; and
    # where this run started the pod, the status is believed only once a probe
    # has run since. This loop owns only the timing and the messages.
    $deadline   = (Get-Date).AddSeconds(90)
    # Tolerated briefly: a container podman has just been told to start may not
    # have flipped yet. Past this it means the gateway is down or crash-looping,
    # and saying so now is far better than spending the remaining 80s to say it
    # less clearly.
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

    # A pod this run did not create carries whatever environment and config the
    # run that created it had. Nothing here can safely fix that: the gateway is
    # shared, so recreating it would kill another project's live session. So
    # detect and report, and leave the decision with the operator.
    #
    # The cases that bite are a first run made before the credentials were
    # exported -- which pins value: '' into a gateway every later run silently
    # reuses -- and a rotated key that never takes effect. Both surface much
    # later as a provider 401, which points at the credential rather than at
    # the stale pod holding it.
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
                # Only the NAME is ever collected. These are credentials and
                # this list gets printed.
                if ($want -ne $have) { $stale += $n }
            }
        }

        # config.yaml is a hostPath mount that LiteLLM reads once at startup,
        # so an edit since then is live on disk and inert in the gateway.
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
    # NOT redundant with podman's default, however much it looks it. `run
    # --pod` inherits the pod's restart policy, and the gateway pod declares
    # `restartPolicy: Always` -- correct for a shared service that should
    # survive a crash, ruinous for a one-shot session that joins it. Inherited,
    # the agent exits, podman restarts it, and it exits again forever; --rm can
    # never fire because the container never stays stopped, so a `cranopener
    # run "..."` spins at 100% until someone notices. Observed at
    # RestartCount 65 with ExitCode 0. The pod is the right place for `Always`
    # and this is the right place to decline it, so the session's lifecycle
    # does not depend on which pod it happens to join.
    '--restart=no',
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

if ($harness -eq 'openhands') {
    # The operator-facing subset of what run-openhands.sh reads. It reads more
    # than this -- interpreter and generator paths, the persistence and work
    # directories, a flag that reuses an existing settings file -- and every one
    # of those names something that exists only inside the image, so forwarding
    # a Windows-side value could only break a run that worked. Which is which is
    # decided in Get-OpenHandsEnvNames, together with the reasons, because
    # test-launcher.ps1 holds both halves against the variables the adapter
    # actually reads. This comment used to claim it listed everything the
    # adapter read and did not: CRANOPENER_LLM_BASE_URL was missing, so an
    # operator who set it got the pod default and no diagnostic.
    #
    # Each is optional in the adapter and has a working default, so anything
    # unset here is silence rather than breakage.
    #
    # `--env NAME` with no value is podman's pass-through form: the value comes
    # from this process rather than from a command line that is visible in
    # process listings and read by Windows Defender besides. Used for all four
    # rather than only the credential -- the day one of these stops being a
    # plain number is the day a value-bearing form would have to be noticed and
    # changed, and it would not be.
    foreach ($n in (Get-OpenHandsEnvNames).Forward) {
        if ([Environment]::GetEnvironmentVariable($n)) { $runArgs += @('--env', $n) }
    }

    # The session's own outbound TLS. opencode gets NODE_EXTRA_CA_CERTS above;
    # these are the Python equivalents, and OpenHands is Python. Nothing on the
    # LLM path needs them -- the gateway is plain HTTP over the pod's shared
    # network namespace and the gateway owns the upstream TLS -- but the agent
    # runs git, pip, and uv against a proxy with its own roots, and a failure
    # there surfaces mid-task as an unexplained tool error.
    #
    # These REPLACE the default trust store rather than adding to it, which is
    # exactly why the bundle is validated above as a complete one. Set only on
    # this path: opencode's behaviour today is the behaviour that works.
    $runArgs += @(
        '--env', 'SSL_CERT_FILE=/etc/ssl/certs/extra-roots.pem',
        '--env', 'REQUESTS_CA_BUNDLE=/etc/ssl/certs/extra-roots.pem'
    )
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
if ($harness -eq 'openhands') {
    # $Remaining is non-empty here: a task is required, and the refusal for a
    # missing one is up with the other contradictions, before the shared gateway
    # is touched.
    #
    # run-openhands.sh is the one stable interface in front of a CLI that has
    # already changed shape once upstream, and it takes a model id litellm can
    # resolve. Get-LitellmModelId adds the transport prefix; the adapter refuses
    # anything it cannot resolve rather than repairing it, so both halves of
    # that contract are load-bearing.
    $runArgs += @('run-openhands.sh', (Get-LitellmModelId $Model)) + $Remaining
} else {
    # -Model has to reach opencode whether or not there are other arguments.
    # Gating the whole branch on $Remaining, as this did when opencode was the
    # only harness, would silently drop the model on a bare `cranopener -Model
    # provider-b/...` and start opencode on whatever its config names -- a wrong
    # answer wearing a right one's clothes.
    $openArgs = @()
    if ($Remaining) { $openArgs += $Remaining }
    # Qualified, not passed through. opencode splits a model id on the first
    # '/' to pick a provider, so the gateway id it is given here would be read
    # as provider 'provider-b' with model 'PLACEHOLDER-MODEL' -- neither of
    # which exists. Measured: the bare form exits 1 with "Unexpected server
    # error" having sent zero requests, which points at the gateway rather than
    # at the argument. Get-OpencodeModelId leaves -Direct alone, where the
    # operator names a stock provider themselves.
    if ($Model) { $openArgs += @('--model', (Get-OpencodeModelId $Model -Direct:$Direct)) }
    if ($openArgs) { $runArgs += @('opencode') + $openArgs }
}

podman @runArgs
exit $LASTEXITCODE
