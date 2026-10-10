import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:omnigisto_pkg/types/types.dart';

import 'slide.dart';

const _bufferSize = 64 * 1024;
const _maxHeaderBytes = 4 * 1024 * 1024;
const _maxSegmentBytes = 64 * 1024 * 1024;
const _maxImageBytes = 256 * 1024 * 1024;
const _maxImagePixels = 16 * 1024 * 1024;

/// A single-scan sequential JPEG whose restart intervals form horizontal tiles.
/// The source is borrowed: its lifetime is managed by the enclosing slide.
class HamamatsuJpeg extends HamamatsuRaster {
  final SvsFile _source;
  final int _offset;
  final int _end;
  final _JpegHeader _header;
  final List<int>? _providedOffsets;
  final List<int> _starts;
  final List<int> _ends = [];
  final _EntropyReader _reader;
  final int _columns;
  final int _rows;
  Future<void>? _indexing;
  FormatException? _indexError;
  int? _imageEnd;

  HamamatsuJpeg._(
    this._source,
    this._offset,
    this._end,
    this._header,
    this._providedOffsets,
    Map<String, String> properties,
  ) : _starts = [_offset + _header.bytes.length],
      _reader = _EntropyReader(
        _source,
        _offset + _header.bytes.length,
        _end,
        _header.interval == 0 ? _maxImageBytes : _maxSegmentBytes,
      ),
      _columns = (_header.width + _header.tileWidth - 1) ~/ _header.tileWidth,
      _rows = (_header.height + _header.tileHeight - 1) ~/ _header.tileHeight,
      super(
        width: _header.width,
        height: _header.height,
        tileWidth: _header.tileWidth,
        tileHeight: _header.tileHeight,
        compression: 'JPEG',
        properties: Map.unmodifiable(properties),
      );

  /// [restartOffsets] contains absolute starts of entropy segments, including
  /// the first (after SOS), and subsequent starts immediately after RST markers.
  /// Table shape/ranges are checked here; marker boundaries are checked lazily
  /// on access, so opening an indexed WSI does not seek through the entire file.
  static Future<HamamatsuJpeg> open(
    SvsFile source, {
    int offset = 0,
    int? length,
    int? width,
    int? height,
    Map<String, String> properties = const {},
    List<int>? restartOffsets,
  }) async {
    final fileLength = await source.synchronized(() => source.raf.length());
    if (offset < 0 || offset > fileLength) {
      throw const FormatException('JPEG offset outside source');
    }
    length ??= fileLength - offset;
    if (length < 4 || length > fileLength - offset) {
      throw const FormatException('Invalid or truncated JPEG range');
    }
    final end = offset + length;
    final header = await _JpegHeader.read(source, offset, end, width, height);
    final columns = (header.width + header.tileWidth - 1) ~/ header.tileWidth;
    final rows = (header.height + header.tileHeight - 1) ~/ header.tileHeight;
    final offsets = restartOffsets == null
        ? null
        : Int64List.fromList(restartOffsets);
    if (offsets != null) {
      if (offsets.length != columns * rows ||
          offsets.first != offset + header.bytes.length) {
        throw const FormatException(
          'Invalid JPEG restart offset table size/start',
        );
      }
      for (var i = 0; i < offsets.length; i++) {
        if (offsets[i] < offset + header.bytes.length ||
            offsets[i] >= end - 2 ||
            (i > 0 &&
                (offsets[i] - offsets[i - 1] < 3 ||
                    offsets[i] - offsets[i - 1] > _maxSegmentBytes))) {
          throw const FormatException(
            'Invalid JPEG restart offset range/order',
          );
        }
      }
    }
    return HamamatsuJpeg._(source, offset, end, header, offsets, properties);
  }

  @override
  bool containsTile(int x, int y) =>
      x >= 0 && y >= 0 && x < _columns && y < _rows;

