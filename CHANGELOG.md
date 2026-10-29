## 0.1.0

First release.

- **Scan**: pick drives or folders and find every Flutter/Dart project, walking them in parallel. Shows each project's reclaimable `build/`, `.dart_tool/`, `android/.gradle`, `android/app/.cxx`, `ios/Pods` and platform `ephemeral/` folders, with when it was last built. The last scan is cached, so a repeat run is instant (`--fresh` scans again).
- **Clean**: `flutter clean` (or `fvm flutter clean` for FVM projects) followed by removal of the leftovers it misses, or direct deletion. Shows free space per drive before and after.
- **Safety**: projects built in the last few days are hidden (`--older-than 14d`); `i` ignores a project for good, and `buildremove ignored` brings it back. `--dry-run` deletes nothing.
- **Info**: Flutter SDKs on PATH, FVM versions, other tools' SDK copies, the Android SDK (NDK, build-tools, platforms, system images), Gradle versions and caches (Pub, Gradle, Dart analysis server, Xcode and CocoaPods on macOS).
- **Usage**: NDK, Gradle and FVM versions and Pub package versions are marked as used or unused by the projects you've scanned. Only unused Pub and Gradle versions can be pruned, instead of wiping the whole cache.
- **Recycle Bin / Trash** option when deleting SDKs and caches.
- **Arrow-key checkbox lists**, with typed numbers (`1,3,5-8`) as a fallback.
