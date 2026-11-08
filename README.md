# omnigisto_pkg

<img src="omnigisto.svg" width="200" alt="OmniGisto logo">

[![Pub Version](https://img.shields.io/pub/v/omnigisto_pkg.svg)](https://pub.dev/packages/omnigisto_pkg)
[![Pub Likes](https://img.shields.io/pub/likes/omnigisto_pkg.svg)](https://pub.dev/packages/omnigisto_pkg)
[![License](https://img.shields.io/badge/License-BSD_3--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![Platform: Pure Dart](https://img.shields.io/badge/Platform-Pure%20Dart%20(No%20Flutter)-orange.svg)](https://dart.dev)

[![Ecosystem: omni_wsi_anotations](https://img.shields.io/badge/Ecosystem-omni_wsi_anotations-purple.svg)](https://pub.dev/packages/omni_wsi_anotations)

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Donate-yellow.svg?logo=buy-me-a-coffee)](https://www.buymeacoffee.com/omnigisto)


A lightweight, fast, and memory-efficient Dart & Flutter library for reading Aperio SVS, Hamamatsu NDPI/VMS/VMU, and DICOM Whole Slide Image (WSI) files, as well as communicating with DICOM PACS servers (C-ECHO, C-FIND, C-MOVE, C-GET, C-STORE). It enables positional metadata parsing, pyramid resolution level inspection, on-demand tile extraction, and associated image retrieval (thumbnail, label, macro) without loading multi-gigabyte files into RAM.

---

## Features

- **Memory-Efficient & Fast**: Uses `RandomAccessFile` and `ByteData` to stream and read TIFF/SVS headers and tile offsets positionally without loading the entire multi-gigabyte image into memory.
- **BigTIFF Support**: Full support for BigTIFF (Magic 43 / 64-bit offsets, `LONG8`, `IFD8`), enabling seamless reading of massive slide files (> 4 GB, up to tens of gigabytes).
- **Extensive Compression Support**: Decodes JPEG (with JPEGTables & Adobe APP14 color handling), JPEG 2000 (Aperio compression tags 33003, 33005, 34712), LZW (with horizontal predictor), Deflate, and uncompressed RGB/Grayscale.
- **Color & Display Support**: Full support for Aperio `DisplayColor` tinting/remapping, embedded ICC profile extraction and attachment, TIFF PhotometricInterpretation (`WhiteIsZero`, Palette/ColorMap), and color space conversions.
- **Full Pyramid Inspection**: Retrieve dimensions, tile configurations, compression formats, and resolution levels for the whole slide pyramid.
- **On-Demand Tile Extraction**: Extract specific image tiles by level and tile grid coordinates (`tileX`, `tileY`) in different formats.
- **Associated Images**: Extract non-tiled associated images such as `thumbnail`, `label` (slide barcode/label), and `macro` (full slide preview) in different formats.
- **Aperio Metadata Parser**: Automatically parses Aperio header properties, compression quality (`Q`), microns-per-pixel (`MPP`), `DisplayColor`, scan dimensions, and custom key-value pairs.
- **Hamamatsu Support**: Reads NDPI extended 64-bit offsets, VMS JPEG mosaics, and VMU/NGR 12-bit RGB data through the same API and result classes; no native OpenSlide dependency is required.
- **Virtual Tiling & Region Decoding**: Automatically aggregates 8-pixel micro-tiles in Hamamatsu NDPI into standard tiles (e.g., 256x256 or 512x512) for smooth, lag-free UI rendering. Provides OpenSlide-compatible arbitrary rectangular region decoding (`readRegion(x, y, w, h)`).
- **DICOM WSI Support**: Reads tiled DICOM Whole Slide Images (multi-frame, concatenated instances, JPEG baseline/lossless and JPEG 2000), supporting pyramids, tile extraction, and OpenSlide-compatible region decoding without external C libraries.
- **Complete DICOM PACS Networking**: Native, lightweight pure-Dart implementation of DICOM network services over TCP: Verification (C-ECHO), Query (C-FIND at STUDY level), Retrieval (C-MOVE and C-GET with embedded Storage SCP and disk streaming), and Storage (C-STORE with batching, PDU fragmentation, and annotation encapsulation). All operations provide typed error codes and comprehensive response models.
- **Cross-Platform**: Works across all platforms supported by Dart `dart:io` (Flutter for Android, iOS, macOS, Windows, Linux).

---

## Getting Started

### 1. Add dependency

Add `omnigisto_pkg` to your `pubspec.yaml`:

```yaml
dependencies:
  omnigisto_pkg:
    path: ../omnigisto_pkg # or from pub.dev / git
```

Then run:

```bash
flutter pub get
# or for pure Dart projects:
dart pub get
```

### 2. Import package

```dart
import 'package:omnigisto_pkg/omnigisto_pkg.dart';
```

---

## Usage

### 1. Opening an SVS / BigTIFF File

Open the SVS file handle using `openSvsFile`. Always close the handle when finished (or use a `try`/`finally` block).
You can optionally configure `maxConcurrency` (default: 4) to tune parallel I/O for your storage medium (e.g., `1` for slow mechanical HDDs, `4` to `8` for fast SSD/NVMe).

```dart
import 'package:omnigisto_pkg/omnigisto_pkg.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Calculates the optimal level of parallelism (maxConcurrency)
/// for opening and processing an SVS file based on the available hardware,
/// platform type, and file size.
int _calculateSvsMaxConcurrency({
  int? fileSizeBytes,
  int activeFilesCount = 1,
}) {

  /// Gets the number of logical processor cores.
  final int totalCores = Platform.numberOfProcessors;

  // Leaves 1-2 cores for the UI thread and the Flutter engine
  final int availableCores = math.max(1, totalCores > 4 ? totalCores - 2 : totalCores - 1);

  // Sets safe bounds depending on the platform
  final bool isMobile = Platform.isAndroid || Platform.isIOS;
  final int minConcurrency = 2;
  final int maxPlatformLimit = isMobile ? 4 : 8;

  int concurrency = availableCores;

  // // Adjusts based on the file size (if the size is provided)
  if (fileSizeBytes != null && fileSizeBytes > 0) {
    final double sizeInMb = fileSizeBytes / (1024 * 1024);

    if (sizeInMb < 150) {
      // For small files, 2-3 threads are enough to avoid pool overhead
      concurrency = math.min(concurrency, 3);
    } else if (sizeInMb > 2048 && isMobile) {
      // On mobile devices, limit parallelism for files > 2 GB 
      // to avoid Out Of Memory (OOM / Jetsam) due to heavy buffers
      concurrency = math.min(concurrency, 3);
    } else if (sizeInMb > 1024 && !isMobile) {
      // On desktop, more resources can be utilized for large files
      concurrency = math.min(concurrency, maxPlatformLimit);
    }
  }

  // Accounts for multiple open screens (load sharing)
  if (activeFilesCount > 1) {
    concurrency = (concurrency / (activeFilesCount * 0.75)).ceil();
  }

  // Clamps the final value to the allowed range
  return concurrency.clamp(minConcurrency, maxPlatformLimit);
}

void main() async {
  // Open with default or custom concurrency limit
  try {
    int? fileSizeBytes;
    try {
      final file = File(path);
      if (await file.exists()) {
        fileSizeBytes = await file.length();
      }
    } catch (e) {
      if (kDebugMode) {
        print("Failed to determine the file size: $e");
      }
    }

    final int activeOpenFiles = _svsFiles.where((f) => f != null).length + 1;

    final int concurrency = _calculateSvsMaxConcurrency(
      fileSizeBytes: fileSizeBytes,
      activeFilesCount: activeOpenFiles,
    );

    return openSvsFile(path, maxConcurrency: concurrency);
  } catch (e) {
    if (kDebugMode) {
      print("error opening svs: $e");
    }
    return null;
  }
}
```

---

### 2. Reading Basic Metadata

To quickly read primary image dimensions and parsed Aperio properties (including `MPP` and `DisplayColor`):

```dart
final metadata = await readSvsMetadata(svs);
if (metadata != null) {
  print('Width: ${metadata.width}, Height: ${metadata.height}');
  print('Tile Size: ${metadata.tileWidth}x${metadata.tileHeight}');
  print('Compression: ${metadata.compression}');
  print('Display Color: ${metadata.displayColor?.toRadixString(16)}');
  print('App Properties: ${metadata.properties}');
  print('MPP: ${metadata.properties['MPP']}');
}
```

---

### 3. Reading Full Pyramid Metadata & Levels

To inspect all resolution pyramid layers and associated images:

```dart
final fullMeta = await readFullSvsMetadata(svs);
if (fullMeta != null) {
  print('Pyramid Levels: ${fullMeta.levels.length}');
  for (int i = 0; i < fullMeta.levels.length; i++) {
    final level = fullMeta.levels[i];
    print('Level $i: ${level.width}x${level.height}, Tile: ${level.tileWidth}x${level.tileHeight}, Downsample: ${level.downsample}');
  }

  print('Associated images: ${fullMeta.associations.keys.toList()}');
  fullMeta.associations.forEach((key, info) {
    print('$key: ${info.width}x${info.height}');
  });
}
```

---

### 4. Extracting Associated Images (Thumbnail, Label, Macro)

Extract `img.Image` to display them directly in Flutter UI (automatically applies color scheme and `DisplayColor` tinting by default):

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// Extract thumbnail, label, or macro
final img.Image? thumb = await extractSvsImageAsImage(svs, 'thumbnail');
final img.Image? label = await extractSvsImageAsImage(svs, 'label');
final img.Image? macro = await extractSvsImageAsImage(svs, 'macro');

// Optional color control:
// extractSvsImageAsImage(svs, 'thumbnail', applyColorScheme: true, applyDisplayColor: true, displayColor: 0x00FF00);

// Example Flutter Widget rendering
Widget buildImage(img.Image? pic) {
  if (pic == null) return const Text('Image not available');
  
  final Uint8List tmp = Uint8List.fromList(img.encodeJpg(pic));
  return Image.memory(tmp);
}
```

Extract raw bytes for associated images:
```dart
import 'dart:typed_data';

// Extract thumbnail, label, or macro as raw bytes
final Uint8List? thumbBytes = await extractSvsImage(svs, 'thumbnail');
final Uint8List? labelBytes = await extractSvsImage(svs, 'label');
final Uint8List? macroBytes = await extractSvsImage(svs, 'macro');
```

---

### 5. Extracting Individual Tiles

Extract specific tiles as raw bytes (recommended for production) :
```dart
import 'dart:typed_data';

final fullMeta = await readFullSvsMetadata(svs);
if (fullMeta != null && fullMeta.levels.isNotEmpty) {
  const int levelIndex = 0; // 0 = highest resolution baseline
  final level = fullMeta.levels[levelIndex];

  if (level.tileWidth != null && level.tileHeight != null) {
    int totalCols = (level.width + level.tileWidth! - 1) ~/ level.tileWidth!;
    int totalRows = (level.height + level.tileHeight! - 1) ~/ level.tileHeight!;

    print('Grid size: $totalCols columns x $totalRows rows');

    // Extract raw tile bytes at coordinate (tileX: 0, tileY: 0)
    final Uint8List? tileBytes = await extractSvsTile(svs, levelIndex, 0, 0);
    if (tileBytes != null) {
      print('Extracted tile (${tileBytes.length} bytes)');
    }
  }
}
```

Extract specific tiles on demand as decoded `img.Image` (supports JPEG, JPEG 2000, LZW, Deflate, Raw RGB, with optional `DisplayColor` and color scheme adjustments):

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

final fullMeta = await readFullSvsMetadata(svs);
if (fullMeta != null && fullMeta.levels.isNotEmpty) {
  const int levelIndex = 0; // 0 = highest resolution baseline
  final level = fullMeta.levels[levelIndex];
  
  int totalCols = (level.width + level.tileWidth! - 1) ~/ level.tileWidth!;
  int totalRows = (level.height + level.tileHeight! - 1) ~/ level.tileHeight!;
  
  print('Grid size: $totalCols columns x $totalRows rows');
  
  // Extract tile at coordinate (tileX: 0, tileY: 0)
  final img.Image? tile = await extractSvsTileAsImage(
    svs,
    levelIndex,
    0,
    0,
    applyColorScheme: true,
    applyDisplayColor: true, // applies DisplayColor from slide metadata if present
  );
  if (tile != null) {
    Uint8List tileBytes = Uint8List.fromList(img.encodeJpg(tile));
    // Display or process tile...
  }
}
```

Extract tiles with cancellation support (`CancellationToken`):

```dart
import 'dart:typed_data';
import 'package:omnigisto_pkg/omnigisto_pkg.dart';

final cancelToken = CancellationToken();

// Start extracting a tile with the cancellation token
final Future<Uint8List?> tileFuture = extractSvsTile(
  svs,
  0, // levelIndex
  0, // tileX
  0, // tileY
  cancelToken: cancelToken,
);

// If the user scrolls, zooms away, or disposes the widget:
cancelToken.cancel();

final Uint8List? tileBytes = await tileFuture;
if (tileBytes != null) {
  print('Tile loaded: ${tileBytes.length} bytes');
} else {
  print('Tile loading was cancelled or failed.');
}
```



---

## Hamamatsu NDPI, VMS and VMU

Use the existing functions without renaming or converting the returned data:

```dart
final slide = await openSvsFile('/slides/sample.ndpi');
// Also accepts /slides/sample.vms or /slides/sample.vmu.
if (slide != null) {
  try {
    final SvsMetadata? metadata = await readSvsMetadata(slide);
    final SvsFullMetadata? full = await readFullSvsMetadata(slide);
    final tile = await extractSvsTileAsImage(slide, 0, 0, 0);
    print(metadata);
    print(full);
    print(tile?.width);
  } finally {
    await slide.close();
  }
}
```

`SvsMetadata`, `SvsFullMetadata`, `SvsImageInfo`, their fields and `toString()` formats are unchanged. `levels` remain sorted from largest to smallest, with `downsample` relative to level 0. Properties remain `Map<String, String>`; Hamamatsu adds `Vendor=Hamamatsu`, `Compression`, `AppMag` and `MPP`/`MPP_X`/`MPP_Y` when available. Invalid coordinates, missing associations and cancelled tile requests still return `null`.

- **NDPI**: Detected by its contents, not its extension. Handles eight-byte header/IFD pointers and the NDPI IFD value-extension table, including files larger than 4 GiB. JPEG strips become native restart-interval tiles; unreliable or absent restart tables fall back to incremental marker scanning. Only focal plane 0 is exposed. Positive `SourceLens` values are pyramid levels; `SourceLens=-1` is `macro`. Other auxiliary directories are not exposed.
- **VMS**: Open the INI index and retain its referenced JPEG files and `MapFile` in their relative locations. `ImageFile`, `ImageFile(x,y)`, `ImageFile(z)` and `ImageFile(z,x,y)` are supported for plane 0. The JPEG mosaic is the baseline, the map is a reduced level and `thumbnail`, and optional `MacroImage` is `macro`. File boundaries must align with the native tile grid; incompatible mosaics are rejected rather than resampled. `.opt` is not required or used; missing restart offsets are discovered incrementally.
- **VMU**: Open the INI index together with its NGR `ImageFile`/`MapFile` and optional JPEG `MacroImage`. Supports `BitsPerPixel=36`, `PixelOrder=RGB`, and the `GN` NGR header. The 12-bit RGB samples stored in little-endian 16-bit words are normalized to 8-bit RGB. Tiles use the NGR column width and 64 rows, with the last row cropped; image width must be divisible by column width.

Always use the reported `tileWidth`/`tileHeight`: Hamamatsu JPEG tiles can be wide and only 8 or 16 pixels high. To eliminate UI rendering bottlenecks caused by tiny 8-pixel strips, **Virtual Tiling** automatically aggregates vertical intervals (e.g. 32 or 64 MCU rows, producing 256x256 or 512x512 tiles). You can also configure or toggle virtual tiling via `openSvsFile` options or `enableVirtualTiling(slide)` / `disableVirtualTiling(slide)`:

```dart
// Open with customized virtual tile dimensions
final slide = await openSvsFile(
  '/slides/sample.ndpi',
  virtualTiling: true,
  mcuRowsPerTile: 32, // 32 MCU rows = 256 px high
  virtualTileWidth: 256,
  virtualTileHeight: 256,
);

// Or decode arbitrary rectangular regions (like OpenSlide readRegion):
final img.Image? region = await readRegion(
  slide,
  0, // layerIndex
  100, // x
  200, // y
  512, // width
  512, // height
);
```

`extractSvsTile` returns standalone JPEG bytes for NDPI/VMS (headers adjusted without recompressing entropy), or row-major 8-bit RGB bytes for VMU. `extractSvsTileAsImage` consistently returns `img.Image`. Associated-image functions keep their existing raw/image/JPEG return types; associations not present in the source, such as a separate label, are not fabricated. Explicit `displayColor` overrides and `applyDisplayColor` remain available.

JPEG support covers sequential 8-bit, single-scan images with one or three components. Progressive, arithmetic, multiscan JPEGs and incompatible restart layouts are rejected. A JPEG without restart markers is a single tile and must fit the whole-image limit (16 Mi pixels); full associated-image decoding has the same pixel limit. Large restart-coded levels are read on demand. `maxConcurrency` applies to each underlying file pool; `close()` closes all sidecar sources as well.

Regression fixtures are generated locally, including sparse NDPI offsets above 4 GiB, JPEG restart markers, VMS mosaics and NGR columns. Real-file validation also used the public [CMU-1.ndpi sample](https://openslide.cs.cmu.edu/download/openslide-testdata/Hamamatsu/CMU-1.ndpi); VMU validation uses synthetic fixtures. Format reference: [OpenSlide Hamamatsu documentation](https://openslide.org/formats/hamamatsu/).

Run the self-contained Hamamatsu tests (no downloads required):

```bash
flutter test test/hamamatsu_ndpi_test.dart test/hamamatsu_vms_test.dart test/hamamatsu_jpeg_test.dart test/virtual_tiling_and_region_test.dart
```

The existing SVS integration tests additionally require their original slide fixtures under `example/assets/`; these large files are not included in the package.

---

## DICOM C-ECHO errors

`DicomEchoClient.echo` still returns a `DicomEchoResult`. A successful verification has status `0x0000`, with `error` and `errorCode` equal to `null`. A failure is not a ready-made string: the result carries a machine-readable `DicomEchoErrorCode` and a typed `DicomEchoException`. `message` is display text assembled from that code and an optional detail. `responseTimeMs` is set once a connection attempt has started; validation failures leave it `null`.

Branch on the code, not on the wording of `message`:

```dart
final result = await DicomEchoClient.echo(
  host: host,
  port: port,
  calledAeTitle: calledAe,
  callingAeTitle: callingAe,
);

final failure = result.error; // DicomEchoException?, same code as result.errorCode
if (failure != null) {
  switch (failure.code) {
    case DicomEchoErrorCode.emptyHost:
    case DicomEchoErrorCode.invalidPort:
    case DicomEchoErrorCode.emptyAeTitle:
      // Caller input. Nothing was sent to the node.
      break;
    case DicomEchoErrorCode.timeout:
    case DicomEchoErrorCode.connectionClosed:
    case DicomEchoErrorCode.associationRejected:
      // The node was not reached, or it refused the association.
      // failure.detail holds the reject reason when the server sent one.
      break;
    case DicomEchoErrorCode.unsupportedSopClass:
    case DicomEchoErrorCode.unsupportedTransferSyntax:
    case DicomEchoErrorCode.protocolViolation:
    case DicomEchoErrorCode.associationAborted:
      // The association was negotiated, then verification could not continue.
      break;
    case DicomEchoErrorCode.serverError:
      // C-ECHO status is in failure.statusCode (and result.statusCode).
      break;
    case DicomEchoErrorCode.unknown:
      break;
  }
}
print(result.message); // display only
print(result.responseTimeMs);
```

| `DicomEchoErrorCode` | When it is returned |
| :--- | :--- |
| `emptyHost` | Host is missing or blank. |
| `invalidPort` | Port is outside `1..65535`. |
| `emptyAeTitle` | Called or calling AE Title is missing or blank. |
| `connectionClosed` | The remote node closed the socket while a PDU was still expected. |
| `timeout` | No PDU arrived before the echo timeout, or the TCP connect timed out. |
| `associationRejected` | The node sent `A-ASSOCIATE-RJ`. The reject text is in `error.detail`. |
| `unsupportedSopClass` | Verification SOP Class was not accepted. |
| `unsupportedTransferSyntax` | The accepted context is not Implicit or Explicit VR Little Endian. |
| `associationAborted` | The node sent `A-ABORT` before C-ECHO completed. |
| `protocolViolation` | The node sent a PDU that does not belong in the current exchange, or the C-ECHO response has no status. |
| `serverError` | C-ECHO finished with a status other than Success (`0x0000`). The status is in `error.statusCode`. |
| `unknown` | Any other network or runtime failure. The original text is in `error.detail`. |

`DicomEchoException.message` is the same display string exposed by `DicomEchoResult.message` when `error` is set. Do not construct a `DicomEchoResult` with a `message` argument: that field is no longer part of the constructor.

The `echo` command in `example/bin/dicom_pacs.dart` prints `errorCode.name` before the display message.

---

## DICOM C-FIND errors

A completed search has `error` and `errorCode` equal to `null`, including when no studies match. An `A-ABORT` after some matches still keeps those studies and sets `associationAborted`.

Branch on the code, not on the wording of `message`:

```dart
final result = await DicomFindClient.find(
  host: host,
  port: port,
  calledAeTitle: calledAe,
  callingAeTitle: callingAe,
  query: const DicomFindQuery(patientName: 'Doe*'),
);

final failure = result.error; // DicomFindException?, same code as result.errorCode
if (failure != null) {
  switch (failure.code) {
    case DicomFindErrorCode.emptyHost:
    case DicomFindErrorCode.invalidPort:
    case DicomFindErrorCode.emptyAeTitle:
      // Caller input. Nothing was sent to the node.
      break;
    case DicomFindErrorCode.timeout:
    case DicomFindErrorCode.connectionClosed:
    case DicomFindErrorCode.associationRejected:
      // The node was not reached, or it refused the association.
      // failure.detail holds the reject reason when the server sent one.
      break;
    case DicomFindErrorCode.unsupportedSopClass:
    case DicomFindErrorCode.unsupportedTransferSyntax:
    case DicomFindErrorCode.protocolViolation:
    case DicomFindErrorCode.associationAborted:
      // The association was negotiated, then the exchange could not continue.
      break;
    case DicomFindErrorCode.serverError:
      // C-FIND status is in failure.statusCode (and result.statusCode).
      break;
    case DicomFindErrorCode.unknown:
      break;
  }
}
print(result.message); // display only
```

| `DicomFindErrorCode` | When it is returned |
| :--- | :--- |
| `emptyHost` | Host is missing or blank. |
| `invalidPort` | Port is outside `1..65535`. |
| `emptyAeTitle` | Called or calling AE Title is missing or blank. |
| `connectionClosed` | The remote node closed the socket while a PDU was still expected. |
| `timeout` | No PDU arrived before the find timeout. |
| `associationRejected` | The node sent `A-ASSOCIATE-RJ`. The reject text is in `error.detail`. |
| `unsupportedSopClass` | Neither Study Root nor Patient Root C-FIND was accepted. |
| `unsupportedTransferSyntax` | The accepted context is not Implicit or Explicit VR Little Endian. |
| `associationAborted` | The node sent `A-ABORT` during C-FIND. Studies already received stay on the result. |
| `protocolViolation` | The node sent a PDU that does not belong in the current exchange. |
| `serverError` | C-FIND finished with a status other than Success (`0x0000`) or Cancel (`0xFE00`). The status is in `error.statusCode`. |
| `unknown` | Any other network or runtime failure. The original text is in `error.detail`. |

`DicomFindException.message` is the same display string exposed by `DicomFindResult.message` when `error` is set. Do not construct a `DicomFindResult` with a `message` argument: that field is no longer part of the constructor.

The `find` command in `example/bin/dicom_pacs.dart` prints `errorCode.name` before the display message.

---

## DICOM C-MOVE & C-GET (Retrieve) errors and responses

`DicomRetrieveClient.retrieve` downloads a study by `studyInstanceUid` using either C-MOVE or C-GET:
- **`DicomRetrieveMethod.cGet`**: Retrieves instances over the existing client-server association.
- **`DicomRetrieveMethod.cMove`**: Requests the PACS to send instances to a destination AE title. An embedded DICOM Storage SCP listens on `listenPort` (default `11112`) to receive incoming C-STORE sub-associations from the PACS.

Both methods stream Part 10 `.dcm` files directly to `outputDirectory` without buffering whole slide images in RAM.

### Response Structure (`DicomRetrieveResult`)

`DicomRetrieveClient.retrieve` returns a `DicomRetrieveResult`:
- **`isSuccess`**: `true` when instances were successfully received and written to disk, including partial downloads with warnings (`0xB000`). `false` when no instances could be saved or an unrecoverable failure occurred.
- **`receivedCount`**: Number of DICOM instances saved to disk.
- **`files`**: `List<String>` containing paths to all saved `.dcm` files.
- **`directory`**: The directory path where files were written.
- **`statusCode`**: Final DICOM status code from the server (e.g., `0x0000`, `0xB000`, `0xFE00`).
- **`error`**: Typed `DicomRetrieveException?` (`null` on a completely clean retrieval).
- **`errorCode`**: Machine-readable `DicomRetrieveErrorCode?` (convenience getter for `error?.code`).
- **`message`**: Human-readable display text summarizing the outcome or error.

### Progress Monitoring (`DicomRetrieveProgress`)

The optional `onProgress` callback emits `DicomRetrieveProgress`:
- **`receivedFiles`**: Number of files saved to disk so far.
- **`remaining`**: Remaining sub-operations count (if reported by the server).
- **`completed`**: Completed sub-operations count (if reported by the server).
- **`failed`**: Failed sub-operations count (if reported by the server).
- **`warning`**: Warning sub-operations count (if reported by the server).

### Usage & Error Handling Example

Branch on the machine-readable `errorCode`, not on `message`:

```dart
final result = await DicomRetrieveClient.retrieve(
  host: host,
  port: port,
  calledAeTitle: calledAe,
  callingAeTitle: callingAe,
  studyInstanceUid: studyUid,
  method: DicomRetrieveMethod.cGet, // or DicomRetrieveMethod.cMove
  outputDirectory: '/path/to/downloads',
  listenPort: 11112, // used by cMove for the local Storage SCP listener
  timeout: const Duration(minutes: 5),
  isCancelled: () => userCancelled,
  onProgress: (progress) {
    print('Received: ${progress.receivedFiles}, remaining: ${progress.remaining ?? '-'}');
  },
);

final failure = result.error;
if (failure != null) {
  switch (failure.code) {
    case DicomRetrieveErrorCode.emptyHost:
    case DicomRetrieveErrorCode.invalidPort:
    case DicomRetrieveErrorCode.emptyAeTitle:
    case DicomRetrieveErrorCode.emptyStudyUid:
    case DicomRetrieveErrorCode.invalidListenPort:
      // Pre-flight validation failed. Nothing was sent to the server.
      break;
    case DicomRetrieveErrorCode.outputDirectoryFailed:
      // Output directory could not be created or accessed.
      break;
    case DicomRetrieveErrorCode.listenPortUnavailable:
      // Local C-MOVE listener port could not be bound (e.g. port already in use).
      break;
    case DicomRetrieveErrorCode.storageNotAccepted:
      // The server rejected all C-GET storage presentation contexts.
      break;
    case DicomRetrieveErrorCode.moveDestinationTimeout:
      // PACS did not establish a connection to the C-MOVE listener before timeout.
      break;
    case DicomRetrieveErrorCode.noObjects:
      // Search succeeded but the study contains no transferable objects.
      break;
    case DicomRetrieveErrorCode.cancelled:
      // Retrieval was cancelled by caller (isCancelled) or status 0xFE00.
      break;
    case DicomRetrieveErrorCode.incomplete:
      // Completed with warnings or some sub-operations failed (status 0xB000).
      // Check result.files and result.receivedCount for partial results.
      break;
    case DicomRetrieveErrorCode.associationRejected:
    case DicomRetrieveErrorCode.unsupportedSopClass:
    case DicomRetrieveErrorCode.unsupportedTransferSyntax:
    case DicomRetrieveErrorCode.associationAborted:
    case DicomRetrieveErrorCode.protocolViolation:
    case DicomRetrieveErrorCode.serverError:
    case DicomRetrieveErrorCode.timeout:
    case DicomRetrieveErrorCode.connectionClosed:
    case DicomRetrieveErrorCode.unknown:
      // Check failure.detail and failure.statusCode for diagnostics.
      break;
  }
}

if (result.isSuccess) {
  print('Successfully saved ${result.receivedCount} instances to ${result.directory}');
}
```

### `DicomRetrieveErrorCode` Reference

| `DicomRetrieveErrorCode` | When it is returned |
| :--- | :--- |
| `emptyHost` | Host is missing or blank. |
| `invalidPort` | Port is outside `1..65535`. |
| `emptyAeTitle` | Called or calling AE Title is missing or blank. |
| `emptyStudyUid` | Study Instance UID is missing or blank. |
| `invalidListenPort` | C-MOVE station listen port is outside `1..65535`. |
| `outputDirectoryFailed` | Failed to create or write to the target download directory. |
| `listenPortUnavailable` | C-MOVE station listen port could not be bound (e.g., already in use). |
| `storageNotAccepted` | Remote PACS did not accept C-GET storage presentation contexts. |
| `moveDestinationTimeout` | Remote PACS did not connect to the C-MOVE Storage SCP within timeout. |
| `noObjects` | Operation completed without any DICOM instances received. |
| `cancelled` | Retrieval was cancelled by caller (`isCancelled`) or status `0xFE00`. |
| `associationRejected` | Remote server rejected association (`A-ASSOCIATE-RJ`). Reason in `error.detail`. |
| `unsupportedSopClass` | C-MOVE or C-GET SOP Class (Study Root / Patient Root) was not accepted. |
| `unsupportedTransferSyntax` | Server proposed an unsupported Transfer Syntax. |
| `associationAborted` | Server sent `A-ABORT` during retrieval. |
| `protocolViolation` | Unexpected PDU received or unexpected protocol response. |
| `incomplete` | Retrieval completed with warnings or failed sub-operations (status `0xB000`). Partial files remain available in `result.files`. |
| `serverError` | Server returned a failure status (e.g., `0xA701`, `0xA702`, `0xA900`, `0xC000`..`0xCFFF`). Status code in `error.statusCode`. |
| `timeout` | Timed out waiting for network response or PDU from the DICOM server. |
| `connectionClosed` | Connection closed unexpectedly by remote node. |
| `unknown` | Any other network or runtime exception. Original text in `error.detail`. |

### DICOM Retrieval Status Codes

When `result.statusCode` (or `error.statusCode`) is populated, it corresponds to standard DICOM status codes:
- **`0x0000`** — **Success**: All sub-operations completed successfully.
- **`0xB000`** — **Warning / Sub-operations Complete with Failures**: One or more sub-operations failed, but remaining instances were retrieved.
- **`0xFE00`** — **Cancel**: Sub-operations terminated due to Cancel request.
- **`0xA701` / `0xA702`** — **Out of Resources**: Unable to calculate matches or perform sub-operations.
- **`0xA801`** — **Move Destination Unknown**: PACS does not recognize destination AE title.
- **`0xA900`** — **Identifier Does Not Match SOP Class**: Dataset syntax error.
- **`0xC000`–`0xCFFF`** — **Failed**: Unable to process request.

---

## DICOM C-STORE errors and responses

`DicomStoreClient.store` uploads DICOM instances (Whole Slide Images, secondary captures, annotations, etc.) to a remote PACS / C-STORE SCP:
- Supports files on disk (`DicomStoreInstance.file`) and in-memory byte buffers (`DicomStoreInstance.bytes`).
- Negotiates Presentation Contexts dynamically in batches (up to 100 contexts per association).
- Automatically fragments large datasets across `P-DATA-TF` PDUs matching the server's negotiated maximum PDU size.
- Streams files directly from disk to keep memory consumption low.

### Helper Methods

- **`DicomStoreClient.collectFiles(path)`**: Scans a file or folder recursively, picking valid DICOM files (checking `.dcm`/`.dicom` and `DICM` magic preamble) while ignoring `DICOMDIR` and non-DICOM assets.
- **`DicomStoreClient.readIdentity(path)`**: Reads Study and Patient attributes (`DicomStudyIdentity`) from the first valid DICOM file in a folder or file path.
- **`DicomStoreClient.buildAnnotationDicom(...)`**: Packages annotation XML bytes into a standard DICOM Raw Data Storage SOP class instance linked to the original study and patient identity.

### Response Structure (`DicomStoreResult`)

`DicomStoreClient.store` returns a `DicomStoreResult`:
- **`isSuccess`**: `true` when all instances were stored successfully without errors.
- **`storedCount`**: Number of instances accepted by the server.
- **`totalCount`**: Total number of instances queued for transmission.
- **`statusCode`**: Last DICOM status code received from the server.
- **`error`**: Typed `DicomStoreException?` (`null` on complete success).
- **`errorCode`**: Machine-readable `DicomStoreErrorCode?` (convenience getter for `error?.code`).
- **`message`**: Display text summarizing the result (e.g. `'C-STORE succeeded (stored 5 of 5)'` or failure message).

### Progress Monitoring (`DicomStoreProgress`)

The optional `onProgress` callback provides `DicomStoreProgress`:
- **`completed`**: Number of instances successfully sent so far.
- **`total`**: Total number of instances being sent.
- **`currentName`**: Name or label of the instance currently in transit.

### Usage & Error Handling Example

Branch on the machine-readable `errorCode`, not on `message`:

```dart
// 1. Collect DICOM instances from a slide folder
final instances = await DicomStoreClient.collectFiles('/path/to/slide_folder');

// 2. Perform C-STORE upload
final result = await DicomStoreClient.store(
  host: host,
  port: port,
  calledAeTitle: calledAe,
  callingAeTitle: callingAe,
  instances: instances,
  connectTimeout: const Duration(seconds: 10),
  responseTimeout: const Duration(seconds: 90),
  isCancelled: () => userCancelled,
  onProgress: (progress) {
    print('Uploaded ${progress.completed}/${progress.total}: ${progress.currentName ?? ''}');
  },
);

final failure = result.error;
if (failure != null) {
  switch (failure.code) {
    case DicomStoreErrorCode.emptyHost:
    case DicomStoreErrorCode.invalidPort:
    case DicomStoreErrorCode.emptyAeTitle:
    case DicomStoreErrorCode.emptyInstances:
    case DicomStoreErrorCode.noStudyFiles:
      // Validation failure before connecting.
      break;
    case DicomStoreErrorCode.prepareFailed:
      // Failed to inspect instance files (e.g. invalid DICOM preamble or corrupt data).
      break;
    case DicomStoreErrorCode.cancelled:
      // Upload was cancelled by caller via isCancelled callback.
      break;
    case DicomStoreErrorCode.associationRejected:
      // PACS rejected association (A-ASSOCIATE-RJ). Reason in failure.detail.
      break;
    case DicomStoreErrorCode.unsupportedSopClass:
      // Server rejected the SOP Class of the instances being transferred.
      break;
    case DicomStoreErrorCode.unsupportedTransferSyntax:
      // Server rejected all offered Transfer Syntaxes.
      break;
    case DicomStoreErrorCode.incomplete:
      // Some instances succeeded, but others were rejected or failed.
      // Check result.storedCount and result.totalCount.
      break;
    case DicomStoreErrorCode.associationAborted:
    case DicomStoreErrorCode.protocolViolation:
    case DicomStoreErrorCode.serverError:
    case DicomStoreErrorCode.timeout:
    case DicomStoreErrorCode.connectionClosed:
    case DicomStoreErrorCode.unknown:
      // Network or protocol error. See failure.detail and failure.statusCode.
      break;
  }
}

print(result.message);
print('Stored ${result.storedCount} of ${result.totalCount} instances');
```

### `DicomStoreErrorCode` Reference

| `DicomStoreErrorCode` | When it is returned |
| :--- | :--- |
| `emptyHost` | Host is missing or blank. |
| `invalidPort` | Port is outside `1..65535`. |
| `emptyAeTitle` | Called or calling AE Title is missing or blank. |
| `emptyInstances` | The instance list passed to `store()` is empty. |
| `noStudyFiles` | No valid DICOM files were discovered at the provided directory or file path. |
| `cancelled` | The C-STORE operation was cancelled by caller (`isCancelled`). |
| `prepareFailed` | Unable to read or inspect DICOM instances (e.g. file is not Part 10 DICOM). |
| `associationRejected` | Remote node sent `A-ASSOCIATE-RJ`. Rejection text is in `error.detail`. |
| `unsupportedSopClass` | Server did not accept the SOP Class of the instances. |
| `unsupportedTransferSyntax` | Server rejected all offered Transfer Syntaxes. |
| `associationAborted` | Server sent `A-ABORT` during transmission. |
| `protocolViolation` | Unexpected PDU received, invalid PDU length, or missing status in `C-STORE-RSP`. |
| `incomplete` | Some instances were stored, but others encountered errors. |
| `serverError` | Server returned an error status in `C-STORE-RSP`. Status code is in `error.statusCode`. |
| `timeout` | Connection or response timeout waiting for PDU from the server. |
| `connectionClosed` | Remote server closed connection unexpectedly. |
| `unknown` | Any other network or unexpected runtime exception. Details in `error.detail`. |

### DICOM C-STORE Status Codes

When `result.statusCode` (or `error.statusCode`) is returned:
- **`0x0000`** — **Success**: Instance stored successfully.
- **`0xB000`** — **Coercion of Data Elements**: Warning; instance was stored with modified elements.
- **`0xB006`** — **Elements Discarded**: Warning; non-critical elements discarded.
- **`0xB007`** — **Data Set Does Not Match SOP Class**: Warning; instance stored with warning.
- **`0xA700`–`0xA7FF`** — **Refused**: Out of resources.
- **`0xA900`–`0xA9FF`** — **Error**: Data Set does not match SOP Class.
- **`0xC000`–`0xCFFF`** — **Error**: Cannot understand / processing failure.

---

## DICOM Whole Slide Image (WSI) Reading

Open a single DICOM WSI instance or a folder containing concatenated multi-part instances using `openDicomSlide`:

```dart
final slide = await openDicomSlide('/path/to/dicom_folder');
if (slide != null) {
  try {
    final meta = slide.fullMetadata();
    print('Resolution levels: ${meta.levels.length}');
    for (int i = 0; i < meta.levels.length; i++) {
      final level = meta.levels[i];
      print('Level $i: ${level.width}x${level.height}, Tile: ${level.tileWidth}x${level.tileHeight}');
    }

    // Read a specific tile
    final Uint8List? tileBytes = await slide.readTile(0, 0, 0);

    // Decode an arbitrary region (OpenSlide-compatible readRegion)
    final img.Image? region = await slide.readRegion(0, 100, 200, 512, 512);
  } finally {
    await slide.close();
  }
}
```

---

## API Reference

### Functions

| Function | Description |
| :--- | :--- |
| `Future<SvsFile?> openSvsFile(String path, {int maxConcurrency = 4, bool? virtualTiling, int? virtualTileWidth, int? virtualTileHeight, int? mcuRowsPerTile})` | Opens SVS/TIFF/BigTIFF, Hamamatsu NDPI, or a VMS/VMU index with optional virtual tiling. |
| `Future<DicomSlide?> openDicomSlide(String path, {String? seriesInstanceUid, int maxConcurrency = 4})` | Opens a DICOM WSI instance file or directory of instances with multi-level pyramid support. |
| `Future<SvsMetadata?> readSvsMetadata(SvsFile svs)` | Reads basic metadata of the primary image (including `displayColor`). |
| `Future<SvsFullMetadata?> readFullSvsMetadata(SvsFile svs)` | Reads all pyramid levels and associated image metadata. |
| `Future<img.Image?> readRegion(SvsFile svs, int layerIndex, int x, int y, int width, int height, {bool applyColorScheme = true, bool applyDisplayColor = true, int? displayColor, CancellationToken? cancelToken})` | OpenSlide-compatible arbitrary rectangle region decoding across SVS and Hamamatsu slides. |
| `Future<img.Image?> extractSvsRegionAsImage(SvsFile svs, int layerIndex, int x, int y, int width, int height, ...)` | Alias for `readRegion`. |
| `Future<Uint8List?> extractSvsRegion(SvsFile svs, int layerIndex, int x, int y, int width, int height, ...)` | Extracts a rectangular region as encoded JPEG bytes. |
| `void enableVirtualTiling(SvsFile svs, {int? virtualTileWidth, int? virtualTileHeight, int? mcuRowsPerTile})` | Enables virtual tiling on an open Hamamatsu slide. |
| `void disableVirtualTiling(SvsFile svs)` | Disables virtual tiling, reverting to raw micro-tiles. |
| `Future<img.Image?> extractSvsImageAsImage(SvsFile svs, String type, {bool applyColorScheme = true, bool applyDisplayColor = true, int? displayColor})` | Extracts decoded `img.Image` for `'thumbnail'`, `'label'`, or `'macro'`. |
| `Future<Uint8List?> extractSvsImageAsJpeg(SvsFile svs, String type, {int quality = 90, bool applyColorScheme = true, bool applyDisplayColor = true, int? displayColor})` | Extracts JPEG encoded byte data for `'thumbnail'`, `'label'`, or `'macro'`. |
| `Future<Uint8List?> extractSvsImage(SvsFile svs, String type)` | Extracts raw bytes for `'thumbnail'`, `'label'`, or `'macro'`. |
| `Future<Uint8List?> extractSvsLevelImage(SvsFile svs, int layerIndex, {CancellationToken? cancelToken})` | Extracts raw whole-image bytes for a resolution layer. |
| `Future<img.Image?> extractSvsTileAsImage(SvsFile svs, int layerIndex, int tileX, int tileY, {bool applyColorScheme = true, bool applyDisplayColor = true, int? displayColor, CancellationToken? cancelToken})` | Extracts and decodes `img.Image` for a specific tile. |
| `Future<Uint8List?> extractSvsTile(SvsFile svs, int layerIndex, int tileX, int tileY, {CancellationToken? cancelToken})` | Extracts raw bytes for a specific tile. |
| `int? parseDisplayColor(dynamic value)` | Utility function to parse Aperio `DisplayColor` strings (decimal, hex, `#RRGGBB`, `0xRRGGBB`) or integers into an integer RGB value. |
| `Future<DicomEchoResult> DicomEchoClient.echo({required String host, required int port, required String calledAeTitle, required String callingAeTitle, Duration timeout})` | DICOM Verification (C-ECHO). Failures are a `DicomEchoErrorCode` plus `DicomEchoException`, not a caller-supplied message string. |
| `Future<DicomFindResult> DicomFindClient.find({required String host, required int port, required String calledAeTitle, required String callingAeTitle, required DicomFindQuery query, Duration timeout, int maxResults})` | Study-level C-FIND. Failures are a `DicomFindErrorCode` plus `DicomFindException`, not a caller-supplied message string. |
| `Future<DicomRetrieveResult> DicomRetrieveClient.retrieve({required String host, required int port, required String calledAeTitle, required String callingAeTitle, required String studyInstanceUid, required DicomRetrieveMethod method, required String outputDirectory, int listenPort, Duration timeout})` | Study-level C-GET/C-MOVE. Failures are a `DicomRetrieveErrorCode` plus `DicomRetrieveException`; received files and partial-success status remain available. |
| `Future<DicomStoreResult> DicomStoreClient.store({required String host, required int port, required String calledAeTitle, required String callingAeTitle, required List<DicomStoreInstance> instances, Duration connectTimeout, Duration responseTimeout})` | Sends DICOM instances with C-STORE. Failures are a `DicomStoreErrorCode` plus `DicomStoreException`, with sent and total counts. |
| `Future<List<DicomStoreInstance>> DicomStoreClient.collectFiles(String path)` | Scans a file or folder recursively, picking valid DICOM instances. |
| `Future<DicomStudyIdentity> DicomStoreClient.readIdentity(String path)` | Reads Study/Patient UID and demographic attributes from DICOM files. |
| `Uint8List DicomStoreClient.buildAnnotationDicom(...)` | Builds a standard DICOM Raw Data Storage object encapsulating annotation XML. |

### Classes

| Class | Description |
| :--- | :--- |
| `SvsFile` | Encapsulates the `RandomAccessFile`, endianness, `isBigTiff` flag, first IFD offset, and cached global tables/colors. Call `close()` when done. |
| `DicomSlide` | Encapsulates a multi-resolution DICOM WSI slide across one or more concatenated files. Call `close()` when finished. |
| `DicomRaster` | Represents a single resolution layer or associated raster from a DICOM WSI series. |
| `DicomFile` | Open DICOM Part 10 file handle with frame indexing and offset tables. |
| `DicomMetadata` | Parsed header metadata for a DICOM WSI instance. |
| `CancellationToken` | Allows cancelling in-flight I/O reads, waiting queues, and heavy tile decompressions (JPEG 2000, LZW, color transformations). |
| `SvsMetadata` | Contains `width`, `height`, `tileWidth`, `tileHeight`, `compression`, `displayColor`, and `properties` map for the primary image. |
| `SvsFullMetadata` | Contains `levels` (`List<SvsImageInfo>`) and `associations` (`Map<String, SvsImageInfo>`). |
| `SvsImageInfo` | Detailed metadata for a single layer or associated image (`width`, `height`, `tileWidth`, `tileHeight`, `compression`, `displayColor`, `downsample`, `properties`, `type`). |
| `DicomEchoResult` | C-ECHO outcome. `error` / `errorCode` are `null` on success. `message` is display text derived from the error or from status `0x0000`. `responseTimeMs` is the round trip, or `null` if validation failed before connect. |
| `DicomEchoException` | Typed C-ECHO failure: `code`, optional `detail`, optional DICOM `statusCode`, and a derived `message`. |
| `DicomEchoErrorCode` | Machine-readable C-ECHO failure: validation, transport, association, protocol, server status, or `unknown`. |
| `DicomFindResult` | C-FIND outcome. `error` / `errorCode` are `null` on success. `message` is display text derived from the error or from the study list. |
| `DicomFindException` | Typed C-FIND failure: `code`, optional `detail`, optional DICOM `statusCode`, and a derived `message`. |
| `DicomFindErrorCode` | Machine-readable C-FIND failure: validation, transport, association, protocol, server status, or `unknown`. |
| `DicomRetrieveResult` | C-MOVE/C-GET outcome. `error` / `errorCode` are `null` on clean success; partial downloads preserve the received file list and success status. |
| `DicomRetrieveException` | Typed C-MOVE/C-GET failure: `code`, optional `detail`, optional DICOM `statusCode`, and a derived `message`. |
| `DicomRetrieveErrorCode` | Machine-readable retrieval failure: validation, output/listen setup, association, protocol, server status, or `unknown`. |
| `DicomRetrieveProgress` | Progress updates during C-MOVE / C-GET retrieval (`receivedFiles`, `remaining`, `completed`, `failed`, `warning`). |
| `DicomStoreResult` | C-STORE outcome with `storedCount`, `totalCount`, optional typed `error` / `errorCode`, and a derived `message`. |
| `DicomStoreException` | Typed C-STORE failure: `code`, optional `detail`, optional DICOM `statusCode`, and a derived `message`. |
| `DicomStoreErrorCode` | Machine-readable C-STORE failure: validation, preparation, association, protocol, transport, server status, or `unknown`. |
| `DicomStoreProgress` | Progress updates during C-STORE transmission (`completed`, `total`, `currentName`). |
| `DicomStoreInstance` | Source DICOM instance (file or bytes) for C-STORE transmission. |
| `DicomStudyIdentity` | Patient and study identity attributes for DICOM instance construction. |

---

## Example Project

A complete runnable Flutter example demonstrating file picking, metadata inspection, and associated image extraction is available in the [`example/`](example/) directory. DICOM command-line samples live in [`example/bin/`](example/bin/): `dicom_read.dart` opens a WSI file or folder, and `dicom_pacs.dart` shows C-ECHO, C-FIND, C-GET, C-MOVE and C-STORE. The `echo`, `find`, retrieve, and store commands print their typed error code before the display message. Run them from the package root, for example `dart run example/bin/dicom_read.dart /path/to/slide.dcm`.

---

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.
