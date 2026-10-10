import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:omnigisto_pkg/types/types.dart';

import 'jpeg.dart';
import 'slide.dart';

const _vmsGroup = 'Virtual Microscope Specimen';
const _vmuGroup = 'Uncompressed Virtual Microscope Specimen';
const _maxIniBytes = 1024 * 1024;
const _maxPixels = 16 * 1024 * 1024;
const _ngrTileHeight = 64;

/// Opens a VMS/VMU set, borrowing [raf] until ownership transfers on success.
Future<HamamatsuFile> openHamamatsuSet(
  RandomAccessFile raf,
  String path,
  int maxConcurrency, {
  bool? virtualTiling,
  int? virtualTileWidth,
  int? virtualTileHeight,
  int? mcuRowsPerTile,
}) async {
  final (uncompressed, entries) = await _readIni(raf);
  final columns = uncompressed ? 1 : _positiveInt(entries['NoJpegColumns']);
  final rows = uncompressed ? 1 : _positiveInt(entries['NoJpegRows']);
  if (uncompressed &&
      (entries['BitsPerPixel'] != '36' || entries['PixelOrder'] != 'RGB')) {
    throw const FormatException('Only 36-bit RGB VMU images are supported');
  }
  // Bound the grid by the number of keys before multiplying or allocating it.
  if (columns > entries.length ||
      rows > entries.length ||
      columns * rows > entries.length) {
    throw const FormatException('Missing ImageFile entries');
  }
  final images = <(int, int), String>{};
  final indexPattern = RegExp(r'^ImageFile\((\d+(?:\s*,\s*\d+){0,2})\)$');
  for (final entry in entries.entries) {
    if (!entry.key.startsWith('ImageFile')) continue;
    var plane = 0;
    var x = 0;
    var y = 0;
    if (entry.key != 'ImageFile') {
      final match = indexPattern.firstMatch(entry.key);
      if (match == null) {
        throw FormatException('Malformed image indices: ${entry.key}');
      }
      final indices = match[1]!.split(',').map((s) {
        final value = int.tryParse(s.trim());
        if (value == null || value > 0x7fffffff) {
          throw const FormatException('Invalid image index');
        }
        return value;
      }).toList();
      if (indices.length != 2) plane = indices.first;
      if (indices.length >= 2) {
        x = indices[indices.length - 2];
        y = indices.last;
      }
    }
    if (plane != 0) continue;
    if (x >= columns || y >= rows || images.containsKey((x, y))) {
      throw const FormatException('Invalid or duplicate ImageFile coordinates');
    }
    images[(x, y)] = _sidecarPath(path, entry.value);
  }
  if (images.length != columns * rows) {
    throw const FormatException('Incomplete ImageFile grid');
  }
  final mapPath = _sidecarPath(path, entries['MapFile']);
  final macro = entries['MacroImage'];
  final macroPath = macro == null || macro.isEmpty
      ? null
      : _sidecarPath(path, macro);
  final slide = HamamatsuFile(raf, Endian.little, 0, path, maxConcurrency);
  Future<SvsFile> sourceFor(String sourcePath) async {
    final source = SvsFile(
      await File(sourcePath).open(),
      Endian.little,
      0,
      false,
      sourcePath,
      maxConcurrency,
    );
    slide.sources.add(source);
    return source;
  }

  try {
    final HamamatsuRaster baseline;
    final HamamatsuRaster map;
    if (uncompressed) {
      baseline = await _NgrRaster.open(
        await sourceFor(images[(0, 0)]!),
        entries,
      );
      map = await _NgrRaster.open(await sourceFor(mapPath), entries);
    } else {
      final jpegs = <HamamatsuJpeg>[];
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < columns; x++) {
          jpegs.add(await HamamatsuJpeg.open(await sourceFor(images[(x, y)]!)));
        }
      }
      baseline = _JpegMosaic.create(jpegs, columns, rows, entries);
      map = await HamamatsuJpeg.open(
        await sourceFor(mapPath),
        properties: baseline.properties,
      );
    }
    if (map.width > baseline.width || map.height > baseline.height) {
      throw const FormatException('MapFile is not a reduced image');
    }
    slide.levels.addAll([baseline, map]);
    if (virtualTiling == true ||
        virtualTileWidth != null ||
        virtualTileHeight != null ||
        mcuRowsPerTile != null) {
      slide.enableVirtualTiling(
        virtualTileWidth: virtualTileWidth,
        virtualTileHeight: virtualTileHeight,
        mcuRowsPerTile: mcuRowsPerTile,
      );
    }
    slide.associations['thumbnail'] = map;
    if (macroPath != null) {
      slide.associations['macro'] = await HamamatsuJpeg.open(
        await sourceFor(macroPath),
        properties: {...entries, 'Vendor': 'Hamamatsu', 'Compression': 'JPEG'},
      );
    }
    return slide;
  } catch (_) {
    // The caller still owns the primary RAF on failure.
    await Future.wait(slide.sources.map((source) => source.close()));
    rethrow;
  }
}

