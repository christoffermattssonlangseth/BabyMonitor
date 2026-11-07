# 🌙 Baby Monitor for iPhone

A native iPhone app. One phone stays in the nursery as the **baby station**;
your phones are **parent stations**. They connect **directly over your home
Wi-Fi**. There is no server, no account and no cloud service.

- 🔊 Live sound that **keeps playing when your phone is locked**
- 📹 Live video (about 8 frames per second, which is plenty for a crib) while
  the app is open
- 🔔 **Notifications and an alert tone when the baby makes noise**, using your
  own sound level and duration
- ⚠️ **A lost contact alarm** that repeats every minute if the baby station
  stops responding (battery, Wi-Fi, app closed)
- 🔒 Encrypted with your family password. Phones without it can't connect or
  listen.
- Any number of parents at once

## What you need

- A **Mac** with **Xcode 16** or newer (free from the Mac App Store)
- Your **iPhones** on **iOS 17** or newer, plus a phone or iPad for the nursery.
  An old iPhone works well.
- An **Apple ID**. See [Free or paid Apple account?](#free-or-paid-apple-account)

## Install

1. Get this project onto your Mac (`git clone`, or download the ZIP from GitHub).
2. Open `ios/BabyMonitor.xcodeproj` in Xcode.
3. Click the **BabyMonitor** project at the top of the file list → target
   **BabyMonitor** → **Signing & Capabilities**:
   - **Team:** choose your Apple ID. Add it under Xcode → Settings → Accounts
     if it isn't listed.
   - If Xcode says the bundle identifier is taken, change **Bundle Identifier**
     to something unique, e.g. `com.yourname.BabyMonitor`.
   - Optional but recommended: click **+ Capability** → **Time Sensitive
     Notifications**. This lets alerts break through Sleep and other Focus modes.
4. Plug in an iPhone, select it at the top of the Xcode window, and press
   **▶ Run**.
5. **The first time on each phone:** Settings → General → VPN & Device
   Management → your Apple ID → **Trust**. Also turn on **Developer Mode** if
   asked: Settings → Privacy & Security → Developer Mode.
6. Repeat for the other phones.

## Use

**Nursery phone:** open Baby Monitor → **Baby station**, enter a family
password, then **Start**. Allow camera, microphone and local network access.
Then:
- Plug it in and point it at the crib.
- Tap **Dark screen**. The app keeps the screen on, so the camera keeps running,
  but at zero brightness.
- Optional: turn on **Guided Access** (Settings → Accessibility) so nobody can
  accidentally leave the app.

**Your phones:** open Baby Monitor → **Parent**, use the **same password**,
then **Start**. Allow notifications and local network access.

You can now lock your phone. Sound keeps playing, and alerts arrive as
notifications. Video pauses while the phone is locked, to save battery, and
resumes when you open the app.

### Make sure alerts get through at night

- **Sleep Focus / Do Not Disturb:** Settings → Notifications → Baby Monitor →
  turn on **Time Sensitive Notifications** (if you added the capability).
  Otherwise add Baby Monitor to the allowed apps: Settings → Focus → Sleep →
  Apps.
- **Silent switch:** the live sound and the in-app alert tones play even with
  the silent switch on, because the app works like a music app. The
  notification sounds themselves follow the silent switch.
- **Don't swipe the app away** in the app switcher. That closes it and stops
  everything. Locking the phone or switching to other apps is fine.

### Tuning alerts

Watch the meter while your son sleeps normally. Drag the slider so the white
line sits a bit above that level. **…for at least** stops short noises, like a
cough or a car outside, from triggering an alert. After an alert there is a
30-second pause before the next one.

## Free or paid Apple account?

| | Free Apple ID | Apple Developer Program ($99/year) |
|---|---|---|
| Install from Xcode | ✅ | ✅ |
| **App keeps working for** | **7 days**, then reinstall from Xcode | 1 year |
| Time Sensitive Notifications | Usually available | ✅ |

With a free account the app **stops opening after 7 days** until you reinstall
it from Xcode. Because a baby monitor must work every night, either reinstall
it on a fixed day each week or get the paid membership.

## Good to know

- **Same Wi-Fi only.** The phones find each other on the local network. When
  you're away from home, the parent phones can't reach the nursery.
- **Battery:** the nursery phone must be plugged in. A parent phone uses about
  as much battery as playing music all night, so charge it by the bed.
- **Phone calls** pause the sound. It resumes when the call ends; if it
  doesn't, open the app.
- **This app helps you keep an eye on your son. It is not a medical device.** It
  does not check breathing or movement, and Wi-Fi and phones can fail.

## How it works

```
 Nursery iPhone (Baby station)              Parent iPhones
 ┌──────────────────────────┐   Wi-Fi   ┌───────────────────────────┐
 │ mic  → 16 kHz PCM  ──────┼──────────▶│ AVAudioEngine (all night) │
 │ camera → JPEG ~8 fps ────┼──────────▶│ video while app is open   │
 │ sound level, heartbeat ──┼──────────▶│ noise + lost-contact      │
 │ Bonjour: _babymonitor    │  TLS-PSK  │   alerts → notifications  │
 └──────────────────────────┘           └───────────────────────────┘
```

- **Finding each other:** the baby station announces itself with Bonjour
  (`_babymonitor._tcp`); parents look for it and connect over TCP.
- **Security:** TLS 1.2 with a key derived from the family password (TLS-PSK),
  so only phones with the password can connect, and the audio and video are
  encrypted.
- **Staying awake:** a parent phone keeps its audio engine running all night.
  iOS lets apps that play audio keep running in the background, so the parent
  phone keeps receiving, can tell when the baby station goes quiet, and can
  post notifications itself.
- **Protocol:** each message is a 1-byte type, a 4-byte length, then the
  payload. See [`Core/Framing.swift`](BabyMonitor/Core/Framing.swift).

The platform-independent logic (message format, noise detection, lost-contact
watchdog) has tests:

```bash
cd ios
swiftc -o /tmp/logic-tests BabyMonitor/Core/Framing.swift BabyMonitor/Core/Detection.swift Tests/main.swift && /tmp/logic-tests
```

GitHub Actions builds the app and runs these tests on every change
(`.github/workflows/ios.yml`).
