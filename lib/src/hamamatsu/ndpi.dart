import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:omnigisto_pkg/types/types.dart';

import 'jpeg.dart';
import 'slide.dart';

/// NDPI uses magic 42, but has an eight-byte first IFD pointer.
Future<bool> isNdpi(RandomAccessFile raf, int offset, Endian endian) async {
  final length = await raf.length();
  if (offset < 12 || offset > length - 2) return false;
  await raf.setPosition(offset);
  final count = ByteData.sublistView(await raf.read(2)).getUint16(0, endian);
  if (count == 0 || offset + 2 + count * 12 > length) return false;
  final entries = ByteData.sublistView(await raf.read(count * 12));
  for (var i = 0; i < count; i++) {
    if (entries.getUint16(i * 12, endian) == 65420 &&
        entries.getUint32(i * 12 + 4, endian) != 0) {
      return true;
    }
  }
  return false;
}

Future<HamamatsuFile> openNdpi(
  RandomAccessFile raf,
  String path,
  Endian endian,
  int firstIfdOffset,
  int maxConcurrency, {
  bool? virtualTiling,
  int? virtualTileWidth,
  int? virtualTileHeight,
  int? mcuRowsPerTile,
}) async {
  final slide = HamamatsuFile(
    raf,
    endian,
    firstIfdOffset,
    path,
    maxConcurrency,
  );
  final length = await raf.length();
  final visited = <int>{};
  var offset = firstIfdOffset;
  while (offset != 0) {
    if (!visited.add(offset) || visited.length > 4096) {
      throw const FormatException('Cyclic or excessive NDPI directory chain');
    }
    final _NdpiDirectory directory;
    try {
      directory = await _NdpiDirectory.read(slide, offset, length);
    } catch (_) {
      if (slide.levels.isNotEmpty) break;
      rethrow;
    }
    offset = directory.next;
    final lens = directory.number(65421);
    final focalPlane = directory.number(65424) ?? 0;
    // The existing 2D API exposes only the in-focus pyramid.
    if (focalPlane != 0 || lens == null || lens == 0 || lens < -1) continue;
    final width = directory.integer(256);
    final height = directory.integer(257);
    if (width <= 0 || height <= 0) {
      throw const FormatException('Invalid NDPI image dimensions');
    }
    final compression = directory.integer(259);
    if (compression != 7 && compression != 6) {
      throw const FormatException('Unsupported NDPI image compression');
    }
    final starts = directory.values[273];
    final counts = directory.values[279];
    if (starts?.length != 1 ||
        counts?.length != 1 ||
        directory.integer(278, height) != height) {
      throw const FormatException('NDPI requires a single JPEG strip');
    }
    final start = starts!.single.toInt();
    final count = counts!.single.toInt();
    final properties = directory.properties();
    List<int>? restartOffsets;
    final low = directory.restartLow ?? directory.values[65426];
    final high = directory.restartHigh ?? directory.values[65432];
    if (low != null && (high == null || high.length == low.length)) {
      final offsets = Int64List(low.length);
      for (var i = 0; i < low.length; i++) {
        final hi = high == null ? 0 : high[i].toInt();
        offsets[i] = start + (low[i].toInt() | (hi << 32));
      }
      restartOffsets = offsets;
    }
    HamamatsuJpeg image;
    try {
      image = await HamamatsuJpeg.open(
        slide,
        offset: start,
        length: count,
        width: width,
        height: height,
        properties: properties,
        restartOffsets: restartOffsets,
      );
    } on FormatException {
      if (restartOffsets == null) rethrow;
      // Scanner-provided restart tables are optional and can be unreliable.
      restartOffsets = null;
      image = await HamamatsuJpeg.open(
        slide,
        offset: start,
        length: count,
        width: width,
        height: height,
        properties: properties,
      );
    }
    final raster = restartOffsets == null
        ? image
        : _NdpiIndexedRaster(image, () {
            return HamamatsuJpeg.open(
              slide,
              offset: start,
              length: count,
              width: width,
              height: height,
              properties: properties,
            );
          });
    if (lens == -1) {
      slide.associations.putIfAbsent('macro', () => raster);
    } else {
      final shouldVirtualTile = virtualTiling ??
          ((virtualTileWidth != null ||
                  virtualTileHeight != null ||
                  mcuRowsPerTile != null)
              ? true
              : (raster.tileHeight <= 16 &&
                  (raster.height >= 256 ||
                      (raster.height + raster.tileHeight - 1) ~/
                              raster.tileHeight >=
                          32)));

      final HamamatsuRaster finalRaster;
      if (shouldVirtualTile) {
        final mcuRows = mcuRowsPerTile ??
            (virtualTileHeight != null
                ? math.max(1, virtualTileHeight ~/ raster.tileHeight)
                : (raster.tileWidth <= 256 ? 32 : 64));
        final tileHeight = virtualTileHeight ?? (mcuRows * raster.tileHeight);
        final tileWidth = virtualTileWidth ??
            (raster.tileWidth >= 256 && raster.tileWidth <= 512
                ? raster.tileWidth
                : (raster.tileWidth > 512 ? 512 : 256));

        finalRaster = VirtualTiledRaster(
          raster,
          tileWidth: tileWidth,
          tileHeight: tileHeight,
          mcuRowsPerTile: mcuRows,
        );
      } else {
        finalRaster = raster;
      }
      slide.levels.add(finalRaster);
    }
  }
  slide.sortLevels();
  return slide;
}

