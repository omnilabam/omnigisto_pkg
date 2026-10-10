import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:omnigisto_pkg/types/types.dart';

import 'virtual_tile.dart';
export 'virtual_tile.dart';

const _maxCachedBandPixels = 48 * 1024 * 1024;
const _maxCachedBands = 4;
const _isolateDecodeBytes = 512 * 1024;

/// Internal adapter; public callers continue to use SvsFile and SvsMetadata.
class HamamatsuFile extends SvsFile {
  final List<HamamatsuRaster> levels = [];
  final Map<String, HamamatsuRaster> associations = {};
  final List<SvsFile> sources = [];

  HamamatsuFile(
    RandomAccessFile raf,
    Endian endian,
    int firstIfdOffset,
    String path,
    int maxConcurrency,
  ) : super(raf, endian, firstIfdOffset, false, path, maxConcurrency);

  @override
  set maxConcurrency(int value) {
    super.maxConcurrency = value;
    for (final source in sources) {
      source.maxConcurrency = value;
    }
  }

  void ensureOpen() {
    if (isClosed) throw StateError('Cannot read from a closed SvsFile');
  }

  void sortLevels() {
    levels.sort((a, b) => b.width.compareTo(a.width));
    if (levels.isEmpty) {
      throw const FormatException('No supported Hamamatsu image levels');
    }
  }

