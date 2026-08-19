# Manual App Store release (Xcode + Transporter)

How to build, sign, and upload a signed build of the iOS app to App Store Connect by hand — the alternative to the automated CI path (`release.yml`'s `upload-ios-appstore` job + `fastlane/`). Use this when you don't want to put an App Store Connect API key in CI, or for a first release before the CI secrets are configured.

## Why Export + Transporter (not Xcode's "Upload")

Xcode Organizer's **Distribute App ▸ Upload** path re-manages signing through the developer portal and needs an Xcode account that belongs to the signing team. If your Apple ID is only an App Store Connect **App Manager** on the team (not an Admin / developer-portal member), that Upload fails with *"No Account for Team …"* and *"No profiles for '…' were found."*

The way around it: **Export** a signed `.ipa` locally (using manually installed profiles — no portal account needed), then upload it with **Transporter**, which only needs App Store Connect access — App Manager is enough to deliver builds.

## One-time prerequisites

- An **Apple Distribution** certificate *with its private key* in your **login** keychain. Verify:
  ```sh
  security find-identity -v -p codesigning   # should list "Apple Distribution: …"
  ```
  (In Keychain Access it shows under the **My Certificates** category, with a private key under its disclosure triangle.)
- The two **App Store provisioning profiles**, one per bundle id:
  - `com.hronro.ime-jd` — the app
  - `com.hronro.ime-jd.keyboard` — the keyboard extension
- Tools: [`zig`](https://ziglang.org), [`xcodegen`](https://github.com/yonaskolb/XcodeGen), and **Transporter** (free, Mac App Store).
- The **App record** created in App Store Connect for `com.hronro.ime-jd`, with metadata, screenshots, a privacy-policy URL, and App Privacy = *Data Not Collected*.

> `project.yml` is intentionally signing-agnostic (no team, no profiles) so the repo carries no account-specific values and the unsigned CI build stays clean. Signing is therefore selected in Xcode per build (step 3), not committed.

## Each release

1. **Pick the version + build number.** Re-uploading the *same* marketing version needs a build number **higher** than any build already in App Store Connect.

2. **Regenerate the project only if the structure changed** (files added/removed, `project.yml` edited):
   ```sh
   cd ios && xcodegen generate
   ```
   ⚠️ Regenerating resets signing back to automatic (because `project.yml` has none), so you must redo step 3. If nothing structural changed, **skip this** and your manual signing persists in the existing `.xcodeproj`.

3. **Set signing + version in Xcode.** Open `JdIME-iOS.xcodeproj`:
   - For **both** targets — `JdIME-iOS` and `JdKeyboard` — open **Signing & Capabilities**, uncheck **Automatically manage signing**, pick the **Team**, and select each target's **App Store profile** (use **Import Profile…** if it isn't listed).
   - On **both** targets' **General** tab, set the **same Version and Build**. The keyboard extension's `CFBundleShortVersionString` and `CFBundleVersion` must match the containing app's, or the upload warns/rejects (error 90473) — editing the app target alone leaves the extension on the `project.yml` placeholder (`0.0.0` / `1`).

4. **Archive.** Set the run destination to **Any iOS Device (arm64)**, then **Product ▸ Archive**.

5. **Export a signed `.ipa`.** In the Organizer: **Distribute App ▸ Custom ▸ App Store Connect ▸ Export ▸ Manually manage signing** (select both profiles) ▸ Export to a folder → `JdIME.ipa`.
   - Distribution options: **Upload symbols → on**; **Manage version and build number → off** (keeps the build number you set).

6. **Upload with Transporter.** Open Transporter, sign in with your Apple ID (App Manager is enough), drag in `JdIME.ipa`, click **Deliver**, and wait for *Delivered*.

7. **Wait for processing.** The build shows as **Processing** in App Store Connect; you can't attach it until that finishes (you'll get an email).

8. **Attach the build + submit.** On the version page, select the processed build under **Build**, confirm all metadata is complete, fill **App Review Information** (contact + reviewer notes on how to enable the keyboard), then **Submit for Review**.
   - If this is a *new* version (the previous one is already submitted/live), add a new version with **+ Version** first; otherwise just swap the build on the current "Prepare for Submission" version.

## Export compliance

`App/Info.plist` declares `ITSAppUsesNonExemptEncryption = false`, so uploads skip the export-compliance prompt automatically — nothing to answer.

## Relationship to the CI path

The automated equivalent is `release.yml`'s `upload-ios-appstore` job, which runs `fastlane release_appstore` (see `fastlane/Fastfile`) on a version tag. It uses the same signing material supplied as base64 GitHub Secrets and **skips itself** if any of those secrets are missing, so the manual path here and the CI path coexist without conflicting.
