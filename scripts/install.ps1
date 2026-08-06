<#
.SYNOPSIS
  Install the cranopener compose tree to ~/.cranopener.

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
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'compose'

if (-not (Test-Path $source)) { throw "missing compose templates at $source" }

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'certs') | Out-Null

$copied = 0
$skipped = 0
$drifted = @()

foreach ($file in (Get-ChildItem -Path $source -Recurse -File -Force)) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative

    # Never overwrite. The installed copies get edited -- model IDs in
    # opencode.proxied.json, extra volumes in compose.yaml -- and clobbering
    # those on an upgrade would be a silent, expensive mistake.
    if (Test-Path $target) {
        # But silently skipping is its own trap: a fixed template would never
        # reach an existing install and nobody would know to look. Report the
        # difference instead of hiding it.
        $same = (Get-FileHash $file.FullName).Hash -eq (Get-FileHash $target).Hash
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
    Copy-Item $file.FullName $target
    Write-Host "copy  $relative"
    $copied++
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
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host "  1. copy $Destination\litellm\config.example.yaml to config.yaml,"
Write-Host '     and replace every PLACEHOLDER with real endpoints and model IDs'
Write-Host "  2. copy $Destination\.env.example to .env and fill in credentials"
Write-Host "  3. place a COMPLETE CA bundle at $Destination\certs\extra-roots.pem"
Write-Host '     The gateway sets SSL_CERT_FILE to it, which REPLACES the default'
Write-Host '     trust store rather than adding to it -- so this file must contain'
Write-Host '     the system roots as well as any corporate roots, or every upstream'
Write-Host '     call fails looking like a provider outage. To build one:'
Write-Host '       podman run --rm ghcr.io/berriai/litellm:main-stable \'
Write-Host '         cat /etc/ssl/certs/ca-certificates.crt > extra-roots.pem'
Write-Host '       cat your-corporate-roots.pem >> extra-roots.pem'
Write-Host "  4. edit $Destination\opencode\opencode.proxied.json so its model"
Write-Host '     IDs match the ones in config.yaml'
Write-Host "  5. add the scripts directory to PATH so `cranopener` resolves"