Future<(bool, Map<String, String>)> _readIni(RandomAccessFile raf) async {
  final size = await raf.length();
  if (size <= 0 || size > _maxIniBytes) {
    throw const FormatException('Not a bounded VMS/VMU key file');
  }
  await raf.setPosition(0);
  final bytes = await raf.read(size);
  if (bytes.length != size) throw const FormatException('Truncated key file');
  var text = utf8.decode(bytes);
  if (text.startsWith('\ufeff')) text = text.substring(1);
  if (text.contains('\u0000')) throw const FormatException('Binary key file');
  final groups = <String, Map<String, String>>{};
  Map<String, String>? current;
  final sectionPattern = RegExp(r'^\[([^\]]+)\]\s*(?:[;#].*)?$');
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    if (line.startsWith('[')) {
      final section = sectionPattern.firstMatch(line);
      if (section == null) throw const FormatException('Malformed INI section');
      current = groups.putIfAbsent(section[1]!.trim(), () => {});
      continue;
    }
    final equals = line.indexOf('=');
    if (current == null || equals <= 0) {
      throw const FormatException('Malformed INI entry');
    }
    final key = line.substring(0, equals).trim();
    if (current.containsKey(key)) {
      throw FormatException('Duplicate INI key: $key');
    }
    current[key] = line.substring(equals + 1).trim();
  }
  if (groups.containsKey(_vmsGroup) == groups.containsKey(_vmuGroup)) {
    throw const FormatException('Not an unambiguous VMS/VMU set');
  }
  final uncompressed = groups.containsKey(_vmuGroup);
  return (uncompressed, groups[uncompressed ? _vmuGroup : _vmsGroup]!);
}

int _positiveInt(String? text) {
  final value = text == null ? null : int.tryParse(text);
  if (value == null || value <= 0 || value > 0x7fffffff) {
    throw const FormatException('Missing or invalid positive integer');
  }
  return value;
}

String _sidecarPath(String path, String? value) {
  if (value == null || value.isEmpty) {
    throw const FormatException('Missing sidecar filename');
  }
  final normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    throw const FormatException('Sidecar filename must be relative');
  }
  return File.fromUri(
    File(path).absolute.parent.uri.resolveUri(Uri.file(normalized)),
  ).path;
}

Map<String, String> _properties(
  Map<String, String> entries,
  int width,
  int height,
  String compression,
) {
  final result = {
    ...entries,
    'Vendor': 'Hamamatsu',
    'Compression': compression,
  };
  for (final (key, pixels, property) in [
    ('PhysicalWidth', width, 'MPP_X'),
    ('PhysicalHeight', height, 'MPP_Y'),
  ]) {
    final physical = double.tryParse(entries[key] ?? '');
    if (physical != null && physical.isFinite && physical > 0) {
      result[property] = (physical / (pixels * 1000)).toString();
    }
  }
  if (result.containsKey('MPP_X')) result['MPP'] = result['MPP_X']!;
  final lens = double.tryParse(entries['SourceLens'] ?? '');
  if (lens != null && lens.isFinite && lens > 0) {
    result['AppMag'] = entries['SourceLens']!;
  }
  return result;
}