  @override
  Future<Uint8List?> readTile(
    int x,
    int y, {
    CancellationToken? cancelToken,
  }) async {
    if (_source.isClosed) throw StateError('Cannot read from a closed SvsFile');
    if (!containsTile(x, y) || cancelToken?.isCancelled == true) return null;
    final index = y * _columns + x;
    final Uint8List entropy;
    if (_providedOffsets != null) {
      final indexed = await _indexedEntropy(index, index, cancelToken);
      if (indexed == null) return null;
      entropy = indexed;
    } else {
      if (!await _ensureIndexed(index, cancelToken)) return null;
      final count = _ends[index] - _starts[index];
      entropy = Uint8List(count);
      if (!await _copyBytes(
        _source,
        _starts[index],
        entropy,
        0,
        count,
        cancelToken,
      )) {
        return null;
      }
    }
    if (cancelToken?.isCancelled == true) return null;
    final bytes = Uint8List(_header.bytes.length + entropy.length + 2);
    bytes.setAll(0, _header.bytes);
    _patchDimensions(
      bytes,
      math.min(tileWidth, width - x * tileWidth),
      math.min(tileHeight, height - y * tileHeight),
    );
    bytes.setRange(_header.bytes.length, bytes.length - 2, entropy);
    bytes[bytes.length - 2] = 0xff;
    bytes[bytes.length - 1] = 0xd9;
    return bytes;
  }

  @override
  Future<Uint8List?> readContiguousJpeg(
    int startRow,
    int rowCount, {
    CancellationToken? cancelToken,
  }) async {
    if (_source.isClosed) throw StateError('Cannot read from a closed SvsFile');
    if (_columns != 1) return null;
    if (startRow < 0 || rowCount <= 0 || startRow >= _rows) return null;
    if (startRow % 8 != 0) return null;
    if (cancelToken?.isCancelled == true) return null;

    final endRow = math.min(_rows - 1, startRow + rowCount - 1);
    final actualRowCount = endRow - startRow + 1;

    final Uint8List entropy;
    if (_providedOffsets != null) {
      final indexed = await _indexedEntropy(startRow, endRow, cancelToken);
      if (indexed == null) return null;
      entropy = indexed;
    } else {
      if (!await _ensureIndexed(endRow, cancelToken)) return null;
      if (cancelToken?.isCancelled == true) return null;
      final startOffset = _starts[startRow];
      final count = _ends[endRow] - startOffset;
      if (count < 0) return null;
      entropy = Uint8List(count);
      if (!await _copyBytes(
        _source,
        startOffset,
        entropy,
        0,
        count,
        cancelToken,
      )) {
        return null;
      }
    }
    if (cancelToken?.isCancelled == true) return null;

    final bytes = Uint8List(_header.bytes.length + entropy.length + 2);
    bytes.setAll(0, _header.bytes);
    final patchedHeight = math.min(
      actualRowCount * tileHeight,
      height - startRow * tileHeight,
    );
    _patchDimensions(bytes, width, patchedHeight);
    bytes.setRange(_header.bytes.length, bytes.length - 2, entropy);
    bytes[bytes.length - 2] = 0xff;
    bytes[bytes.length - 1] = 0xd9;
    return bytes;
  }

  @override
  Future<Uint8List?> readImage() async {
    if (_source.isClosed) throw StateError('Cannot read from a closed SvsFile');
    _checkImageSize(width, height);
    if (_providedOffsets != null) {
      final size = _end - _offset;
      if (size < 2 || size > _maxImageBytes) {
        throw const FormatException('JPEG exceeds whole-image byte limit');
      }
      final bytes = Uint8List(size);
      if (!await _copyBytes(_source, _offset, bytes, 0, size, null)) {
        return null;
      }
      final eoi = bytes[size - 2] == 0xff && bytes[size - 1] == 0xd9
          ? size
          : _markerOffset(bytes, _header.bytes.length, 0xd9) + 2;
      final image = eoi == size ? bytes : Uint8List.sublistView(bytes, 0, eoi);
      _patchDimensions(image, width, height);
      return image;
    }
    await _ensureIndexed(_columns * _rows - 1, null);
    final size = _imageEnd! - _offset;
    if (size > _maxImageBytes) {
      throw const FormatException('JPEG exceeds whole-image byte limit');
    }
    final bytes = Uint8List(size);
    await _copyBytes(_source, _offset, bytes, 0, size, null);
    _patchDimensions(bytes, width, height);
    return bytes;
  }

