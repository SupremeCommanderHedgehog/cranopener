# Unit tests for the launcher's pure functions.
# Run: pwsh -File tests/test-launcher.ps1
#
# Deliberately no Pester dependency: it is not reliably present on a locked
# down Windows host, and these assertions are simple enough not to need it.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/lib/launcher-lib.ps1"

$script:Run = 0
$script:Failed = 0

function Assert-Eq($desc, $expected, $actual) {
    $script:Run++
    if ($expected -eq $actual) {
        Write-Host "ok   $desc"
    } else {
        $script:Failed++
        Write-Host "FAIL $desc"
        Write-Host "       expected: $expected"
        Write-Host "       actual:   $actual"
    }
}

# --- ConvertTo-PodmanPath --------------------------------------------------
# `podman run -v` splits volume specs on ':', so a raw C:\Users\... parses as
# host "C" with container path "\Users\...". Forward slashes remove the
# ambiguity.

Assert-Eq 'backslashes become forward slashes' `
    'C:/Users/me/proj' (ConvertTo-PodmanPath 'C:\Users\me\proj')

Assert-Eq 'already-forward paths are unchanged' `
    'C:/Users/me/proj' (ConvertTo-PodmanPath 'C:/Users/me/proj')

Assert-Eq 'trailing separator is stripped' `
    'C:/Users/me/proj' (ConvertTo-PodmanPath 'C:\Users\me\proj\')

Assert-Eq 'spaces are preserved' `
    'C:/Users/me/my proj' (ConvertTo-PodmanPath 'C:\Users\me\my proj')

# A drive root must keep its trailing slash. Trimming it yields "C:", and the
# volume specification then reads "C::/workspace".
Assert-Eq 'drive root keeps its slash' `
    'C:/' (ConvertTo-PodmanPath 'C:\')

Assert-Eq 'forward-slash drive root keeps its slash' `
    'C:/' (ConvertTo-PodmanPath 'C:/')

# --- ConvertTo-ProjectName -------------------------------------------------
# The gateway pod is shared and kube play sets no labels, so this value is what
# tells one project's session from another's in `podman ps`.

# The name ends in a six-hex-character digest of the full path. These cases
# are about the readable part, so strip it rather than asserting on offsets.
function Get-NamePrefix($path) {
    return (ConvertTo-ProjectName $path) -replace '-[0-9a-f]{6}$', ''
}

Assert-Eq 'derives from the leaf directory' `
    'cranopener-myproj' (Get-NamePrefix 'C:\Users\me\myproj')

Assert-Eq 'lowercases' `
    'cranopener-myproj' (Get-NamePrefix 'C:\Users\me\MyProj')

Assert-Eq 'illegal characters become hyphens' `
    'cranopener-my-proj' (Get-NamePrefix 'C:\Users\me\my.proj')

Assert-Eq 'collapses repeated separators' `
    'cranopener-my-proj' (Get-NamePrefix 'C:\Users\me\my..proj')

Assert-Eq 'handles a drive root' `
    'cranopener-c' (Get-NamePrefix 'C:\')

Assert-Eq 'the digest is six hex characters' `
    $true ((ConvertTo-ProjectName 'C:\Users\me\myproj') -cmatch '-[0-9a-f]{6}$')

# The leaf alone is not unique. Two clients each with an "api" directory is an
# ordinary layout, and colliding on it would mean a `down` in one tearing down
# the other's gateway -- exactly what this function exists to prevent.
Assert-Eq 'same leaf in different trees does not collide' `
    $true `
    ((ConvertTo-ProjectName 'C:\work\clientA\api') -ne (ConvertTo-ProjectName 'C:\work\clientB\api'))

# The name has to be stable, or every invocation would start a fresh stack.
Assert-Eq 'the same path always yields the same name' `
    (ConvertTo-ProjectName 'C:\work\clientA\api') `
    (ConvertTo-ProjectName 'C:\work\clientA\api')

Assert-Eq 'separator style does not change the name' `
    (ConvertTo-ProjectName 'C:\work\clientA\api') `
    (ConvertTo-ProjectName 'C:/work/clientA/api')

