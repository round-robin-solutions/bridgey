# Phone files: thumbnails that always load, previews that never crash

Status: built on `rr/phone-files-flawless` (2026-10-28) and tested live on the personal Mac against the
Android 16 emulator with a 2,045-item library. Not yet tested on the OnePlus 11 (see the end).

This page explains why Photos and Videos showed only placeholders and why preview "crashed", what other
products do, the design that replaced the old pipeline, and the live numbers before and after.
[files-browse.md](files-browse.md) describes the feature itself.

## 1. What went wrong

Each cause was reproduced live (a throwaway Mac build talking to the Android app on the emulator) or read
from Rahul's own Mac. References are to the shipped code: beta 6 is `2a3f5e2`, beta 7 is `f2c4732`.

| # | Symptom | Cause | Where |
| --- | --- | --- | --- |
| 1 | Beta 5 and 6: every cell stays a placeholder | The grid's single request was replaced by the next flush before the phone could answer. The replaced request's handler then cleared the new request's bookkeeping and asked for another flush, every turn of the run loop. Live on beta 6: 2,403 cancels and 180 requests in 20 seconds, 0 of 36 visible cells filled after 15 seconds, the app at 100% CPU while idle | beta 6 `PhoneThumbnailScheduler.swift:211-223` (`finished` clears `current`, `requested`, then `scheduleFlush()`); `PhoneFilesController.swift:332` cancels the lane's previous job |
| 2 | Rahul's "crash" at 01:24 on 28 October | No Swift crash: on the work Mac (beta 6) the process sat at 69% CPU for two minutes in that loop (`BridgeyMac_2026-10-28-012310_rb2.cpu_resource.diag`: every sample in `scheduleFlush` → `flush` → `cacheKey` → `PhoneFilesDigest.hex`), then was killed with SIGKILL at 01:24:25, right after ten seconds of typing in Raycast, and relaunched at 01:24:30. No crash report exists; the logs are consistent with a force quit of an app that felt hung | the loop in 1, plus `PhoneFiles.swift:292` (`String(format: "%02x")` per byte of every key, on every flush) |
| 3 | Preview: nothing happens, then it opens much later or never | Space and the eye button downloaded the whole original before showing anything (two minutes for a 196 MB video on beta 7); a second press while it downloaded was dropped without a word; a preview download cut off by a disconnect stayed "waiting to resume" for the rest of the session, which blocked that item | `PhoneFilesWindow.swift:39-43`, `:68-75`; `PhoneFilesModel.swift:435`; `FolderReceiver.swift:479-480` |
| 4 | Beta 7: pressing Play on a video quits the app | A real crash, 100% reproducible: SIGABRT, "failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'". SwiftUI's `VideoPlayer` lives in `_AVKit_SwiftUI`, which needs AVKit loaded; nothing in the app linked AVKit itself (`otool -L`), so creating the view aborted. Reproduced with a ten-line probe too | `PhoneFilesViews.swift:957` |
| 5 | Beta 7: the window freezes during a download | `PhoneMediaGrid.body` regrouped the whole library on every model change, making a new `DateFormatter` for every item. With 2,000 items that is about 100 ms per redraw, and a download publishes progress four times a second: a sample showed the main thread 92% inside `DateFormatter` | `PhoneFilesViews.swift:466`, `PhoneFilesText.swift:101` |
| 6 | Beta 7: 1.5 GB after scrolling through the library | `LazyVGrid` kept every cell it had shown, each holding its image, and the memory cache was an `NSCache` whose 120-megapixel limit (about 480 MB) is only a hint. Live: 48 MB at open, 1,568 MB after one scroll through 2,045 items | `PhoneFilesViews.swift:468`, `PhoneThumbnailCache.swift:45-55` |
| 7 | Beta 7: scrolling throws work away | The grid lane kept one request and replaced it whenever a visible cell needed something it did not carry, cancelling what was about to arrive | `PhoneThumbnailScheduler.swift:195-203`, `PhoneFilesController.swift:332` |
| 8 | Day headers out of order ("9 April", "29 January", "2 October" at the top) | The phone sorts the gallery by date taken (else added); the Mac headed the days by date modified | `PhoneFilesViews.swift:497` |
| 9 | Transparent stickers on black | MediaStore's ready-made thumbnails are JPEGs, which drop alpha | `AndroidThumbnails.kt:48` |
| 10 | One slow item holds back a whole screen | The phone sent thumbnails strictly in the order asked: a 50 MP photo (130 to 155 ms) or a video frame delayed every item behind it | `BrowseServer.kt:401-403` |
| 11 | Risk, not seen live | Quick Look's data source and the drag-out file name were `nonisolated` methods wrapping `MainActor.assumeIsolated`, which traps if AppKit calls them off the main thread; the panel holds its data source without retaining it | `PhoneFilesInteraction.swift:117`, `:184-189` |

