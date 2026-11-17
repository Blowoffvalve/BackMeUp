# Releasing

For the maintainer, on your own Mac. You need the Command Line Tools (`xcode-select --install`) and nothing else.

## 1. Make the zip

From a clean checkout of the commit you want to release:

```sh
scripts/release.sh 1.2.0
```

The version is one to three numbers separated by dots. The script:

1. builds a universal (arm64 and x86_64) release of `BackMeUp.app`
2. sets both version fields in its `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`) to the version you gave
3. ad-hoc signs it, with no hardened runtime, and checks the signature with `codesign --verify`
4. zips it to `build/release/BackMeUp-1.2.0.zip`

It never uploads, pushes or tags anything. Each version must be higher than the last, because updates compare `CFBundleVersion`.

To check the script itself, run `scripts/test-release.sh`. It does a full release build of a test version, so it takes a minute or two.

## 2. Upload it

This is a separate step, done by hand when you're ready.

1. Tag the release commit and push the tag: `git tag v1.2.0 && git push origin v1.2.0`.
2. On GitHub, open **Releases → Draft a new release**, choose the `v1.2.0` tag, and attach `build/release/BackMeUp-1.2.0.zip`.
3. Write the release notes and publish.

Or, with the `gh` CLI, after tagging: `gh release create v1.2.0 build/release/BackMeUp-1.2.0.zip --title "BackMeUp 1.2.0" --notes "..."`.