Assert-Eq 'a trailing separator does not change the name' `
    (ConvertTo-ProjectName 'C:\work\clientA\api') `
    (ConvertTo-ProjectName 'C:\work\clientA\api\')

# Label values only accept lowercase alphanumerics, hyphens, and underscores.
Assert-Eq 'the generated name is a legal label value' `
    $true `
    ((ConvertTo-ProjectName 'C:\Users\me\My.Proj') -cmatch '^[a-z0-9_-]+$')

# --- ConvertTo-VmPath ------------------------------------------------------
# hostPath resolves inside the podman machine, not on Windows: a C:/ path is
# looked up as /C:/ and reported missing. The machine mounts Windows drives
# under /mnt. `podman run -v` accepts the Windows form, which is exactly why
# this is easy to get wrong -- the same string works in one place and not the
# other.

Assert-Eq 'a drive letter becomes a /mnt mount' `
    '/mnt/c/Users/me/.cranopener' (ConvertTo-VmPath 'C:\Users\me\.cranopener')

Assert-Eq 'the drive letter is lowercased' `
    '/mnt/d/data' (ConvertTo-VmPath 'D:\data')

Assert-Eq 'forward slashes are accepted' `
    '/mnt/c/Users/me' (ConvertTo-VmPath 'C:/Users/me')

Assert-Eq 'spaces are preserved' `
    '/mnt/c/Users/my proj' (ConvertTo-VmPath 'C:\Users\my proj')

Assert-Eq 'a trailing separator is stripped' `
    '/mnt/c/Users/me' (ConvertTo-VmPath 'C:\Users\me\')

Assert-Eq 'a drive root yields the mount point' `
    '/mnt/c' (ConvertTo-VmPath 'C:\')

# A UNC path has no /mnt equivalent. Translating it anyway would produce
# something plausible and wrong, and the failure would surface as a missing
# file inside the VM with no hint of where the path came from.
$threw = $false
try { ConvertTo-VmPath '\\server\share' | Out-Null } catch { $threw = $true }
Assert-Eq 'a UNC path is rejected rather than mistranslated' $true $threw

# A relative path has no drive to translate under /mnt.
$threw = $false
try { ConvertTo-VmPath 'Users\me\x' | Out-Null } catch { $threw = $true }
Assert-Eq 'a relative path is rejected rather than mistranslated' $true $threw

# C:foo is drive-relative (relative to the current directory on drive C), not
# absolute -- it is not the same path as C:\foo. Translating it as though it
# were absolute would silently point at the wrong file.
$threw = $false
try { ConvertTo-VmPath 'C:foo' | Out-Null } catch { $threw = $true }
Assert-Eq 'a drive-relative path is rejected rather than mistranslated' $true $threw

# --- New-GatewayEnvBlock ---------------------------------------------------
# Credentials reach the gateway as a YAML env block built in memory and piped
# to `podman kube play -`. Every value is single-quoted: YAML single-quoted
# scalars take no escapes except '' for a literal quote, which makes the
# quoting total. Without it a key containing ':' splits the scalar and a key
# starting '!' is read as a type tag.

Assert-Eq 'emits an env block at the requested indent' `
    "      env:`n        - name: A_KEY`n          value: 'plain'" `
    (New-GatewayEnvBlock -Names @('A_KEY') -Values @{ 'A_KEY' = 'plain' } -Indent 6)

Assert-Eq 'a value containing a colon stays a single scalar' `
    "      env:`n        - name: P`n          value: 'http://h:8080'" `
    (New-GatewayEnvBlock -Names @('P') -Values @{ 'P' = 'http://h:8080' } -Indent 6)

Assert-Eq 'a single quote is doubled' `
    "      env:`n        - name: K`n          value: 'it''s'" `
    (New-GatewayEnvBlock -Names @('K') -Values @{ 'K' = "it's" } -Indent 6)

Assert-Eq 'a leading exclamation mark is not read as a tag' `
    "      env:`n        - name: K`n          value: '!secret'" `
    (New-GatewayEnvBlock -Names @('K') -Values @{ 'K' = '!secret' } -Indent 6)

# Absent variables are emitted empty rather than omitted, matching shell
# parameter expansion's ${VAR:-}. A missing key should fail at the provider
# with an auth error, not at startup with a malformed manifest.
Assert-Eq 'a missing value becomes an empty string' `
    "      env:`n        - name: K`n          value: ''" `
    (New-GatewayEnvBlock -Names @('K') -Values @{} -Indent 6)

Assert-Eq 'multiple names keep their given order' `
    "      env:`n        - name: A`n          value: '1'`n        - name: B`n          value: '2'" `
    (New-GatewayEnvBlock -Names @('A', 'B') -Values @{ 'A' = '1'; 'B' = '2' } -Indent 6)

# A newline means the input is already wrong -- none of the variables this
# function carries (API keys, proxy URLs, CA bundle paths) has a legitimate
# reason to contain one. Escaping cannot make a line break part of a
# single-quoted flow scalar without altering it: YAML folds any line break
# inside one to a space, so accepting it would silently turn a bad
# credential into a *different* bad credential instead of failing loudly --
# exactly the "silently wrong value" failure mode this function exists to
# avoid. Reject it instead of accommodating it.
$threw = $false
try {
    New-GatewayEnvBlock -Names @('K') -Values @{ 'K' = "line1`nline2" } -Indent 6 | Out-Null
} catch { $threw = $true }
Assert-Eq 'a value containing an embedded line break throws' $true $threw

# The realistic trigger: `$env:KEY = Get-Content key.txt` keeps the file's
# trailing newline. That must fail here, loudly, not three layers away as a
# provider authentication error that points at the credential instead of
# the launcher.
$threw = $false
try {
    New-GatewayEnvBlock -Names @('K') -Values @{ 'K' = "secret`n" } -Indent 6 | Out-Null
} catch { $threw = $true }
Assert-Eq 'a trailing newline throws' $true $threw

# --- Get-LastProbe ---------------------------------------------------------
# Read as an identity, never parsed as a time. The shapes below are the ones
# `podman inspect --format '{{json .State}}'` actually produces; the
# single-entry case is the trap, because a one-element JSON array is exactly
# what PowerShell is prone to unwrap out of an array.

function New-State($json) { return ($json | ConvertFrom-Json) }

Assert-Eq 'no probe recorded when there is no container' `
    '' (Get-LastProbe $null)

Assert-Eq 'no probe recorded when the container has no healthcheck' `
    '' (Get-LastProbe (New-State '{"Running":true}'))

Assert-Eq 'no probe recorded when the log is empty' `
    '' (Get-LastProbe (New-State '{"Running":true,"Health":{"Status":"starting","Log":[]}}'))

Assert-Eq 'no probe recorded when the log is null' `
    '' (Get-LastProbe (New-State '{"Running":true,"Health":{"Status":"starting","Log":null}}'))

Assert-Eq 'a single log entry is read, not unwrapped away' `
    'T1' (Get-LastProbe (New-State '{"Health":{"Log":[{"Start":"T1"}]}}'))

Assert-Eq 'the LAST entry is the one read' `
    'T2' (Get-LastProbe (New-State '{"Health":{"Log":[{"Start":"T1"},{"Start":"T2"}]}}'))

# podman keeps at most five entries, so the newest is not at a fixed index.
Assert-Eq 'the last of five entries is read' `
    'T5' (Get-LastProbe (New-State ('{"Health":{"Log":[{"Start":"T1"},{"Start":"T2"},' +
                                    '{"Start":"T3"},{"Start":"T4"},{"Start":"T5"}]}}')))

# --- Get-GatewayVerdict ----------------------------------------------------
# The launcher's poll acts on this and owns nothing but timing and messages.

$runningHealthy = New-State '{"Running":true,"Health":{"Status":"healthy","Log":[{"Start":"T9"}]}}'
$runningStarting = New-State '{"Running":true,"Health":{"Status":"starting","Log":[{"Start":"T9"}]}}'
$runningUnhealthy = New-State '{"Running":true,"Health":{"Status":"unhealthy","Log":[{"Start":"T9"}]}}'
$stoppedHealthy = New-State '{"Running":false,"Health":{"Status":"healthy","Log":[{"Start":"T9"}]}}'
$probedSince = New-State '{"Running":true,"Health":{"Status":"healthy","Log":[{"Start":"T9"},{"Start":"T10"}]}}'

Assert-Eq 'a gateway already running and healthy is ready' `
    'ready' (Get-GatewayVerdict -State $runningHealthy)

Assert-Eq 'a missing container is not a verdict, just wait' `
    'wait' (Get-GatewayVerdict -State $null)

Assert-Eq 'a starting gateway is waited on' `
    'wait' (Get-GatewayVerdict -State $runningStarting)

Assert-Eq 'a settled unhealthy gateway is reported' `
    'unhealthy' (Get-GatewayVerdict -State $runningUnhealthy)

# A running container with a healthcheck that has not reported yet has no
# Health block at all. That must not be read as a failure.
Assert-Eq 'a running container with no health block is waited on' `
    'wait' (Get-GatewayVerdict -State (New-State '{"Running":true}'))

# The regression that cost a session: podman does NOT clear
# .State.Health.Status when a container stops, so a stopped gateway goes on
# reading 'healthy'. Believing it hands the session an ECONNREFUSED at the
# first prompt -- the exact failure this poll exists to prevent. .State.Running
# is the discriminator, and no health status may override it.
Assert-Eq 'a STOPPED gateway is never ready, however healthy it claims to be' `
    'wait' (Get-GatewayVerdict -State $stoppedHealthy)

# ...and once the caller's grace period has passed, being stopped is worth
# saying out loud rather than waiting out the full timeout.
Assert-Eq 'a stopped gateway is reported once the grace period has passed' `
    'not-running' (Get-GatewayVerdict -State $stoppedHealthy -PastGrace $true)

Assert-Eq 'grace applies to a missing container too, not just a stopped one' `
    'wait' (Get-GatewayVerdict -State $null -PastGrace $true)

# The second half of the same regression. After this run started the pod, the
# recorded verdict may predate the stop. It is believed only once a probe has
# run since -- established by the probe timestamp differing from the one
# snapshotted before the start.
Assert-Eq 'a verdict left over from before a restart is not believed' `
    'wait' (Get-GatewayVerdict -State $runningHealthy -StartedNow $true -ProbeBaseline 'T9')

Assert-Eq 'a verdict produced after the restart is believed' `
    'ready' (Get-GatewayVerdict -State $probedSince -StartedNow $true -ProbeBaseline 'T9')

# Staleness cuts both ways: a leftover failure must not condemn a gateway that
# has only just been started either.
Assert-Eq 'a stale unhealthy verdict is not believed after a restart' `
    'wait' (Get-GatewayVerdict -State $runningUnhealthy -StartedNow $true -ProbeBaseline 'T9')

# Where this run did NOT start the pod, the periodic healthcheck has been
# running all along, so the status is current and no freshness test applies.
Assert-Eq 'freshness is not demanded of a pod this run did not start' `
    'ready' (Get-GatewayVerdict -State $runningHealthy -StartedNow $false -ProbeBaseline 'T9')

# --- Get-Sha256 ------------------------------------------------------------

Assert-Eq 'hashes "abc" to the known SHA-256 vector' `
    'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD' `
    (Get-Sha256 ([System.Text.Encoding]::ASCII.GetBytes('abc')))

Assert-Eq 'a one-byte difference changes the hash' `
    $false ((Get-Sha256 ([byte[]]@(1))) -eq (Get-Sha256 ([byte[]]@(2))))

# --- Get-InstallBytes ------------------------------------------------------
# A temp fixture rather than the real kube/gateway.yaml: these assertions are
# about the function's contract, and pinning them to the shipped manifest would
# turn every legitimate edit of it into a test failure.

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "cranopener-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
try {
    # LF endings and the marker line exactly as the real template carries them.
    $templateText = "apiVersion: v1`nspec:`n  containers:`n    - name: litellm`n" +
                    "      env: []  # __CRANOPENER_GATEWAY_ENV__`n" +
                    "  volumes:`n    - hostPath:`n        path: __CRANOPENER_HOME__/litellm/config.yaml`n"
    $templatePath = Join-Path $fixtureDir 'gateway.yaml'
    [System.IO.File]::WriteAllBytes(
        $templatePath, (New-Object System.Text.UTF8Encoding $false).GetBytes($templateText))

    $otherPath = Join-Path $fixtureDir 'opencode.json'
    $otherBytes = [byte[]]@(0x7B, 0x0A, 0x7D, 0x0A)
    [System.IO.File]::WriteAllBytes($otherPath, $otherBytes)

    $vm = '/mnt/c/Users/me/.cranopener'
    $out = Get-InstallBytes -TemplatePath $templatePath -Relative 'gateway.yaml' -VmHome $vm
    $text = [System.Text.Encoding]::UTF8.GetString($out)

    Assert-Eq 'the hostPath placeholder is substituted' `
        $true ($text -match [regex]::Escape("$vm/litellm/config.yaml"))

    Assert-Eq 'no placeholder survives substitution' `
        $false ($text -match '__CRANOPENER_HOME__')

    # A BOM would be the first bytes of the file. kube play tolerates it, but
    # it changes the hash and so would read as permanent drift.
    Assert-Eq 'the output carries no UTF-8 BOM' `
        $false ($out.Length -ge 3 -and $out[0] -eq 0xEF -and $out[1] -eq 0xBB -and $out[2] -eq 0xBF)

    # The failure this prevents: a string-array round trip re-joins with CRLF,
    # and the launcher then reports a missing marker that is plainly in the file.
    Assert-Eq 'no CR is introduced -- LF endings survive' `
        0 (@($out | Where-Object { $_ -eq 0x0D }).Count)

    Assert-Eq 'the line count is unchanged by substitution' `
        (@($templateText -split "`n").Count) (@($text -split "`n").Count)

    # The cross-component coupling nothing else checks: the launcher's marker
    # regex has to match what the installer writes. The pattern is lifted out of
    # cranopener.ps1 rather than retyped, so an edit there cannot silently
    # diverge from what is asserted here.
    $launcherSrc = Get-Content "$PSScriptRoot/../scripts/cranopener.ps1"
    $markerLine = $launcherSrc | Where-Object { $_ -match '^\s*\$marker = \[regex\]' }
    $pattern = ($markerLine -replace "^\s*\`$marker = \[regex\]'", '') -replace "'\s*$", ''
    Assert-Eq 'the marker pattern was found in cranopener.ps1' `
        $true ($pattern.Length -gt 0)
    Assert-Eq "the launcher's marker regex matches what Get-InstallBytes writes" `
        $true ([regex]::IsMatch($text, $pattern))

    # Non-gateway files are copied byte for byte, with no substitution pass.
    $passthru = Get-InstallBytes -TemplatePath $otherPath -Relative 'opencode.json' -VmHome $vm
    Assert-Eq 'other templates are copied byte for byte' `
        (Get-Sha256 $otherBytes) (Get-Sha256 $passthru)

    # Only the exact relative name is substituted -- a file merely NAMED like
    # the manifest deeper in the tree is not rewritten.
    $nested = Get-InstallBytes -TemplatePath $templatePath -Relative 'sub/gateway.yaml' -VmHome $vm
    Assert-Eq 'substitution keys on the exact relative path, not the file name' `
        $true ([System.Text.Encoding]::UTF8.GetString($nested) -match '__CRANOPENER_HOME__')

    # --- the drift property, both directions -------------------------------
    # This is what the installer's report depends on. Compare an installed file
    # against Get-InstallBytes, never against the raw template.

    $installed = Join-Path $fixtureDir 'installed-gateway.yaml'
    [System.IO.File]::WriteAllBytes($installed, $out)

    Assert-Eq 'a substitution-only difference reads as UNCHANGED' `
        (Get-Sha256 $out) (Get-Sha256 ([System.IO.File]::ReadAllBytes($installed)))

    # The bug this guards: comparing against the raw template instead would
    # flag the manifest on every single run and bury the real signal.
    Assert-Eq 'the raw template does NOT match the installed file' `
        $false ((Get-Sha256 ([System.IO.File]::ReadAllBytes($templatePath))) -eq
                (Get-Sha256 ([System.IO.File]::ReadAllBytes($installed))))

    $edited = Join-Path $fixtureDir 'edited-gateway.yaml'
    [System.IO.File]::WriteAllBytes(
        $edited, (New-Object System.Text.UTF8Encoding $false).GetBytes($text + "  # local edit`n"))
    Assert-Eq 'any other difference reads as DRIFT' `
        $false ((Get-Sha256 $out) -eq (Get-Sha256 ([System.IO.File]::ReadAllBytes($edited))))

    # A different install directory is a real difference too: an install tree
    # copied to a new home carries a hostPath that no longer resolves.
    $otherHome = Get-InstallBytes -TemplatePath $templatePath -Relative 'gateway.yaml' `
                                  -VmHome '/mnt/d/elsewhere'
    Assert-Eq 'a different VmHome reads as DRIFT' `
        $false ((Get-Sha256 $out) -eq (Get-Sha256 $otherHome))

    Assert-Eq 'the same inputs produce the same bytes every time' `
        (Get-Sha256 $out) `
        (Get-Sha256 (Get-InstallBytes -TemplatePath $templatePath -Relative 'gateway.yaml' -VmHome $vm))
} finally {
    Remove-Item -Recurse -Force $fixtureDir -ErrorAction SilentlyContinue
}

# --- Get-HarnessForModel ---------------------------------------------------
# opencode fails on its first tool call against a provider that refuses tools,
# and the failure looks like a gateway outage. The routing rule is therefore
# derived from the model rather than left to an operator flag.

Assert-Eq 'a provider-a model selects openhands' `
    'openhands' (Get-HarnessForModel 'provider-a/some-model')

Assert-Eq 'a provider-b model selects opencode' `
    'opencode' (Get-HarnessForModel 'provider-b/some-model')

Assert-Eq 'a provider-c model selects opencode' `
    'opencode' (Get-HarnessForModel 'provider-c/some-model')

Assert-Eq 'no model at all selects opencode' `
    'opencode' (Get-HarnessForModel '')

Assert-Eq 'a null model selects opencode' `
    'opencode' (Get-HarnessForModel $null)

Assert-Eq 'the prefix match is case-insensitive' `
    'openhands' (Get-HarnessForModel 'PROVIDER-A/Some-Model')

# The valuable one. A naive StartsWith('provider-a') also matches
# 'provider-abc/...', which would silently route a tool-capable provider to the
# wrong harness. The separator has to be part of the match.
Assert-Eq 'a longer namespace sharing the prefix is not matched' `
    'opencode' (Get-HarnessForModel 'provider-abc/some-model')

Assert-Eq 'a bare namespace with no model is still matched' `
    'openhands' (Get-HarnessForModel 'provider-a/')

Assert-Eq 'the prompt-mode set is overridable for testing' `
    'openhands' (Get-HarnessForModel 'provider-z/m' -PromptModeNamespaces @('provider-z'))

# The two outcomes are not equally safe: falling through to opencode is the
# failure this function exists to prevent. A stray leading space must not be
# what causes it.
Assert-Eq 'surrounding whitespace does not route to the wrong harness' `
    'openhands' (Get-HarnessForModel '  provider-a/some-model  ')

# An override that merely added to the default would pass every assertion
# above while silently keeping provider-a in prompt mode.
Assert-Eq 'the override replaces the default rather than adding to it' `
    'opencode' (Get-HarnessForModel 'provider-a/m' -PromptModeNamespaces @('provider-z'))

Write-Host ''
Write-Host "test-launcher.ps1: $script:Run run, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