/// A table can have plausible offsets but invalid marker boundaries. Recover
/// lazily rather than scanning every tile while opening the slide.
class _NdpiIndexedRaster extends HamamatsuRaster {
  final HamamatsuJpeg _image;
  final Future<HamamatsuJpeg> Function() _openWithoutIndex;
  Future<HamamatsuJpeg>? _fallback;

  _NdpiIndexedRaster(this._image, this._openWithoutIndex)
    : super(
        width: _image.width,
        height: _image.height,
        tileWidth: _image.tileWidth,
        tileHeight: _image.tileHeight,
        compression: _image.compression,
        properties: _image.properties,
      );

  Future<T> _read<T>(Future<T> Function(HamamatsuJpeg) operation) async {
    if (_fallback != null) return operation(await _fallback!);
    try {
      return await operation(_image);
    } on FormatException {
      _fallback ??= _openWithoutIndex();
      return operation(await _fallback!);
    }
  }

  @override
  Future<Uint8List?> readTile(int x, int y, {CancellationToken? cancelToken}) =>
      _read((image) => image.readTile(x, y, cancelToken: cancelToken));

  @override
  Future<Uint8List?> readImage() => _read((image) => image.readImage());

  @override
  Future<Uint8List?> readContiguousJpeg(
    int startRow,
    int rowCount, {
    CancellationToken? cancelToken,
  }) => _read((image) => image.readContiguousJpeg(
    startRow,
    rowCount,
    cancelToken: cancelToken,
  ));

  @override
  Future<img.Image?> readRegion(
    int x,
    int y,
    int width,
    int height, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) => _read((image) => image.readRegion(
    x,
    y,
    width,
    height,
    applyColorScheme: applyColorScheme,
    cancelToken: cancelToken,
  ));
}

class _NdpiDirectory {
  final int next;
  final Map<int, List<num>> values;
  final Map<int, String> strings;
  final List<int>? restartLow;
  final List<int>? restartHigh;

  _NdpiDirectory(
    this.next,
    this.values,
    this.strings, {
    this.restartLow,
    this.restartHigh,
  });

  num? number(int tag) => values[tag]?.firstOrNull;
  int integer(int tag, [int fallback = 0]) => number(tag)?.toInt() ?? fallback;

