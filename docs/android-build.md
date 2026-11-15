# Android artifact and signing recipe

This recipe builds the client repository only. All specifications belong in the
private workspace; code and build artifacts belong to their owning client/backend
repositories. Client behavior and limits:
[platforms](https://github.com/serverdeck-app/workspace/blob/main/specs/client/009-device-sync/contracts/platforms.md),
[workspace](https://github.com/serverdeck-app/workspace/blob/main/specs/client/009-device-sync/contracts/workspace.md),
[runtime](https://github.com/serverdeck-app/workspace/blob/main/specs/client/009-device-sync/contracts/runtime.md).

## Prerequisites

Use pinned Flutter3.47.7/Dart3.13.5, JDK17+, Android SDK/Build Tools36, NDK28.2.13676358.
Gradle9.3.1 wrapper, AGP9.1.0 and Kotlin2.4.0 are committed. Set local SDK/Flutter
paths in ignored android/local.properties or use the normal installed toolchain.
Do not commit workstation paths, keystores, signing passwords or production keys.

Supported Android min24/target36, arm64-v8a and x86_64 only. Packaged Isar3.4.1
loads libisar.so for the actual64bit ABI; download:false. APK must contain Isar
for both selected ABIs and no32bit native libraries. Local Keystore alias requires
ordinary Android Keystore availability; no biometric enrollment requirement.

## Unit checks and debug compilation

From the client root in PowerShell:

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
./tools/check-test-boundaries.ps1
# Run specification link checks separately from private workspace root.
./android/gradlew.bat -p android :app:testDebugUnitTest --console=plain
flutter build apk --debug --target-platform android-arm64,android-x64
```

Each command must succeed before continuing. Debug output:
build/app/outputs/flutter-apk/app-debug.apk. This uses debug signing, suitable for
local development compilation only. No app/device/emulator launch is part of the
unit gate. Build success does not prove hardware/OS/backend integration.

## Unsigned release compilation

The committed release build type has no signing configuration; it never silently
uses debug signing. Build a separate unsigned artifact:

```powershell
flutter build apk --release --target-platform android-arm64,android-x64
```

Output build/app/outputs/flutter-apk/app-release.apk is unsigned, despite its generic
filename. Verify this explicitly before using it: apksigner verify is expected to
reject this unsigned input. Do not distribute it as an installable signed release.
APK versionName follows pubspec.yaml unless explicitly overridden by --build-name.
Developer builds default to versionCode1 unless --build-number is supplied; a signed
Android release must use a monotonically increasing build number. Windows
installer/catalog/signing follow their separate release contract.

## External signing

The release operator supplies an Android signing keystore outside the repository,
an existing alias, and credentials in environment variables. Retain the same signing
identity for future updates. Key loss can require reinstall/local-data loss; cloud
content still requires login plus the user's separate recovery code. This recipe
does not create or export any signing/recovery key.

Example variables: SERVERDECK_ANDROID_KEYSTORE, SERVERDECK_ANDROID_KEY_ALIAS,
SERVERDECK_ANDROID_KS_PASS, SERVERDECK_ANDROID_KEY_PASS. Their values must not be
printed, committed or put into Gradle properties. In the following example sdkTools
is the operator's installed Build Tools36 directory and artifact paths are local
build outputs:

```powershell
$sdkTools = Join-Path $env:LOCALAPPDATA 'Android/Sdk/build-tools/36.0.0'
New-Item -ItemType Directory -Force build/distributions | Out-Null
& "$sdkTools/zipalign.exe" -P 16 -f 4 build/app/outputs/flutter-apk/app-release.apk build/distributions/serverdeck-aligned-unsigned.apk
& "$sdkTools/apksigner.bat" sign --ks $env:SERVERDECK_ANDROID_KEYSTORE --ks-key-alias $env:SERVERDECK_ANDROID_KEY_ALIAS --ks-pass env:SERVERDECK_ANDROID_KS_PASS --key-pass env:SERVERDECK_ANDROID_KEY_PASS --out build/distributions/serverdeck-signed.apk build/distributions/serverdeck-aligned-unsigned.apk
& "$sdkTools/apksigner.bat" verify --verbose build/distributions/serverdeck-signed.apk
& "$sdkTools/zipalign.exe" -c -P 16 4 build/distributions/serverdeck-signed.apk
```

Stop on any nonzero command exit; never sign a failed/missing/stale build. Verify
the certificate against the operator's intended Android signing identity before
distribution. Signing/installation/store upload, GitHub release/tag/publish and
production rollout are separate operations, not performed by these implementation
tasks. No signing secret or actual production certificate is required for unit or
unsigned compilation evidence.

## Static artifact audit

Use aapt dump badging/xmltree to verify com.unng.serverdeck, min24/target36, expected
version/build, allowBackup=false and usesCleartextTraffic=false. Only requested OS
permission is INTERNET; AndroidX's generated app-local signature permission is
permitted. No foreground service, broad storage permission or auth callback/app link.
Check ZIP native library ABI directories and Isar presence, zipalign16KiB page
alignment and native ELF LOAD alignment using NDK llvm-readelf. Do not infer runtime
availability from archive presence alone.

Android SSH remains a local native connection while the process lives, with no
foreground service or persistence guarantee after process death. Sync pauses on
foreground loss and resumes after clock calibration with existing pending state;
opening the external browser does not grant a background polling exception.
