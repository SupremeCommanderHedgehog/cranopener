# Pure functions shared by cranopener.ps1 and install.ps1, unit tested without
# podman or an install directory.
#
# What belongs here is decidability: anything that DECIDES something lives
# here so a test can pin it, anything that shells out stays in its script.
# Every function below was inline first, and every one of them had a bug a
# unit test would have caught.

function ConvertTo-PodmanPath {
    <#
    .SYNOPSIS
      Render a Windows path so podman can parse it in a volume specification.

    .DESCRIPTION
      `podman run -v` splits volume specifications on ':'. A Windows path like
      C:\Users\me\proj therefore parses as host "C" with container path
      "\Users\me\proj". Forward slashes remove the ambiguity.

      This is NOT the translation hostPath needs -- see ConvertTo-VmPath. The
      two are different on purpose and are not interchangeable.
    #>
    param([Parameter(Mandatory)][string]$Path)

    # NOTE: for a Kubernetes hostPath value, use ConvertTo-VmPath below
    # instead -- this returns a Windows-style path, which hostPath cannot use.
    $normalized = $Path -replace '\\', '/'

    # A trailing separator would produce a doubled slash in the volume spec --
    # except at a drive root, where trimming it leaves "C:" and the volume
    # then reads "C::/workspace".
    if ($normalized.Length -gt 1 -and $normalized -notmatch '^[A-Za-z]:/$') {
        $normalized = $normalized.TrimEnd('/')
    }

    return $normalized
}

function ConvertTo-ProjectName {
    <#
    .SYNOPSIS
      Derive a per-project label value from a working directory.

    .DESCRIPTION
      Kube play sets no labels of its own, and the gateway pod is shared by
      every project, so without this there would be nothing distinguishing one
      project's session from another's in `podman ps`. The launcher applies
      the result as cranopener.project on the agent container.

      The leaf directory alone is not enough. Two clients each with an "api"
      directory is an ordinary layout, and colliding on it reintroduces the
      exact failure this function exists to prevent. A short digest of the
      full path is appended so the name stays unique while remaining
      recognisable at a glance.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $normalized = ConvertTo-PodmanPath $Path

    # Normalise before hashing so C:\a\b, C:/a/b, and C:\a\b\ are one project
    # rather than three.
    $canonical = $normalized.TrimEnd('/').ToLower()

    $leaf = $normalized -split '/' |
        Where-Object { $_ -ne '' } |
        Select-Object -Last 1

    if (-not $leaf) { $leaf = 'root' }

    # Label values allow lowercase alphanumerics, hyphens, and
    # underscores. Fold anything else to a hyphen, then tidy the result so a
    # directory like "my..proj" does not become "my--proj".
    $leaf = $leaf.ToLower() -replace '[^a-z0-9_-]', '-'
    $leaf = $leaf -replace '-{2,}', '-'
    $leaf = $leaf.Trim('-')

    if (-not $leaf) { $leaf = 'root' }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
        $digest = ($sha.ComputeHash($bytes) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }

    return "cranopener-$leaf-$($digest.Substring(0, 6))"
}

function ConvertTo-VmPath {
    <#
    .SYNOPSIS
      Translate a Windows path to the path the podman machine sees.

    .DESCRIPTION
      `podman run -v` accepts a Windows path and translates it. `podman kube
      play` does not: hostPath resolves inside the machine, so C:/x is looked
      up as /C:/x and reported missing. The machine mounts Windows drives
      under /mnt, so C:\Users\me becomes /mnt/c/Users/me.

      The two forms are interchangeable everywhere else in this project, which
      is precisely why this is easy to get wrong. Use this for a Kubernetes
      hostPath value only -- for a `podman run -v` volume spec, use
      ConvertTo-PodmanPath instead, which returns a Windows-style path.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path -replace '\\', '/'

    if ($normalized -notmatch '^([A-Za-z]):(/.*)?$') {
        throw "ConvertTo-VmPath requires an absolute drive-letter path like 'C:\Users\me', got '$Path'."
    }

    $drive = $Matches[1].ToLower()
    $rest = $Matches[2]

    # Trailing separators would produce a doubled slash when joined. A drive
    # root reduces to the mount point itself.
    if ($rest) { $rest = $rest.TrimEnd('/') }

    return "/mnt/$drive$rest"
}

