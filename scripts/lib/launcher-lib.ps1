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
    #>
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path -replace '\\', '/'

    # A trailing separator would produce a doubled slash in the volume spec.
    if ($normalized.Length -gt 1) {
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
    #>
    param([Parameter(Mandatory)][string]$Path)

    $normalized = ConvertTo-ComposePath $Path
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

    return "cranopener-$leaf"
}
