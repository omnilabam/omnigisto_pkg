import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../../types/types.dart';
import 'dicom.dart';

/// Represents a single resolution layer or associated raster from a DICOM WSI series.
class DicomRaster {
  final DicomFile dicom;
  final DicomMetadata metadata;
  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;
  final int numberOfFrames;
  final int tilesAcross;
  final int tilesDown;
  final Map<String, String> properties;
  final Int32List? tileToFrame;

  DicomRaster({
    required this.dicom,
    required this.metadata,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.numberOfFrames,
    Map<String, String>? properties,
    Int32List? tileToFrame,
  })  : tilesAcross = tileWidth > 0 ? (width + tileWidth - 1) ~/ tileWidth : 1,
        tilesDown = tileHeight > 0 ? (height + tileHeight - 1) ~/ tileHeight : 1,
        tileToFrame = tileToFrame ??
            _buildTileToFrame(
              metadata,
              tileWidth > 0 ? tileWidth : width,
              tileHeight > 0 ? tileHeight : height,
              width,
              height,
              numberOfFrames,
            ),
        properties = properties ?? {
          'SOPClassUID': metadata.sopClassUid,
          'SOPInstanceUID': metadata.sopInstanceUid,
          'StudyInstanceUID': metadata.studyInstanceUid,
          'SeriesInstanceUID': metadata.seriesInstanceUid,
          'TransferSyntax': metadata.transferSyntax,
        };

  static Int32List? _buildTileToFrame(
    DicomMetadata metadata,
    int effectiveTileW,
    int effectiveTileH,
    int width,
    int height,
    int numberOfFrames,
  ) {
    final perFrame = metadata.perFramePositions;
    if (perFrame == null || perFrame.isEmpty) return null;
    final across = effectiveTileW > 0 ? (width + effectiveTileW - 1) ~/ effectiveTileW : 1;
    final down = effectiveTileH > 0 ? (height + effectiveTileH - 1) ~/ effectiveTileH : 1;
    if (across <= 0 || down <= 0) return null;

    final total = across * down;
    final map = Int32List(total)..fillRange(0, total, -1);

    for (var f = 0; f < perFrame.length && f < numberOfFrames; f++) {
      final pos = perFrame[f];
      final tx = (pos.colPos - 1) ~/ effectiveTileW;
      final ty = (pos.rowPos - 1) ~/ effectiveTileH;
      if (tx >= 0 && tx < across && ty >= 0 && ty < down) {
        map[ty * across + tx] = f;
      }
    }
    return map;
  }

  bool containsTile(int x, int y) {
    return x >= 0 && x < tilesAcross && y >= 0 && y < tilesDown;
  }

  int frameIndexForTile(int x, int y) {
    if (tileToFrame != null) {
      if (x < 0 || x >= tilesAcross || y < 0 || y >= tilesDown) return -1;
      final idx = y * tilesAcross + x;
      return idx < tileToFrame!.length ? tileToFrame![idx] : -1;
    }
    return y * tilesAcross + x;
  }

  Future<Uint8List?> readTile(int x, int y, {CancellationToken? cancelToken}) async {
    if (!containsTile(x, y)) return null;
    final frame = frameIndexForTile(x, y);
    if (frame < 0 || frame >= numberOfFrames) return null;
    return extractDicomFrame(dicom, frame, cancelToken: cancelToken);
  }

  Future<img.Image?> readTileImage(
    int x,
    int y, {
    bool applyColorScheme = true,
    bool applyDisplayColor = true,
    int? displayColor,
    CancellationToken? cancelToken,
  }) async {
    if (!containsTile(x, y)) return null;
    final frame = frameIndexForTile(x, y);
    if (frame < 0 || frame >= numberOfFrames) return null;
    return extractDicomFrameAsImage(dicom, frame, cancelToken: cancelToken);
  }