  Map<String, String> properties() {
    final properties = <String, String>{};
    for (final tag in [270, 65449]) {
      final text = strings[tag];
      if (text == null) continue;
      for (final line in text.split(RegExp(r'[\r\n|]'))) {
        final separator = line.indexOf('=');
        if (separator > 0) {
          properties[line.substring(0, separator).trim()] = line
              .substring(separator + 1)
              .trim();
        }
      }
    }
    properties['Vendor'] = 'Hamamatsu';
    properties['Compression'] = 'JPEG';
    properties['CompressionFormat'] = 'JPEG';
    final lens = number(65421);
    if (lens != null) {
      properties['SourceLens'] = '$lens';
      if (lens > 0) properties['AppMag'] = '$lens';
    }
    for (final entry in {
      65422: 'XOffsetFromSlideCentre',
      65423: 'YOffsetFromSlideCentre',
      65424: 'FocalPlane',
    }.entries) {
      final value = number(entry.key);
      if (value != null) properties[entry.value] = '$value';
    }
    for (final entry in {
      271: 'Make',
      272: 'Model',
      306: 'DateTime',
      65427: 'Reference',
    }.entries) {
      if (strings.containsKey(entry.key)) {
        properties[entry.value] = strings[entry.key]!;
      }
    }
    final unit = integer(296, 2);
    final microns = unit == 3 ? 10000.0 : (unit == 2 ? 25400.0 : null);
    if (microns != null) {
      final x = number(282);
      final y = number(283);
      if (x != null && x > 0 && x.isFinite) {
        properties['MPP'] = '${microns / x}';
        properties['MPP_X'] = properties['MPP']!;
      }
      if (y != null && y > 0 && y.isFinite) {
        properties['MPP_Y'] = '${microns / y}';
      }
    }
    return properties;
  }

