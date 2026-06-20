# ChowSA — Play Store Release Checklist

Living checklist for getting (and keeping) ChowSA shippable to the Google
Play Store. Tick items off in PRs as they land.

## One-time setup (must be done once before the first AAB upload)

- [ ] **Generate the release keystore.** Run on a trusted machine:
      ```pwsh
      keytool -genkey -v `
        -keystore android/keystores/chowsa-release.jks `
        -keyalg RSA -keysize 2048 -validity 10000 `
        -alias chowsa
      ```
      Back up the `.jks` file AND the passwords in your password manager.
      **Losing them means you can never update the app again** — Google
      Play permanently binds the upload key to the package id.
- [ ] **Create `android/key.properties`** alongside the keystore:
      ```
      storeFile=../keystores/chowsa-release.jks
      storePassword=••••
      keyAlias=chowsa
      keyPassword=••••
      ```
      Both `key.properties` and `keystores/` are already gitignored.
- [ ] **Enrol in Play App Signing** during the first AAB upload (Play
      Console offers it automatically).
- [ ] **Host the privacy policy + delete-account page.** The files in
      `marketing/site/` are ready to deploy — push to any static host
      (GitHub Pages, Netlify, Cloudflare Pages) and grab the public URLs
      for the Play Console listing.
- [ ] **Fill the Play Console Data Safety form.** ChowSA collects:
      location (coarse + fine), email, photos picked from gallery/camera,
      Supabase auth tokens, AdMob device identifiers. Declare each.
- [ ] **Complete the content rating questionnaire** in Play Console.
- [ ] **Decide the IAP path for ChowSA Pro.** Play's Payments policy
      generally requires Google Play Billing for in-app subscriptions.
      PayFast in a WebView is a known rejection trigger unless ChowSA
      Pro qualifies for an exemption (e.g. real-world goods/services).
      Confirm with Play policy or migrate to Play Billing before the
      first production rollout.

## Per-release checklist

- [ ] **Bump `version:` in `pubspec.yaml`.** Format is `X.Y.Z+N`:
      - `X.Y.Z` (versionName) is what users see.
      - `N` (versionCode) is what Play tracks — must strictly increase
        every upload. Bump it even for the same versionName.
- [ ] **Update the changelog** (or release notes for Play Console).
- [ ] **Run the release build:**
      ```pwsh
      pwsh ./scripts/build-release.ps1
      ```
      or on POSIX:
      ```bash
      ./scripts/build-release.sh
      ```
      The script clean-builds, runs `flutter analyze`, and produces a
      production-flagged AAB at
      `build/app/outputs/bundle/release/app-release.aab`.
- [ ] **Upload to the Internal testing track first.** Let Play's
      pre-launch report run — fix any red items before promoting.
- [ ] **Test the install on a real device** (login, location prompt,
      notifications, photo pick, PayFast checkout, AdMob banner).
- [ ] **Promote → Closed → Open → Production** after the internal
      cohort signs off.

## Store listing assets (already collected)

- App icon: `assets/icon/` (verify 512×512 export exists).
- Phone screenshots: `marketing/screenshots/` (15 captures — pick 2–8
  best for the listing).
- Feature graphic (1024×500): **not in repo yet** — design and drop
  into `marketing/play-store/feature-graphic.png`.
- Short description (≤80 chars) + full description (≤4000 chars):
  draft in `marketing/play-store/listing.md` before submission.

## Things the build script enforces

- `flutter analyze` must be clean.
- Production dart-define + Gradle prop are both set, so AdMob ships
  the real App ID instead of Google's test ID.
- Build fails fast if `android/key.properties` is missing — no more
  accidental debug-signed AABs.