  Future<Uint8List?> readImage({CancellationToken? cancelToken}) async {
    if (numberOfFrames == 1) {
      final bytes = await extractDicomFrame(dicom, 0, cancelToken: cancelToken);
      if (bytes == null || bytes.isEmpty || cancelToken?.isCancelled == true) return null;
      if (_isEncodedRaster(bytes)) return bytes;
      final image = await extractDicomFrameAsImage(dicom, 0, cancelToken: cancelToken);
      if (image == null) return null;
      return Uint8List.fromList(img.encodeJpg(image, quality: 90));
    }
    final image = await readRegion(0, 0, width, height, cancelToken: cancelToken);
    if (image == null) return null;
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }

  Future<img.Image?> readImageDecoded({bool applyColorScheme = true, CancellationToken? cancelToken}) async {
    if (numberOfFrames == 1) {
      return extractDicomFrameAsImage(dicom, 0, cancelToken: cancelToken);
    }
    return readRegion(0, 0, width, height, applyColorScheme: applyColorScheme, cancelToken: cancelToken);
  }

  Future<img.Image?> readRegion(
    int x,
    int y,
    int width,
    int height, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) async {
    if (width <= 0 || height <= 0 || cancelToken?.isCancelled == true) {
      return null;
    }

    final output = img.Image(width: width, height: height);
    output.clear(img.ColorRgb8(255, 255, 255));

    final effectiveTileW = tileWidth > 0 ? tileWidth : this.width;
    final effectiveTileH = tileHeight > 0 ? tileHeight : this.height;

    final startCol = (x / effectiveTileW).floor();
    final endCol = ((x + width - 1) / effectiveTileW).floor();
    final startRow = (y / effectiveTileH).floor();
    final endRow = ((y + height - 1) / effectiveTileH).floor();

    final jobs = <({int col, int row})>[];
    for (var row = startRow; row <= endRow; row++) {
      for (var col = startCol; col <= endCol; col++) {
        if (containsTile(col, row)) {
          final frame = frameIndexForTile(col, row);
          if (frame >= 0 && frame < numberOfFrames) {
            jobs.add((col: col, row: row));
          }
        }
      }
    }

    final limit = dicom.maxConcurrency < 1 ? 1 : dicom.maxConcurrency;
    for (var i = 0; i < jobs.length; i += limit) {
      if (cancelToken?.isCancelled == true) return null;
      final batch = jobs.sublist(i, math.min(i + limit, jobs.length));
      final images = await Future.wait(batch.map((job) => readTileImage(
            job.col,
            job.row,
            applyColorScheme: applyColorScheme,
            cancelToken: cancelToken,
          )));
      for (var j = 0; j < batch.length; j++) {
        final tileImg = images[j];
        if (tileImg == null) continue;
        final col = batch[j].col;
        final row = batch[j].row;

        final tileLeft = col * effectiveTileW;
        final tileTop = row * effectiveTileH;

        final srcX = math.max(0, x - tileLeft);
        final srcY = math.max(0, y - tileTop);
        final dstX = math.max(0, tileLeft - x);
        final dstY = math.max(0, tileTop - y);

        final copyW = math.min(tileImg.width - srcX, width - dstX);
        final copyH = math.min(tileImg.height - srcY, height - dstY);

        if (copyW > 0 && copyH > 0) {
          img.compositeImage(
            output,
            tileImg,
            srcX: srcX,
            srcY: srcY,
            srcW: copyW,
            srcH: copyH,
            dstX: dstX,
            dstY: dstY,
          );
        }
      }
    }
    return output;
  }

  SvsImageInfo info(String type, {double downsample = 1.0}) {
    return SvsImageInfo(
      type: type,
      width: width,
      height: height,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      compression: 'DICOM',
      properties: Map.of(properties),
    );
  }
}

/// A wrapper over a DICOM WSI multi-file slide folder or set of DICOM files.
/// Implements [SvsFile] so it seamlessly integrates into OmniHisto viewing pipeline.
class DicomSlideFile extends SvsFile {
  final List<DicomRaster> levels = [];
  final Map<String, DicomRaster> associations = {};
  final List<DicomFile> sources = [];