function New-GatewayEnvBlock {
    <#
    .SYNOPSIS
      Render a Kubernetes env block from a set of variable names and values.

    .DESCRIPTION
      Credentials must not be written to a file the operator manages, and
      `podman kube play` has no --env flag, so the launcher builds this block
      in memory and pipes the manifest to `podman kube play -`. Note what that
      does and does not buy: podman records the container's environment in its
      own state inside the machine, where `podman inspect` prints it in
      plaintext, so this is not secrecy. What it buys over `kind: Secret` is
      lifetime -- these values die with the pod, a secret persists until
      someone runs `podman secret rm`. stdin is also preferable to argv,
      which is visible in process listings.

      Every value is single-quoted. YAML single-quoted scalars honour no
      escape except '' for a literal quote, so this is total: a value
      containing ':', '#', '!', or a leading digit cannot alter the parse or
      the inferred type.

      A carriage return or line feed is rejected rather than escaped. This is
      deliberate, not an oversight: quoting cannot make a line break part of
      a single-quoted flow scalar without changing it, because YAML folds any
      line break inside one to a space -- so "escaping" a newline would
      silently substitute a different, wrong value rather than preserve the
      original, defeating the whole point of this function. None of the
      variables this function carries (provider API keys, proxy URLs, CA
      bundle paths) has a legitimate reason to span multiple lines, so a
      newline means the input is already wrong -- most commonly from
      `$env:KEY = Get-Content key.txt`, which keeps the file's trailing
      newline. Failing loudly here, with the offending variable named, is far
      cheaper than the alternative: a provider authentication failure that
      points at the credential instead of the launcher. Do not "fix" this by
      adding block-scalar (|/>) support -- these values must stay
      single-line, so rejection is the correct answer forever, not a
      shortcut to revisit later.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][hashtable]$Values,
        [int]$Indent = 6
    )

    $pad = ' ' * $Indent
    $lines = @("${pad}env:")

    foreach ($name in $Names) {
        $raw = ''
        if ($Values.ContainsKey($name) -and $null -ne $Values[$name]) {
            $raw = [string]$Values[$name]
        }
        if ($raw -match "[`r`n]") {
            throw "New-GatewayEnvBlock: value for '$name' contains a line break (CR or LF). Provider credentials and URLs must be single-line; check for a trailing newline from e.g. Get-Content."
        }
        $escaped = $raw -replace "'", "''"
        $lines += "${pad}  - name: $name"
        $lines += "${pad}    value: '$escaped'"
    }

    return ($lines -join "`n")
}

function Get-LastProbe {
    <#
    .SYNOPSIS
      The start time of the most recent health probe recorded on a container.

    .DESCRIPTION
      Returned as an identity, never parsed as a time: the only question ever
      asked of it is whether it differs from one snapshotted earlier, which
      proves a probe ran in between. That keeps Go's nanosecond timestamps out
      of .NET's date parser entirely.

      '' when no probe has run, when the container has no healthcheck, or when
      there is no container -- all of which mean the same thing to the caller.
    #>
    param($State)

    if ($null -eq $State -or $null -eq $State.Health -or -not $State.Health.Log) { return '' }
    return [string]$State.Health.Log[-1].Start
}

function Get-GatewayVerdict {
    <#
    .SYNOPSIS
      Decide, from a gateway container's state, whether to proceed.

    .DESCRIPTION
      Returns one of:
        ready       -- running, and freshly reported healthy
        wait        -- no verdict yet; poll again
        not-running -- the container exists but is not running
        unhealthy   -- the healthcheck has settled on a failure

      Two properties this has to keep, both of which cost real debugging:

      A recorded health verdict is not a current one. podman does not clear
      .State.Health.Status when a container stops, so it goes on reading
      'healthy' for a gateway that is not running. Believing it hands the
      session an ECONNREFUSED at the first prompt -- precisely the failure the
      poll exists to prevent. .State.Running gates everything.

      A verdict from before a restart must not be believed either. Where the
      caller started the pod on this run, the status is trusted only once a
      probe has run since -- established by comparing against ProbeBaseline,
      snapshotted before the start.

      The caller owns the timing, not this function: PastGrace says whether the
      caller's tolerance for a not-yet-started container has elapsed, so a
      container podman was just told to start is not reported down before it
      has had a chance to flip.
    #>
    param(
        $State,
        [bool]$StartedNow = $false,
        [string]$ProbeBaseline = '',
        [bool]$PastGrace = $false
    )

    if ($null -eq $State) { return 'wait' }

    if (-not $State.Running -and $PastGrace) { return 'not-running' }

    if ($State.Running) {
        $status = if ($null -eq $State.Health) { '' } else { [string]$State.Health.Status }
        $fresh = (-not $StartedNow) -or ((Get-LastProbe $State) -ne $ProbeBaseline)
        if ($fresh) {
            if ($status -eq 'healthy') { return 'ready' }
            if ($status -eq 'unhealthy') { return 'unhealthy' }
        }
    }

    return 'wait'
}