  SvsFullMetadata fullMetadata() {
    ensureOpen();
    return SvsFullMetadata(
      levels: [
        for (final level in levels)
          level.info('level', downsample: levels.first.width / level.width),
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
      compression: level.compression,
      properties: Map.of(level.properties),
    );
  }

  HamamatsuRaster? levelAt(int index, int x, int y) {
    ensureOpen();
    if (index < 0 || index >= levels.length) return null;
    final level = levels[index];
    return level.containsTile(x, y) ? level : null;
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

  void enableVirtualTiling({
    int? virtualTileWidth,
    int? virtualTileHeight,
    int? mcuRowsPerTile,
  }) {
    for (var i = 0; i < levels.length; i++) {
      final raw = levels[i] is VirtualTiledRaster
          ? (levels[i] as VirtualTiledRaster).base
          : levels[i];

      final mcuRows = mcuRowsPerTile ??
          (virtualTileHeight != null
              ? math.max(1, virtualTileHeight ~/ raw.tileHeight)
              : (raw.tileWidth <= 256 ? 32 : 64));
      final tileHeight = virtualTileHeight ?? (mcuRows * raw.tileHeight);
      final tileWidth = virtualTileWidth ??
          (raw.tileWidth >= 256 && raw.tileWidth <= 512
              ? raw.tileWidth
              : (raw.tileWidth > 512 ? 512 : 256));

      levels[i] = VirtualTiledRaster(
        raw,
        tileWidth: tileWidth,
        tileHeight: tileHeight,
        mcuRowsPerTile: mcuRows,
      );
    }
  }

  void disableVirtualTiling() {
    for (var i = 0; i < levels.length; i++) {
      if (levels[i] is VirtualTiledRaster) {
        levels[i] = (levels[i] as VirtualTiledRaster).base;
      }
    }
  }

  @override
  Future<void> close() async {
    try {
      await Future.wait(sources.map((source) => source.close()));
    } finally {
      await super.close();
    }
  }
}

abstract class HamamatsuRaster {
  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;
  final String compression;
  final Map<String, String> properties;

  final Map<(int, int), img.Image> _decodedBands = {};
  final List<(int, int)> _decodedBandOrder = [];
  final Map<(int, int), Future<img.Image?>> _decodingBands = {};

  HamamatsuRaster({
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.compression,
    required this.properties,
  });

  bool containsTile(int x, int y) =>
      x >= 0 && y >= 0 && x * tileWidth < width && y * tileHeight < height;

  SvsImageInfo info(String type, {double? downsample}) => SvsImageInfo(
    width: width,
    height: height,
    tileWidth: type == 'level' ? tileWidth : null,
    tileHeight: type == 'level' ? tileHeight : null,
    compression: compression,
    properties: Map.of(properties),
    type: type,
    downsample: downsample,
  );

  Future<Uint8List?> readTile(int x, int y, {CancellationToken? cancelToken});

  Future<img.Image?> readTileImage(
    int x,
    int y, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) async {
    final bytes = await readTile(x, y, cancelToken: cancelToken);
    if (bytes == null || cancelToken?.isCancelled == true) return null;
    final image = await _decodeJpegBytes(bytes);
    return cancelToken?.isCancelled == true ? null : image;
  }

  Future<Uint8List?> readImage();

  Future<img.Image?> readImageDecoded({bool applyColorScheme = true}) async {
    final bytes = await readImage();
    return bytes == null ? null : img.decodeImage(bytes);
  }

  Future<Uint8List?> readContiguousJpeg(
    int startRow,
    int rowCount, {
    CancellationToken? cancelToken,
  }) async => null;

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
    final span = _contiguousSpan(x, y, width, height);
    if (span != null) {
      final banded = await _readRegionFromBands(
        x,
        y,
        width,
        height,
        span.$1,
        span.$2,
        cancelToken,
      );
      if (banded != null || cancelToken?.isCancelled == true) return banded;
    }
    return _readRegionByTiles(
      x,
      y,
      width,
      height,
      applyColorScheme: applyColorScheme,
      cancelToken: cancelToken,
    );
  }

  /// Row span of a single-column JPEG band that covers [x, y, width, height].
  /// The span is aligned to 8 restart rows so neighbouring crops share one decode.
  (int, int)? _contiguousSpan(int x, int y, int regionWidth, int regionHeight) {
    if (tileWidth <= 0 || tileHeight <= 0 || this.width <= 0) return null;
    final y0 = math.max(0, y);
    final y1 = math.min(this.height, y + regionHeight);
    final x0 = math.max(0, x);
    final x1 = math.min(this.width, x + regionWidth);
    if (x1 <= x0 || y1 <= y0) return null;
    // A single full-width strip is already one tile. Banding only pays off
    // when the request crops horizontally or covers more than one strip.
    if (x0 == 0 && x1 == this.width && y1 - y0 <= tileHeight) return null;
    final rows = (this.height + tileHeight - 1) ~/ tileHeight;
    final firstRow = y0 ~/ tileHeight;
    final lastRow = (y1 - 1) ~/ tileHeight;
    final aligned = firstRow - (firstRow % 8);
    final end = math.min(rows, ((lastRow + 8) ~/ 8) * 8);
    if (end <= aligned) return null;
    return (aligned, end - aligned);
  }

  Future<img.Image?> _readRegionFromBands(
    int x,
    int y,
    int regionWidth,
    int regionHeight,
    int startRow,
    int rowCount,
    CancellationToken? token,
  ) async {
    final rowPixels = this.width * tileHeight;
    var maxRows = rowPixels <= 0
        ? rowCount
        : _maxCachedBandPixels ~/ rowPixels;
    if (maxRows < 1) maxRows = 1;
    if (maxRows >= 8) maxRows -= maxRows % 8;
    if (maxRows < 1) maxRows = math.min(8, rowCount);

    img.Image? output;
    var row = startRow;
    final endRow = startRow + rowCount;
    while (row < endRow) {
      if (token?.isCancelled == true) return null;
      var count = math.min(maxRows, endRow - row);
      if (row == startRow && rowCount <= maxRows) count = rowCount;
      final band = await _cachedBand(row, count, token);
      if (token?.isCancelled == true || band == null) return null;
      output ??= img.Image(width: regionWidth, height: regionHeight)
        ..clear(img.ColorRgb8(255, 255, 255));
      _blitBand(output, band, x, y, regionWidth, regionHeight, row * tileHeight);
      row += count;
    }
    return output;
  }

  Future<img.Image?> _cachedBand(
    int startRow,
    int rowCount,
    CancellationToken? token,
  ) {
    final key = (startRow, rowCount);
    final cached = _decodedBands[key];
    if (cached != null) {
      _decodedBandOrder.remove(key);
      _decodedBandOrder.add(key);
      return Future.value(cached);
    }
    final inflight = _decodingBands[key];
    if (inflight != null) return inflight;
    final future = _decodeBand(startRow, rowCount, token);
    _decodingBands[key] = future;
    return future.whenComplete(() {
      if (identical(_decodingBands[key], future)) _decodingBands.remove(key);
    });
  }

  Future<img.Image?> _decodeBand(
    int startRow,
    int rowCount,
    CancellationToken? token,
  ) async {
    final bytes = await readContiguousJpeg(
      startRow,
      rowCount,
      cancelToken: token,
    );
    if (bytes == null || token?.isCancelled == true) return null;
    final image = await _decodeJpegBytes(bytes);
    if (image == null || token?.isCancelled == true) return null;
    if (image.width * image.height <= _maxCachedBandPixels) {
      final key = (startRow, rowCount);
      _decodedBands[key] = image;
      _decodedBandOrder.remove(key);
      _decodedBandOrder.add(key);
      while (_decodedBandOrder.length > _maxCachedBands) {
        _decodedBands.remove(_decodedBandOrder.removeAt(0));
      }
    }
    return image;
  }

  void _blitBand(
    img.Image output,
    img.Image band,
    int x,
    int y,
    int regionWidth,
    int regionHeight,
    int bandTop,
  ) {
    final srcX = math.max(0, x);
    final srcY = math.max(0, y - bandTop);
    final dstX = math.max(0, -x);
    final dstY = math.max(0, bandTop - y);
    final copyW = math.min(band.width - srcX, regionWidth - dstX);
    final copyH = math.min(band.height - srcY, regionHeight - dstY);
    if (copyW > 0 && copyH > 0) {
      img.compositeImage(
        output,
        band,
        srcX: srcX,
        srcY: srcY,
        srcW: copyW,
        srcH: copyH,
        dstX: dstX,
        dstY: dstY,
      );
    }
  }

  Future<img.Image?> _readRegionByTiles(
    int x,
    int y,
    int width,
    int height, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) async {
    final output = img.Image(width: width, height: height);
    output.clear(img.ColorRgb8(255, 255, 255));

    final startCol = (x / tileWidth).floor();
    final endCol = ((x + width - 1) / tileWidth).floor();
    final startRow = (y / tileHeight).floor();
    final endRow = ((y + height - 1) / tileHeight).floor();

    for (var row = startRow; row <= endRow; row++) {
      for (var col = startCol; col <= endCol; col++) {
        if (cancelToken?.isCancelled == true) return null;
        if (!containsTile(col, row)) continue;

        final tileImg = await readTileImage(
          col,
          row,
          applyColorScheme: applyColorScheme,
          cancelToken: cancelToken,
        );
        if (tileImg == null) continue;

        final tileLeft = col * tileWidth;
        final tileTop = row * tileHeight;

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
}

Future<img.Image?> _decodeJpegBytes(Uint8List bytes) async {
  if (bytes.length < _isolateDecodeBytes) return img.decodeImage(bytes);
  try {
    final decoded = await Isolate.run(() => _decodeJpegRgba(bytes));
    if (decoded == null) return null;
    return img.Image.fromBytes(
      width: decoded.$1,
      height: decoded.$2,
      bytes: decoded.$3.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  } catch (_) {
    return img.decodeImage(bytes);
  }
}

(int, int, Uint8List)? _decodeJpegRgba(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return null;
  return (
    image.width,
    image.height,
    Uint8List.fromList(image.getBytes(order: img.ChannelOrder.rgba)),
  );
}
