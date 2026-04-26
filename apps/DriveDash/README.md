# DriveDash

Offline UIKit dashboard for iPhone 6-class devices on iOS 12 and later.

## Screenshot

<p>
  <img src="screenshots/IMG_0394.PNG" alt="DriveDash landscape driving dashboard" width="360">
</p>

## Features

- GPS speed with mph/km/h toggle
- Stationary speed deadband and weak-fix filtering to reduce false GPS speed jumps at stoplights or indoors
- Clock, battery, heading, GPS quality, coordinates, and altitude
- Native iPhone 6 launch images to avoid letterboxed/compatibility-mode layout
- Trip distance, trip time, average speed, and max speed
- CoreMotion g-meter with acceleration, braking, and cornering peaks
- HUD mirror mode for windshield reflection
- Motion calibration for the phone mount
- Local trip summary storage in `NSUserDefaults`

## GPS Satellite Count

iOS 12 CoreLocation does not expose the raw GPS satellite count to apps. DriveDash shows a `SAT` tile, but it reports `N/A` rather than inventing a number. Use the `GPS` accuracy tile and `GPS STRONG` / `GPS OK` / `GPS WEAK` status as the reliable public signal quality indicator.

## GPS Notes

If the status stays on `GPS STARTING`, check that Location Services are enabled and DriveDash has `While Using the App` permission in iOS Settings. The phone also needs a real sky view for an initial fix; inside a house, garage, or dense dashboard mount it may only report weak fixes. When accuracy is weak, DriveDash now holds speed at zero for low-confidence movement instead of showing noisy stationary jumps.

## Build And Install

From the workspace root:

```sh
scripts/install_usb_unsigned_ios12.sh apps/DriveDash
```

The app is pure Objective-C. It does not link Swift runtime libraries.