  void _patchDimensions(Uint8List bytes, int width, int height) {
    final data = ByteData.sublistView(bytes);
    data.setUint16(_header.dimensionsOffset, height);
    data.setUint16(_header.dimensionsOffset + 2, width);
  }

  /// Reads entropy for restart tiles [startIndex]..[endIndex] in one I/O.
  /// Marker bytes are checked in memory; the offset table already gives the
  /// boundaries, so the segment body is not scanned through the file.
  Future<Uint8List?> _indexedEntropy(
    int startIndex,
    int endIndex,
    CancellationToken? token,
  ) async {
    final offsets = _providedOffsets!;
    final start = offsets[startIndex];
    final last = endIndex + 1 == offsets.length;
    final lead = startIndex > 0 ? 2 : 0;
    final readStart = start - lead;
    final readEnd = last ? _end : offsets[endIndex + 1];
    if (readEnd < readStart) {
      throw const FormatException(
        'Invalid JPEG entropy/RST sequence or segment count',
      );
    }
    final count = readEnd - readStart;
    final limit = endIndex == startIndex
        ? (_header.interval == 0 ? _maxImageBytes : _maxSegmentBytes)
        : _maxImageBytes;
    if (count < 2 || count > limit) {
      throw const FormatException('JPEG entropy segment exceeds byte limit');
    }
    final raw = Uint8List(count);
    if (!await _copyBytes(_source, readStart, raw, 0, count, token)) {
      return null;
    }
    if (token?.isCancelled == true) return null;
    if (lead == 2 &&
        (raw[0] != 0xff || raw[1] != 0xd0 + ((startIndex - 1) % 8))) {
      throw const FormatException('JPEG restart offset does not follow RST');
    }
    if (!last) {
      if (raw[count - 2] != 0xff || raw[count - 1] != 0xd0 + (endIndex % 8)) {
        throw const FormatException(
          'JPEG restart offset does not match entropy boundary',
        );
      }
      return Uint8List.sublistView(raw, lead, count - 2);
    }
    final marker = raw[count - 2] == 0xff && raw[count - 1] == 0xd9
        ? count - 2
        : _markerOffset(raw, lead, 0xd9);
    if (marker < lead) {
      throw const FormatException(
        'Invalid JPEG entropy/RST sequence or segment count',
      );
    }
    return Uint8List.sublistView(raw, lead, marker);
  }

  void _validateMarker(int index, int start, _Marker marker) {
    final last = index == _columns * _rows - 1;
    if (marker.start <= start ||
        marker.code != (last ? 0xd9 : 0xd0 + (index % 8))) {
      throw const FormatException(
        'Invalid JPEG entropy/RST sequence or segment count',
      );
    }
    if (_providedOffsets != null &&
        !last &&
        marker.end != _providedOffsets[index + 1]) {
      throw const FormatException(
        'JPEG restart offset does not match entropy boundary',
      );
    }
  }

  Future<bool> _ensureIndexed(int index, CancellationToken? token) async {
    while (_ends.length <= index) {
      if (token?.isCancelled == true) return false;
      if (_indexError != null) throw _indexError!;
      final active = _indexing;
      if (active != null) {
        await _waitForIndex(active, token);
        continue;
      }
      final scan = _scanThrough(index, token);
      _indexing = scan;
      try {
        await scan;
      } on FormatException catch (error) {
        _indexError = error;
        rethrow;
      } finally {
        _indexing = null;
      }
    }
    return token?.isCancelled != true;
  }

  Future<void> _scanThrough(int index, CancellationToken? token) async {
    while (_ends.length <= index) {
      final marker = await _reader.nextMarker(token);
      if (marker == null) return;
      final current = _ends.length;
      _validateMarker(current, _starts[current], marker);
      _ends.add(marker.start);
      if (marker.code == 0xd9) {
        _imageEnd = marker.end;
      } else {
        _starts.add(marker.end);
      }
    }
  }
}

