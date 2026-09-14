# Releasing Teams Mute Helper

Official releases are built locally so the Developer ID private key stays in the maintainer's macOS Keychain.

## One-time setup

1. Install a **Developer ID Application** certificate in Keychain through Xcode or the Apple Developer portal.
2. Create an app-specific password for the Apple ID used for notarization.
3. Store the notarization details in Keychain:

   ```sh
   xcrun notarytool store-credentials teams-mute-helper \
     --apple-id "APPLE_ID" \
     --team-id "TEAM_ID"
   ```

Enter an app-specific password at the secure prompt. It is saved in the login Keychain and is not stored in shell history or this repository.

4. Trust and install the Homebrew tap:

   ```sh
   brew trust m-rk/tap
   brew tap m-rk/tap
   ```

   The updater uses Homebrew's registered tap checkout.

## Publish a release

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in [`TeamsMuteHelper-Info.plist`](TeamsMuteHelper-Info.plist).
2. Commit and push the release changes.
3. Run:

   ```sh
   ./scripts/release.sh VERSION --publish
   ```

The script verifies the Homebrew tap checkout before doing the expensive release work. It then builds a universal Apple silicon and Intel app, signs it with the first installed Developer ID Application identity, submits it to Apple for notarization, staples the ticket, checks it with Gatekeeper, creates a checksum, tags the commit, and publishes both files to GitHub Releases.

After GitHub publishes the release, the script updates the tap with the exact archive checksum, runs `brew style` and the online cask audit, commits and pushes the tap change, refreshes Homebrew, reinstalls the released cask, verifies the installed version and signature, and reopens the helper.

Set `TEAMS_MUTE_SIGN_IDENTITY` to choose a specific certificate or `TEAMS_MUTE_NOTARY_PROFILE` to use a different Keychain profile.

## Recover a Homebrew update

If the GitHub release succeeds but the tap update does not, fix the reported tap checkout problem and rerun only the Homebrew step using the checksum printed in the release's `.sha256` asset:

```sh
./scripts/update-homebrew-cask.sh VERSION SHA256
```

Replace `VERSION` and `SHA256` with the values from the release. The updater is idempotent when the tap already contains the requested version and checksum.