function Get-InstallBytes {
    <#
    .SYNOPSIS
      The exact bytes the installer writes for one template.

    .DESCRIPTION
      Both the copy and the drift check go through here, and that is the whole
      point. gateway.yaml is substituted on the way out, so an installed copy
      never matches the raw template; a drift check that compared against the
      raw template would flag the manifest forever and bury the one signal the
      report exists to carry. Comparing against this instead means a
      substitution-only difference reads as unchanged while every other
      difference still reports as drift. Two separate implementations of "what
      a correct install looks like" would eventually disagree -- hence one.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Relative,
        [Parameter(Mandatory)][string]$VmHome
    )

    if ($Relative -eq 'gateway.yaml') {
        # A placeholder because hostPath needs a literal path and kube YAML has
        # no interpolation. It must be the path the VM sees: hostPath does not
        # translate Windows paths. See docs/hazards.md.
        $text = (Get-Content $TemplatePath -Raw).Replace('__CRANOPENER_HOME__', $VmHome)
        # -Raw in, UTF8-no-BOM out, so the file's LF endings survive. A string
        # array would re-join with CRLF and break the launcher's marker regex.
        return (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    }

    return [System.IO.File]::ReadAllBytes($TemplatePath)
}

function Get-Sha256 {
    <#
    .SYNOPSIS
      Uppercase hex SHA-256 of a byte array.

    .DESCRIPTION
      Bytes rather than a path because the installer compares what it would
      write against what is on disk, and one side of that has never been a
      file.

      AllowEmptyCollection because PowerShell treats an empty array as a
      missing mandatory argument. Without it a zero-byte template makes the
      installer die on "cannot bind argument ... because it is an empty array",
      naming a parameter the operator never supplied. An empty file is a
      degenerate input, not an unrepresentable one -- it hashes fine.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-HarnessForModel {
    <#
    .SYNOPSIS
      Decide which agent harness a model identifier requires.

    .DESCRIPTION
      Provider A does not do native tool calling, so opencode cannot drive it.
      It does not refuse the `tools` parameter either -- it accepts the request
      and throws the definitions away, so there is no error at all: the session
      runs to its iteration limit with a model that never calls a tool.
      OpenHands renders tools into the prompt and parses them back out itself,
      so it can.

      Derived from the model rather than exposed as a flag on purpose. A flag
      can be set to contradict the model, and the resulting failure is
      expensive to diagnose and gives no hint of its cause.

      Matching is on the namespace up to and including the separator. A bare
      StartsWith on the namespace would also match 'provider-abc/', routing a
      tool-capable provider to the wrong harness for a reason nobody would
      think to look for.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Model,
        [string[]]$PromptModeNamespaces = @('provider-a')
    )

    if ([string]::IsNullOrWhiteSpace($Model)) { return 'opencode' }

    # Trimmed first: the two outcomes are not equally safe, and a stray space
    # must not be what causes the fall-through to opencode.
    $Model = $Model.Trim()

    foreach ($ns in $PromptModeNamespaces) {
        if ($Model.StartsWith("$ns/", [StringComparison]::OrdinalIgnoreCase)) {
            return 'openhands'
        }
    }

    return 'opencode'
}