Future<void> _waitForIndex(
  Future<void> active,
  CancellationToken? token,
) async {
  if (token == null) return active;
  final cancelled = Completer<void>();
  void onCancel() => cancelled.complete();
  token.addListener(onCancel);
  try {
    await Future.any([active, cancelled.future]);
  } finally {
    token.removeListener(onCancel);
  }
}

void _checkImageSize(int width, int height) {
  if (width > 65535 || height > 65535 || width > _maxImagePixels ~/ height) {
    throw const FormatException(
      'JPEG is too large for non-random-access decoding (16M pixel limit)',
    );
  }
}

Future<bool> _copyBytes(
  SvsFile source,
  int start,
  Uint8List output,
  int outputOffset,
  int count,
  CancellationToken? token,
) async {
  if (count <= 0) return true;
  if (token?.isCancelled == true) return false;
  // Tile and strip ranges are one read. Chunk only past 8 MiB so a cancelled
  // whole-image copy can still stop between chunks.
  const chunkSize = 8 * 1024 * 1024;
  for (var copied = 0; copied < count;) {
    if (token?.isCancelled == true) return false;
    final size = math.min(chunkSize, count - copied);
    final chunk = await source.readBytesAt(
      start + copied,
      size,
      cancelToken: token,
    );
    if (token?.isCancelled == true) return false;
    if (chunk.length != size) {
      throw const FormatException('Truncated JPEG data');
    }
    output.setRange(outputOffset + copied, outputOffset + copied + size, chunk);
    copied += size;
  }
  return true;
}

/// Offset of [code] in entropy, treating stuffed `FF 00` as data.
int _markerOffset(Uint8List raw, int from, int code) {
  int? ff;
  for (var i = from; i < raw.length; i++) {
    final value = raw[i];
    if (ff == null) {
      if (value == 0xff) ff = i;
    } else if (value == 0) {
      if (i != ff + 1) {
        throw const FormatException('Invalid JPEG entropy byte stuffing');
      }
      ff = null;
    } else if (value != 0xff) {
      if (value == code) return ff;
      throw const FormatException(
        'Invalid JPEG entropy/RST sequence or segment count',
      );
    }
  }
  throw const FormatException(
    'Invalid JPEG entropy/RST sequence or segment count',
  );
}

class _Marker {
  final int start;
  final int end;
  final int code;

  _Marker(this.start, this.end, this.code);
}

/// Keeps only one I/O buffer and resumable marker state, never entropy payloads.
class _EntropyReader {
  final SvsFile source;
  final int end;
  final int maxSegmentBytes;
  int _position;
  int _segmentStart;
  int? _ffStart;
  Uint8List _buffer = Uint8List(0);
  int _cursor = 0;

  _EntropyReader(this.source, int start, this.end, this.maxSegmentBytes)
    : _position = start,
      _segmentStart = start;

  Future<_Marker?> nextMarker(CancellationToken? token) async {
    while (true) {
      if (token?.isCancelled == true) return null;
      if (_cursor == _buffer.length) {
        if (_position >= end) {
          throw const FormatException('Truncated JPEG entropy');
        }
        final size = math.min(_bufferSize, end - _position);
        final chunk = await source.readBytesAt(
          _position,
          size,
          cancelToken: token,
        );
        if (token?.isCancelled == true) return null;
        if (chunk.length != size) {
          throw const FormatException('Truncated JPEG entropy');
        }
        _buffer = chunk;
        _cursor = 0;
      }
      while (_cursor < _buffer.length) {
        final value = _buffer[_cursor++];
        final position = _position++;
        if (_position - _segmentStart > maxSegmentBytes) {
          throw const FormatException(
            'JPEG entropy segment exceeds byte limit',
          );
        }
        if (_ffStart == null) {
          if (value == 0xff) _ffStart = position;
        } else if (value == 0) {
          if (position != _ffStart! + 1) {
            throw const FormatException('Invalid JPEG entropy byte stuffing');
          }
          _ffStart = null;
        } else if (value != 0xff) {
          final marker = _Marker(_ffStart!, _position, value);
          _ffStart = null;
          _segmentStart = _position;
          return marker;
        }
      }
    }
  }
}