  static Future<_NdpiDirectory> read(
    HamamatsuFile source,
    int offset,
    int length,
  ) async {
    final endian = source.endian;
    if (offset < 12 || offset > length - 2) {
      throw const FormatException('NDPI directory outside file');
    }
    final countData = await source.readBytesAt(offset, 2);
    if (countData.length != 2) {
      throw const FormatException('Truncated NDPI IFD');
    }
    final count = ByteData.sublistView(countData).getUint16(0, endian);
    final size = count * 16 + 8;
    if (count == 0 || offset + 2 + size > length) {
      throw const FormatException('Truncated NDPI directory extensions');
    }
    final bytes = await source.readBytesAt(offset + 2, size);
    if (bytes.length != size) throw const FormatException('Truncated NDPI IFD');
    final bd = ByteData.sublistView(bytes);
    final next = bd.getUint64(count * 12, endian);
    final values = <int, List<num>>{};
    final strings = <int, String>{};
    List<int>? restartLow;
    List<int>? restartHigh;
    const tags = {
      256,
      257,
      259,
      262,
      270,
      271,
      272,
      273,
      277,
      278,
      279,
      282,
      283,
      296,
      306,
      65420,
      65421,
      65422,
      65423,
      65424,
      65426,
      65427,
      65432,
      65449,
    };
    const sizes = {
      1: 1,
      2: 1,
      3: 2,
      4: 4,
      5: 8,
      6: 1,
      7: 1,
      8: 2,
      9: 4,
      10: 8,
      11: 4,
      12: 8,
      13: 4,
      16: 8,
      17: 8,
      18: 8,
    };
    for (var i = 0; i < count; i++) {
      final p = i * 12;
      final tag = bd.getUint16(p, endian);
      if (!tags.contains(tag)) continue;
      if (values.containsKey(tag) ||
          strings.containsKey(tag) ||
          (tag == 65426 && restartLow != null) ||
          (tag == 65432 && restartHigh != null)) {
        throw const FormatException('Duplicate NDPI tag');
      }
      var type = bd.getUint16(p + 2, endian);
      final items = bd.getUint32(p + 4, endian);
      var itemSize = sizes[type];
      if (itemSize == null ||
          items == 0 ||
          items * itemSize > 32 * 1024 * 1024) {
        throw const FormatException('Invalid NDPI tag type/count');
      }
      final extended = Uint8List(8)
        ..setRange(0, 4, bytes, p + 8)
        ..setRange(4, 8, bytes, count * 12 + 8 + i * 4);
      final value = ByteData.sublistView(extended);
      Uint8List payload;
      if (items * itemSize <= 4) {
        final extension = bd.getUint32(count * 12 + 8 + i * 4, endian);
        if (extension != 0) {
          if (items != 1 || (type != 4 && type != 9)) {
            throw const FormatException('Invalid NDPI inline value extension');
          }
          type = type == 4 ? 16 : 17;
          itemSize = 8;
        }
        payload = extended;
      } else {
        final position = value.getUint64(0, endian);
        final payloadSize = items * itemSize;
        if (position < 12 || position > length - payloadSize) {
          throw const FormatException('NDPI tag payload outside file');
        }
        payload = await source.readBytesAt(position, payloadSize);
        if (payload.length != payloadSize) {
          throw const FormatException('Truncated NDPI tag');
        }
      }
      if (type == 2) {
        final text = payload.sublist(0, items);
        final zero = text.indexOf(0);
        strings[tag] = utf8.decode(
          zero < 0 ? text : text.sublist(0, zero),
          allowMalformed: true,
        );
        continue;
      }
      final data = ByteData.sublistView(payload);
      num readNumber(int p) {
        switch (type) {
          case 1:
          case 7:
            return data.getUint8(p);
          case 6:
            return data.getInt8(p);
          case 3:
            return data.getUint16(p, endian);
          case 8:
            return data.getInt16(p, endian);
          case 4:
          case 13:
            return data.getUint32(p, endian);
          case 9:
            return data.getInt32(p, endian);
          case 16:
          case 18:
            return data.getUint64(p, endian);
          case 17:
            return data.getInt64(p, endian);
          case 11:
            return data.getFloat32(p, endian);
          case 12:
            return data.getFloat64(p, endian);
          case 5:
          case 10:
            final denominator = type == 5
                ? data.getUint32(p + 4, endian)
                : data.getInt32(p + 4, endian);
            if (denominator == 0) {
              throw const FormatException('Invalid NDPI rational');
            }
            final numerator = type == 5
                ? data.getUint32(p, endian)
                : data.getInt32(p, endian);
            return numerator / denominator;
          default:
            throw const FormatException('Unsupported NDPI tag type');
        }
      }

      final typed = _typedIntegers(data, type, items, itemSize, endian);
      if ((tag == 65426 || tag == 65432) && typed != null) {
        if (tag == 65426) {
          restartLow = typed;
        } else {
          restartHigh = typed;
        }
        continue;
      }
      values[tag] = typed?.cast<num>() ??
          [for (var n = 0; n < items; n++) readNumber(n * itemSize)];
    }
    return _NdpiDirectory(
      next,
      values,
      strings,
      restartLow: restartLow,
      restartHigh: restartHigh,
    );
  }
}

/// Unboxed integer payloads. Restart tables can hold hundreds of thousands of
/// offsets; a growable [List<num>] would box every one of them.
List<int>? _typedIntegers(
  ByteData data,
  int type,
  int items,
  int itemSize,
  Endian endian,
) {
  switch (type) {
    case 1:
    case 7:
      final out = Uint8List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getUint8(n * itemSize);
      }
      return out;
    case 6:
      final out = Int8List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getInt8(n * itemSize);
      }
      return out;
    case 3:
      final out = Uint16List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getUint16(n * itemSize, endian);
      }
      return out;
    case 8:
      final out = Int16List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getInt16(n * itemSize, endian);
      }
      return out;
    case 4:
    case 13:
      final out = Uint32List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getUint32(n * itemSize, endian);
      }
      return out;
    case 9:
      final out = Int32List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getInt32(n * itemSize, endian);
      }
      return out;
    case 16:
    case 18:
      final out = Uint64List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getUint64(n * itemSize, endian);
      }
      return out;
    case 17:
      final out = Int64List(items);
      for (var n = 0; n < items; n++) {
        out[n] = data.getInt64(n * itemSize, endian);
      }
      return out;
    default:
      return null;
  }
}
