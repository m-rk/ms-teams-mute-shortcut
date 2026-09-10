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

## Publish a release

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in [`TeamsMuteHelper-Info.plist`](TeamsMuteHelper-Info.plist).
2. Commit and push the release changes.
3. Run:

   ```sh
   ./scripts/release.sh 0.6.0 --publish
   ```

The script builds a universal Apple silicon and Intel app, signs it with the first installed Developer ID Application identity, submits it to Apple for notarization, staples the ticket, checks it with Gatekeeper, creates a checksum, tags the commit, and publishes both files to GitHub Releases.

Set `TEAMS_MUTE_SIGN_IDENTITY` to choose a specific certificate or `TEAMS_MUTE_NOTARY_PROFILE` to use a different Keychain profile.

## Update Homebrew

Update the version and SHA-256 in `Casks/teams-mute-helper.rb` in the `m-rk/homebrew-tap` repository, then run:

```sh
brew style --cask Casks/teams-mute-helper.rb
brew audit --cask --online m-rk/tap/teams-mute-helper
brew reinstall --cask m-rk/tap/teams-mute-helper
```
