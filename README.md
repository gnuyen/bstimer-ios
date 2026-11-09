# bsTimer for iOS

csTimer connects to smart cubes and Bluetooth timers through Web Bluetooth, which iOS
Safari doesn't have. bsTimer is an iOS app that runs csTimer in a `WKWebView` and
supplies it: `bluetooth-shim.js` provides `navigator.bluetooth` inside the page and
forwards every call to CoreBluetooth (`BluetoothBridge.swift`). The page's own
Bluetooth drivers run unchanged. See [PROTOCOL.md](PROTOCOL.md) for the bridge contract.

On top of that, the app:

- syncs sessions and solves through the user's iCloud, with no account or sign-in;
- keeps the screen awake while a timer is in inspection, ready or running, and lets it
  auto-lock when idle (turning a smart cube's faces, while scrambling say, also restarts
  the auto-lock countdown; tilting it does not);
- works offline once the page has loaded;
- saves exports through the share sheet.

The app loads a site running [bsTimer](https://github.com/gnuyen/bstimer), a lightly
modified csTimer with the sync server (see *The website*). bsTimer is an unofficial
wrapper: csTimer is written by [cs0x7f](https://github.com/cs0x7f/cstimer) and licensed
under GPL-3.0, and this repository contains none of its code, only the app that loads it.

A build option (`CSTIMER_NET_OPTION` in `project.yml`, off by default) adds a "Website"
choice in the iOS Settings app between the bsTimer site and csTimer.net. Bluetooth and
the screen lock work on both; iCloud sync needs the bsTimer site.

## Layout

| Path | What |
|------|------|
| `CstimerApp/Resources/bluetooth-shim.js` | Web Bluetooth polyfill injected at document start |
| `CstimerApp/BluetoothBridge.swift` | CoreBluetooth side of the bridge |
| `CstimerApp/DevicePickerViewController.swift` | Native device chooser for `requestDevice()` |
| `CstimerApp/WebViewController.swift` | Web view, navigation policy, JS alert/confirm/prompt |
| `CstimerApp/DownloadHandler.swift` | Saves exports and offers them through the share sheet |
| `CstimerApp/AppDelegate.swift` | App and scene delegates |
| `CstimerApp/CloudBridge.swift` | iCloud sync and Sign in with Apple for the page (`bsCloud`) |
| `CstimerApp/SiteMode.swift` | The site the app loads, and the optional choice of csTimer.net |
| `scripts/mac-build.sh` | Builds on a remote Mac over SSH |
| `CstimerApp/Resources/PrivacyInfo.xcprivacy` | Privacy manifest (required-reason APIs, data collected) |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated, not committed). `CURRENT_PROJECT_VERSION` is the build number, shown as `r<n>` in the launch badge; raise it for every upload |
| `test/*.test.js` | Node tests for the shim and the csTimer.net build option |

## The website

The page side lives in the [bsTimer](https://github.com/gnuyen/bstimer) fork of csTimer:

- `js/bstimer/app-auth.js` hands Google sign-in back to the app. Google sign-in runs in
  an `ASWebAuthenticationSession` and returns to the page with the token in the URL
  fragment; the script only acts when the sign-in's `state` ends in `.cstimer-ios`, a
  marker only the app adds. WCA sign-in needs nothing extra.
- `sw.js` makes the site work offline. The app lists the site under
  `WKAppBoundDomains`, which WKWebView requires before it runs service workers.
- The Sync section (`js/bstimer/sync*.js`, `sync.php`) uses the app's `bsCloud`
  bridge for iCloud sync.

## Build and run (on a Mac)

1. Install Xcode and XcodeGen: `brew install xcodegen`
2. `xcodegen generate` in this directory, then open `CstimerBT.xcodeproj`.
3. Signing: create `Config/Local.xcconfig` containing `DEVELOPMENT_TEAM = <your Team ID>`
   (see `Config/Signing.xcconfig`; git ignores it), then run `xcodegen generate` again.
   Or pick a team in Xcode under *Signing & Capabilities*, which `xcodegen generate` resets.
4. On the iPhone enable *Settings → Privacy & Security → Developer Mode*, connect
   it, pick it as the run destination and press Run. The first launch may require
   trusting the developer under *Settings → General → VPN & Device Management*.

Run `xcodegen generate` after pulling. It creates `Info.plist` and
`bsTimer.entitlements`, both of which git ignores.

### Building your own app

The project is set up for the published bsTimer app: its bundle id, iCloud container and
site. Your team can't register those, so change them:

| What | Where |
|------|-------|
| Bundle id | `PRODUCT_BUNDLE_IDENTIFIER` and `bundleIdPrefix` in `project.yml` |
| iCloud container (`iCloud.` + your bundle id, say) | `com.apple.developer.icloud-container-identifiers` in `project.yml`, and `CloudBridge.containerIdentifier` |
| Your site | `SiteMode.swift` (its URL and allowed hosts) and `WKAppBoundDomains` in `project.yml` |

`grep -rn -e bstimer.manoagames.com -e org.gnuyen .` finds the remaining mentions (a
debug-only test URL and `test/sitemode.test.js`). Then run `xcodegen generate` and the
tests.

## iCloud sync

On the bsTimer site the page syncs to the user's private CloudKit database (one record
named `snapshot` of type `Snapshot` holding zlib-compressed JSON in an asset) with no
sign-in, and keeps a copy on the site's sync server. That server's sync code is stored in
iCloud key-value storage (key `serverCode`) so other devices and reinstalls reuse it. The
bridge is `CloudBridge.swift` (message handler `bsCloud`, see [PROTOCOL.md](PROTOCOL.md)).

The Sync section also offers "Sign in with Apple (to use the website)". The app uses
the native Apple sign-in sheet (bsCloud op `appleSignIn`) and sends the identity token
to the sync server, which links the Apple ID to the app's server copy. The App ID needs
the Sign in with Apple capability (project.yml requests it).

Setting up iCloud for your team:

1. `project.yml` already requests the iCloud entitlements (CloudKit container and
   key-value storage).
2. In Xcode, open Signing & Capabilities for the target and make sure your container is
   ticked under iCloud (press + to create it if Xcode says it doesn't exist).
3. Debug builds use CloudKit's Development environment, where the record type is
   created on the first save. Before a TestFlight or App Store build, open the CloudKit
   Console, pick the container, and "Deploy Schema Changes" to Production.
4. The simulator needs an iCloud account signed in (Settings app) to test sync; without
   one the page falls back to the website's sync options.

## Debugging

Debug builds set `isInspectable`, so on the Mac *Safari → Develop → (iPhone) → (the
site's address)* opens Web Inspector for the page. Native logs show in Xcode's console.

## Tests

```
node --test test/
```
