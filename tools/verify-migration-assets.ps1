param(
    [string]$Directory = 'output/migration',
    [string]$Policy = 'release/update-policy.json'
)
# Pure local catalog/signature/hash verification. Does not execute an installer.
$ErrorActionPreference = 'Stop'
$policyValue = Get-Content -LiteralPath $Policy -Raw | ConvertFrom-Json
$rows = @{}
foreach ($channel in @('current', 'legacy')) {
    $folder = Join-Path $Directory $channel
    $bytes = [IO.File]::ReadAllBytes((Join-Path $folder 'serverdeck-update-catalog.txt'))
    if ($bytes.Length -gt 131072 -or ($bytes | Where-Object { $_ -eq 0 -or $_ -eq 13 -or $_ -gt 127 }).Count) { throw 'Invalid catalog encoding/bounds' }
    $parts = [Text.Encoding]::ASCII.GetString($bytes).Split("`n", 4)
    if ($parts.Count -ne 4 -or $parts[0] -cne 'SDCATALOG002' -or $parts[2] -cnotmatch '^[0-9a-f]{128}$') { throw 'Invalid catalog envelope' }
    $key = @($policyValue.keys | Where-Object id -CEQ $parts[1])
    if ($key.Count -ne 1) { throw 'Unknown signing key' }
    $point = [Convert]::FromHexString($key[0].p256)
    if ($point.Length -ne 64) { throw 'Invalid signing point' }
    $parameters = [Security.Cryptography.ECParameters]::new()
    $parameters.Curve = [Security.Cryptography.ECCurve+NamedCurves]::nistP256
    $q = [Security.Cryptography.ECPoint]::new(); $q.X = $point[0..31]; $q.Y = $point[32..63]; $parameters.Q = $q
    $verifier = [Security.Cryptography.ECDsa]::Create($parameters)
    try {
        if (!$verifier.VerifyData([Text.Encoding]::ASCII.GetBytes($parts[3]), [Convert]::FromHexString($parts[2]),
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)) { throw 'Invalid catalog signature' }
    } finally { $verifier.Dispose() }
    $fields = $parts[3].Split("`n")
    if ($fields.Count -ne 15 -or $fields[14] -cne '' -or $fields[0] -cne 'SDRELEASES002' -or
        $fields[2] -cne '1' -or $fields[3] -cne '0.3.6' -or $fields[4] -cne 'windows-x64' -or
        $fields[5] -cne '1' -or $fields[6] -cne '2' -or $fields[9] -cnotmatch '^[0-9a-f]{64}$' -or
        $fields[11] -cnotmatch '^[0-9a-f]{64}$') { throw 'Migration record identity mismatch' }
    foreach ($index in @(1,7,8,10)) {
        if ($fields[$index] -cnotmatch '^[1-9][0-9]{0,14}$') { throw 'Invalid migration integer' }
    }
    if ([long]$fields[7] -gt [long]$fields[1] -or [long]$fields[1] -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) { throw 'Invalid migration timestamps' }
    $repository = if ($channel -eq 'current') { 'serverdeck-app/client' } else { 'unng-lab/serverdeck' }
    if ($fields[12] -cne "https://github.com/$repository/releases/download/v0.3.6/ServerDeckSetup.exe") { throw 'Wrong migration channel URL' }
    $installer = Get-Item -LiteralPath (Join-Path $folder 'ServerDeckSetup.exe')
    if ($installer.Length -ne [long]$fields[8] -or (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $fields[9]) { throw 'Installer differs from signed catalog' }
    $rows[$channel] = $fields
}
foreach ($index in @(0,2,3,4,5,6,8,9,10,11,13,14)) {
    if ($rows.current[$index] -cne $rows.legacy[$index]) { throw 'Migration channels disagree on signed installer/app/notes identity' }
}
[PSCustomObject]@{version='0.3.6';setupSHA256=$rows.current[9];appSHA256=$rows.current[11];storeFormat=2} | ConvertTo-Json -Compress
