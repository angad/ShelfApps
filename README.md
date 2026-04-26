# iPhone App Workspace

This workspace contains small UIKit apps designed around the iPhone 6 form factor and iOS 12 compatibility, while still fitting the normal Xcode developer lifecycle for physical iPhones.

## Released Apps

Only these app folders are intended for the public release:

| App | Preview | Description |
| --- | --- | --- |
| [OverheadFlight](apps/OverheadFlight) | <img src="apps/OverheadFlight/screenshots/IMG_0391.PNG" alt="OverheadFlight nearby aircraft screen" width="180"> | Nearby aircraft display with route metadata and a map. |
| [NetworkWall](apps/NetworkWall) | <img src="apps/NetworkWall/screenshots/IMG_0395.PNG" alt="NetworkWall local network dashboard" width="260"> | Local network status wall with lightweight companion-script support. |
| [DriveDash](apps/DriveDash) | <img src="apps/DriveDash/screenshots/IMG_0394.PNG" alt="DriveDash driving dashboard" width="260"> | Driving dashboard using GPS, compass, battery, and motion sensors. |
| [Bookshelf](apps/Bookshelf) | <img src="apps/Bookshelf/screenshots/IMG_0400.PNG" alt="Bookshelf personal library screen" width="180"> | Personal library browser with book details, ISBN scanner, and loan tracking. |
| [CityCams](apps/CityCams) | <img src="apps/CityCams/screenshots/IMG_0405.PNG" alt="CityCams public camera browser" width="180"> | City traffic and public camera browser. |
| [ParkCams](apps/ParkCams) | <img src="apps/ParkCams/screenshots/IMG_0401.PNG" alt="ParkCams national park camera browser" width="180"> | National park camera browser. |

Other app folders are local experiments and are ignored for release.

## Layout

- `apps/<AppName>/`: app-specific source, `project.yml`, README files, assets, generated Xcode projects, build folders, and packaged output.
- `scripts/`: shared build, install, diagnostics, and companion data scripts.
- `skills/`: reusable Codex instructions and references for future app work.

Each app owns its own XcodeGen configuration at `apps/<AppName>/project.yml`. There is intentionally no root `project.yml`.

## Environment

Private values belong in `.env`, which is ignored. Start from the template:

```sh
cp .env.example .env
```

Set `IPHONE_UDID` in `.env` if you use the USB installer and have more than one device connected. Do not commit `.env`.

## Build With Xcode

Generate a project for the app you want to work on:

```sh
cd apps/OverheadFlight
xcodegen generate
open OverheadFlight.xcodeproj
```

In Xcode, select your development team, adjust the bundle identifier if needed, pick a connected iPhone, and use the normal Run flow. The apps target iOS 12.0 for broad compatibility.

## Optional USB Install

For local unsigned iOS 12 device workflows, the shared installer remains available:

```sh
scripts/install_usb_unsigned_ios12.sh apps/OverheadFlight
scripts/install_usb_unsigned_ios12.sh apps/DriveDash
```

The installer reads app metadata from the selected app's `project.yml`, generates the Xcode project, builds with signing disabled, patches the Mach-O build version for iOS 12 compatibility, signs with `ldid`, packages an IPA, installs with `ideviceinstaller`, and verifies the bundle id.

## Development Guidance

Build for the physical iPhone 6 screen first, not a desktop-sized idea of the app. Keep each first version small, native, and diagnosable:

- Use Objective-C UIKit and iOS 12 APIs unless there is a strong reason not to.
- Prefer programmatic views and explicit layout constraints.
- Include a `Default-667h@2x.png` launch image with matching `UILaunchImageFile`/`UILaunchImages` entries. Missing launch assets make iOS 12 letterbox the app on the iPhone 6.
- Keep each screen focused; add tabs or scrollable detail views instead of dense dashboard panels.
- Put long lists inside `UIScrollView` or table-style views with stable row heights.
- Use wrapper `UIView`s for panel backgrounds, borders, and rounded corners rather than relying on `UIStackView` drawing behavior.
- Keep generated icons, launch images, and source artwork inside the app folder.
- Show runtime status and errors in the app because physical-device debugging on older iOS versions can be less reliable with modern Xcode.
- For data-heavy apps, keep the phone UI simple and push richer collection into optional root-level scripts or local JSON endpoints.

## App Icons

Apps that avoid asset catalogs should include the PNG icon sizes referenced by `Info.plist`:

- `AppIcon20x20@2x.png`, `AppIcon20x20@3x.png`
- `AppIcon29x29@2x.png`, `AppIcon29x29@3x.png`
- `AppIcon40x40@2x.png`, `AppIcon40x40@3x.png`
- `AppIcon60x60@2x.png`, `AppIcon60x60@3x.png`

Keep the full-size source image under the app folder, for example `apps/<AppName>/IconSource/`. Do not bake rounded corners into icon PNGs.

## Launch Screen

Every app should include an app-local launch asset so iOS 12 treats it as native to the 4.7-inch iPhone 6 display. The preferred setup in this workspace is:

- `apps/<AppName>/<AppName>/Default-667h@2x.png`, sized `750x1334`
- `Info.plist` key `UILaunchImageFile` with value `Default`
- `Info.plist` `UILaunchImages` entry for `{375, 667}` portrait using `Default-667h`

Launch storyboards are acceptable when `ibtool` compiles them in the current Xcode setup, but static launch images are the safer default for these iOS 12 builds.

## License And Attributions

This repository's original source code is released under the MIT License. See `LICENSE`.

External APIs, camera feeds, flags, book metadata, aircraft data, park data, photos, and trademarks remain subject to their own terms. See `ATTRIBUTIONS.md` before distributing public builds or operating hosted services based on these apps.