class _JpegHeader {
  final Uint8List bytes;
  final int dimensionsOffset;
  final int width;
  final int height;
  final int interval;
  final int tileWidth;
  final int tileHeight;

  _JpegHeader(
    this.bytes,
    this.dimensionsOffset,
    this.width,
    this.height,
    this.interval,
    this.tileWidth,
    this.tileHeight,
  );

  static Future<_JpegHeader> read(
    SvsFile source,
    int offset,
    int end,
    int? width,
    int? height,
  ) async {
    final output = BytesBuilder(copy: false);
    var position = offset;
    Future<Uint8List> take(int count) async {
      if (count > end - position || output.length + count > _maxHeaderBytes) {
        throw const FormatException('Truncated or oversized JPEG header');
      }
      final bytes = Uint8List(count);
      await _copyBytes(source, position, bytes, 0, count, null);
      position += count;
      output.add(bytes);
      return bytes;
    }

    final soi = await take(2);
    if (soi[0] != 0xff || soi[1] != 0xd8) {
      throw const FormatException('Missing JPEG SOI');
    }
    var dimensionsOffset = -1;
    var frameMarker = 0;
    var interval = 0;
    var hasDri = false;
    var maxH = 1;
    var maxV = 1;
    var hasWideQuantizer = false;
    final components = <int, (int, int, int)>{};
    final quantizers = <int>{};
    final huffman = <int>{};
    while (true) {
      if ((await take(1))[0] != 0xff) {
        throw const FormatException('Missing JPEG header marker');
      }
      var marker = (await take(1))[0];
      while (marker == 0xff) {
        marker = (await take(1))[0];
      }
      if (!(marker == 0xc0 ||
          marker == 0xc1 ||
          marker == 0xc4 ||
          marker == 0xdb ||
          marker == 0xdd ||
          marker == 0xda ||
          marker == 0xfe ||
          (marker >= 0xe0 && marker <= 0xef))) {
        throw FormatException(
          'Unsupported JPEG marker 0x${marker.toRadixString(16)}',
        );
      }
      final sizeBytes = await take(2);
      final size = (sizeBytes[0] << 8) | sizeBytes[1];
      if (size < 2) throw const FormatException('Invalid JPEG marker length');
      final payloadOffset = output.length;
      final data = await take(size - 2);
      int uint16(int p) => (data[p] << 8) | data[p + 1];
      switch (marker) {
        case 0xc0:
        case 0xc1:
          if (dimensionsOffset >= 0 ||
              data.length < 6 ||
              data[0] != 8 ||
              (data[5] != 1 && data[5] != 3) ||
              data.length != 6 + 3 * data[5]) {
            throw const FormatException('Unsupported or malformed JPEG SOF');
          }
          frameMarker = marker;
          dimensionsOffset = payloadOffset + 1;
          width ??= uint16(3);
          height ??= uint16(1);
          if (width <= 0 ||
              height <= 0 ||
              width > 0x7fffffff ||
              height > 0x7fffffff) {
            throw const FormatException(
              'Invalid JPEG dimensions; zero SOF needs overrides',
            );
          }
          var blocks = 0;
          for (var p = 6; p < data.length; p += 3) {
            final h = data[p + 1] >> 4;
            final v = data[p + 1] & 15;
            final q = data[p + 2];
            if (components.containsKey(data[p]) ||
                h < 1 ||
                h > 4 ||
                v < 1 ||
                v > 4 ||
                q > 3) {
              throw const FormatException(
                'Invalid JPEG component sampling/table',
              );
            }
            components[data[p]] = (h, v, q);
            maxH = math.max(maxH, h);
            maxV = math.max(maxV, v);
            blocks += h * v;
          }
          if (blocks > 10 ||
              (components.length == 1 && blocks != 1) ||
              components.values.any(
                (c) => maxH % c.$1 != 0 || maxV % c.$2 != 0,
              )) {
            throw const FormatException('Unsupported JPEG sampling');
          }
        case 0xdd:
          if (hasDri || data.length != 2) {
            throw const FormatException('Malformed JPEG DRI');
          }
          hasDri = true;
          interval = uint16(0);
        case 0xdb:
          if (data.isEmpty) throw const FormatException('Empty JPEG DQT');
          for (var p = 0; p < data.length;) {
            final descriptor = data[p++];
            final precision = descriptor >> 4;
            final id = descriptor & 15;
            final size = precision == 0 ? 64 : 128;
            if (precision > 1 || id > 3 || p + size > data.length) {
              throw const FormatException('Invalid JPEG DQT');
            }
            hasWideQuantizer |= precision == 1;
            for (var q = p; q < p + size; q += precision + 1) {
              if ((precision == 0 ? data[q] : uint16(q)) == 0) {
                throw const FormatException('Zero JPEG quantizer');
              }
            }
            quantizers.add(id);
            p += size;
          }
        case 0xc4:
          if (data.isEmpty) throw const FormatException('Empty JPEG DHT');
          for (var p = 0; p < data.length;) {
            final descriptor = data[p++];
            final type = descriptor >> 4;
            final id = descriptor & 15;
            if (type > 1 || id > 3 || p + 16 > data.length) {
              throw const FormatException('Invalid JPEG DHT');
            }
            var count = 0;
            var available = 1;
            for (var i = 0; i < 16; i++) {
              final n = data[p++];
              count += n;
              available = available * 2 - n;
              if (available <= 0) {
                throw const FormatException('Invalid JPEG Huffman tree');
              }
            }
            if (count == 0 || count > 256 || p + count > data.length) {
              throw const FormatException('Invalid JPEG Huffman symbols');
            }
            for (var i = 0; i < count; i++) {
              final symbol = data[p++];
              if ((type == 0 && symbol > 11) ||
                  (type == 1 &&
                      ((symbol & 15) > 10 ||
                          ((symbol & 15) == 0 &&
                              symbol != 0 &&
                              symbol != 0xf0)))) {
                throw const FormatException('Unsupported JPEG Huffman symbol');
              }
            }
            huffman.add(type * 4 + id);
          }
        case 0xda:
          if (dimensionsOffset < 0 ||
              data.isEmpty ||
              data[0] != components.length ||
              data.length != 4 + 2 * data[0] ||
              data[data.length - 3] != 0 ||
              data[data.length - 2] != 63 ||
              data.last != 0 ||
              (frameMarker == 0xc0 && hasWideQuantizer)) {
            throw const FormatException('Unsupported or malformed JPEG SOS');
          }
          final seen = <int>{};
          for (var p = 1; p < data.length - 3; p += 2) {
            final component = components[data[p]];
            final dc = data[p + 1] >> 4;
            final ac = data[p + 1] & 15;
            if (component == null ||
                !seen.add(data[p]) ||
                dc > 3 ||
                ac > 3 ||
                !quantizers.contains(component.$3) ||
                !huffman.contains(dc) ||
                !huffman.contains(4 + ac)) {
              throw const FormatException('Invalid JPEG scan component/tables');
            }
          }
          final mcuWidth = maxH * 8;
          final mcuHeight = maxV * 8;
          final mcusPerRow = (width! + mcuWidth - 1) ~/ mcuWidth;
          if (interval == 0) {
            _checkImageSize(width, height!);
          } else if (mcusPerRow % interval != 0 ||
              interval * mcuWidth > 65535) {
            throw const FormatException(
              'JPEG restart interval crosses a row or exceeds tile width limit',
            );
          }
          if (position >= end - 2) {
            throw const FormatException('Missing JPEG entropy');
          }
          return _JpegHeader(
            output.takeBytes(),
            dimensionsOffset,
            width,
            height!,
            interval,
            interval == 0 ? width : interval * mcuWidth,
            interval == 0 ? height : mcuHeight,
          );
      }
    }
  }
}
