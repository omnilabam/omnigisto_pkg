## 0.0.1-alfa.1
* Initial, read about it in README.md

## 0.0.1-alfa.3
* new function extractSvsImageAsImage, extractSvsImageAsJpeg, extractSvsTileAsImage added
* Export changes
* Example added
* bug fixes

## 0.0.2-alfa.1
* Async upload of the tiles, without mutex


## 0.1.0-beta
* Increased reading speed of the tiles
* Added full BigTIFF support for reading slides > 4 GB
* Added JPEG 2000 decompression support
* Added SubIFD traversal for multi-resolution pyramid levels.
* Added main library export `package:omnigisto_pkg/omnigisto_pkg.dart`
* Added comprehensive test suite for BigTIFF and JPEG 2000 parsing and extraction
* Extra tests on iOs and Android
* Bug fixes

## 0.1.1
* First release
* Fixed SubIFD (tag 330) handling in `readFullSvsMetadata` for consistent pyramid level count with `extractSvsTile`
* Improved associated image detection (`label`, `macro`, `thumbnail`) in `_determineImageType`
* Removed hardcoded resolution check (687x687) for label images to support various Aperio scanner models (AT2, GT450, CS2, etc.)
* Added aspect ratio and keyword-based heuristics for slide labels, macro overviews, and thumbnails

## 0.1.2
* Some packages updated

## 0.1.4
* Added `DisplayColor` support: automatic extraction and parsing of Aperio `DisplayColor` parameter in `SvsMetadata` and `SvsImageInfo`.
* Added pixel tinting and color mapping according to `DisplayColor` in tile and associated image extraction pipelines.
* Added `applyDisplayColor` and optional `displayColor` override parameters to `extractSvsTileAsImage`, `extractSvsImageAsImage`, and `extractSvsImageAsJpeg`.
* Exported `parseDisplayColor` utility function for parsing decimal and hexadecimal color formats.
* Added `downsample` property to `SvsImageInfo` representing resolution pyramid layer downsampling factor in `readFullSvsMetadata`.
* Added file descriptor pooling (`RandomAccessFile`) in `SvsFile` for high-throughput parallel asynchronous tile reading without I/O serialization bottlenecks.
* Added `maxConcurrency` parameter to `openSvsFile` (default: 4) and `SvsFile`, allowing fine-tuned I/O scaling for slow HDDs (1-2) up to fast SSDs/NVMe (4-8).
* Added dynamic concurrency level adjustment via `SvsFile.maxConcurrency` setter with automatic idle handle cleanup and pool shrinking.
* Enhanced `SvsFile.synchronized` with re-entrancy support and exclusive primary handle locking, keeping metadata scans thread-safe without blocking parallel tile reads.
* Added graceful degradation when hitting OS file descriptor limits (`EMFILE`) and safe cleanup of all pooled handles in `SvsFile.close()`.
* Added `CancellationToken` class for cooperative cancellation of asynchronous I/O and image decoding tasks.
* Added `cancelToken` support to `SvsFile` descriptor pool (`_acquireHandle` and `readBytesAt`) with automatic waiter removal and zero descriptor leaks upon cancellation.
* Added `cancelToken` parameter to `extractSvsTile` and `extractSvsTileAsImage` with cancellation checks before heavy operations (I/O, LZW, JPEG 2000 decompressions, ICC and color map processing).

## 0.1.5
* Added Hamamatsu NDPI, VMS and VMU support through the existing SVS API, preserving metadata models, field types and string output formats.
* Added NDPI extended 64-bit IFD/strip offsets, focal-plane filtering, objective/MPP properties and macro image extraction.
* Added on-demand JPEG restart-interval extraction without recompression, with cancellation and fallback scanning for missing or unreliable NDPI indexes.
* Added Virtual Tiling (micro-tile aggregation) for Hamamatsu NDPI: aggregates vertical MCU intervals (e.g. 32 or 64 MCU rows, 256x256 or 512x512) to eliminate UI rendering lag caused by 8-pixel micro-tiles.
* Added OpenSlide-compatible arbitrary region decoding: `readRegion(svs, layerIndex, x, y, width, height)` and `extractSvsRegion` / `extractSvsRegionAsImage` across both SVS and Hamamatsu formats.
* Added `enableVirtualTiling` and `disableVirtualTiling` functions and configuration parameters in `openSvsFile` (`virtualTiling`, `virtualTileWidth`, `virtualTileHeight`, `mcuRowsPerTile`).
* Added VMS JPEG mosaics and VMU/NGR column reads with 12-bit to 8-bit RGB conversion, map thumbnails and optional macro images.
> [!NOTE]
> Comprehensive compatibility tests have been conducted for all three formats.
> The evaluation successfully covers scenarios featuring sparse offsets above 4 GiB,
> malformed data handling, as well as concurrent reads and cancellation.
> NDPI correctness has been additionally validated against public samples.

## 0.1.6
* Exported new DICOM functions in the main library `package:omnigisto_pkg/omnigisto_pkg.dart`.
* Faster Hamamatsu NDPI tile reads: restart-interval boundaries are taken from the offset table, RST markers are checked in memory, and the entropy range is read in one call instead of a byte-by-byte scan.
* Tile and strip copies are a single read up to 8 MiB. Fallback scanning without an offset table still uses 64 KiB chunks so cancellation can stop between buffers.
* NDPI restart tables (tags 65426 and 65432) are stored in typed integer lists (`Uint32List` / `Int64List`) instead of boxed `List<num>`, reducing allocation when opening large slides.
* Wide MCU strips used by virtual tiles and region crops are decoded once and cached; neighbouring horizontal tiles are cropped from that band instead of decoding the full strip again.
* JPEG payloads larger than 512 KiB are decoded in an isolate so tile and region decoding does not block the event loop.

## 0.1.7
* Fixed JPEG 2000 decoding of subsampled components (`XRsiz` / `YRsiz`), including DICOM `YBR_FULL_422` tiles that previously failed while assembling chroma.
* Added YCbCr to RGB conversion when `PhotometricInterpretation` is `YBR_FULL_422`.
* Added support for reading single instances of DICOM Whole Slide Imaging (WSI).
* Implemented `DicomFile` with `RandomAccessFile` pooling for efficient parallel reading without loading the entire file into memory.
* Added `openDicomFile` for fast DICOM parsing and scanning Basic Offset Table for O(1) frame access.
* Added `DicomMetadata` and `readDicomMetadata` to extract key tags (UIDs, Total Pixel Matrix sizes, Transfer Syntax) and classify instance types (`VOLUME`, `LABEL`, `OVERVIEW`, `THUMBNAIL`).
* Added `extractDicomFrame` for extracting raw frame bytes from encapsulated and uncompressed DICOM pixel data.
* Added `extractDicomFrameAsImage` for decoding JPEG-compressed and uncompressed 8-bit DICOM frames.
* Faster DICOM open: tags are parsed from large reads, known-length sequences such as per-frame functional groups are skipped, and offset tables are stored in typed lists.
* Frame lookup without a usable offset table is indexed once, then each frame is a single range read. File handles are no longer shared between concurrent reads.
* Encapsulated frames are decoded by transfer syntax in a small isolate pool, and DICOM region reads fetch tiles in parallel.
* DICOM WSI (only WSI) C-FIND, C-ECHO, C-GET/C-MOVE support