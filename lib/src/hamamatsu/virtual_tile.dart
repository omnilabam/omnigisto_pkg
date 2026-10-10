import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:omnigisto_pkg/types/types.dart';

import 'slide.dart';

/// Wraps a [HamamatsuRaster] to aggregate micro-tiles (e.g. 8-pixel high strips)
/// into virtual tiles of adequate dimensions (e.g. 256x256 or 512x512).
class VirtualTiledRaster extends HamamatsuRaster {
  final HamamatsuRaster base;
  final int mcuRowsPerTile;

  VirtualTiledRaster(
    this.base, {
    required super.tileWidth,
    required super.tileHeight,
    required this.mcuRowsPerTile,
  }) : super(
         width: base.width,
         height: base.height,
         compression: base.compression,
         properties: base.properties,
       );

  @override
  Future<Uint8List?> readTile(
    int x,
    int y, {
    CancellationToken? cancelToken,
  }) async {
    if (!containsTile(x, y) || cancelToken?.isCancelled == true) return null;
    final left = x * tileWidth;
    final top = y * tileHeight;
    final w = math.min(tileWidth, width - left);
    final h = math.min(tileHeight, height - top);

    // Fast path: contiguous JPEG read across rows when possible
    if (left == 0 && w == base.width && (top ~/ base.tileHeight) % 8 == 0) {
      final startRow = top ~/ base.tileHeight;
      final rowCount = (h + base.tileHeight - 1) ~/ base.tileHeight;
      final contiguous = await base.readContiguousJpeg(
        startRow,
        rowCount,
        cancelToken: cancelToken,
      );
      if (contiguous != null) return contiguous;
    }

    final image = await readTileImage(x, y, cancelToken: cancelToken);
    if (image == null || cancelToken?.isCancelled == true) return null;
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }

  @override
  Future<img.Image?> readTileImage(
    int x,
    int y, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) async {
    if (!containsTile(x, y) || cancelToken?.isCancelled == true) return null;
    final left = x * tileWidth;
    final top = y * tileHeight;
    final w = math.min(tileWidth, width - left);
    final h = math.min(tileHeight, height - top);

    // Fast path: contiguous JPEG decode
    if (left == 0 && w == base.width && (top ~/ base.tileHeight) % 8 == 0) {
      final startRow = top ~/ base.tileHeight;
      final rowCount = (h + base.tileHeight - 1) ~/ base.tileHeight;
      final contiguous = await base.readContiguousJpeg(
        startRow,
        rowCount,
        cancelToken: cancelToken,
      );
      if (contiguous != null) {
        if (cancelToken?.isCancelled == true) return null;
        final decoded = img.decodeImage(contiguous);
        if (decoded != null) return decoded;
      }
    }

    return base.readRegion(
      left,
      top,
      w,
      h,
      applyColorScheme: applyColorScheme,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<img.Image?> readRegion(
    int x,
    int y,
    int width,
    int height, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) {
    return base.readRegion(
      x,
      y,
      width,
      height,
      applyColorScheme: applyColorScheme,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<Uint8List?> readImage() => base.readImage();

  @override
  Future<img.Image?> readImageDecoded({bool applyColorScheme = true}) =>
      base.readImageDecoded(applyColorScheme: applyColorScheme);
}
