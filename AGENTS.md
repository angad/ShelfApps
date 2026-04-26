# AGENTS.md

## Workspace Purpose

This repository is a workspace for building small UIKit apps designed around the iPhone 6 form factor and iOS 12 compatibility, while still fitting the normal Xcode developer lifecycle for physical iPhones.

## Public App Set

Only these app folders are intended for release:

- `apps/OverheadFlight/`
- `apps/NetworkWall/`
- `apps/DriveDash/`
- `apps/Bookshelf/`
- `apps/CityCams/`
- `apps/ParkCams/`

Other app folders are local experiments and should remain ignored.

## Layout Rules

- Keep each app under `apps/<AppName>/`.
- Keep app-specific source, `project.yml`, app README files, diagnostics, generated Xcode projects, build folders, payloads, and IPAs inside that app folder.
- Keep reusable workflow code at the root under `scripts/`.
- Keep reusable Codex instructions and references under `skills/`.
- Do not add a root `project.yml` for a single app. Each app should own its own XcodeGen config.

## Build And Install

For the standard developer workflow, generate the selected app's Xcode project and use Xcode Run on a connected device:

```sh
cd apps/<AppName>
xcodegen generate
open <AppName>.xcodeproj
```

Set the development team and bundle identifier in Xcode as needed for your Apple Developer account.

For local unsigned iOS 12 USB installs, use the shared installer from the workspace root:

```sh
scripts/install_usb_unsigned_ios12.sh apps/<AppName>
```

The default app is `apps/OverheadFlight`:

```sh
scripts/install_usb_unsigned_ios12.sh
```

The installer reads `name`, `PRODUCT_NAME`, and `PRODUCT_BUNDLE_IDENTIFIER` from the selected app's `project.yml`, then generates the Xcode project, builds with signing disabled, patches the Mach-O build version for iOS 12 compatibility, signs with `ldid`, packages an IPA, installs with `ideviceinstaller`, and verifies the bundle id.

## Environment

- Keep private values in `.env`; it is ignored.
- Use `IPHONE_UDID` in `.env` for the local USB installer.
- Keep `.env.example` scrubbed and safe to commit.

## App Defaults

- Prefer Objective-C UIKit for new apps targeting older iPhones. Swift can work, but Objective-C keeps runtime and deployment behavior simpler on iOS 12.
- Use programmatic UI for app screens unless there is a clear reason to add storyboards.
- Always include an iPhone 6-compatible launch asset. For this workspace, prefer a `Default-667h@2x.png` launch image plus matching `UILaunchImageFile`/`UILaunchImages` entries because it avoids storyboard compilation issues with modern Xcode. A launch storyboard is fine only after verifying `ibtool` can compile it. Without a launch asset, iOS 12 may run the app in legacy letterboxed mode on the iPhone 6.
- Target iOS 12.0 for compatibility.
- Use iOS 12-era app structure: `UIApplicationMain`, `AppDelegate`, one root `UIViewController`, and no SceneDelegate or SwiftUI.
- Include required `Info.plist` privacy strings for location, camera, microphone, photos, or Bluetooth when used.

## UI And UX Defaults

- Design for the real iPhone 6 screen first: 4.7-inch display, 1334x750 landscape pixels or 750x1334 portrait pixels, older GPU, and arm64 iOS 12 UIKit behavior.
- Prefer one primary job per screen. Use tabs or simple navigation for secondary views instead of cramming desktop-dashboard density onto the small phone.
- Keep text large and glanceable. Use fewer panels, stronger hierarchy, and short labels. Avoid tiny tables, dense charts, and long row metadata unless the screen is explicitly scrollable.
- Use `UIScrollView` or table-style rows for long content. Make row heights and panel heights explicit enough that dynamic text does not overlap on device.
- Be careful with newer UIKit conveniences. `UIStackView` is for layout, not decoration; put backgrounds, borders, and corner radii on wrapper `UIView`s for iOS 12 reliability.
- Disable the idle timer only for apps that are intended to stay on-screen, and re-enable it when the view disappears.
- Include basic runtime status in the UI because older-device debugging can be less reliable with modern Xcode.

## Assets And Icons

- Keep app assets inside the app folder. If generated assets are used, keep the durable source under `apps/<AppName>/IconSource/` or a similar app-local folder.
- For app icons without an asset catalog, provide the expected PNG sizes referenced by `CFBundleIconFiles`, commonly `20@2x`, `20@3x`, `29@2x`, `29@3x`, `40@2x`, `40@3x`, `60@2x`, and `60@3x`.
- Do not bake rounded corners into iOS app icons. Provide square PNGs; SpringBoard applies the mask.
- Keep launch storyboards, launch images, or other compatibility assets app-local. Avoid root-level generated media.

## Data And Device Capabilities

- Prefer lightweight native APIs and conservative polling on the phone. The iPhone 6 is best used as a display and local collector, not as a heavy background scanner.
- For richer data, add an optional companion script or local JSON endpoint under `scripts/` and ingest it from the app. Keep the app UI simple while improving the data source.
- Persist useful identity and calibration data locally with `NSUserDefaults` or small app-local files so later scans or sessions improve instead of starting over.
- For network apps, expect iOS sandbox limits around MAC addresses, ARP data, hostnames, and privileged scans. Design graceful fallbacks and do not assume all devices can be perfectly identified on-device.

## Debugging

For immediate launch crashes, first inspect device logs before changing app code:

```sh
perl -e 'alarm shift; exec @ARGV' 30 idevicesyslog -u "$IPHONE_UDID" > launch.log 2>&1
rg -n -i 'failed to exec|Bootstrap failed|dyld|amfid|signature|crash|exited|com.angad' launch.log
```

If logs show `The process failed to exec`, treat it as packaging, signing, or load-command trouble. If the app reaches `main` and logs an Objective-C exception, debug the app code normally.

For visual or layout issues, prefer fixing the programmatic UIKit layout and redeploying to a physical device. The simulator is useful for rough layout only; the connected iPhone is the real target.

## Generated Files

Generated Xcode projects, build folders, IPA/Payload output, device crash dumps, and syslog captures should normally stay untracked. Keep durable source, scripts, skills, README files, and `project.yml` files tracked.