function Get-OpenHandsEnvNames {
    <#
    .SYNOPSIS
      Which environment variables the launcher forwards into an OpenHands
      session, and which it reads but deliberately leaves behind.

    .DESCRIPTION
      run-openhands.sh reads nine variables from its environment. Only some of
      them are anything an operator on this side of the container has business
      setting, and which is which is not obvious from either file -- which is
      how CRANOPENER_LLM_BASE_URL came to be used by
      tests/integration/openhands-wire.sh, covered by a launcher comment
      claiming to forward "everything run-openhands.sh reads from the
      environment, and nothing else", and silently dropped. An operator who set
      it got the pod default with no diagnostic at all.

      Both halves are returned, not just the forwarded one, so
      test-launcher.ps1 can hold the pair against the variables the adapter
      actually reads and fail when they stop agreeing. A comment asserting its
      own completeness is worse than no comment, because it stops the next
      reader checking; this is the same assertion in a form that cannot quietly
      stop being true.

      Forward:
        CRANOPENER_LLM_API_KEY      the credential.
        CRANOPENER_LLM_BASE_URL     which endpoint. Its default is the gateway
                                    on the pod's shared network namespace --
                                    right for the ordinary case and wrong for
                                    anyone aiming a session somewhere else, and
                                    being wrong silently is the expensive part.
        CRANOPENER_MAX_ITERATIONS   the only real bound on an unattended run.
        CRANOPENER_TIMEOUT_SECONDS  the backstop the iteration cap cannot be.

      InImage -- read by the adapter, deliberately not forwarded:
        CRANOPENER_OPENHANDS_GENERATOR, CRANOPENER_OPENHANDS_PYTHON
                                    paths to files that exist only inside the
                                    image. A value set on Windows names nothing
                                    the container can open, so forwarding one
                                    could only break a run that worked.
        CRANOPENER_OPENHANDS_KEEP_SETTINGS
                                    reuses an agent_settings.json already on
                                    disk instead of generating one. Nothing is
                                    mounted at the persistence directory, so
                                    the only file it could reuse is one this
                                    launcher did not put there.
        OPENHANDS_PERSISTENCE_DIR, OPENHANDS_WORK_DIR
                                    container-side paths the launcher has
                                    already decided by mounting the working
                                    directory at /workspace, which is
                                    OPENHANDS_WORK_DIR's default. Moving either
                                    aims the harness at somewhere nothing is
                                    mounted.

      Nothing is forwarded by value: `podman --env NAME` takes it from the
      launcher's own process. Uniform across all four rather than only the
      credential, because the day one of these stops being a plain number is
      the day a value-bearing form would have to be noticed and would not be.
    #>

    return @{
        Forward = @('CRANOPENER_LLM_API_KEY',
                    'CRANOPENER_LLM_BASE_URL',
                    'CRANOPENER_MAX_ITERATIONS',
                    'CRANOPENER_TIMEOUT_SECONDS')
        InImage = @('CRANOPENER_OPENHANDS_GENERATOR',
                    'CRANOPENER_OPENHANDS_KEEP_SETTINGS',
                    'CRANOPENER_OPENHANDS_PYTHON',
                    'OPENHANDS_PERSISTENCE_DIR',
                    'OPENHANDS_WORK_DIR')
    }
}

function Get-OpenHandsTaskObjection {
    <#
    .SYNOPSIS
      Why these arguments cannot be an OpenHands task, or $null if they can.

    .DESCRIPTION
      Two failures, both of which the rest of this project makes easy to walk
      into, and neither of which podman or the adapter can diagnose usefully
      once the session has started.

      No task at all. The adapter runs `openhands --headless -t "TASK"` and
      there is no interactive mode on this path to fall back to.

      A leading `run`. That is opencode's grammar, and every .EXAMPLE in
      cranopener.ps1 uses it, so it is exactly what a hand reaches for. On the
      OpenHands path there is no verb -- the adapter does TASK="$*" -- so
      `cranopener -Model provider-a/x run "fix the thing"` becomes the task
      `run fix the thing`. That is not a failure anyone would notice: the run
      proceeds, spends its whole iteration budget against a corrupted
      instruction, and reports success. Refused for the same reason -Direct
      with a gateway-only model is refused -- the launcher can see the
      combination is wrong, and saying so costs one line.

      Deliberately not "handled" by stripping the verb. A launcher that
      silently rewrote the operator's words would be guessing at intent, and
      the guess is wrong for the task 'run the migration and report'. Refusing
      names the problem and leaves the sentence to the person who meant it.

      Returned as a string rather than thrown so the decision can be tested
      without invoking the launcher, which needs podman and an install tree.
    #>
    param(
        [AllowNull()][string[]]$Remaining,
        [AllowNull()][AllowEmptyString()][string]$Model
    )

    $shown = if ([string]::IsNullOrWhiteSpace($Model)) { '<model>' } else { $Model.Trim() }

    if (-not $Remaining) {
        return "-Model $shown runs under OpenHands, which has no interactive mode here -- it needs a task. Try: cranopener -Model $shown `"fix the failing test`""
    }

    # -eq on strings is case-insensitive in PowerShell, which is what is wanted:
    # `Run` is the same mistake as `run`.
    if ([string]$Remaining[0] -and ([string]$Remaining[0]).Trim() -eq 'run') {
        return "-Model $shown runs under OpenHands, which has no 'run' verb -- the whole argument list is the task, so this would run the task 'run ...' instead of the one you typed, spend its entire iteration budget on it, and report success. 'run' is opencode's verb and belongs only to models that use opencode. Drop it: cranopener -Model $shown `"fix the failing test`""
    }

    return $null
}

