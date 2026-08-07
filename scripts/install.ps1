<#
.SYNOPSIS
  Install the cranopener kube tree to ~/.cranopener.

.DESCRIPTION
  Copies templates without ever overwriting local configuration. The
  operator's real endpoints, model identifiers, and certificates live only in
  the install directory -- this repository is public and must never carry
  them.

  Re-running picks up new templates while leaving local edits alone, so the
  same command serves for both install and upgrade.
#>
[CmdletBinding()]
param(
    # Mirrors the launcher's CRANOPENER_HOME override so the two cannot drift
    # apart and install to different directories.
    [string]$Destination = $(
        if ($env:CRANOPENER_HOME) { $env:CRANOPENER_HOME }
        else { Join-Path $env:USERPROFILE '.cranopener' }
    )
)

$ErrorActionPreference = 'Stop'

# ConvertTo-VmPath lives here. hostPath resolves inside the podman machine, so
# the install directory has to be rewritten to its /mnt form.
. (Join-Path $PSScriptRoot 'lib/launcher-lib.ps1')

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'kube'

if (-not (Test-Path $source)) { throw "missing kube templates at $source" }

# Translate before creating or copying anything. A destination this cannot
# express as a VM path -- a relative path, a UNC share -- produces an install
# that can never start the gateway, so it has to fail while the disk is still
# untouched. Doing it after the copy loop left five files and an
# unsubstituted placeholder behind for the operator to clean up by hand.
$vmHome = ConvertTo-VmPath $Destination

function Get-InstallBytes {
    <#
    .SYNOPSIS
      The exact bytes this installer writes for one template.

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
        # gateway.yaml ships with a placeholder because hostPath needs a
        # literal absolute path and kube YAML has no interpolation. The value
        # must be the path the podman machine sees, not the Windows one:
        # `podman run -v` translates Windows paths but hostPath does not, and
        # C:/x is looked up as /C:/x.
        $text = (Get-Content $TemplatePath -Raw).Replace('__CRANOPENER_HOME__', $VmHome)
        # -Raw in, UTF8-no-BOM bytes out: the file's own LF endings pass
        # through untouched. Reading into a string array and writing it back
        # would re-join with CRLF, and the launcher's marker regex is anchored
        # per line -- the gateway would then fail with "no
        # __CRANOPENER_GATEWAY_ENV__ marker" while the marker sits plainly
        # visible in the file. The launcher tolerates CRLF too; neither guard
        # stands alone.
        return (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    }

    return [System.IO.File]::ReadAllBytes($TemplatePath)
}

function Get-Sha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'certs') | Out-Null

$copied = 0
$skipped = 0
$drifted = @()
$gatewayCopied = $false

foreach ($file in (Get-ChildItem -Path $source -Recurse -File -Force)) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative

    $expected = Get-InstallBytes -TemplatePath $file.FullName -Relative $relative -VmHome $vmHome

    # Never overwrite. The installed copies get edited -- model IDs in
    # opencode.proxied.json, extra mounts in gateway.yaml -- and clobbering
    # those on an upgrade would be a silent, expensive mistake.
    if (Test-Path $target) {
        # But silently skipping is its own trap: a fixed template would never
        # reach an existing install and nobody would know to look. Report the
        # difference instead of hiding it.
        $same = (Get-Sha256 $expected) -eq (Get-Sha256 ([System.IO.File]::ReadAllBytes($target)))
        if ($same) {
            Write-Host "skip  $relative (unchanged)"
        } else {
            Write-Host "SKIP  $relative (differs from template)" -ForegroundColor Yellow
            $drifted += $relative
        }
        $skipped++
        continue
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    # Written from the same bytes the drift check compares against, so the
    # substitution happens exactly once and only on a file this run created.
    # Rewriting an installed one would undo local edits, which is the whole
    # reason the never-overwrite rule exists.
    [System.IO.File]::WriteAllBytes($target, $expected)
    Write-Host "copy  $relative"
    if ($relative -eq 'gateway.yaml') {
        $gatewayCopied = $true
        Write-Host "      gateway.yaml hostPath -> $vmHome"
    }
    $copied++
}

# An installed manifest this run did not write, still carrying the
# placeholder, cannot start the gateway -- most likely someone copied the
# template in by hand. Say so; do not rewrite it.
$gateway = Join-Path $Destination 'gateway.yaml'
if (-not $gatewayCopied -and (Test-Path $gateway) -and ((Get-Content $gateway -Raw) -match '__CRANOPENER_HOME__')) {
    Write-Host "WARN  gateway.yaml still contains __CRANOPENER_HOME__." -ForegroundColor Yellow
    Write-Host "      The gateway cannot start until it is replaced with $vmHome" -ForegroundColor Yellow
}

Write-Host ''
Write-Host "installed to $Destination ($copied copied, $skipped skipped)"

if ($drifted) {
    Write-Host ''
    Write-Host 'These installed files differ from the shipped templates.' -ForegroundColor Yellow
    Write-Host 'That is expected where you edited them, but it also means any' -ForegroundColor Yellow
    Write-Host 'template fix has not landed. Diff them if an upgrade was expected:' -ForegroundColor Yellow
    foreach ($d in $drifted) {
        Write-Host "  $d"
        Write-Host "    diff `"$(Join-Path $source $d)`" `"$(Join-Path $Destination $d)`""
    }
}

