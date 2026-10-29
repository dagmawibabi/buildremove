# buildremove

Free up disk space taken by Flutter and Dart development.

`buildremove` is an interactive command-line tool that finds every Flutter/Dart project on your drives,
shows how much space its build output takes, and cleans the ones you pick. It also lists your Flutter
SDKs, FVM versions, Android NDKs, Gradle versions and package caches, and tells you which ones none of
your projects use anymore.

```
$ buildremove scan

20 projects, 11.37 GB reclaimable
Clean which projects?
↑/↓ move · space select · a all · i ignore · enter done · q cancel
          Total      build  .dart_tool      other  Last build  Project
› [x]   4.22 GB    3.62 GB    510.4 MB    94.9 MB  7h ago      my_app  D:\Projects\my_app
  [x]   4.10 GB    3.54 GB    537.4 MB    33.2 MB  2d ago      shop_app  D:\Projects\shop_app
  [ ]   1.01 GB   582.0 MB    442.6 MB     4.8 MB  3mo ago     old_demo  D:\Projects\old_demo
  ...
2 selected · 8.32 GB
```

## Features

- **Finds every project.** Pick drives, or specific folders, and it walks them in parallel looking
  for `pubspec.yaml`. It skips system folders, `node_modules`, package caches and Flutter SDK
  checkouts.
- **Shows what each project can give back:** `build/`, `.dart_tool/`, `android/.gradle`,
  `android/app/.cxx`, `ios/Pods`, and the platform `ephemeral/` folders, plus when it was last built.
- **Cleans the way you want.** It can run `flutter clean` (or `fvm flutter clean` for FVM projects)
  and then remove the leftovers `flutter clean` misses, or delete the folders directly, which is
  faster.
- **Protects the project you're working on.** Projects built in the last few days are hidden, and
  you can ignore any project so it never shows up again.
- **Tells you what's unused.** The `info` screen marks each SDK version and cache as "used by N
  projects" or "not used by any known project" (see [how usage is detected](#how-usage-is-detected)).
- **Prunes caches instead of wiping them.** It can delete only the Pub package versions and Gradle
  versions your projects no longer use.
- **Shows the result** as free space per drive before and after cleaning.
- **Can be undone.** SDKs and caches can go to the Recycle Bin / Trash instead of being deleted
  permanently.
- **Keyboard-driven lists** with arrow keys and checkboxes, and typed numbers (`1,3,5-8`) as a
  fallback when the terminal doesn't support raw input.
- **Fast repeat runs.** The last scan is cached, so running it again shows results immediately.

## Installation

```bash
dart pub global activate buildremove
```

Make sure the Pub executables folder is on your `PATH`:

| OS | Folder |
| --- | --- |
| Windows | `%LOCALAPPDATA%\Pub\Cache\bin` |
| macOS / Linux | `~/.pub-cache/bin` |

Then run `buildremove` from any terminal.

## Usage

```bash
buildremove                    # interactive menu
buildremove scan               # pick drives/folders, then choose projects to clean
buildremove scan ~/projects    # scan specific folders
buildremove info               # SDKs, FVM, Android SDK, Gradle and caches, with usage
buildremove ignored            # bring back projects you ignored
buildremove config             # show saved settings
```

| Option | Description |
| --- | --- |
| `-n`, `--dry-run` | Show what would be freed without deleting anything. |
| `-o`, `--older-than <age>` | Only show projects not built for this long, e.g. `14d`, `2w`, `3mo`. |
| `-f`, `--fresh` | Scan again instead of offering the cached results. |
| `-y`, `--yes` | Clean every project found without asking. Needs explicit paths. |
| `-h`, `--help` | Show help. |

### Keys in lists

| Key | Action |
| --- | --- |
| `↑` `↓` (or `j` `k`) | Move |
| `Space` | Select / unselect |
| `a` | Select all |
| `u` | Select everything not used by any known project |
| `i` | Ignore this project from now on |
| `Enter` | Confirm |
| `q` | Cancel |

## What the info screen shows

- Flutter SDKs on your `PATH` and in `FLUTTER_ROOT`, with version, channel and size
- FVM: where it is installed, every cached version and its size, and which one is global
- Flutter SDK copies kept by other tools (Puro, AirReload)
- Android SDK: each NDK version, build-tools, platforms, system images and emulator
- Gradle: each downloaded Gradle version, counting its cache, daemon and wrapper folders
- Caches: Pub, Gradle, the Dart analysis server, Android emulators, and on macOS Xcode DerivedData
  and CocoaPods

You can then pick any of these to delete.

## How usage is detected

When you scan, every project found is remembered. The `info` screen checks those projects for:

| Item | Where buildremove looks |
| --- | --- |
| Android NDK | `ndkVersion` in `android/app/build.gradle(.kts)`. `flutter.ndkVersion` is resolved from the Flutter SDK the project uses. |
| Gradle | `distributionUrl` in `android/gradle/wrapper/gradle-wrapper.properties` |
| FVM version | `.fvmrc` / `.fvm/fvm_config.json`, plus the projects FVM itself has recorded |
| Pub packages | Each project's `pubspec.lock` and `.dart_tool/package_config.json`, Pub's own record of projects that used the cache, globally activated packages, and the Flutter SDKs' own dependencies |

"Not used by any known project" only covers projects buildremove has seen. If you keep projects on a
drive you haven't scanned, scan it first. Anything you delete is downloaded again by `flutter pub get`,
`fvm install` or the next Gradle build when it's needed.

## Safety

- Nothing is deleted until you confirm. SDKs and caches require typing `yes`.
- Project cleanup only touches generated folders (see [Features](#features)). Your source,
  `pubspec.yaml`, `pubspec.lock` and platform project files are never removed.
- Use `--dry-run` to see what a cleanup would free first.

Settings, the list of known projects and the last scan are stored in `~/.buildremove/`.

## Platform support

The tool is built and tested mostly on Windows. It also runs on macOS and Linux, where drives are
replaced by your home folder, `/` and mounted volumes, and the Trash is used instead of the Recycle
Bin (via `gio trash` on Linux).

### Native executable on Windows (optional)

The `dart pub global` launcher checks dependencies each time it starts. For instant startup, clone
[the repository](https://github.com/dagmawibabi/buildremove) and run:

```bash
powershell -ExecutionPolicy Bypass -File tool/install.ps1
```

This compiles `buildremove.exe` into `%LOCALAPPDATA%\Pub\Cache\bin` and adds that folder to your
`PATH`.