  DicomSlideFile(
    RandomAccessFile raf,
    Endian endian,
    String path,
    int maxConcurrency,
  ) : super(raf, endian, 0, false, path, maxConcurrency);

  void ensureOpen() {
    if (isClosed) throw StateError('Cannot read from a closed DicomSlideFile');
  }

  void sortLevels() {
    levels.sort((a, b) => b.width.compareTo(a.width));
    if (levels.isEmpty) {
      throw const FormatException('No supported DICOM image levels found');
    }
  }

  SvsFullMetadata fullMetadata() {
    ensureOpen();
    final baseWidth = levels.isNotEmpty && levels.first.width > 0 ? levels.first.width.toDouble() : 1.0;
    return SvsFullMetadata(
      levels: [
        for (final level in levels)
          level.info('level', downsample: baseWidth / (level.width > 0 ? level.width : 1)),
      ],
      associations: {
        for (final entry in associations.entries)
          entry.key: entry.value.info(entry.key),
      },
    );
  }

  SvsMetadata metadata() {
    ensureOpen();
    final level = levels.first;
    return SvsMetadata(
      width: level.width,
      height: level.height,
      tileWidth: level.tileWidth,
      tileHeight: level.tileHeight,
      compression: 'DICOM',
      properties: Map.of(level.properties),
    );
  }

  DicomRaster? levelAt(int index, int x, int y) {
    ensureOpen();
    if (index < 0 || index >= levels.length) return null;
    final level = levels[index];
    return level.containsTile(x, y) ? level : null;
  }

  Future<Uint8List?> readTile(
    int layerIndex,
    int tileX,
    int tileY, {
    CancellationToken? cancelToken,
  }) async {
    ensureOpen();
    if (layerIndex < 0 || layerIndex >= levels.length) return null;
    return levels[layerIndex].readTile(tileX, tileY, cancelToken: cancelToken);
  }

