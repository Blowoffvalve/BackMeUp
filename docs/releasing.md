# Releasing

For the maintainer, on your own Mac. You need the Command Line Tools (`xcode-select --install`) and nothing else.

## 0. One-time setup: the update signing key

BackMeUp updates itself with [Sparkle](https://sparkle-project.org). Every update is signed with an EdDSA key, and copies of BackMeUp install only updates signed with the key whose public half is in their `Info.plist`. Until you've done this setup, `Packaging/Info.plist` holds the placeholder `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`. With the placeholder, `scripts/release.sh` refuses to run, and the app never checks for updates.

1. Fetch Sparkle's tools, which come with the Sparkle package: `swift package resolve`. They end up in `.build/artifacts/sparkle/Sparkle/bin`.
2. Make the key: `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. It saves the private key in your login Keychain, as "Private key for signing Sparkle updates", and prints the public key. If a key is already in your Keychain, it prints that one's public key instead of making a new one. Allow Keychain access if asked.
3. In `Packaging/Info.plist`, replace `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` (the `SUPublicEDKey` value) with the public key, and commit that. The public key isn't secret.
4. **Back up the private key now.** If you lose it, you can never ship another update: everyone would have to download the next version by hand. If it leaks, anyone could sign updates that BackMeUp would install.
   1. Export it: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt`.
   2. Copy the file's contents into your password manager.
   3. Delete the file: `rm -P sparkle-private-key.txt`. Never commit it.

To use the key on another Mac, save the backup to a file there and import it with `generate_keys -f FILE`, then delete the file.

## 1. Make the zip and appcast

From a clean checkout of the commit you want to release:

```sh
scripts/release.sh
```

It asks what kind of release this is and works out the version from the last one, the highest `vX.Y.Z` tag on your Mac or on GitHub:

| Choice | When | 1.2.0 becomes |
|---|---|---|
| 1) Patch | bug fixes only | 1.2.1 |
| 2) Minor | new features or settings; everything that worked still works | 1.3.0 |
| 3) Major | big changes: something removed, or people must set it up again | 2.0.0 |

With no tags yet, it counts from 0.0.0, so the first minor release is 0.1.0. You can skip the question with `scripts/release.sh patch`, `minor` or `major`, or give an exact version of three numbers, such as `scripts/release.sh 1.2.0`, which must be higher than the last release. `scripts/release.sh --dry-run` shows the version it would use and stops.

The examples below use 1.2.0. The script:

1. stops straight away if `SUPublicEDKey` is still the placeholder
2. builds a universal (arm64 and x86_64) release of `BackMeUp.app`, with Sparkle inside
3. sets both version fields in its `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`) to the new version
4. ad-hoc signs it, with no hardened runtime, and checks the signature with `codesign --verify`
5. zips it to `build/release/BackMeUp-1.2.0.zip`
6. signs the zip with your private key, using Sparkle's `generate_appcast`, and writes `build/release/appcast.xml`. macOS may ask whether `generate_appcast` can use the key in your Keychain. The appcast offers only this version, downloaded from the `v1.2.0` release on GitHub
7. checks the signature against `SUPublicEDKey`, and stops without an appcast if the private key doesn't match it

It never uploads, pushes or tags anything, and prints the commands for step 2 when it's done. Each version must be higher than the last, because updates compare `CFBundleVersion`. The tag from step 2 is what records the release, so tag every release you publish, or the next run will offer the same version again.

To sign with a key file instead of the Keychain, set `SPARKLE_ED_KEY_FILE`: `SPARKLE_ED_KEY_FILE=path/to/key scripts/release.sh`.

To check the script itself, run `scripts/test-release.sh`. It checks the version choices first, in a scratch repository with made-up tags, then does two release builds of a test version with a throwaway key, so it takes a few minutes. It doesn't touch your Keychain or `Packaging/Info.plist`.

## 2. Upload it

This is a separate step, done by hand when you're ready. Copies of BackMeUp look for updates at `https://github.com/Blowoffvalve/BackMeUp/releases/latest/download/appcast.xml`, so the appcast must be attached to the newest published release, and that release must not be a draft or a pre-release.

1. Tag the release commit and push the tag: `git tag v1.2.0 && git push origin v1.2.0`. The tag must match the version, because the appcast points at `releases/download/v1.2.0/`.
2. On GitHub, open **Releases → Draft a new release**, choose the `v1.2.0` tag, and attach both `build/release/BackMeUp-1.2.0.zip` and `build/release/appcast.xml`.
3. Write the release notes and publish.

Or, with the `gh` CLI, after tagging: `gh release create v1.2.0 build/release/BackMeUp-1.2.0.zip build/release/appcast.xml --title "BackMeUp 1.2.0" --notes "..."`.

Don't edit `appcast.xml` by hand afterwards. Run the script again instead.
