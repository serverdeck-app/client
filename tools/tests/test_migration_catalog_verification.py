"""Synthetic signed-catalog verification only; no GitHub/release/product process."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class MigrationCatalogVerificationTest(unittest.TestCase):
    def test_matching_signed_channels_and_tamper_refusal(self):
        verifier = Path(__file__).resolve().parents[1] / 'verify-migration-assets.ps1'
        with tempfile.TemporaryDirectory() as directory:
            quote = lambda value: "'" + str(value).replace("'", "''") + "'"
            script = r'''
$ErrorActionPreference = 'Stop'
$root = ROOT_PATH
$signer = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
try {
    $public = $signer.ExportParameters($false)
    $point = [Convert]::ToHexString($public.Q.X + $public.Q.Y).ToLowerInvariant()
    @{keys=@(@{id='unit';p256=$point})} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'policy.json')
    foreach($channel in @('current','legacy')) {
        $folder=Join-Path $root $channel
        New-Item -ItemType Directory -Path $folder | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $folder 'ServerDeckSetup.exe'),[Text.Encoding]::ASCII.GetBytes('synthetic fixture, never executed'))
    }
    $installer=Get-Item (Join-Path $root 'current/ServerDeckSetup.exe')
    $hash=(Get-FileHash -LiteralPath $installer.FullName).Hash.ToLowerInvariant()
    function WriteCatalog([string]$channel,[string]$appHash) {
        $repo=if($channel -eq 'current'){'serverdeck-app/client'}else{'unng-lab/serverdeck'}
        $fields=@('SDRELEASES002','100000','1','0.3.6','windows-x64','1','2','99999',"$($installer.Length)",$hash,'7',$appHash,"https://github.com/$repo/releases/download/v0.3.6/ServerDeckSetup.exe",'VGVzdA==','')
        $payload=$fields -join "`n"
        $signature=$signer.SignData([Text.Encoding]::ASCII.GetBytes($payload),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
        $envelope="SDCATALOG002`nunit`n"+[Convert]::ToHexString($signature).ToLowerInvariant()+"`n"+$payload
        [IO.File]::WriteAllText((Join-Path $root "$channel/serverdeck-update-catalog.txt"),$envelope)
    }
    $appHash='a'*64
    WriteCatalog current $appHash
    WriteCatalog legacy $appHash
    & VERIFIER_PATH -Directory $root -Policy (Join-Path $root 'policy.json') | Out-Null
    WriteCatalog legacy ('b'*64)
    $rejected=$false
    try { & VERIFIER_PATH -Directory $root -Policy (Join-Path $root 'policy.json') | Out-Null } catch { $rejected=$true }
    if(!$rejected){throw 'Differently signed app identities accepted'}
    WriteCatalog legacy $appHash
    [IO.File]::AppendAllText((Join-Path $root 'legacy/ServerDeckSetup.exe'),'tamper')
    $rejected=$false
    try { & VERIFIER_PATH -Directory $root -Policy (Join-Path $root 'policy.json') | Out-Null } catch { $rejected=$true }
    if(!$rejected){throw 'Tampered installer accepted'}
} finally { $signer.Dispose() }
'''.replace('ROOT_PATH', quote(directory)).replace('VERIFIER_PATH', quote(verifier))
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('PRIVATE KEY', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