class _JpegMosaic extends HamamatsuRaster {
  final List<HamamatsuJpeg> _images;
  final List<int> _columnStarts;
  final List<int> _rowStarts;

  _JpegMosaic._(
    this._images,
    this._columnStarts,
    this._rowStarts,
    int width,
    int height,
    Map<String, String> properties,
  ) : super(
        width: width,
        height: height,
        tileWidth: _images.first.tileWidth,
        tileHeight: _images.first.tileHeight,
        compression: 'JPEG',
        properties: Map.unmodifiable(properties),
      );

  factory _JpegMosaic.create(
    List<HamamatsuJpeg> images,
    int columns,
    int rows,
    Map<String, String> entries,
  ) {
    final tileWidth = images.first.tileWidth;
    final tileHeight = images.first.tileHeight;
    final columnStarts = <int>[];
    final rowStarts = <int>[];
    var width = 0;
    var height = 0;
    for (var x = 0; x < columns; x++) {
      columnStarts.add(width ~/ tileWidth);
      width += images[x].width;
      if (x < columns - 1 && width % tileWidth != 0) {
        throw const FormatException('Interior JPEG column is not tile aligned');
      }
    }
    for (var y = 0; y < rows; y++) {
      rowStarts.add(height ~/ tileHeight);
      height += images[y * columns].height;
      if (y < rows - 1 && height % tileHeight != 0) {
        throw const FormatException('Interior JPEG row is not tile aligned');
      }
      for (var x = 0; x < columns; x++) {
        final image = images[y * columns + x];
        if (image.width != images[x].width ||
            image.height != images[y * columns].height ||
            !_compatibleTile(image.tileWidth, image.width, tileWidth) ||
            !_compatibleTile(image.tileHeight, image.height, tileHeight)) {
          throw const FormatException('Incompatible JPEG mosaic dimensions');
        }
      }
    }
    return _JpegMosaic._(
      images,
      columnStarts,
      rowStarts,
      width,
      height,
      _properties(entries, width, height, 'JPEG'),
    );
  }

  static bool _compatibleTile(int local, int size, int global) =>
      local == global || (local == size && size <= global);

  static int _locate(List<int> starts, int tile) {
    var low = 0;
    var high = starts.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (starts[middle] <= tile) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  @override
  bool containsTile(int x, int y) =>
      x >= 0 &&
      y >= 0 &&
      x < (width + tileWidth - 1) ~/ tileWidth &&
      y < (height + tileHeight - 1) ~/ tileHeight;

  @override
  Future<Uint8List?> readTile(
    int x,
    int y, {
    CancellationToken? cancelToken,
  }) async {
    if (!containsTile(x, y) || cancelToken?.isCancelled == true) return null;
    final column = _locate(_columnStarts, x);
    final row = _locate(_rowStarts, y);
    return _images[row * _columnStarts.length + column].readTile(
      x - _columnStarts[column],
      y - _rowStarts[row],
      cancelToken: cancelToken,
    );
  }

  // A mosaic is only a tiled level; whole-image associations use their source.
  @override
  Future<Uint8List?> readImage() async => null;
}

class _NgrRaster extends HamamatsuRaster {
  final SvsFile _source;
  final int _start;

  _NgrRaster._(
    this._source,
    this._start,
    int width,
    int height,
    int columnWidth,
    Map<String, String> entries,
  ) : super(
        width: width,
        height: height,
        tileWidth: columnWidth,
        tileHeight: _ngrTileHeight,
        compression: 'Uncompressed',
        properties: Map.unmodifiable(
          _properties(entries, width, height, 'Uncompressed'),
        ),
      );

