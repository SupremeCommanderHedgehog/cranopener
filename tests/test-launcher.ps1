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

# Absent variables are emitted empty rather than omitted, matching compose's
# ${VAR:-}. A missing key should fail at the provider with an auth error, not
# at startup with a malformed manifest.
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

Write-Host ''
Write-Host "test-launcher.ps1: $script:Run run, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
