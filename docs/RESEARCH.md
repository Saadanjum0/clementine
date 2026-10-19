# Tangerine, studied

What the app is, how it behaves, what it must be built on, and what this replica
copies. Everything here comes from public sources: the website, the press kit, the
App Store listing and the demo videos. Tangerine's binary was not opened.

## 1. Identity

| | |
|---|---|
| Name | Tangerine: File Converter ("the zero-click offline file converter for Mac") |
| Developer | LEAP STUDIO (Thameem, @th2049) |
| Price | $29.99 one-time (Mac App Store, free to try; 50 % launch discount at times) |
| Requirements | macOS 13.0+, **Apple silicon only** ("Mac with Apple M1 chip or later") |
| Size | ≈ 97.6 MB |
| Versions | 1.4 (public launch 2026-09-07) → 2.0 (Actions wheel, Office formats, % compression) → 2.0.1 (current) |
| Bundle id | not published; App Store id 6813034065 |

Sources: [tangerineformac.com](https://tangerineformac.com/), [press kit](https://tangerineformac.com/press),
[App Store](https://apps.apple.com/us/app/tangerine-file-converter/id6813034065?mt=12),
[Product Hunt](https://www.producthunt.com/products/tangerine-zero-click-file-converter),
developer posts on X ([launch](https://x.com/th2049/status/2097015553508725184), [App Store](https://x.com/th2049/status/2105662442789581202)).

Why it does not run on an Intel Mac: the developer ships an arm64-only binary. There is
no technical reason in the feature set that needs Apple silicon; every engine it can
be using (below) has x86_64 builds. A universal build of the same idea is exactly what
this repository is.

## 2. Behaviour, as the user sees it

**The gesture.** Start dragging a file in Finder. Hold a modifier. A radial wheel
appears under the cursor with the file in the hub and choices around the rim. Drop the
file on a choice. The result is written *next to the original*; the original is left
alone. Release without dropping on the wheel and nothing happens.

| Modifier | Wheel | Contents |
|---|---|---|
| Shift | Convert | every format this file can become ("249 conversion options") |
| Command — App Store text says Option+Shift (older) | Tools | "26 file tools": compress, crop, trim, split, merge, metadata view/edit/remove, … filtered to the file's kind |
| Control | Actions (v2.0) | AirDrop, Float, Copy, Move, Copy Path, Terminal ("6 file actions") |

Other observed facts:

- Batches: several files dragged together are converted to one format in one drop.
- Keyboard: Enter / arrow keys pick a sector, Escape cancels (site playground).
- A progress panel appears after the drop; the demo video shows MOV → MP4 with a progress readout.
- "Float" (2.0) parks a file in a floating tile for drag-and-drop into other apps later.
- % compression (2.0): compress a file or a batch to a percentage of its size.
- Crop (video/image) and Trim (audio/video) open an editor with aspect ratio, dimensions, Apply.
- Everything is local; "files are never uploaded".
- Reviews: wants presets; the Option wheel is "dense on first use"; PDF → EPUB missing at the time.

## 3. Format table (site, v2.0.1)

| Category | Output | Input only |
|---|---|---|
| Images | JPG PNG WebP HEIC TIFF AVIF, + PDF export | SVG BMP |
| Audio | MP3 M4A WAV FLAC OGG Opus AIFF | WMA |
| Video | MP4 MOV MKV WebM GIF, + MP3 export | AVI WMV |
| Documents | PDF → DOCX Pages PPTX XLSX JPG PNG EPUB TXT MD; DOCX Pages MD TXT EPUB | |
| Spreadsheets | XLSX ODS CSV TSV | XLS |
| Slides | PPT PPTX | |
| Archives | ZIP TAR GZIP | RAR |
| Subtitles | SRT VTT | |

The App Store copy lists RAR as fully supported; the site says input only. The site is
newer and matches reality: there is no licensable RAR encoder.

## 4. What it must be built on (inference)

No engine names are published. The evidence:

| Observation | Inference |
|---|---|
| 97.6 MB download for a menu-bar app | Several bundled command-line engines. An AppKit app alone is < 5 MB. A static ffmpeg is 40–80 MB. |
| MKV, WebM, Opus, OGG, FLAC, MP3 *encode*, AVI/WMV decode | Not in AVFoundation. **ffmpeg** (or libav) is certain. |
| WebP and AVIF *encode* | ImageIO decodes both but encodes neither. ffmpeg (libwebp, libaom/SVT-AV1) or libvips. |
| HEIC, TIFF, JPG, PNG | ImageIO, built in. |
| PDF merge / split / reorganize / compress / metadata | PDFKit + Quartz filters, built in. |
| MD, EPUB, DOCX ↔ each other | **pandoc** or a Swift markdown/EPUB library; EPUB strongly suggests pandoc. |
| XLSX, ODS, PPTX, XLS, PDF → DOCX/PPTX/XLSX | Only **LibreOffice** does these offline. Bundling it would be 400 MB+, so either a trimmed converter or something smaller; this remains the least certain part. |
| Pages export | Only Pages.app (AppleScript / `osascript`) can write .pages. |
| RAR extract, ZIP/TAR/GZIP | libarchive / `bsdtar`, built in. |
| Metadata read / edit | ImageIO + AVFoundation metadata APIs, or exiftool. |
| The gesture works from Finder with no Accessibility prompt | `NSEvent.addGlobalMonitorForEvents` on mouse events (no permission needed for mouse, unlike keyboard) + reading the system drag pasteboard (`NSPasteboard(name: .drag)`), which any app may read. The wheel is a non-activating floating `NSPanel` registered for `.fileURL` drops. |
| Menu-bar only, no Dock icon | `LSUIElement = true`. |

To turn inference into evidence, see section 6.

## 5. What this replica does

Same gesture, same three modifiers, same wheel-per-kind filtering, same
sibling-file output, same batch rule. Tangerine's tool list (reconstructed from the
App Store copy, the press kit captions, the Product Hunt page and a third-party
reimplementation of the 25-tool-era list) is covered one for one: compress, shrink to
%, fit to an exact size, metadata view/edit/remove, crop, trim, rotate & flip, edit photo
(adjust), add background, redact, resize, create PDF, collage, join, split, speed, frames,
mute, extract audio, normalize, channels, bleep, visualizer, merge, reorder pages, read
QR, plus Read Text (OCR), Searchable PDF and Annotate. Measured: 262 conversion paths and 34
distinct tools against Tangerine's 249 and 26. The wheel follows Tangerine's proportions
(measured from the press screenshots) in Liquid Glass on macOS 26.

Beyond Tangerine, the Option-drag wheel opens the dropped file in a new chat in the Claude
desktop app (Ask, Summarize, Translate, New Chat; no API key, Claude asks before uploading).
Also added: clipboard as input, type-to-pick and digit keys on the wheel, a global shortcut
for the Finder selection, a Homebrew-free static engine installer.

| Layer | File | Engine |
|---|---|---|
| Format graph | `Formats.swift` | – |
| Routing | `Convert.swift` | ImageIO · ffmpeg · PDFKit · Core Text · textutil · pandoc · LibreOffice · Pages.app (osascript) · bsdtar |
| Tools / actions | `Tools.swift`, `Actions.swift`, `Editors.swift` | same + Vision (OCR, QR, faces/text) + Core Image |
| Claude wheel | `Claude.swift` | hands the files to Claude.app (Launch Services) |
| Gesture | `DragMonitor.swift` | global mouse monitor + drag pasteboard |
| Wheel | `WheelPanel.swift` | non-activating `NSPanel`, custom `NSView` drop target |
| Engines | `Engine.swift`, `EngineInstaller.swift` | bundled → Application Support → Homebrew prefixes → PATH, with a Mach-O slice check |
| Tests | `SelfTest.swift`, `UITest.swift` | `--selftest` (155 checks on macOS) and `--uitest` (50, through the real event handlers) |

Verified on an Intel MacBook (macOS 26).

## 6. Open-source neighbours (read, not copied)

- [rirachii/converty](https://github.com/rirachii/converty) — GPL-3, SwiftUI/AppKit, its `docs/reference-research.md` has a frame-by-frame reading of Tangerine's demo video.
- [ishanmalu/daisy](https://github.com/ishanmalu/daisy) — PolyForm Noncommercial, SwiftPM-only build like this one, bundles nine engines.
- [jherobred/KiwiConvert](https://github.com/jherobred/KiwiConvert), [CristianO2601/tangerine-windows](https://github.com/CristianO2601/tangerine-windows) — Windows ports of the gesture.

Clementine's code is original and MIT; it shares AppKit techniques with these, not code.
