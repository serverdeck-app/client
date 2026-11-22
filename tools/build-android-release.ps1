param([string]$Sdk = $env:ANDROID_HOME)
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    function Checked([string]$Program,[string[]]$Arguments) {
        & $Program @Arguments
        if($LASTEXITCODE) { throw "Android build/audit failed: $Program" }
    }
    $version=([regex]::Match((Get-Content -Raw pubspec.yaml),'(?m)^version:\s*(\S+)\s*$')).Groups[1].Value
    if($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Stable version required' }
    $code=(Get-Content -Raw release/android-version-code.txt).Trim()
    if($code -cnotmatch '^[1-9][0-9]{0,9}$' -or [long]$code -gt 2100000000) { throw 'Invalid Android version code' }
    $certificate=(Get-Content -Raw release/android-signing-certificate.sha256).Trim()
    if($certificate -cnotmatch '^[0-9a-f]{64}$') { throw 'Pinned Android certificate required' }
    if(!$env:SERVERDECK_ANDROID_KEYSTORE -or !$env:SERVERDECK_ANDROID_SIGNING_PASSWORD) { throw 'External Android signing credentials required' }
    if(!$Sdk) { throw 'Android SDK required' }
    $tools=Join-Path $Sdk 'build-tools/36.0.0'
    $out=Join-Path (Get-Location) 'output/android'
    if(Test-Path -LiteralPath $out) { throw 'Android output already exists; use fresh output to avoid stale artifacts' }
    New-Item -ItemType Directory -Path $out | Out-Null
    Checked flutter @('pub','get','--enforce-lockfile')
    Checked flutter @('build','apk','--release','--no-tree-shake-icons','--target-platform','android-arm64,android-x64','--build-number',$code)
    $unsigned='build/app/outputs/flutter-apk/app-release.apk'
    Checked python @('tools/audit-android-release.py','--apk',$unsigned,'--aapt',"$tools/aapt.exe",'--version',$version,'--code',$code)
    $aligned=Join-Path $out 'aligned-unsigned.apk'
    $signed=Join-Path $out 'ServerDeck-android.apk'
    Checked "$tools/zipalign.exe" @('-P','16','-f','4',$unsigned,$aligned)
    Checked "$tools/apksigner.bat" @('sign','--ks',$env:SERVERDECK_ANDROID_KEYSTORE,'--ks-key-alias','serverdeck','--ks-pass','env:SERVERDECK_ANDROID_SIGNING_PASSWORD','--key-pass','env:SERVERDECK_ANDROID_SIGNING_PASSWORD','--out',$signed,$aligned)
    $verification=& "$tools/apksigner.bat" verify --verbose --print-certs $signed
    if($LASTEXITCODE) { throw 'Android signature verification failed' }
    $digests=@($verification | Select-String '^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)$' | ForEach-Object {$_.Matches[0].Groups[1].Value})
    if($digests.Count -ne 1 -or $digests[0] -cne $certificate) { throw 'Android signing certificate mismatch' }
    Checked "$tools/zipalign.exe" @('-c','-P','16','4',$signed)
    Checked python @('tools/audit-android-release.py','--apk',$signed,'--aapt',"$tools/aapt.exe",'--version',$version,'--code',$code)
    $digest=(Get-FileHash -LiteralPath $signed -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $out 'ServerDeck-android.apk.sha256'),$digest+"  ServerDeck-android.apk`n")
    Remove-Item -LiteralPath $aligned
    Write-Output "Signed Android APK ready: version$version code$code certificate$certificate SHA256$digest"
} finally { Pop-Location }
