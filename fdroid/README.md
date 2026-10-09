# F-Droid

[`in.commandlinecoding.elephant.yml`](in.commandlinecoding.elephant.yml) is the build recipe to submit to [fdroiddata](https://gitlab.com/fdroid/fdroiddata). F-Droid builds the app from source with that recipe and signs it with its own key. The store listing (description, changelogs, icon, screenshots) is read from [`metadata/en-US/`](../metadata/en-US/) in this repository.

## Releasing a new version

F-Droid checks for new releases by reading `mobile/pubspec.yaml` at each `v*` tag, so the version there must be bumped before tagging.

1. Bump `version:` in `mobile/pubspec.yaml`. Increase both parts: `0.3.1+3` → `0.3.2+4`. The number after `+` is the versionCode and must always go up.
2. Add a changelog at `metadata/en-US/changelogs/<4000 + versionCode>.txt` (for `+4`, that's `4004.txt`). Keep it under 500 characters.
3. Commit, then tag `v<version>` (e.g. `v0.3.2`) and push the tag. The release workflow fails if the tag doesn't match `pubspec.yaml`.

F-Droid picks up the new tag automatically within a few days.

## Version codes

APKs are built per ABI, and Flutter derives each versionCode from the `pubspec.yaml` build number:

| ABI | versionCode |
|---|---|
| armeabi-v7a | 1000 + build number |
| arm64-v8a | 2000 + build number |
| x86_64 | 4000 + build number |

The recipe's `VercodeOperation` mirrors this. If a Flutter upgrade changes this scheme, update the recipe.

## Flutter version

F-Droid builds with the Flutter version pinned as `flutter-version` in [`.github/workflows/android-release.yaml`](../.github/workflows/android-release.yaml). To upgrade Flutter, change it there; both the GitHub release and F-Droid follow.

## Release signing (GitHub releases)

F-Droid signs its own builds; this only affects the APKs attached to GitHub releases. Add these repository secrets so every release is signed with the same key and users can update from one release to the next:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Key alias |
| `ANDROID_KEY_PASSWORD` | Key password |

Without them, the workflow falls back to a throwaway debug key and prints a warning.

For local release builds, create `mobile/android/key.properties` (git-ignored):

```properties
storeFile=/absolute/path/to/release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Without `key.properties` or the secrets, release builds are unsigned, which is what F-Droid expects.

## Submitting to F-Droid

1. Tag the release (see above).
2. Fork [fdroiddata](https://gitlab.com/fdroid/fdroiddata) and copy the recipe to `metadata/in.commandlinecoding.elephant.yml`.
3. Replace `commit: v0.3.1` in each build with the tag's full commit hash.
4. Run `fdroid lint in.commandlinecoding.elephant` and `fdroid build -v -l in.commandlinecoding.elephant`, then open a merge request.
