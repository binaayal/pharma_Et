# Installing PharmaEt on a pharmacy's Android phone

Until PharmaEt is on Google Play, you install it by hand from an APK file. It takes about five
minutes per phone. The app talks to the live server on Render. Nothing is set up on the
phone except the sign-in.

---

## What you need

- **The APK file**, `pharmaet-<version>.apk`. Get it from either place:
  - **GitHub:** repository → **Actions** → the latest green **CD** run → **Artifacts** →
    `pharmaet-android` → download → unzip → `app-release.apk`.
  - **Your computer:** `~/Desktop/pharmaet-apk/` when it was built locally.
- The phone: **Android 7 or newer**, about 120 MB free, and internet for the first sign-in.
- The pharmacy's **code, username and PIN**, which you set when you approve their account in
  the web console (see "Opening a new pharmacy" below).

## Install it (on the pharmacy's phone)

1. **Send the APK to the phone.** WhatsApp or Telegram it to the owner (send it as a
   *document/file*, not as media), or copy it over USB.
2. **Open the file** on the phone. Tap it in WhatsApp/Telegram, or in *Files → Downloads*.
3. Android will say *"For your security, your phone is not allowed to install unknown apps
   from this source."* Tap **Settings**, turn on **Allow from this source**, then go back.
4. Tap **Install**. If **Play Protect** warns about an unknown developer, tap **More details →
   Install anyway**. This is expected for any app installed outside the Play Store.
5. Tap **Open**. Turn **Allow from this source** back off afterwards (Settings → Apps →
   *WhatsApp/Telegram/Files* → Install unknown apps).

## First sign-in

1. Connect to the internet (mobile data or Wi-Fi). The very first sign-in needs it once.
2. Enter the **pharmacy code**, **username** and **PIN** you gave them.
3. The first time, the owner creates the **first branch** (the one this phone is in).
4. From then on the phone works **offline too**. Sales are saved on the phone and upload by
   themselves when the internet returns.

The app has its own **Help & user guide** (on the sign-in screen, and under **More**), in
Amharic and English. Show the owner where it is.

## Opening a new pharmacy (on your web console)

1. On their phone, they tap **Request an account** and fill in the form.
2. You open the web console → **Sign-up requests** → you see it.
3. **Call the phone number** to verify the pharmacy.
4. **Approve & open account.** You choose the pharmacy **code** (e.g. `abebe-bole`), the owner's
   **username** and a **starting PIN** (4–8 digits). Tell them the PIN by phone.

Or open it straight from **Tenants → New tenant** if you have already verified them.

## Getting paid

1. The subscription is **ETB 1,000/month**. The app shows them your CBE and Telebirr
   accounts under **More → Subscription**.
2. They pay and upload the screenshot in the app.
3. You open **Payments** in the console, check the screenshot against your bank or Telebirr,
   and **Approve**. The screenshot is deleted after you decide (keep the box ticked). Only
   the amount, reference and your decision are kept.

## Updating the app later

Send the new APK and install it the same way. Android installs it **over** the old one, and
all sales and settings stay. This works because every PharmaEt APK is signed with the same
key (`~/Desktop/pharmaet-android-signing/`). **Never lose that folder.** Keep a copy on a USB
stick and in your password manager. Without it, no phone can ever be updated, and every
pharmacy would have to uninstall (losing unsynced sales) and reinstall.

## If something goes wrong

| What they see | What to do |
|---|---|
| "App not installed" | An older PharmaEt signed with a different key is on the phone. Sync it, uninstall it, install again. |
| "No connection — the first sign-in needs the internet once" | Turn on data/Wi-Fi and try again. |
| The first sign-in after a long quiet period is slow or fails once | The free server was asleep. Wait 30 seconds and try again. (Fixed by the uptime monitor, or by the paid Render plan.) |
| "Could not sign in" | Check the code, username and PIN. After 5 wrong tries, wait 15 minutes. |
| "Account deactivated" | You deactivated the pharmacy in the console. Reactivate it under Tenants. |

---

### Short version to send the owner (Amharic)

> **ፋርማኢትን መጫን፦**
> 1. የላክሁልዎትን `pharmaet.apk` ፋይል ይክፈቱ።
> 2. «ከዚህ ምንጭ ፍቀድ» (Allow from this source) የሚለውን ያብሩ፣ ከዚያ **Install** ይንኩ።
> 3. Play Protect ካስጠነቀቀ፦ **More details → Install anyway**።
> 4. መተግበሪያውን ከፍተው በኢንተርኔት የፋርማሲ ኮድ፣ የተጠቃሚ ስምና የሰጠሁዎትን ፒን ያስገቡ።
> 5. ከዚያ በኋላ ያለ ኢንተርኔትም ይሰራል። እገዛ ከፈለጉ፦ በመግቢያ ገጹ ላይ «ፋርማኢትን እንዴት እጠቀማለሁ?» ወይም 0902432346 ይደውሉ።