Beta 7's two fixes (39e3796, 9cc99f3) were right about the loop and the EXIF thumbnails, but 4 to 11 remained.

## 2. What others do

Sources are in the research notes linked inline; where only community reports exist, it says so.

- **Apple Image Capture** reads the whole catalogue first, then asks for thumbnails per item; only the
  embedded thumbnail or a 160 x 120 one is cached
  ([ICCameraItem.h](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS17.0.sdk/System/Library/Frameworks/ImageCaptureCore.framework/Headers/ICCameraItem.h)).
  Android's MTP stack answers GetThumb with the EXIF thumbnail, or a MINI_KIND JPEG under 200 KiB, and
  none for videos ([MtpDatabase.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/media/java/android/mtp/MtpDatabase.java)).
- **Apple Photos for Mac** draws its grid with Metal from texture atlases and a cancellable thumbnail
  request queue, with a scroll speedometer that changes behaviour for fast scrolls (class dumps of
  PhotosUICore, not documentation). Apple's PhotoKit sample pre-caches half a screen each way and
  recomputes only after a third of a screen of movement
  ([sample](https://developer.apple.com/library/archive/samplecode/UsingPhotosFramework/Listings/Shared_AssetGridViewController_swift.html)).
- **Microsoft Phone Link** shows the 2,000 most recent photos and no videos, "to minimize network
  bandwidth" ([support](https://support.microsoft.com/en-us/topic/troubleshooting-photos-in-the-phone-link-37986f18-faa6-dd03-4277-f9543e90ec6f)).
  **KDE Connect** mounts the phone over SFTP and makes no remote thumbnails by default
  ([thumbnail.cpp](https://github.com/KDE/kio-extras/blob/master/thumbnail/thumbnail.cpp)).
  **LocalSend**, **Quick Share** and **Android Studio's Device Explorer** do not browse galleries with
  thumbnails at all. O+ Connect's thumbnail behaviour is undocumented.
- **Immich** (the closest open design): a small WebP thumbnail, a 1440 px preview, a ThumbHash placeholder;
  the timeline loads month buckets near the viewport and cancels loads that move far away
  ([timeline](https://github.com/immich-app/immich/blob/main/web/src/lib/managers/timeline-manager/internal/intersection-support.svelte.ts)).
- **NSCollectionView vs LazyVGrid.** NSCollectionView reuses about two screens of cells and reports exactly
  what it shows; prefetching exists from macOS 10.13
  ([docs](https://developer.apple.com/documentation/appkit/nscollectionview/prefetchdatasource)). Apple says
  `onAppear` in a lazy container means "added to the hierarchy", not "visible", and may run for prefetched
  views ([WWDC26 321](https://developer.apple.com/videos/play/wwdc2026/321/),
  [DTS](https://developer.apple.com/forums/thread/775204)). Community measurements: an album grid cost
  22 to 27 ms per scroll step in LazyVGrid against 11 to 12 ms in an NSCollectionView with layer tiles
  ([koan](https://github.com/radiosilence/koan/pull/618)), and a macOS LazyVGrid gallery grew to 2.48 GB
  after 1,500 images ([shot](https://github.com/LorcanChinnock/shot/issues/229)), which matches item 6 above.
- **Image pipelines** (Nuke, Kingfisher, SDWebImage): one task per image shared by every requester and
  cancelled only when all of them cancel; priorities that follow the screen; a fixed number of slots;
  decoding off the main thread with ImageIO thumbnails; an exact LRU memory cache sized in bytes, because
  `NSCache`'s limit "is not a strict limit"
  ([Nuke](https://github.com/kean/Nuke/blob/main/Sources/Nuke/Caching/ImageCache.swift),
  [NSCache](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit)).
- **Android.** `ContentResolver.loadThumbnail` returns MediaProvider's cached thumbnail: one square box of
  half the screen's short edge whatever size is asked, a JPEG, and for photos with an EXIF thumbnail that
  thumbnail as it is, with no size check
  ([MediaProvider](https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main/src/com/android/providers/media/MediaProvider.java),
  [ThumbnailUtils](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/media/java/android/media/ThumbnailUtils.java)).
  `ImageDecoder` applies EXIF rotation and `BitmapFactory` does not; JPEG shrinks cheaply during decode only
  by powers of two ([Skia](https://skia.googlesource.com/skia/+/refs/heads/main/src/codec/SkSampledCodec.cpp)).
- **Previews of remote files.** Quick Look needs a local file URL; its panel holds its data source without
  retaining it, and only the controlling responder may change it
  ([QLPreviewPanel.h](https://github.com/alexey-lysiuk/macos-sdk/blob/main/MacOSX26.5.sdk/System/Library/Frameworks/QuickLookUI.framework/Versions/A/Headers/QLPreviewPanel.h)).
  Streaming a remote video needs an `AVAssetResourceLoaderDelegate` on a custom URL scheme
  ([notes](https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html)).

## 3. The design now

**The grid is an NSCollectionView** (`PhoneMediaCollection.swift`), hosted in the SwiftUI window. Square
layer-backed cells (118 to 142 pt), day headers, about two screens of reused cells for any library size.
Selection, Command and Shift clicks, rubber band, arrows, drag to Finder (file promises) and the context
menu are the collection view's own. Day sections are built once per listing change, with cached date
formatters. Screenshots still draw the SwiftUI grid, since ImageRenderer cannot draw AppKit views.

**The scheduler is a small image pipeline** (`PhoneThumbnailScheduler.swift`):

- The grid reports exactly what is on screen (layout attributes in the visible rectangle, in order) and
  what comes next in the scroll direction (two screens ahead, half a screen behind).
- Each item has a state: waiting, on the wire, decoding, loaded, unavailable (the phone has no picture, or
  it does not decode) or failed.
- A screen goes out as one request per thumbnail size (384 or 512 px, at most 64 items), the next screens
  as one more; at most three on the wire, one of the phone's four media slots stays free for the viewer.
- A request is cancelled only when none of its items is wanted any more. A screen that shares nothing with
  the one before (a fast scroll) waits 120 ms to settle, so screens flown past cost nothing.
- The phone serves 60 media requests per 10 seconds; the grid stops at 52 and prefetch at 32, so the
  screen the scroll stops on, and the viewer, always have room.
- A failed request is asked again after 0.5, 2 and 6 seconds, then the cell says "Couldn't load"; a
  thumbnail the phone does not have says "No preview". `busy` pauses for a second without counting as a
  failure; a disconnect pauses until the phone is back. Refresh asks again for everything that failed.
- Memory: decoded images live in a least-recently-used tier with a hard budget (96 MB of thumbnails,
  64 MB of previews), and boxes far from the screen let go of their images; the disk cache (300 MB,
  owner-only, digests as names) keeps the bytes. Checking the disk cache uses an in-memory index, not a
  `stat` per cell on the main thread. Cache keys are hashed once per item and hex-encoded from a table.

**Space opens the viewer at once** (Photos' behaviour): the thumbnail immediately, the 1600 px preview
from the phone as an urgent request that goes ahead of queued thumbnails, arrows to step (a held key shows
thumbnails and asks only for the item it stops on), Space or Escape to go back. Videos play with
`AVPlayerView` after their original downloads, with progress and Cancel; a second Play or Quick Look while it
downloads joins that download. Quick Look of the original stays one keystroke away (Command-Y, the viewer's
button, the menu). An item deleted on the phone says so and leaves the grid; a damaged file says it cannot be
previewed and points to Download; a preview download cut off by a disconnect fails at once, leaves no part
file or journal, and works again after the reconnect. A download whose `folders.offer` never follows
`places.download_started` times out after 20 seconds instead of waiting forever.

**Quick Look** reads a thread-safe snapshot owned by the window (the panel does not retain its data
source), takes control only when it has files to show, and is let go of before the window closes.

**The phone** (`BrowseServer.kt`, `AndroidThumbnails.kt`) makes thumbnails in the order asked but sends
each as soon as it is ready, so one slow item no longer holds back a screen. Pictures that may be
transparent (decided from the first 4 KiB: PNG colour type or `tRNS`, the WebP alpha flag, GIF) are decoded
directly and sent as WebP, which keeps the transparency; everything else keeps MediaProvider's fast cached
path. `media.page` items carry `taken`, the date the gallery is sorted by, so day headers follow the items.

**Protocol.** No new message or key. `taken` is an optional field (older Macs ignore it, older phones leave
it out and the Mac falls back to `modified`), and thumbnails may arrive in any order (askers already matched
them by key). `protocol/messages.json`, [protocol.md](protocol.md) and the contract tables are updated; the
golden vectors do not cover `media.page`, so they are unchanged.

**Not chosen.** A binary thumbnail frame (twice the density per message) and streamed video playback from
byte ranges both need protocol changes; the numbers below did not need them. A ThumbHash placeholder per
item would need a new `media.page` field; the phone's average-colour tint already gives each cell a colour.

## 4. Measured live

Personal Mac (M4), the Android 16 emulator over `adb forward` (a loopback, not Wi-Fi), a library of 2,045
items: 1,000 screenshots (1080 x 2412 and 1440 x 3216), 560 12 MP and 20 50 MP JPEGs (a third rotated by
EXIF), 80 HEIC, 60 transparent PNGs, 250 small JPEGs, 57 videos (H.264 and HEVC 4K, portrait, rotated, one
196 MB), panoramas, a 12,000 px tall screenshot, GIF, WebP, BMP and five damaged files. Each picture shows
its own number, so a wrong thumbnail or rotation is visible. The Mac app was a throwaway build with its own
bundle ID, folder and port; Rahul's Bridgey was not touched.

| Measure | Beta 6 | Beta 7 | This branch |
| --- | --- | --- | --- |
| First screen of thumbnails, cold (empty cache) | 0.24 s for the 4 top cells, then nothing below | 1.40 s for 4 cells | 0.44 s for 30 cells |
| First screen from the disk cache | | | 0.07 s |
| A screen after scrolling | 0 of 36 filled after 15 s | 0.95 s | 0.04 s; a far jump 0.14 to 0.30 s |
| Every screen of a 200-screen scroll filled 1 s after stopping | no | yes | yes; 1,951 items shown, the 5 damaged files show the fallback |
| Requests and cancels while scrolling | 180 and 2,403 in 20 s | 27 and 19 per long scroll | 239 and 0 for the whole library |
| Memory after scrolling the whole library | | 1,568 MB | 237 MB at most |
| CPU with the window open and idle | 100% (the loop) | 1% | 1% |
| Main thread during a 196 MB preview download | | stalls of 250 to 270 ms for 121 s | longest stall 30 to 45 ms, download under 6 s |
| Play a video in the preview | | crash (SIGABRT) | plays (status ready, time advancing) |
| Space on 13 kinds (screenshot, 12 and 50 MP JPEG, HEIC, video, 196 MB video, panorama, 12,000 px PNG, sticker, GIF, 1 px PNG, two damaged JPEGs) | Quick Look after the full download | the same | viewer at once, 1600 px preview in 0.2 to 0.8 s (HEIC slowest), damaged files say so |
| 20 Space presses and 15 held arrows | | | no crash, longest stall 31 to 65 ms, 5 or 6 preview requests in all |
| Quick Look (Command-Y), closing the window under it, a deleted item, a disconnect mid-download, partial photo access | | | all pass; Quick Look's data source was asked 76 times, always on the main thread |

Phone time per item on the emulator, measured one at a time (thumbnail at 512 px / preview at 1600 px):
screenshots 16 to 22 / 72 to 101 ms, 12 MP JPEG 52 to 85 / 123 to 149 ms, 50 MP JPEG 115 to 155 / 283 to
333 ms, HEIC 15 / 562 to 688 ms, video 12 / 158 to 187 ms.

## 5. Testing it again

The Mac tests that guard each item are in `PhoneFilesFlawlessTests`, `PhoneFilesUITests` (scheduler) and
`PhoneThumbnailPipelineTests` (scheduler, real browse client and disk cache against a simulated phone);
Android's in `BrowseServerTest` and `ImageAlphaTest`. The live run used a throwaway Mac build (own bundle ID
`in.roundrobin.bridgey.e2etest`, support folder, log subsystem and port 42468, an auto-pair hook and a
command folder for the test driver) that is made by a script outside the repository and never ships.

## 6. Still to confirm on the OnePlus 11

- Real Wi-Fi (the emulator link is a loopback): first-screen time, and thumbnails while a large file sends.
- OxygenOS's MediaProvider: thumbnail sizes, HEIC and 50 MP camera photos from the OnePlus camera, and
  whether its screenshots (RGBA PNG) now take the direct-decode path and how long that takes.
- A library of 10,000 or more items, and partial photo access chosen through OxygenOS's picker.
- The work Mac: Phone files open for a few minutes should stay near 1% CPU (no `cpu_resource.diag`).
