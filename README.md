# ServerDeck client

Flutter desktop client for Windows and Android, with local SSH profiles,
credentials and software cards, plus optional end-to-end encrypted device sync.

This repository contains client code, assets, native adapters and unit tests.
All specifications and Spec Kit live in the private
[ServerDeck workspace](https://github.com/serverdeck-app/workspace).
The client builds independently of that repository.

Use the pinned Flutter SDK, then run:

```powershell
flutter pub get --enforce-lockfile
./tools/test-unit.ps1
flutter build windows --debug
flutter build apk --debug --target-platform android-arm64,android-x64
```

See [Android build prerequisites](docs/android-build.md) and
[AGENTS.md](AGENTS.md) for check boundaries. Tests use synthetic/fake dependencies;
passing units/builds do not establish full real-device integration.

New releases and update metadata live at
[serverdeck-app/client](https://github.com/serverdeck-app/client/releases).
Existing installations receive a separately signed transition release through the
previous public update channel before switching to this repository.
