# Pure functions used by cranopener.ps1. Kept separate from the launcher so
# they can be unit tested without invoking podman.

function ConvertTo-ComposePath {
    <#
    .SYNOPSIS
      Render a Windows path so compose can parse it in a volume specification.

    .DESCRIPTION
      Compose splits volume specifications on ':'. A Windows path like
      C:\Users\me\proj therefore parses as host "C" with container path
      "\Users\me\proj". Forward slashes remove the ambiguity.

      This is for `podman run -v` / compose volume specs only. For a
      Kubernetes hostPath value (`podman kube play`), use ConvertTo-VmPath
      instead -- this function still returns a Windows-style path, and a
      hostPath given a Windows-style path resolves inside the podman machine
      and fails to find the file.
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
      Derive a compose project name from a working directory.

    .DESCRIPTION
      Compose derives its project name from the compose file's directory.
      Because cranopener keeps one install location shared by every
      repository, the default would make every project collide -- starting
      cranopener in one repo would reuse or tear down another's containers.
      Deriving the name from the working directory instead keeps stacks
      distinct and `podman ps` readable.

      The leaf directory alone is not enough. Two clients each with an "api"
      directory is an ordinary layout, and colliding on it reintroduces the
      exact failure this function exists to prevent. A short digest of the
      full path is appended so the name stays unique while remaining
      recognisable at a glance.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $normalized = ConvertTo-ComposePath $Path

    # Normalise before hashing so C:\a\b, C:/a/b, and C:\a\b\ are one project
    # rather than three.
    $canonical = $normalized.TrimEnd('/').ToLower()

    $leaf = $normalized -split '/' |
        Where-Object { $_ -ne '' } |
        Select-Object -Last 1

    if (-not $leaf) { $leaf = 'root' }

    # Compose project names allow lowercase alphanumerics, hyphens, and
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
      hostPath value only -- for a `podman run -v` / compose volume spec, use
      ConvertTo-ComposePath instead, which returns a Windows-style path.
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
