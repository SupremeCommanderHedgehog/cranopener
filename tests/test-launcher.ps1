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

# --- ConvertTo-ComposePath -------------------------------------------------
# compose splits volume specs on ':', so a raw C:\Users\... parses as host "C"
# with container path "\Users\...". Forward slashes remove the ambiguity.

Assert-Eq 'backslashes become forward slashes' `
    'C:/Users/me/proj' (ConvertTo-ComposePath 'C:\Users\me\proj')

Assert-Eq 'already-forward paths are unchanged' `
    'C:/Users/me/proj' (ConvertTo-ComposePath 'C:/Users/me/proj')

Assert-Eq 'trailing separator is stripped' `
    'C:/Users/me/proj' (ConvertTo-ComposePath 'C:\Users\me\proj\')

Assert-Eq 'spaces are preserved' `
    'C:/Users/me/my proj' (ConvertTo-ComposePath 'C:\Users\me\my proj')

# A drive root must keep its trailing slash. Trimming it yields "C:", and the
# volume specification then reads "C::/workspace".
Assert-Eq 'drive root keeps its slash' `
    'C:/' (ConvertTo-ComposePath 'C:\')

Assert-Eq 'forward-slash drive root keeps its slash' `
    'C:/' (ConvertTo-ComposePath 'C:/')

# --- ConvertTo-ProjectName -------------------------------------------------
# Compose derives its project name from the compose file's directory. cranopener
# keeps one install location for every repository, so the default would make
# every project collide -- starting cranopener in one repo would reuse or tear
# down another's containers.

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

# Compose only accepts lowercase alphanumerics, hyphens, and underscores.
Assert-Eq 'the generated name is compose-legal' `
    $true `
    ((ConvertTo-ProjectName 'C:\Users\me\My.Proj') -cmatch '^[a-z0-9_-]+$')

Write-Host ''
Write-Host "test-launcher.ps1: $script:Run run, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
