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

# --- ConvertTo-ProjectName -------------------------------------------------
# Compose derives its project name from the compose file's directory. cranopener
# keeps one install location for every repository, so the default would make
# every project collide -- starting cranopener in one repo would reuse or tear
# down another's containers.

Assert-Eq 'derives from the leaf directory' `
    'cranopener-myproj' (ConvertTo-ProjectName 'C:\Users\me\myproj')

Assert-Eq 'lowercases' `
    'cranopener-myproj' (ConvertTo-ProjectName 'C:\Users\me\MyProj')

Assert-Eq 'illegal characters become hyphens' `
    'cranopener-my-proj' (ConvertTo-ProjectName 'C:\Users\me\my.proj')

Assert-Eq 'collapses repeated separators' `
    'cranopener-my-proj' (ConvertTo-ProjectName 'C:\Users\me\my..proj')

Assert-Eq 'handles a drive root' `
    'cranopener-c' (ConvertTo-ProjectName 'C:\')

Write-Host ''
Write-Host "test-launcher.ps1: $script:Run run, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
