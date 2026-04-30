# CodexMobile

CodexMobile is a native Objective-C/UIKit iOS 12 app for an owned jailbroken/rooted iPhone 6-class device. It runs a local Codex-driven app-builder workflow on the phone so prompts can create Objective-C/UIKit apps, build them with the on-device AppBuilder toolchain, and install them locally.

This app is developer tooling, not one of the public shelf-display apps. The source is safe to publish, but the local binaries and device artifacts used to run it should stay private.

## Local-Only Requirements

CodexMobile expects local files that are intentionally not committed:

- `CodexMobile/Resources/codex`: a user-supplied, cross-compiled Codex executable for the target device.
- `CodexMobile/Resources/codex_probe`: an optional helper binary built from `Helpers/codex_probe.c`.
- `entitlements.plist`: local jailbreak/rooted-device entitlements for private builds, if your install path needs them.
- device SDKs, `ldid`, install helpers, SSH keys, Codex auth/session state, API keys, and any other credentials.

The XcodeGen project marks the Codex and probe binaries as optional resources so the project can be generated from a clean source checkout. A fully working device build still needs the local binaries supplied before installing to the phone.

## Current Surfaces

- Chat: streams Codex output as assistant text, thinking/activity, command cards, and changed-file cards.
- App Library: remembers apps created under the on-device AppBuilder projects directory.
- AppBuilder Skill: writes Objective-C/UIKit source, asks for ImageGen/imagegen mockups and icon concepts, builds with the local AppBuilder script, and installs the generated app.
- Device Status: shows CPU, memory, and disk indicators tuned for the small iPhone 6 screen.

## Open-Source Hygiene

Keep these files out of commits:

- `build/`, `Payload/`, `*.ipa`, `*.app`, `*.xcodeproj/`, `.dSYM/`, module caches, and other generated build output.
- `CodexMobile/Resources/codex` and `CodexMobile/Resources/codex_probe`.
- `diagnostics/`, `diagnostics-spawn.log`, crash reports, syslogs, and raw device screenshots unless they are intentionally curated and scrubbed.
- `.env`, API keys, bearer tokens, Codex auth caches, device identifiers, SSH keys, jailbreak passwords, and local install credentials.

It is fine to say this workflow uses a rooted or jailbroken iPhone 6 that you own. Do not present the project as a way to bypass iCloud, Activation Lock, DRM, App Store policy on third-party devices, or access controls on devices you do not own/control.

Before staging a public commit from the workspace root, run:

```sh
scripts/check_open_source_hygiene.sh
```

## Remaining Work

- Add approval UI for command and patch permission requests.
- Add file read/write editors, not only directory listing.
- Add a more formal local-binary provisioning script for `Resources/codex` and `Resources/codex_probe`.
