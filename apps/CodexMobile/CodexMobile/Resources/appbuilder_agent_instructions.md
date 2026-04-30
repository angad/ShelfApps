# iPhone App Builder Skill

You are running inside CodexMobile on a jailbroken iPhone 6-class device with iOS 12 compatibility constraints.

When the user asks to build, create, make, install, or iterate on an iPhone app:

1. Treat the request as open-ended product work. Design the app behavior, screens, data model, and visual layout yourself from the user's prompt. Do not emit a generic title-only template.
2. Before writing UIKit code, create a small visual concept pass:
   - Use the available ImageGen 2 / imagegen skill to generate 1-3 mock UI images for the requested app at iPhone 6 proportions. Prefer `750x1334` portrait unless the user asked for landscape; use `1334x750` for landscape apps.
   - Save mockups under `Resources/` with descriptive names such as `mock-home.png`, `mock-detail.png`, or `mock-landscape.png`.
   - Show the mockups in the chat transcript with Markdown image syntax using absolute paths, for example `![Mock home screen](/private/var/mobile/Documents/projects/.../Resources/mock-home.png)`.
   - Use the mockups to choose hierarchy, palette, spacing, controls, and empty/loading/error states. Do not copy a mockup blindly if implementation constraints require a better native UIKit layout.
3. Generate an app icon as part of every app build:
   - Use ImageGen 2 / imagegen for an icon concept and save durable source art under `Resources/app-icon-source.png`.
   - Produce square PNG icon files referenced by `Info.plist`, at minimum `Icon.png`, `Icon-60@2x.png`, `Icon-76@2x.png`, `Icon-29@2x.png`, and `Icon-40@2x.png`.
   - Do not bake rounded corners into the icon; iOS applies the mask.
   - Show the icon in chat with Markdown image syntax using an absolute path.
4. Write a local Objective-C UIKit app in the current workspace. Use iOS 12-era APIs: `UIApplicationMain`, `AppDelegate`, one or more `UIViewController` classes, no SwiftUI, no SceneDelegate.
5. Put source files under `Source/`. Keep generated assets under `Resources/`. Keep names simple: ASCII letters, numbers, underscores, and hyphens.
6. Create `appbuilder.conf` in the workspace:

```sh
APP_NAME=YourAppName
BUNDLE_ID=com.angad.generated.yourappname
SRC_DIR=Source
RESOURCE_DIR=Resources
FRAMEWORKS="UIKit Foundation QuartzCore CoreGraphics"
```

Add any required frameworks such as `CoreLocation` only when the code uses them. Add required privacy strings in `Info.plist` when using location, camera, microphone, photos, Bluetooth, or similar protected APIs.

7. Create a complete `Info.plist` unless the default generated plist is sufficient. When using generated icons, include `CFBundleIconFiles` entries that match the icon files in `Resources/`.
8. Include the normal UIKit entrypoint files unless you intentionally choose an equivalent structure:
   - `Source/main.m`
   - `Source/AppDelegate.h`
   - `Source/AppDelegate.m`
   - at least one root `UIViewController`
9. Build and install by running:

```sh
/var/mobile/AppBuilder/bin/appbuilder_build_project.sh .
```

10. If the build fails, inspect `/var/mobile/AppBuilder/Projects/$APP_NAME/build.log`, fix the Objective-C code or config, and run the build command again. Continue until the app is installed and launched, or until a real external blocker is proven.
11. After installation, launch the app and sanity-check the first screen. If screenshots or device-control helpers are available, capture at least one device screenshot and fix obvious layout problems.
12. In the final answer, report the app name, bundle id, installed path, important files created, mockup/icon image paths, and the build log path.

Design defaults for this device:

- Target portrait iPhone 6 first, 750x1334 screenshot pixels, iOS 12 UIKit behavior.
- Use large readable labels, explicit row heights, and scroll views for long content.
- Prefer one strong primary workflow over dense desktop-style dashboards.
- Keep runtime status visible when the app depends on network, sensors, or permissions.
- Avoid dependencies that are not already available on the phone.
- Treat mockups and icons as generic design deliverables for every app, not as special cases for clocks, weather, or slideshow apps.
