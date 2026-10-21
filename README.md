# Tidio

Tidio is a photo and video compression app for macOS and iOS. It can compress items in the Apple Photos library on both platforms; on macOS it can also compress media files from a folder. Images are encoded as HEIC. Videos use HEVC when available, with compatibility fallbacks.

## Features

- Browse the Photos library by album and select items to process.
- Compress photos and videos in batches, with progress and a per-item result summary.
- Choose quality profiles and an optional maximum output resolution; skip items already in HEIC or HEVC.
- Scan selected Photos library items for exact duplicates using SHA-256. Review each group, choose which item to keep, and add the other copies to a configurable Photos album. Tidio does not delete duplicates.
- On macOS, recursively scan a selected folder and save compressed results in its `Compressed` subfolder. Existing files are not overwritten; a numbered suffix is added when needed.
- Keep compressed library items and originals organized in separate configurable Photos albums. Compression creates new items and leaves the source items in place.

Folder compression supports JPG/JPEG, PNG, TIFF/TIF, BMP, and GIF images, plus MOV, MP4, M4V, and AVI videos. HEIC and HEIF files are not included in folder compression.

## Requirements

- macOS 13 or later to build and run the macOS app.
- Xcode 15 or later with the iOS 16 SDK to build the iOS app.
- XcodeGen to generate the Xcode project from `project.yml`.

## Build and Run

From the `Tidio` directory:

```sh
xcodegen generate
open Tidio.xcodeproj
```

In Xcode, select the `Tidio` scheme, choose a macOS or iOS simulator/device destination, then build and run. For iOS on a physical device, configure signing in Xcode.

The Xcode project is generated and excluded from version control. If you change `project.yml`, run `xcodegen generate` again.

## Using Tidio

1. Launch the app and grant Photos library access when prompted. You can also use **Check for Library Access** from the app menu on macOS.
2. Select an album or the full library, then select the photos and videos to process.
3. Start compression, review the chosen settings, and run the job. Results are added to the configured compressed album; source items are also organized in the originals album.
4. To find duplicates, select the scope to scan and choose **Scan for Duplicates**. Review each exact-match group, choose the copy to keep, and send the remaining copies to the duplicates album.
5. On macOS, choose a folder from the sidebar to compress supported media files. Results go into a `Compressed` folder inside the selected folder.

Compression settings include photo and video quality profiles, output resolution caps, skip rules for items already in target formats, and names for the Photos albums used by the app. Settings persist between launches.

## Tech Stack

- Swift 6 and SwiftUI
- Photos and PhotoKit
- ImageIO and Core Image for image processing
- AVFoundation for video export
- CryptoKit for exact duplicate detection