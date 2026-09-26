# Mobile release — Android and iOS

**Status:** ✅ Draft · owner: Bina
**Depends on:** `ci-cd.md`, `staging.md`, `device-matrix.md`
**Pipeline:** `.github/workflows/cd.yml` jobs `release-android` and `release-ios`

Every merge to `main` builds the phone apps against staging, from the same commit as the server
they talk to. Each job checks for its own signing secrets first. If they are missing, the job
writes what is missing to the run summary and builds nothing. It never produces something that
looks shippable but isn't.

What stays true whether or not anything below is set up: CI's `mobile · iOS build` job compiles
the iPhone target on every mobile change, and `mobile · analyze, format, guardian` runs the
suites.

## 1. What each job produces

| Job | Output | Where it goes |
|---|---|---|
| `release-android` | `app-release.aab` (Google Play) and `app-release.apk` (direct install), signed with the upload key | the `pharmaet-android` artifact on the CD run, kept 30 days |
| `release-ios` | a signed `.ipa` | uploaded to App Store Connect → TestFlight |

- **Version code / build number:** the CD run number, so every merge installs over the last one.
- **API base URL:** the repository variable `MOBILE_API_BASE_URL`, falling back to
  `https://pharmaet-staging.fly.dev/api`.
- **Controlled dispensing:** the app has no switch of its own. It follows the server's
  `/health` → `features.controlledDispensing`, which stays off until A-1 is signed off
  (ADR-024, `../compliance-sign-off.md`).

## 2. Android: one-time setup (owner only)

1. Create the **upload key**. Keep the file and both passwords somewhere that is not this
   repository (a password manager). If you lose it, Play has to reset it, which takes days.
   ```sh
   keytool -genkeypair -v -keystore pharmaet-upload.jks -alias upload \
     -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Add four repository secrets (Settings → Secrets and variables → Actions):
   ```sh
   gh secret set ANDROID_UPLOAD_KEYSTORE_B64 < <(base64 -w0 pharmaet-upload.jks)
   gh secret set ANDROID_UPLOAD_STORE_PASSWORD
   gh secret set ANDROID_UPLOAD_KEY_ALIAS      # "upload"
   gh secret set ANDROID_UPLOAD_KEY_PASSWORD
   ```
3. To publish on Google Play (optional, needs a $25 developer account): create the app as
   `et.pharma.pharmaet_mobile` and turn on **Play App Signing**. Upload the first `.aab` from the
   artifact by hand to the internal testing track. After that, the APK is only needed for phones
   installed outside Play.

The job checks that the APK's signer is not `CN=Android Debug` and fails if it is.

**Local release builds.** Write `apps/mobile/android/key.properties` (it is git-ignored):
```
storeFile=/absolute/path/to/pharmaet-upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
```
Without this file, `flutter build apk --release` still works but is signed with the debug key,
and Gradle prints `release build is DEBUG-signed and cannot ship`. That build is fine for
testing on a phone you own. It cannot go to Play and cannot update an install signed with the
upload key (Android refuses to swap signers, so you would have to uninstall first).

## 3. iOS: one-time setup (owner only)

Putting the app on an iPhone outside Xcode requires the **Apple Developer Program** ($99/year).
It is the only way to get to TestFlight. Without it, the app can only be sideloaded from a Mac
with Xcode, and that install expires after 7 days.

1. Enrol at developer.apple.com and note your **Team ID** (Membership details).
2. In App Store Connect, create the app with bundle ID `et.pharma.pharmaetMobile` (register the
   identifier under Certificates, Identifiers & Profiles first).
3. Create an **App Store Connect API key** with the *Admin* role (Users and Access →
   Integrations). The role matters: it lets CI create the distribution certificate and profile
   itself. Download the `.p8` file. Apple only lets you download it once.
4. Add four repository secrets:
   ```sh
   gh secret set APPLE_TEAM_ID
   gh secret set APP_STORE_CONNECT_KEY_ID
   gh secret set APP_STORE_CONNECT_ISSUER_ID
   gh secret set APP_STORE_CONNECT_KEY_P8_B64 < <(base64 -w0 AuthKey_XXXXXXXXXX.p8)
   ```
5. On the next merge, the build shows up in TestFlight once Apple has processed it (usually
   10–30 minutes). Add yourself as an internal tester and install through the TestFlight app.

The job signs automatically with the API key (cloud-managed certificates). No certificate or
provisioning profile is stored in the repository or in secrets.

**Not yet exercised.** The iOS upload path has not run end to end, because no Apple account
exists yet. The unsigned build is proven on every PR. The signing and upload steps will run for
the first time the day the secrets are added, so check that run's log.

## 4. After a release

- Run the device matrix on the new build (`device-matrix.md`) before it goes to a pharmacy.
- A pilot pharmacy should only get a build whose API URL points at an environment you intend
  them to use. Staging holds synthetic data only.
