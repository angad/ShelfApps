#!/bin/sh
set -eu

APP_NAME="${1:-PhoneBuilt}"
BUNDLE_ID="${2:-com.angad.phonebuilt}"
ROOT="/var/mobile/AppBuilder/Projects/$APP_NAME"
SRC="$ROOT/Source"
BUILD="$ROOT/Build"
APP="$BUILD/$APP_NAME.app"
SDK="${APPBUILDER_SDK:-/var/mobile/sdks/iPhoneOS12.4.sdk}"
if [ ! -d "$SDK" ]; then
  SDK="/var/mobile/sdks/iPhoneOS.sdk"
fi
LOG="$ROOT/build.log"

rm -rf "$ROOT"
mkdir -p "$SRC" "$BUILD"
exec > "$LOG" 2>&1

printf "[builder] project=%s bundle=%s\n" "$APP_NAME" "$BUNDLE_ID"
printf "[builder] sdk=%s\n" "$SDK"

cat > "$SRC/main.m" <<'EOF'
#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
EOF

cat > "$SRC/AppDelegate.h" <<'EOF'
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
EOF

cat > "$SRC/AppDelegate.m" <<'EOF'
#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[RootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
EOF

cat > "$SRC/RootViewController.h" <<'EOF'
#import <UIKit/UIKit.h>

@interface RootViewController : UIViewController
@end
EOF

cat > "$SRC/RootViewController.m" <<EOF
#import "RootViewController.h"

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"$APP_NAME";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    [self.view addSubview:title];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.text = @"Built and installed from a CodexMobile message on this iPhone.";
    body.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    body.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    [self.view addSubview:body];

    UIView *badge = [[UIView alloc] initWithFrame:CGRectZero];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [UIColor colorWithRed:0.13 green:0.43 blue:0.35 alpha:1.0];
    badge.layer.cornerRadius = 6.0;
    [self.view addSubview:badge];

    UILabel *badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    badgeLabel.text = @"ON-DEVICE BUILD OK";
    badgeLabel.textColor = [UIColor whiteColor];
    badgeLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    badgeLabel.textAlignment = NSTextAlignmentCenter;
    [badge addSubview:badgeLabel];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:28.0],
        [title.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-28.0],
        [title.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor constant:-80.0],
        [body.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:36.0],
        [body.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-36.0],
        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18.0],
        [badge.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [badge.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:28.0],
        [badge.widthAnchor constraintEqualToConstant:220.0],
        [badge.heightAnchor constraintEqualToConstant:44.0],
        [badgeLabel.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor constant:12.0],
        [badgeLabel.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:-12.0],
        [badgeLabel.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor]
    ]];
}

@end
EOF

cat > "$SRC/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFiles</key>
  <array>
    <string>Icon.png</string>
    <string>Icon-29@2x.png</string>
    <string>Icon-40@2x.png</string>
    <string>Icon-60@2x.png</string>
    <string>Icon-76@2x.png</string>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>MinimumOSVersion</key>
  <string>12.0</string>
  <key>UIDeviceFamily</key>
  <array>
    <integer>1</integer>
  </array>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
  </array>
</dict>
</plist>
EOF

printf "[builder] compiling objects\n"
cd "$SRC"
clang -arch arm64 -miphoneos-version-min=12.0 -isysroot "$SDK" -fobjc-arc -c main.m AppDelegate.m RootViewController.m

printf "[builder] linking\n"
clang -arch arm64 -miphoneos-version-min=12.0 \
  -isysroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" \
  main.o AppDelegate.o RootViewController.o \
  -o "$BUILD/$APP_NAME" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics

printf "[builder] packaging %s\n" "$APP"
mkdir -p "$APP"
cp "$BUILD/$APP_NAME" "$APP/$APP_NAME"
cp "$SRC/Info.plist" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
chmod 755 "$APP/$APP_NAME"
ldid -Hsha1 -Hsha256 -P -Cadhoc -I"$BUNDLE_ID" -S "$APP/$APP_NAME"

INSTALL_HELPER="/var/mobile/AppBuilder/bin/appbuilder_install_helper"
if [ -x "$INSTALL_HELPER" ]; then
  "$INSTALL_HELPER" "$APP" "$APP_NAME" "$BUNDLE_ID"
else
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  uicache -p "/Applications/$APP_NAME.app" || uicache
  uiopen "$BUNDLE_ID" || true
fi

printf "[builder] done app=%s log=%s\n" "/Applications/$APP_NAME.app" "$LOG"