  static Future<_NgrRaster> open(
    SvsFile source,
    Map<String, String> entries,
  ) async {
    final bytes = await source.readBytesAt(0, 28);
    if (bytes.length != 28 || bytes[0] != 0x47 || bytes[1] != 0x4e) {
      throw const FormatException('Invalid NGR header');
    }
    final data = ByteData.sublistView(bytes);
    final width = data.getInt32(4, Endian.little);
    final height = data.getInt32(8, Endian.little);
    final columnWidth = data.getInt32(12, Endian.little);
    final start = data.getInt32(24, Endian.little);
    final length = await source.synchronized(() => source.raf.length());
    if (width <= 0 ||
        height <= 0 ||
        columnWidth <= 0 ||
        width % columnWidth != 0 ||
        start < 28 ||
        start > length ||
        (length - start) ~/ 6 ~/ height < width) {
      throw const FormatException(
        'Invalid NGR dimensions or truncated payload',
      );
    }
    return _NgrRaster._(source, start, width, height, columnWidth, entries);
  }

  void _ensureOpen() {
    if (_source.isClosed) throw StateError('Cannot read from a closed SvsFile');
  }

  @override
  bool containsTile(int x, int y) =>
      x >= 0 &&
      y >= 0 &&
      x < width ~/ tileWidth &&
      y < (height + tileHeight - 1) ~/ tileHeight;

  @override
  Future<Uint8List?> readTile(
    int x,
    int y, {
    CancellationToken? cancelToken,
  }) async {
    _ensureOpen();
    if (!containsTile(x, y) || cancelToken?.isCancelled == true) return null;
    final h = math.min(tileHeight, height - y * tileHeight);
    if (tileWidth > _maxPixels ~/ h) {
      throw const FormatException('NGR tile exceeds pixel limit');
    }
    final offset = _start + (x * height + y * tileHeight) * tileWidth * 6;
    final output = Uint8List(tileWidth * h * 3);
    for (var component = 0; component < output.length;) {
      if (cancelToken?.isCancelled == true) return null;
      final count = math.min(32 * 1024, output.length - component);
      final bytes = await _source.readBytesAt(
        offset + component * 2,
        count * 2,
        cancelToken: cancelToken,
      );
      if (cancelToken?.isCancelled == true) return null;
      if (bytes.length != count * 2) {
        throw const FormatException('Truncated NGR tile');
      }
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < count; i++) {
        final sample = data.getUint16(i * 2, Endian.little);
        if (sample > 0xfff) {
          throw const FormatException('Invalid 12-bit sample');
        }
        output[component + i] = sample >> 4;
      }
      component += count;
    }
    return output;
  }

  @override
  Future<img.Image?> readTileImage(
    int x,
    int y, {
    bool applyColorScheme = true,
    CancellationToken? cancelToken,
  }) async {
    final bytes = await readTile(x, y, cancelToken: cancelToken);
    if (bytes == null || cancelToken?.isCancelled == true) return null;
    return _decode(
      bytes,
      tileWidth,
      math.min(tileHeight, height - y * tileHeight),
    );
  }

  @override
  Future<Uint8List?> readImage() async {
    _ensureOpen();
    if (width > _maxPixels ~/ height) {
      throw const FormatException('NGR image exceeds whole-image pixel limit');
    }
    final output = Uint8List(width * height * 3);
    for (var x = 0; x < width ~/ tileWidth; x++) {
      for (var y = 0; y < (height + tileHeight - 1) ~/ tileHeight; y++) {
        final tile = (await readTile(x, y))!;
        final rowBytes = tileWidth * 3;
        for (var row = 0; row < tile.length ~/ rowBytes; row++) {
          final dest = ((y * tileHeight + row) * width + x * tileWidth) * 3;
          output.setRange(dest, dest + rowBytes, tile, row * rowBytes);
        }
      }
    }
    return output;
  }

  @override
  Future<img.Image?> readImageDecoded({bool applyColorScheme = true}) async {
    final bytes = await readImage();
    return bytes == null ? null : _decode(bytes, width, height);
  }

  static img.Image _decode(Uint8List bytes, int width, int height) =>
      img.Image.fromBytes(
        width: width,
        height: height,
        bytes: bytes.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
}