  Future<img.Image?> readTileImage(
    int layerIndex,
    int tileX,
    int tileY, {
    bool applyColorScheme = true,
    bool applyDisplayColor = true,
    int? displayColor,
    CancellationToken? cancelToken,
  }) async {
    ensureOpen();
    if (layerIndex < 0 || layerIndex >= levels.length) return null;
    return levels[layerIndex].readTileImage(
      tileX,
      tileY,
      applyColorScheme: applyColorScheme,
      applyDisplayColor: applyDisplayColor,
      displayColor: displayColor,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List?> readLevelImage(
    int layerIndex, {
    CancellationToken? cancelToken,
  }) async {
    ensureOpen();
    if (layerIndex < 0 || layerIndex >= levels.length) return null;
    return levels[layerIndex].readImage(cancelToken: cancelToken);
  }

  Future<img.Image?> readRegion(
    int layerIndex,
    int x,
    int y,
    int width,
    int height, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) async {
    ensureOpen();
    if (layerIndex < 0 || layerIndex >= levels.length) return null;
    return levels[layerIndex].readRegion(
      x,
      y,
      width,
      height,
      applyColorScheme: applyColorScheme,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<void> close() async {
    for (final src in sources) {
      try {
        await src.close();
      } catch (_) {}
    }
    sources.clear();
    await super.close();
  }
}

/// Opens a DICOM WSI slide from a directory containing multiple `.dcm` files or from a single file.
///
/// When [seriesInstanceUid] is set, only instances of that series are loaded.
Future<DicomSlideFile?> openDicomFolder(
  String path, {
  int maxConcurrency = 4,
  String? seriesInstanceUid,
}) async {
  final isDir = await FileSystemEntity.isDirectory(path);
  final List<String> filePaths = [];

  if (isDir) {
    final dir = Directory(path);
    if (!await dir.exists()) return null;

    final entities = await dir.list(recursive: true, followLinks: false).toList();
    for (final entity in entities) {
      if (entity is File) {
        final segments = entity.uri.pathSegments;
        final name = segments.isEmpty ? entity.path : segments.last;
        if (name.startsWith('.') || name.toUpperCase() == 'DICOMDIR') continue;
        final lower = name.toLowerCase();
        if (lower.endsWith('.dcm') || lower.endsWith('.dicom') || await _fileHasDicomMagic(entity)) {
          filePaths.add(entity.path);
        }
      }
    }
  } else {
    final file = File(path);
    if (await file.exists()) {
      filePaths.add(path);
    }
  }

  if (filePaths.isEmpty) return null;

  final List<({DicomFile dicom, DicomMetadata meta})> parsedList = [];

  for (final filePath in filePaths) {
    try {
      final dicom = await openDicomFile(filePath, maxConcurrency: maxConcurrency);
      if (dicom != null) {
        final meta = await readDicomMetadata(dicom);
        if (meta != null && _seriesMatches(meta.seriesInstanceUid, seriesInstanceUid)) {
          parsedList.add((dicom: dicom, meta: meta));
        } else {
          await dicom.close();
        }
      }
    } catch (_) {}
  }

  if (parsedList.isEmpty) return null;

  final primaryRaf = parsedList.first.dicom.raf;
  final primaryEndian = parsedList.first.dicom.endian;
  final slide = DicomSlideFile(primaryRaf, primaryEndian, path, maxConcurrency);

  for (final item in parsedList) {
    slide.sources.add(item.dicom);
    final meta = item.meta;

    final raster = DicomRaster(
      dicom: item.dicom,
      metadata: meta,
      width: meta.totalPixelMatrixColumns > 0 ? meta.totalPixelMatrixColumns : meta.columns,
      height: meta.totalPixelMatrixRows > 0 ? meta.totalPixelMatrixRows : meta.rows,
      tileWidth: meta.columns > 0 ? meta.columns : meta.totalPixelMatrixColumns,
      tileHeight: meta.rows > 0 ? meta.rows : meta.totalPixelMatrixRows,
      numberOfFrames: meta.numberOfFrames > 0 ? meta.numberOfFrames : 1,
    );

    if (meta.type == 'level') {
      slide.levels.add(raster);
    } else if (meta.type == 'label') {
      slide.associations['label'] = raster;
    } else if (meta.type == 'macro') {
      slide.associations['macro'] = raster;
    } else if (meta.type == 'thumbnail') {
      slide.associations['thumbnail'] = raster;
    } else {
      if (raster.numberOfFrames > 1 || raster.width > 2048) {
        slide.levels.add(raster);
      } else {
        slide.associations['macro'] ??= raster;
      }
    }
  }

  if (slide.levels.isEmpty) {
    if (slide.associations.isNotEmpty) {
      final promo = slide.associations.values.first;
      slide.levels.add(promo);
    } else {
      await slide.close();
      return null;
    }
  }

  slide.sortLevels();

  if (!slide.associations.containsKey('thumbnail') && slide.levels.isNotEmpty) {
    slide.associations['thumbnail'] = slide.levels.last;
  }

  return slide;
}

/// Convenience alias for [openDicomFolder].
Future<DicomSlideFile?> openDicomSlide(
  String path, {
  int maxConcurrency = 4,
  String? seriesInstanceUid,
}) =>
    openDicomFolder(path, maxConcurrency: maxConcurrency, seriesInstanceUid: seriesInstanceUid);

bool _isEncodedRaster(Uint8List bytes) {
  if (bytes.length < 3) return false;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
  return bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
}

bool _seriesMatches(String actual, String? wanted) {
  final filter = wanted?.trim();
  if (filter == null || filter.isEmpty) return true;
  return actual.trim() == filter;
}

Future<bool> _fileHasDicomMagic(File file) async {
  RandomAccessFile? raf;
  try {
    if (await file.length() < 132) return false;
    raf = await file.open(mode: FileMode.read);
    await raf.setPosition(128);
    final magic = await raf.read(4);
    return magic.length == 4 && String.fromCharCodes(magic) == 'DICM';
  } catch (_) {
    return false;
  } finally {
    await raf?.close();
  }
}
