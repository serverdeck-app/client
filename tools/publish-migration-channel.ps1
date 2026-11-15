param(
    [Parameter(Mandatory)][ValidateSet('serverdeck-app/client','unng-lab/serverdeck')][string]$Repository,
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidatePattern('^unng-lab/serverdeck-history-private/actions/runs/[1-9][0-9]*$')][string]$PublisherRun,
    [string]$Notes = 'release/notes/0.3.6.md'
)
$ErrorActionPreference = 'Stop'
$names = @('ServerDeckSetup.exe','serverdeck-update-catalog.txt')
$marker = "<!-- migration-publisher:$PublisherRun -->"
function Read-Release {
    $releases = gh api "repos/$Repository/releases?per_page=100" | ConvertFrom-Json
    if ($LASTEXITCODE) { throw 'Cannot inspect release state; no publication attempted' }
    if (@($releases).Count -ge 100) { throw 'Release listing bound reached; inspect migration state explicitly' }
    $existing = @($releases | Where-Object tag_name -CEQ 'v0.3.6')
    if ($existing.Count -gt 1) { throw 'Ambiguous release state' }
    if ($existing.Count) { return $existing[0] }
    return $null
}
function Assert-Asset($release, [string]$name) {
    $asset = @($release.assets | Where-Object name -CEQ $name)
    $file = Get-Item -LiteralPath (Join-Path $Directory $name)
    $digest = 'sha256:' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($asset.Count -ne 1 -or $asset[0].state -cne 'uploaded' -or $asset[0].size -ne $file.Length -or $asset[0].digest -cne $digest) {
        throw 'Migration assets differ; preserve the release and stop'
    }
}
function Assert-OwnedDraft($release) {
    if (!$release -or !$release.draft -or $release.prerelease -or
        [regex]::Matches([string]$release.body, '(?m)^' + [regex]::Escape($marker) + '\r?$').Count -ne 1 -or
        @($release.assets | Where-Object { $_.name -cnotin $names }).Count) {
        throw 'Draft is not the owned same-run migration operation; preserve it and stop'
    }
}
$release = Read-Release
if (!$release) {
    $notesFile = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '.md')
    try {
        [IO.File]::WriteAllText($notesFile, (Get-Content -LiteralPath $Notes -Raw).TrimEnd() + "`n`n$marker`n")
        # Metadata alone first: an interrupted upload remains an owned draft.
        gh release create v0.3.6 --repo $Repository --verify-tag --draft --title 'ServerDeck 0.3.6' --notes-file $notesFile
        if ($LASTEXITCODE) { throw 'Draft creation uncertain; rerun to inspect owned state' }
    } finally { Remove-Item -LiteralPath $notesFile -ErrorAction SilentlyContinue }
    $release = Read-Release
}
if ($release.draft) {
    Assert-OwnedDraft $release
    foreach ($name in $names) {
        $release = Read-Release
        Assert-OwnedDraft $release
        $asset = @($release.assets | Where-Object name -CEQ $name)
        if ($asset.Count -gt 1) { throw 'Ambiguous draft asset identity' }
        if ($asset.Count -eq 1 -and $asset[0].state -ceq 'uploaded') {
            Assert-Asset $release $name
            continue
        }
        if ($asset.Count -eq 1) {
            if ($asset[0].state -cne 'starter') { throw 'Unknown draft asset state; preserve it and stop' }
            # Only this run's incomplete upload is removed, never published bytes.
            gh api --method DELETE "repos/$Repository/releases/assets/$($asset[0].id)"
            if ($LASTEXITCODE) { throw 'Draft upload cleanup uncertain; rerun' }
        }
        gh release upload v0.3.6 (Join-Path $Directory $name) --repo $Repository
        if ($LASTEXITCODE) { throw 'Draft upload incomplete; resume with retained artifacts' }
    }
    $release = Read-Release
    Assert-OwnedDraft $release
    foreach ($name in $names) { Assert-Asset $release $name }
    gh release edit v0.3.6 --repo $Repository --draft=false --latest
    if ($LASTEXITCODE) { throw 'Publication uncertain; rerun verification without overwriting assets' }
    $release = Read-Release
}
if (!$release -or $release.draft -or $release.prerelease) { throw 'Migration release is not published stable' }
foreach ($name in $names) { Assert-Asset $release $name }
Write-Output "Verified immutable published release: $Repository v0.3.6"