# install.ps1 never overwrites, so an install predating the kube migration
# keeps an opencode.proxied.json pointing at http://litellm:4000. Containers in
# a pod share one network namespace, so that name no longer resolves at all --
# and the failure surfaces at the first prompt of a session, looking like a
# gateway outage rather than a stale file. Detect it here instead.
$dead = @()
foreach ($f in 'compose.yaml', 'compose.direct.yaml', '.env.example', '.env') {
    if (Test-Path (Join-Path $Destination $f)) { $dead += $f }
}
$proxied = Join-Path $Destination 'opencode/opencode.proxied.json'
$staleUrl = (Test-Path $proxied) -and ((Get-Content $proxied -Raw) -match 'litellm:4000')

if ($dead -or $staleUrl) {
    Write-Host ''
    Write-Host 'This install predates the move to podman kube.' -ForegroundColor Red
    if ($staleUrl) {
        Write-Host '  * opencode.proxied.json still points at http://litellm:4000/v1.' -ForegroundColor Red
        Write-Host '    Containers in a pod share one network namespace, so that name no'
        Write-Host '    longer resolves. Change baseURL to http://localhost:4000/v1:'
        Write-Host "      $proxied"
    }
    if ($dead) {
        Write-Host '  * These files are no longer read and can be deleted:' -ForegroundColor Red
        foreach ($f in $dead) { Write-Host "      $(Join-Path $Destination $f)" }
    }
    if ($dead -contains '.env' -or $dead -contains '.env.example') {
        Write-Host '    Credentials now come from the environment, never a file. See step 2.'
    }
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host "  1. copy $Destination\litellm\config.example.yaml to config.yaml,"
Write-Host '     and replace every PLACEHOLDER with real endpoints and model IDs'
Write-Host '  2. export credentials in your shell. They are read from the environment'
Write-Host '     and are never written to a file:'
Write-Host '       $env:PROVIDER_A_API_KEY, $env:PROVIDER_B_API_KEY, $env:PROVIDER_C_API_KEY'
Write-Host '     For -Direct: $env:ANTHROPIC_API_KEY, $env:OPENAI_API_KEY'
Write-Host '     Optional egress: $env:HTTP_PROXY, $env:HTTPS_PROXY, $env:NO_PROXY'
Write-Host "  3. place a COMPLETE CA bundle at $Destination\certs\extra-roots.pem"
Write-Host '     The gateway sets SSL_CERT_FILE to it, which REPLACES the default'
Write-Host '     trust store rather than adding to it -- so this file must contain'
Write-Host '     the system roots as well as any corporate roots, or every upstream'
Write-Host '     call fails looking like a provider outage. To build one:'
# Both commands write the bundle from inside the container, through a bind
# mount, so no host shell ever touches the bytes. That is the point, not a
# stylistic preference: every redirect-based form of this instruction has a
# silent failure mode.
#
#   `podman run IMAGE cat ...` -- the image entrypoint is litellm, so the
#   arguments parse as a subcommand and it exits 2, while the redirect has
#   already truncated the target to zero bytes.
#
#   `... > file` under Windows PowerShell 5.1 -- 5.1 writes UTF-16LE. OpenSSL
#   then reads ZERO certificates from a ~435KB file that is non-empty, is
#   plausibly sized, and whose first line even reads correctly through
#   Get-Content, because PowerShell decodes the BOM back to text. It defeats
#   the emptiness check in cranopener.ps1 and every size heuristic.
#
# A bash-style `\` continuation would be wrong here too: this text is read at
# a PowerShell prompt, where `\` does not continue a line. Printed unwrapped.
$certsMount = "$(ConvertTo-PodmanPath $Destination)/certs"
Write-Host "       podman run --rm -v `"${certsMount}:/out`" --entrypoint cp ghcr.io/berriai/litellm:main-stable /etc/ssl/certs/ca-certificates.crt /out/extra-roots.pem"
Write-Host '     To add corporate roots, place them beside it as'
Write-Host '     corporate-roots.pem and build both halves in one pass instead,'
Write-Host '     so the concatenation also happens inside the container:'
Write-Host "       podman run --rm -v `"${certsMount}:/out`" --entrypoint sh ghcr.io/berriai/litellm:main-stable -c `"cat /etc/ssl/certs/ca-certificates.crt /out/corporate-roots.pem > /out/extra-roots.pem`""
Write-Host '     Do not build this file with a `>` redirect from a PowerShell'
Write-Host '     prompt. Confirm the bytes really are PEM -- this prints True or'
Write-Host '     False, and works the same in powershell.exe and pwsh. Reading the'
Write-Host '     first line as text is NOT enough: it reports success on a UTF-16'
Write-Host '     file that contains no usable certificates at all.'
Write-Host "       [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(`"$Destination\certs\extra-roots.pem`"), 0, 27) -eq '-----BEGIN CERTIFICATE-----'"
Write-Host "  4. edit $Destination\opencode\opencode.proxied.json so its model"
Write-Host '     IDs match the ones in config.yaml'
Write-Host "  5. add the scripts directory to PATH so `cranopener` resolves"