function Get-LitellmModelId {
    <#
    .SYNOPSIS
      Render a gateway model id as an argument litellm can resolve.

    .DESCRIPTION
      Two names are involved here and they are very easy to conflate. The
      gateway's model id -- 'provider-a/some-model' -- is what the operator
      types, and it is what must appear in the request body LiteLLM receives,
      because that is the `model_name` its `model_list` matches on. The litellm
      CLIENT inside the harness needs something else first: a leading transport
      prefix telling it how to dial. It splits on the FIRST '/', so
      'openai/provider-a/some-model' resolves the transport as 'openai' and
      leaves 'provider-a/some-model' as the model -- exactly the id the gateway
      is listening for. The base URL then decides where the request goes.

      The prefix is an internal detail of how the harness dials, so it is added
      here and appears in no template, no installed file, and nothing the
      operator types.

      Always prepended, never conditionally. Treating an id that already begins
      with a transport-looking segment as pre-prefixed would corrupt a gateway
      model legitimately named 'openai/...' -- an ordinary model_list entry --
      by sending only the remainder as the model name, which LiteLLM answers
      with a model-not-found that reads as a broken gateway.

      Applied here rather than in run-openhands.sh because the adapter's
      contract is to REFUSE a model it cannot resolve, and container-checks.sh
      pins that refusal. An adapter that quietly prefixed instead would make its
      own guard unreachable, and that guard is the only thing between a
      hand-run adapter and the failure below.

      An empty model throws rather than yielding a bare 'openai/'. That is the
      quietest failure in this whole path: litellm gives up before opening a
      socket, so the harness makes zero requests, reports no error, and exits 0
      -- indistinguishable from a clean run that had nothing to say.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Model,
        [string]$Transport = 'openai'
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        throw "Get-LitellmModelId: no model to prefix. litellm resolves the transport from the leading segment of the model id; with nothing to resolve it gives up before opening a socket, and the harness then reports success having sent no requests at all."
    }

    # Trimmed for the same reason Get-HarnessForModel trims: a stray space from
    # a quoted argument or a copied model id must not become part of the name
    # the gateway is asked to match.
    return "$Transport/$($Model.Trim())"
}

function Get-OpencodeModelId {
    <#
    .SYNOPSIS
      Render a gateway model id as an argument opencode can resolve.

    .DESCRIPTION
      The same two-names problem as Get-LitellmModelId, one layer out. opencode
      identifies a model as '<provider id>/<model key>' and splits on the FIRST
      '/' to pick the provider, so the gateway id 'provider-b/PLACEHOLDER-MODEL'
      passed through untouched is read as provider 'provider-b' with model
      'PLACEHOLDER-MODEL' -- and neither exists. The gateway is not an opencode
      provider; it is reached through the one opencode.proxied.json declares,
      whose `models` map is keyed by the full gateway id.

      This was measured, both forms, against the image with a stub endpoint
      recording every request:

        --model provider-b/PLACEHOLDER-MODEL
            exit 1, "UnknownError: Unexpected server error", ZERO requests sent
        --model cranopener/provider-b/PLACEHOLDER-MODEL
            exit 0, endpoint received model='provider-b/PLACEHOLDER-MODEL'

      The failing form is loud, which is the one merciful thing about it, but
      "Unexpected server error" points at the gateway rather than at the
      argument, and the gateway is the expensive place to go looking.

      -Direct is the exception and not a special case: it means no gateway is
      involved and opencode uses its own stock providers, where the operator has
      already named one ('anthropic/some-model'). Qualifying that would invent a
      provider that does not exist.

      Always prefixed otherwise, never conditionally, for the reason spelled out
      in Get-LitellmModelId: a gateway model legitimately named 'cranopener/...'
      would otherwise be sent as a model key its provider does not have.

    .PARAMETER ProviderId
      The provider key in opencode.proxied.json. A parameter rather than a
      literal so test-launcher.ps1 can read the shipped config and assert the
      default still matches it -- a rename there is otherwise invisible until
      every proxied run fails naming a provider opencode has never heard of.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Model,
        [switch]$Direct,
        [string]$ProviderId = 'cranopener'
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        throw "Get-OpencodeModelId: no model to qualify. opencode resolves the provider from the leading segment of the model id, so a bare '$ProviderId/' names no model at all and the run fails before it sends anything."
    }

    $Model = $Model.Trim()

    if ($Direct) { return $Model }

    return "$ProviderId/$Model"
}
