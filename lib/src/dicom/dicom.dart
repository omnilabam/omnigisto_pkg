import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import '../jpeg2000/jpeg2000.dart';

import '../../types/types.dart';

const int _dicomWindow = 1024 * 1024;
const int _maxInlineValue = 64 * 1024;
const int _maxBulkValue = 64 * 1024 * 1024;

const Set<String> _longVrs = {
  'OB',
  'OW',
  'OF',
  'SQ',
  'UT',
  'UN',
  'OD',
  'OL',
  'OV',
  'SV',
  'UC',
  'UR',
};

/// Represents an open DICOM file handle and metadata parsed from its header.
class DicomFile {
  final RandomAccessFile raf;
  final Endian endian;
  final Map<int, dynamic> tags;
  final List<int> basicOffsetTable;
  final List<int> extendedOffsetTable;
  final List<int> extendedOffsetTableLengths;
  final int firstFragmentOffset;
  final bool isEncapsulated;
  final String transferSyntax;
  final int pixelDataLength;

  final String? filePath;

  /// Byte offset added to Extended Offset Table values.
  ///
  /// DICOM measures those values from the first byte of the Basic Offset Table
  /// item. Some files (and the synthetic fixtures) measure them from the first
  /// fragment item instead. The base is chosen by checking which candidate
  /// lands on a fragment item tag.
  final int _extendedOffsetBase;
  final List<({int colPos, int rowPos})>? perFramePositions;

  final int _maxConcurrency;
  int _effectiveMaxConcurrency;
  bool _isClosed = false;

  final List<RandomAccessFile> _allHandles = [];
  final List<RandomAccessFile> _availableHandles = [];
  final List<RandomAccessFile> _busyHandles = [];
  final List<Completer<RandomAccessFile?>> _waiters = [];

  Uint64List _fragmentOffsets = Uint64List(0);
  Uint32List _fragmentLengths = Uint32List(0);
  bool _fragmentIndexComplete = false;
  Future<void>? _fragmentIndexFuture;

  DicomFile(
    this.raf,
    this.endian,
    this.tags,
    this.basicOffsetTable,
    this.firstFragmentOffset,
    this.isEncapsulated,
    this.transferSyntax,
    this.pixelDataLength, [
    this.filePath,
    int maxConcurrency = 4,
    List<int>? extendedOffsetTable,
    List<int>? extendedOffsetTableLengths,
    int? extendedOffsetBase,
    this.perFramePositions,
  ])  : extendedOffsetTable = extendedOffsetTable ??
            (tags[DicomTag.extendedOffsetTable] is List<int>
                ? tags[DicomTag.extendedOffsetTable] as List<int>
                : const []),
        extendedOffsetTableLengths = extendedOffsetTableLengths ??
            (tags[DicomTag.extendedOffsetTableLengths] is List<int>
                ? tags[DicomTag.extendedOffsetTableLengths] as List<int>
                : const []),
        _extendedOffsetBase = extendedOffsetBase ?? firstFragmentOffset,
        _maxConcurrency = maxConcurrency < 1 ? 1 : maxConcurrency,
        _effectiveMaxConcurrency = maxConcurrency < 1 ? 1 : maxConcurrency {
    _allHandles.add(raf);
    _availableHandles.add(raf);
  }

  /// Maximum number of file handles used for parallel reads.
  int get maxConcurrency => _maxConcurrency;

  Future<int?> getFrameOffset(int frameIndex, {CancellationToken? cancelToken}) async {
    final located = await _locateFrame(frameIndex, cancelToken: cancelToken);
    return located?.itemOffset;
  }

  Future<Uint8List?> _readFrame(int frameIndex, {CancellationToken? cancelToken}) async {
    final located = await _locateFrame(frameIndex, cancelToken: cancelToken);
    if (located == null || cancelToken?.isCancelled == true) return null;

    if (located.directPayload && located.payloadLength != null) {
      if (located.payloadLength! <= 0) return Uint8List(0);
      return readBytesAt(located.itemOffset + 8, located.payloadLength!, cancelToken: cancelToken);
    }

    final next = located.nextItemOffset;
    if (next != null && next > located.itemOffset) {
      final raw = await readBytesAt(located.itemOffset, next - located.itemOffset, cancelToken: cancelToken);
      if (cancelToken?.isCancelled == true) return null;
      return _concatFragments(raw, endian, payloadLimit: located.payloadLength);
    }

    if (located.payloadLength != null) {
      return _readFrameByLength(located.itemOffset, located.payloadLength!, cancelToken);
    }

    final head = await readBytesAt(located.itemOffset, 8, cancelToken: cancelToken);
    if (head.length < 8 || cancelToken?.isCancelled == true) return null;
    final bd = ByteData.sublistView(head);
    if (bd.getUint16(0, endian) != 0xFFFE || bd.getUint16(2, endian) != 0xE000) return null;
    final len = bd.getUint32(4, endian);
    if (len == 0xFFFFFFFF) return null;
    return readBytesAt(located.itemOffset + 8, len, cancelToken: cancelToken);
  }

  Future<Uint8List?> _readFrameByLength(
    int itemOffset,
    int payloadLength,
    CancellationToken? cancelToken,
  ) async {
    var extra = 0;
    while (extra <= payloadLength + 8 * 4096) {
      if (cancelToken?.isCancelled == true) return null;
      final rawLen = 8 + payloadLength + extra;
      final raw = await readBytesAt(itemOffset, rawLen, cancelToken: cancelToken);
      if (cancelToken?.isCancelled == true) return null;
      final parsed = _concatFragments(raw, endian, payloadLimit: payloadLength);
      if (parsed != null) return parsed;
      if (raw.length < rawLen) return null;
      extra = extra == 0 ? 64 : extra * 4;
    }
    return null;
  }

  Future<_FrameLoc?> _locateFrame(int frameIndex, {CancellationToken? cancelToken}) async {
    if (_isClosed) throw StateError('Closed');
    if (cancelToken?.isCancelled == true || frameIndex < 0) return null;

    if (extendedOffsetTable.isNotEmpty && frameIndex < extendedOffsetTable.length) {
      final itemOffset = _extendedOffsetBase + extendedOffsetTable[frameIndex];
      int? next;
      if (frameIndex + 1 < extendedOffsetTable.length) {
        final candidate = _extendedOffsetBase + extendedOffsetTable[frameIndex + 1];
        if (candidate > itemOffset) next = candidate;
      }
      int? payload;
      if (frameIndex < extendedOffsetTableLengths.length) {
        payload = extendedOffsetTableLengths[frameIndex];
      }
      return _FrameLoc(itemOffset, next, payload, directPayload: false);
    }

    if (basicOffsetTable.isNotEmpty && frameIndex < basicOffsetTable.length) {
      final botOffset = basicOffsetTable[frameIndex];
      if (botOffset != 0xFFFFFFFF) {
        final itemOffset = firstFragmentOffset + botOffset;
        int? next;
        if (frameIndex + 1 < basicOffsetTable.length && basicOffsetTable[frameIndex + 1] != 0xFFFFFFFF) {
          final candidate = firstFragmentOffset + basicOffsetTable[frameIndex + 1];
          if (candidate > itemOffset) next = candidate;
        }
        return _FrameLoc(itemOffset, next, null, directPayload: false);
      }
    }

    if (!isEncapsulated || firstFragmentOffset <= 0) return null;
    await _ensureFragmentIndex(cancelToken);
    if (cancelToken?.isCancelled == true || frameIndex >= _fragmentOffsets.length) return null;
    return _FrameLoc(
      _fragmentOffsets[frameIndex],
      null,
      _fragmentLengths[frameIndex],
      directPayload: true,
    );
  }

  Future<void> _ensureFragmentIndex(CancellationToken? cancelToken) async {
    while (!_fragmentIndexComplete) {
      if (_isClosed) throw StateError('Closed');
      if (cancelToken?.isCancelled == true) return;
      var pending = _fragmentIndexFuture;
      if (pending == null) {
        pending = _scanAllFragments(cancelToken);
        _fragmentIndexFuture = pending;
      }
      await pending;
      if (!_fragmentIndexComplete && identical(_fragmentIndexFuture, pending)) {
        _fragmentIndexFuture = null;
      }
    }
  }

  Future<void> _scanAllFragments(CancellationToken? cancelToken) async {
    final handle = await _acquireHandle(cancelToken: cancelToken);
    if (handle == null) return;
    try {
      if (cancelToken?.isCancelled == true) return;
      final fileLength = await handle.length();
      final offsets = <int>[];
      final lengths = <int>[];
      var offset = firstFragmentOffset;
      Uint8List buf = Uint8List(0);
      var bufStart = 0;

      bool inBuf(int pos, int count) => pos >= bufStart && pos + count <= bufStart + buf.length;

      while (offset + 8 <= fileLength) {
        if (cancelToken?.isCancelled == true) return;
        if (!inBuf(offset, 8)) {
          await handle.setPosition(offset);
          final head = await handle.read(8);
          if (head.length < 8) break;
          final parsed = _fragmentHeader(head, endian);
          if (parsed == null) break;
          offsets.add(offset);
          lengths.add(parsed);
          if (parsed <= _dicomWindow && offset + 8 < fileLength) {
            final aheadCount = math.min(_dicomWindow, fileLength - (offset + 8));
            final ahead = await handle.read(aheadCount);
            buf = Uint8List(head.length + ahead.length);
            buf.setRange(0, head.length, head);
            buf.setRange(head.length, buf.length, ahead);
            bufStart = offset;
          } else {
            buf = Uint8List(0);
          }
          offset += 8 + parsed;
          continue;
        }

        final index = offset - bufStart;
        final parsed = _fragmentHeader(Uint8List.sublistView(buf, index, index + 8), endian);
        if (parsed == null) break;
        offsets.add(offset);
        lengths.add(parsed);
        offset += 8 + parsed;
      }

      _fragmentOffsets = Uint64List.fromList(offsets);
      _fragmentLengths = Uint32List.fromList(lengths);
      _fragmentIndexComplete = true;
    } finally {
      _releaseHandle(handle);
    }
  }

  Future<RandomAccessFile?> _acquireHandle({CancellationToken? cancelToken}) async {
    if (_isClosed) throw StateError('Closed');
    if (cancelToken?.isCancelled == true) return null;

    if (_availableHandles.isNotEmpty) {
      final handle = _availableHandles.removeLast();
      _busyHandles.add(handle);
      return handle;
    }

    final effectivePath = filePath ?? (raf.path.isNotEmpty ? raf.path : null);
    if (_allHandles.length < _effectiveMaxConcurrency && effectivePath != null) {
      try {
        final newHandle = await File(effectivePath).open(mode: FileMode.read);
        if (_isClosed || cancelToken?.isCancelled == true) {
          await newHandle.close();
          return null;
        }
        _allHandles.add(newHandle);
        _busyHandles.add(newHandle);
        return newHandle;
      } catch (_) {
        _effectiveMaxConcurrency = _allHandles.isEmpty ? 1 : _allHandles.length;
      }
    }

    if (cancelToken?.isCancelled == true || _isClosed) return null;

    final completer = Completer<RandomAccessFile?>();
    _waiters.add(completer);
    void onCancel() {
      if (!completer.isCompleted) {
        _waiters.remove(completer);
        completer.complete(null);
      }
    }

    cancelToken?.addListener(onCancel);
    try {
      return await completer.future;
    } finally {
      cancelToken?.removeListener(onCancel);
    }
  }

  void _releaseHandle(RandomAccessFile handle) {
    _busyHandles.remove(handle);
    if (_isClosed) {
      handle.close();
      return;
    }
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) {
        _busyHandles.add(handle);
        waiter.complete(handle);
        return;
      }
    }
    if (!_availableHandles.contains(handle)) {
      _availableHandles.add(handle);
    }
  }

  Future<Uint8List> readBytesAt(int offset, int count, {CancellationToken? cancelToken}) async {
    if (_isClosed) throw StateError('Closed');
    if (count <= 0 || cancelToken?.isCancelled == true) return Uint8List(0);
    final handle = await _acquireHandle(cancelToken: cancelToken);
    if (handle == null) return Uint8List(0);
    try {
      if (cancelToken?.isCancelled == true) return Uint8List(0);
      await handle.setPosition(offset);
      return await handle.read(count);
    } finally {
      _releaseHandle(handle);
    }
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    final waiters = List<Completer<RandomAccessFile?>>.from(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    final handles = List<RandomAccessFile>.from(_allHandles);
    _allHandles.clear();
    _availableHandles.clear();
    _busyHandles.clear();
    for (final handle in handles) {
      try {
        await handle.close();
      } catch (_) {}
    }
  }
}

class _FrameLoc {
  final int itemOffset;
  final int? nextItemOffset;
  final int? payloadLength;
  final bool directPayload;

  const _FrameLoc(this.itemOffset, this.nextItemOffset, this.payloadLength, {required this.directPayload});
}

int? _fragmentHeader(Uint8List head, Endian endian) {
  if (head.length < 8) return null;
  final bd = ByteData.sublistView(head);
  if (bd.getUint16(0, endian) != 0xFFFE || bd.getUint16(2, endian) != 0xE000) return null;
  final itemLen = bd.getUint32(4, endian);
  if (itemLen == 0xFFFFFFFF) return null;
  return itemLen;
}

Uint8List? _concatFragments(Uint8List raw, Endian endian, {int? payloadLimit}) {
  if (raw.length < 8) return null;
  final out = BytesBuilder(copy: false);
  var pos = 0;
  var accumulated = 0;
  while (pos + 8 <= raw.length) {
    final bd = ByteData.sublistView(raw, pos, pos + 8);
    if (bd.getUint16(0, endian) != 0xFFFE || bd.getUint16(2, endian) != 0xE000) break;
    final len = bd.getUint32(4, endian);
    if (len == 0xFFFFFFFF) return null;
    final start = pos + 8;
    final end = start + len;
    if (end > raw.length) return null;
    out.add(Uint8List.sublistView(raw, start, end));
    accumulated += len;
    pos = end;
    if (payloadLimit != null && accumulated >= payloadLimit) break;
  }
  if (out.isEmpty) return null;
  if (payloadLimit != null && accumulated < payloadLimit) return null;
  return out.takeBytes();
}

class DicomTag {
  static const int fileMetaInformationGroupLength = 0x00020000;
  static const int transferSyntaxUid = 0x00020010;
  static const int imageType = 0x00080008;
  static const int sopClassUid = 0x00080016;
  static const int sopInstanceUid = 0x00080018;
  static const int studyInstanceUid = 0x0020000D;
  static const int seriesInstanceUid = 0x0020000E;
  static const int rows = 0x00280010;
  static const int columns = 0x00280011;
  static const int pixelSpacing = 0x00280030;
  static const int numberOfFrames = 0x00280008;
  static const int samplesPerPixel = 0x00280002;
  static const int photometricInterpretation = 0x00280004;
  static const int bitsAllocated = 0x00280100;
  static const int bitsStored = 0x00280101;
  static const int lossyImageCompression = 0x00282110;
  static const int lossyImageCompressionMethod = 0x00282114;
  static const int iccProfile = 0x00282000;
  static const int totalPixelMatrixColumns = 0x00480006;
  static const int totalPixelMatrixRows = 0x00480007;
  static const int imagedVolumeWidth = 0x00480001;
  static const int imagedVolumeHeight = 0x00480002;
  static const int imagedVolumeDepth = 0x00480003;
  static const int columnPositionInTotalImagePixelMatrix = 0x0048021E;
  static const int rowPositionInTotalImagePixelMatrix = 0x0048021F;
  static const int sharedFunctionalGroupsSequence = 0x52009229;
  static const int perFrameFunctionalGroupsSequence = 0x52009230;
  static const int pixelMeasuresSequence = 0x00289110;
  static const int extendedOffsetTable = 0x7FE00001;
  static const int extendedOffsetTableLengths = 0x7FE00002;
  static const int pixelData = 0x7FE00010;
}

Future<DicomFile?> openDicomFile(String path, {int maxConcurrency = 4}) async {
  final file = File(path);
  if (!await file.exists()) return null;

  final raf = await file.open(mode: FileMode.read);
  var success = false;
  try {
    final length = await raf.length();
    if (length < 132) return null;

    final reader = _Reader(raf, length);
    await reader.ensure(128, 4);
    if (reader.remaining(128) < 4) return null;
    final magic = reader.slice(128, 4);
    if (String.fromCharCodes(magic) != 'DICM') return null;

    final state = _OpenState();
    await _parseDataset(reader, state, 132, end: null, depth: 0, stopAt: null);
    if (state.stoppedEarly && state.tags.isEmpty && !state.sawPixelData) return null;

    final eotBase = await _resolveExtendedOffsetBase(reader, state);

    success = true;
    return DicomFile(
      raf,
      state.endian,
      state.tags,
      state.basicOffsetTable,
      state.firstFragmentOffset,
      state.isEncapsulated,
      state.transferSyntax,
      state.pixelDataLength,
      path,
      maxConcurrency,
      state.extendedOffsetTable,
      state.extendedOffsetTableLengths,
      eotBase,
      state.perFramePositions,
    );
  } finally {
    if (!success) {
      await raf.close();
    }
  }
}

class _OpenState {
  final Map<int, dynamic> tags = {};
  String transferSyntax = '1.2.840.10008.1.2.1';
  bool isExplicitVr = true;
  Endian endian = Endian.little;
  bool inFileMeta = true;
  bool isEncapsulated = false;
  bool sawPixelData = false;
  bool stoppedEarly = false;
  List<int> basicOffsetTable = Uint32List(0);
  List<int> extendedOffsetTable = const [];
  List<int> extendedOffsetTableLengths = const [];
  List<({int colPos, int rowPos})>? perFramePositions;
  int firstFragmentOffset = 0;
  int botItemOffset = 0;
  int pixelDataLength = 0;
}

class _Elem {
  final int tag;
  final String vr;
  final int vl;
  final int dataOffset;

  const _Elem(this.tag, this.vr, this.vl, this.dataOffset);
}

class _Reader {
  final RandomAccessFile raf;
  final int length;
  Uint8List buf = Uint8List(0);
  int start = 0;

  _Reader(this.raf, this.length);

  int remaining(int offset) {
    if (offset < start) return 0;
    final end = start + buf.length;
    if (offset >= end) return 0;
    return end - offset;
  }

  Future<void> ensure(int offset, int count) async {
    if (count <= 0) return;
    if (offset >= start && offset + count <= start + buf.length) return;
    if (offset < 0 || offset >= length) {
      buf = Uint8List(0);
      start = offset;
      return;
    }
    final n = math.min(math.max(count, _dicomWindow), length - offset);
    await raf.setPosition(offset);
    buf = await raf.read(n);
    start = offset;
  }

  ByteData view(int offset, int count) {
    final index = offset - start;
    return ByteData.sublistView(buf, index, index + count);
  }

  Uint8List slice(int offset, int count) {
    final index = offset - start;
    return Uint8List.sublistView(buf, index, index + count);
  }
}

Future<void> _parseDataset(
  _Reader reader,
  _OpenState state,
  int offset, {
  required int? end,
  required int depth,
  required int? stopAt,
}) async {
  if (depth > 8) return;
  while (offset + 8 <= reader.length && (end == null || offset < end)) {
    final headerNeed = math.min(12, reader.length - offset);
    if (headerNeed < 8) return;
    await reader.ensure(offset, headerNeed);
    if (reader.remaining(offset) < 8) return;

    final headerEndian = state.inFileMeta ? Endian.little : state.endian;
    final preview = reader.view(offset, math.min(12, reader.remaining(offset)));
    final group = preview.getUint16(0, headerEndian);
    final element = preview.getUint16(2, headerEndian);
    final tag = (group << 16) | element;

    if (state.inFileMeta && group != 0x0002) {
      state.inFileMeta = false;
    }

    if (tag == stopAt) return;

    if (tag == 0xFFFEE000 || tag == 0xFFFEE00D || tag == 0xFFFEE0DD) {
      if (reader.remaining(offset) < 8) return;
      final itemLen = reader.view(offset, 8).getUint32(4, headerEndian);
      if (tag == 0xFFFEE0DD || tag == 0xFFFEE00D) return;
      if (itemLen == 0xFFFFFFFF) {
        offset += 8;
        continue;
      }
      offset += 8 + itemLen;
      continue;
    }

    final elem = _decodeElement(reader, state, offset, preview, group, tag);
    if (elem == null) return;

    if (tag == DicomTag.pixelData && depth == 0) {
      await _readPixelData(reader, state, elem);
      state.sawPixelData = true;
      state.stoppedEarly = true;
      return;
    }

    if (tag == DicomTag.perFrameFunctionalGroupsSequence && depth == 0) {
      offset = await _parsePerFrameFunctionalGroups(reader, state, elem.dataOffset, elem.vl);
      continue;
    }

    if (elem.vl == 0xFFFFFFFF) {
      if (_shouldEnterSequence(tag, depth)) {
        offset = await _parseSequence(reader, state, elem.dataOffset, null, depth + 1);
      } else {
        offset = await _skipUndefinedSequence(reader, state, elem.dataOffset);
      }
      continue;
    }

    if (elem.vr == 'SQ' || _isKnownSequence(tag)) {
      final seqEnd = elem.dataOffset + elem.vl;
      if (_shouldEnterSequence(tag, depth)) {
        await _parseSequence(reader, state, elem.dataOffset, seqEnd, depth + 1);
      }
      offset = seqEnd;
      continue;
    }

    if (_shouldKeepValue(tag, elem.vl)) {
      await reader.ensure(elem.dataOffset, elem.vl);
      if (reader.remaining(elem.dataOffset) < elem.vl) return;
      final bytes = Uint8List.fromList(reader.slice(elem.dataOffset, elem.vl));
      final value = _parseValue(tag, elem.vr, bytes, state.endian);
      state.tags[tag] = value;
      if (tag == DicomTag.extendedOffsetTable && value is List<int>) {
        state.extendedOffsetTable = value;
      } else if (tag == DicomTag.extendedOffsetTableLengths && value is List<int>) {
        state.extendedOffsetTableLengths = value;
      } else if (tag == DicomTag.transferSyntaxUid && value is String) {
        state.transferSyntax = value;
        if (value == '1.2.840.10008.1.2') {
          state.isExplicitVr = false;
        } else if (value == '1.2.840.10008.1.2.2') {
          state.isExplicitVr = true;
          state.endian = Endian.big;
        }
      }
    }

    offset = elem.dataOffset + elem.vl;
  }
}

_Elem? _decodeElement(
  _Reader reader,
  _OpenState state,
  int offset,
  ByteData preview,
  int group,
  int tag,
) {
  final inMeta = group == 0x0002;
  final headerEndian = inMeta ? Endian.little : state.endian;
  final explicitVr = inMeta || state.isExplicitVr;
  if (!explicitVr) {
    if (reader.remaining(offset) < 8) return null;
    final vl = preview.getUint32(4, headerEndian);
    return _Elem(tag, '', vl, offset + 8);
  }

  if (reader.remaining(offset) < 8) return null;
  final vr = String.fromCharCodes([preview.getUint8(4), preview.getUint8(5)]);
  if (_longVrs.contains(vr)) {
    if (reader.remaining(offset) < 12) {
      return null;
    }
    final vl = reader.view(offset, 12).getUint32(8, headerEndian);
    return _Elem(tag, vr, vl, offset + 12);
  }
  final vl = preview.getUint16(6, headerEndian);
  return _Elem(tag, vr, vl, offset + 8);
}

bool _isKnownSequence(int tag) {
  return tag == DicomTag.sharedFunctionalGroupsSequence ||
      tag == DicomTag.perFrameFunctionalGroupsSequence ||
      tag == DicomTag.pixelMeasuresSequence;
}

bool _shouldEnterSequence(int tag, int depth) {
  if (tag == DicomTag.perFrameFunctionalGroupsSequence) return false;
  if (tag == DicomTag.sharedFunctionalGroupsSequence) return depth == 0;
  if (tag == DicomTag.pixelMeasuresSequence) return true;
  return false;
}

bool _shouldKeepValue(int tag, int vl) {
  if (vl <= 0 || vl == 0xFFFFFFFF) return false;
  if (tag == DicomTag.extendedOffsetTable || tag == DicomTag.extendedOffsetTableLengths) {
    return vl <= _maxBulkValue;
  }
  return vl <= _maxInlineValue;
}

Future<int> _parseSequence(
  _Reader reader,
  _OpenState state,
  int offset,
  int? end,
  int depth,
) async {
  while (offset + 8 <= reader.length && (end == null || offset < end)) {
    await reader.ensure(offset, 8);
    if (reader.remaining(offset) < 8) return end ?? offset;
    final endian = state.inFileMeta ? Endian.little : state.endian;
    final bd = reader.view(offset, 8);
    final tag = (bd.getUint16(0, endian) << 16) | bd.getUint16(2, endian);
    if (tag == 0xFFFEE0DD) return offset + 8;
    if (tag != 0xFFFEE000) return offset;
    final itemLen = bd.getUint32(4, endian);
    if (itemLen == 0xFFFFFFFF) {
      await _parseDataset(reader, state, offset + 8, end: null, depth: depth, stopAt: 0xFFFEE00D);
      offset = await _skipUntil(reader, state, offset + 8, 0xFFFEE00D);
    } else {
      final itemEnd = offset + 8 + itemLen;
      await _parseDataset(reader, state, offset + 8, end: itemEnd, depth: depth, stopAt: null);
      offset = itemEnd;
    }
  }
  return end ?? offset;
}

Future<int> _skipUndefinedSequence(_Reader reader, _OpenState state, int offset) async {
  while (offset + 8 <= reader.length) {
    await reader.ensure(offset, 8);
    if (reader.remaining(offset) < 8) return offset;
    final endian = state.inFileMeta ? Endian.little : state.endian;
    final bd = reader.view(offset, 8);
    final tag = (bd.getUint16(0, endian) << 16) | bd.getUint16(2, endian);
    if (tag == 0xFFFEE0DD) return offset + 8;
    if (tag != 0xFFFEE000) return offset;
    final itemLen = bd.getUint32(4, endian);
    if (itemLen == 0xFFFFFFFF) {
      offset = await _skipUntil(reader, state, offset + 8, 0xFFFEE00D);
    } else {
      offset += 8 + itemLen;
    }
  }
  return offset;
}

Future<int> _skipUntil(_Reader reader, _OpenState state, int offset, int delim) async {
  while (offset + 8 <= reader.length) {
    final headerNeed = math.min(12, reader.length - offset);
    if (headerNeed < 8) return offset;
    await reader.ensure(offset, headerNeed);
    if (reader.remaining(offset) < 8) return offset;
    final headerEndian = state.inFileMeta ? Endian.little : state.endian;
    final preview = reader.view(offset, math.min(12, reader.remaining(offset)));
    final group = preview.getUint16(0, headerEndian);
    final element = preview.getUint16(2, headerEndian);
    final tag = (group << 16) | element;
    if (tag == delim || tag == 0xFFFEE0DD || tag == 0xFFFEE00D) return offset + 8;
    if (tag == 0xFFFEE000) {
      final itemLen = preview.getUint32(4, headerEndian);
      if (itemLen == 0xFFFFFFFF) {
        offset = await _skipUntil(reader, state, offset + 8, 0xFFFEE00D);
      } else {
        offset += 8 + itemLen;
      }
      continue;
    }
    final elem = _decodeElement(reader, state, offset, preview, group, tag);
    if (elem == null) return offset;
    if (elem.vl == 0xFFFFFFFF) {
      offset = await _skipUndefinedSequence(reader, state, elem.dataOffset);
    } else {
      offset = elem.dataOffset + elem.vl;
    }
  }
  return offset;
}

Future<int> _parsePerFrameFunctionalGroups(
  _Reader reader,
  _OpenState state,
  int offset,
  int vl,
) async {
  final endian = state.inFileMeta ? Endian.little : state.endian;
  final seqEnd = vl == 0xFFFFFFFF ? null : offset + vl;
  final positions = <({int colPos, int rowPos})>[];

  while (offset + 8 <= reader.length && (seqEnd == null || offset < seqEnd)) {
    await reader.ensure(offset, 8);
    if (reader.remaining(offset) < 8) break;

    final bd = reader.view(offset, 8);
    final tag = (bd.getUint16(0, endian) << 16) | bd.getUint16(2, endian);

    if (tag == 0xFFFEE0DD) {
      // Sequence delimitation item
      offset += 8;
      break;
    }
    if (tag != 0xFFFEE000) {
      // Unexpected tag, try to advance
      offset += 2;
      continue;
    }

    final itemLen = bd.getUint32(4, endian);
    final itemDataStart = offset + 8;
    final itemEnd = itemLen == 0xFFFFFFFF ? null : itemDataStart + itemLen;

    final parsed = await _parseFrameItem(reader, state, itemDataStart, itemEnd);
    if (parsed.colPos != null && parsed.rowPos != null) {
      positions.add((colPos: parsed.colPos!, rowPos: parsed.rowPos!));
    }
    offset = parsed.nextOffset;
  }

  state.perFramePositions = positions;
  return seqEnd ?? offset;
}

Future<({int? colPos, int? rowPos, int nextOffset})> _parseFrameItem(
  _Reader reader,
  _OpenState state,
  int offset,
  int? itemEnd,
) async {
  int? colPos;
  int? rowPos;
  final endian = state.inFileMeta ? Endian.little : state.endian;

  while (offset + 8 <= reader.length && (itemEnd == null || offset < itemEnd)) {
    await reader.ensure(offset, 12);
    if (reader.remaining(offset) < 8) break;

    final preview = reader.view(offset, math.min(12, reader.remaining(offset)));
    final group = preview.getUint16(0, endian);
    final element = preview.getUint16(2, endian);
    final tag = (group << 16) | element;

    if (tag == 0xFFFEE00D) {
      // Item delimitation item
      return (colPos: colPos, rowPos: rowPos, nextOffset: offset + 8);
    }
    if (tag == 0xFFFEE0DD) {
      // Sequence delimitation item
      return (colPos: colPos, rowPos: rowPos, nextOffset: offset);
    }
    if (tag == 0xFFFEE000) {
      // Nested item inside sequence
      final itemLen = preview.getUint32(4, endian);
      final nestedStart = offset + 8;
      final nestedEnd = itemLen == 0xFFFFFFFF ? null : nestedStart + itemLen;
      final res = await _parseFrameItem(reader, state, nestedStart, nestedEnd);
      colPos ??= res.colPos;
      rowPos ??= res.rowPos;
      offset = res.nextOffset;
      continue;
    }

    final elem = _decodeElement(reader, state, offset, preview, group, tag);
    if (elem == null) break;

    if (tag == DicomTag.columnPositionInTotalImagePixelMatrix) {
      await reader.ensure(elem.dataOffset, 4);
      if (reader.remaining(elem.dataOffset) >= 4) {
        colPos = reader.view(elem.dataOffset, 4).getInt32(0, endian);
      }
      offset = elem.dataOffset + elem.vl;
      continue;
    }

    if (tag == DicomTag.rowPositionInTotalImagePixelMatrix) {
      await reader.ensure(elem.dataOffset, 4);
      if (reader.remaining(elem.dataOffset) >= 4) {
        rowPos = reader.view(elem.dataOffset, 4).getInt32(0, endian);
      }
      offset = elem.dataOffset + elem.vl;
      continue;
    }

    // Check if element is a sequence or contains nested items
    bool isSequence = elem.vr == 'SQ' ||
        elem.vl == 0xFFFFFFFF ||
        tag == 0x0048021A ||
        tag == 0x00209111 ||
        _isKnownSequence(tag);

    if (!isSequence && !state.isExplicitVr && elem.vl >= 8) {
      await reader.ensure(elem.dataOffset, 4);
      if (reader.remaining(elem.dataOffset) >= 4) {
        final nextG = reader.view(elem.dataOffset, 4).getUint16(0, endian);
        final nextE = reader.view(elem.dataOffset, 4).getUint16(2, endian);
        if (nextG == 0xFFFE && nextE == 0xE000) {
          isSequence = true;
        }
      }
    }

    if (isSequence) {
      final seqEnd = elem.vl == 0xFFFFFFFF ? null : elem.dataOffset + elem.vl;
      final res = await _parseSequenceForPositions(reader, state, elem.dataOffset, seqEnd);
      colPos ??= res.colPos;
      rowPos ??= res.rowPos;
      offset = res.nextOffset;
      continue;
    }

    offset = elem.dataOffset + elem.vl;
  }

  return (colPos: colPos, rowPos: rowPos, nextOffset: itemEnd ?? offset);
}

Future<({int? colPos, int? rowPos, int nextOffset})> _parseSequenceForPositions(
  _Reader reader,
  _OpenState state,
  int offset,
  int? seqEnd,
) async {
  int? colPos;
  int? rowPos;
  final endian = state.inFileMeta ? Endian.little : state.endian;

  while (offset + 8 <= reader.length && (seqEnd == null || offset < seqEnd)) {
    await reader.ensure(offset, 8);
    if (reader.remaining(offset) < 8) break;

    final bd = reader.view(offset, 8);
    final tag = (bd.getUint16(0, endian) << 16) | bd.getUint16(2, endian);

    if (tag == 0xFFFEE0DD) {
      // Sequence delimitation item
      return (colPos: colPos, rowPos: rowPos, nextOffset: offset + 8);
    }
    if (tag != 0xFFFEE000) {
      // Non-item tag inside sequence
      break;
    }

    final itemLen = bd.getUint32(4, endian);
    final itemDataStart = offset + 8;
    final itemEnd = itemLen == 0xFFFFFFFF ? null : itemDataStart + itemLen;

    final res = await _parseFrameItem(reader, state, itemDataStart, itemEnd);
    colPos ??= res.colPos;
    rowPos ??= res.rowPos;
    offset = res.nextOffset;
  }

  return (colPos: colPos, rowPos: rowPos, nextOffset: seqEnd ?? offset);
}

Future<void> _readPixelData(_Reader reader, _OpenState state, _Elem elem) async {
  if (elem.vl != 0xFFFFFFFF) {
    state.pixelDataLength = elem.vl;
    state.firstFragmentOffset = elem.dataOffset;
    return;
  }

  state.isEncapsulated = true;
  state.botItemOffset = elem.dataOffset;
  await reader.ensure(elem.dataOffset, 8);
  if (reader.remaining(elem.dataOffset) < 8) return;
  final bot = reader.view(elem.dataOffset, 8);
  final group = bot.getUint16(0, state.endian);
  final element = bot.getUint16(2, state.endian);
  if (group != 0xFFFE || element != 0xE000) return;
  final botLen = bot.getUint32(4, state.endian);
  if (botLen != 0 && botLen != 0xFFFFFFFF) {
    await reader.ensure(elem.dataOffset + 8, botLen);
    if (reader.remaining(elem.dataOffset + 8) < botLen) return;
    final bytes = reader.slice(elem.dataOffset + 8, botLen);
    final count = botLen ~/ 4;
    final table = Uint32List(count);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < count; i++) {
      table[i] = bd.getUint32(i * 4, state.endian);
    }
    state.basicOffsetTable = table;
  }
  final tableBytes = botLen == 0xFFFFFFFF ? 0 : botLen;
  state.firstFragmentOffset = elem.dataOffset + 8 + tableBytes;
}

Future<int> _resolveExtendedOffsetBase(_Reader reader, _OpenState state) async {
  if (!state.isEncapsulated || state.extendedOffsetTable.isEmpty || state.botItemOffset <= 0) {
    return state.firstFragmentOffset;
  }
  final first = state.extendedOffsetTable[0];
  final standard = state.botItemOffset + first;
  final legacy = state.firstFragmentOffset + first;
  final standardOk = standard != state.botItemOffset && await _isFragmentItem(reader, standard, state.endian);
  if (standardOk) return state.botItemOffset;
  if (await _isFragmentItem(reader, legacy, state.endian)) return state.firstFragmentOffset;
  if (await _isFragmentItem(reader, standard, state.endian)) return state.botItemOffset;
  return state.firstFragmentOffset;
}

Future<bool> _isFragmentItem(_Reader reader, int offset, Endian endian) async {
  if (offset < 0 || offset + 8 > reader.length) return false;
  await reader.ensure(offset, 8);
  if (reader.remaining(offset) < 8) return false;
  final bd = reader.view(offset, 8);
  return bd.getUint16(0, endian) == 0xFFFE && bd.getUint16(2, endian) == 0xE000;
}

dynamic _parseValue(int tag, String vr, Uint8List bytes, Endian endian) {
  if (tag == DicomTag.extendedOffsetTable || tag == DicomTag.extendedOffsetTableLengths || vr == 'OV' || vr == 'UV') {
    return _readUint64List(bytes, endian);
  }
  if (vr == 'UI' || vr == 'SH' || vr == 'LO' || vr == 'CS' || vr == 'PN' || vr == 'IS' || vr == 'DS' || vr == 'AS' || vr == 'LT' || vr == 'ST' || vr == 'UT') {
    final text = String.fromCharCodes(bytes).replaceAll('\x00', '').trim();
    if (vr == 'IS' || vr == 'DS') {
      final parts = text.split('\\').map((part) => part.trim()).toList();
      if (parts.length == 1) {
        return vr == 'IS' ? int.tryParse(parts[0]) : double.tryParse(parts[0]);
      }
      return parts.map((part) => vr == 'IS' ? int.tryParse(part) : double.tryParse(part)).toList();
    }
    final parts = text.split('\\');
    if (parts.length > 1) return parts;
    return text;
  }
  if (vr == 'US' || vr == 'UL' || vr == 'SS' || vr == 'SL' || vr == 'AT') {
    final bd = ByteData.sublistView(bytes);
    if (bytes.length >= 4 && (vr == 'UL' || vr == 'SL' || vr == 'AT')) {
      return vr == 'SL' ? bd.getInt32(0, endian) : bd.getUint32(0, endian);
    }
    if (bytes.length >= 2) {
      return vr == 'SS' ? bd.getInt16(0, endian) : bd.getUint16(0, endian);
    }
  }
  if (vr == 'SV') {
    final bd = ByteData.sublistView(bytes);
    if (bytes.length == 8) return bd.getInt64(0, endian);
    final count = bytes.length ~/ 8;
    return [for (var i = 0; i < count; i++) bd.getInt64(i * 8, endian)];
  }
  if (vr == 'FL' && bytes.length >= 4) {
    return ByteData.sublistView(bytes).getFloat32(0, endian);
  }
  if (vr == 'FD' && bytes.length >= 8) {
    return ByteData.sublistView(bytes).getFloat64(0, endian);
  }
  return bytes;
}

Uint64List _readUint64List(Uint8List bytes, Endian endian) {
  final count = bytes.length ~/ 8;
  final out = Uint64List(count);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    out[i] = bd.getUint64(i * 8, endian);
  }
  return out;
}

/// Basic metadata for a DICOM WSI instance.
class DicomMetadata {
  final String sopClassUid;
  final String sopInstanceUid;
  final String studyInstanceUid;
  final String seriesInstanceUid;
  final List<String> imageType;
  final int rows;
  final int columns;
  final int numberOfFrames;
  final int totalPixelMatrixColumns;
  final int totalPixelMatrixRows;
  final String transferSyntax;
  final List<({int colPos, int rowPos})>? perFramePositions;

  String get type {
    if (imageType.contains('VOLUME')) return 'level';
    if (imageType.contains('LABEL')) return 'label';
    if (imageType.contains('OVERVIEW')) return 'macro';
    if (imageType.contains('THUMBNAIL')) return 'thumbnail';
    return 'other';
  }

  DicomMetadata({
    required this.sopClassUid,
    required this.sopInstanceUid,
    required this.studyInstanceUid,
    required this.seriesInstanceUid,
    required this.imageType,
    required this.rows,
    required this.columns,
    required this.numberOfFrames,
    required this.totalPixelMatrixColumns,
    required this.totalPixelMatrixRows,
    required this.transferSyntax,
    this.perFramePositions,
  });

  @override
  String toString() =>
      'DicomMetadata(type: $type, frames: $numberOfFrames, matrix: ${totalPixelMatrixColumns}x$totalPixelMatrixRows, tile: ${columns}x$rows)';
}

Future<DicomMetadata?> readDicomMetadata(DicomFile dicom) async {
  try {
    final sopClass = dicom.tags[DicomTag.sopClassUid] as String? ?? '';
    final sopInst = dicom.tags[DicomTag.sopInstanceUid] as String? ?? '';
    final studyUid = dicom.tags[DicomTag.studyInstanceUid] as String? ?? '';
    final seriesUid = dicom.tags[DicomTag.seriesInstanceUid] as String? ?? '';

    final imgTypeRaw = dicom.tags[DicomTag.imageType];
    List<String> imgType = [];
    if (imgTypeRaw is String) {
      imgType = [imgTypeRaw];
    } else if (imgTypeRaw is List) {
      imgType = imgTypeRaw.map((entry) => entry.toString()).toList();
    }

    final rows = dicom.tags[DicomTag.rows] as int? ?? 0;
    final columns = dicom.tags[DicomTag.columns] as int? ?? 0;
    final numFrames = dicom.tags[DicomTag.numberOfFrames] as int? ?? 1;
    final totalCols = dicom.tags[DicomTag.totalPixelMatrixColumns] as int? ?? columns;
    final totalRows = dicom.tags[DicomTag.totalPixelMatrixRows] as int? ?? rows;

    return DicomMetadata(
      sopClassUid: sopClass,
      sopInstanceUid: sopInst,
      studyInstanceUid: studyUid,
      seriesInstanceUid: seriesUid,
      imageType: imgType,
      rows: rows,
      columns: columns,
      numberOfFrames: numFrames,
      totalPixelMatrixColumns: totalCols,
      totalPixelMatrixRows: totalRows,
      transferSyntax: dicom.transferSyntax,
      perFramePositions: dicom.perFramePositions,
    );
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> extractDicomFrame(DicomFile dicom, int frameIndex, {CancellationToken? cancelToken}) async {
  if (frameIndex < 0) return null;
  final numFrames = dicom.tags[DicomTag.numberOfFrames] as int? ?? 1;
  if (frameIndex >= numFrames) return null;
  if (cancelToken?.isCancelled == true) return null;

  if (dicom.isEncapsulated) {
    return dicom._readFrame(frameIndex, cancelToken: cancelToken);
  }

  final rows = dicom.tags[DicomTag.rows] as int? ?? 0;
  final columns = dicom.tags[DicomTag.columns] as int? ?? 0;
  final samples = dicom.tags[DicomTag.samplesPerPixel] as int? ?? 1;
  final bitsAlloc = dicom.tags[DicomTag.bitsAllocated] as int? ?? 8;
  final bytesPerPixel = (bitsAlloc / 8).ceil() * samples;
  final frameSize = rows * columns * bytesPerPixel;
  if (frameSize <= 0) return null;
  final offset = dicom.firstFragmentOffset + frameIndex * frameSize;
  return dicom.readBytesAt(offset, frameSize, cancelToken: cancelToken);
}

Future<img.Image?> extractDicomFrameAsImage(DicomFile dicom, int frameIndex, {CancellationToken? cancelToken}) async {
  final bytes = await extractDicomFrame(dicom, frameIndex, cancelToken: cancelToken);
  if (bytes == null || bytes.isEmpty || cancelToken?.isCancelled == true) return null;

  if (dicom.isEncapsulated) {
    return _decodeEncapsulatedAsync(
      bytes,
      dicom.transferSyntax,
      dicom.tags[DicomTag.photometricInterpretation] as String?,
    );
  }

  final rows = dicom.tags[DicomTag.rows] as int? ?? 0;
  final columns = dicom.tags[DicomTag.columns] as int? ?? 0;
  final samples = dicom.tags[DicomTag.samplesPerPixel] as int? ?? 1;
  final bitsAlloc = dicom.tags[DicomTag.bitsAllocated] as int? ?? 8;
  final photoInterp = dicom.tags[DicomTag.photometricInterpretation] as String? ?? 'MONOCHROME2';

  if (bitsAlloc == 8 && samples == 3 && photoInterp == 'RGB') {
    return img.Image.fromBytes(width: columns, height: rows, bytes: bytes.buffer, order: img.ChannelOrder.rgb);
  }
  if (bitsAlloc == 8 && samples == 1) {
    return img.Image.fromBytes(width: columns, height: rows, bytes: bytes.buffer, order: img.ChannelOrder.red);
  }
  return null;
}

Future<img.Image?> _decodeEncapsulatedAsync(
  Uint8List bytes,
  String transferSyntax, [
  String? photometricInterpretation,
]) async {
  try {
    final worker = await _DecodePool.acquire();
    final reply = ReceivePort();
    try {
      worker.send([reply.sendPort, bytes, transferSyntax, photometricInterpretation]);
      final message = await reply.first;
      if (message == null) return null;
      final parts = message as List;
      return _imageFromRaw(parts[0] as int, parts[1] as int, parts[2] as Uint8List, parts[3] as int);
    } finally {
      reply.close();
      _DecodePool.release(worker);
    }
  } catch (_) {
    return _decodeEncapsulated(bytes, transferSyntax, photometricInterpretation);
  }
}

img.Image? _imageFromRaw(int width, int height, Uint8List bytes, int channels) {
  if (width <= 0 || height <= 0 || bytes.isEmpty) return null;
  final order = channels >= 4
      ? img.ChannelOrder.rgba
      : channels == 3
          ? img.ChannelOrder.rgb
          : img.ChannelOrder.red;
  return img.Image.fromBytes(
    width: width,
    height: height,
    bytes: Uint8List.fromList(bytes).buffer,
    numChannels: channels,
    order: order,
  );
}

img.Image? _decodeEncapsulated(
  Uint8List bytes,
  String transferSyntax, [
  String? photometricInterpretation,
]) {
  try {
    switch (transferSyntax) {
      case '1.2.840.10008.1.2.4.50':
      case '1.2.840.10008.1.2.4.51':
      case '1.2.840.10008.1.2.4.57':
      case '1.2.840.10008.1.2.4.70':
        return img.decodeJpg(bytes);
      case '1.2.840.10008.1.2.4.90':
      case '1.2.840.10008.1.2.4.91':
        return _decodeDicomJpeg2000(bytes, photometricInterpretation);
      case '1.2.840.10008.1.2.4.201':
      case '1.2.840.10008.1.2.4.202':
      case '1.2.840.10008.1.2.4.203':
        return _decodeDicomJpeg2000(bytes, photometricInterpretation);
      default:
        if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
          return img.decodeJpg(bytes);
        }
        if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
          return img.decodePng(bytes);
        }
        if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0x4F) {
          return _decodeDicomJpeg2000(bytes, photometricInterpretation);
        }
        return null;
    }
  } catch (_) {
    return null;
  }
}

void _decodeWorkerMain(SendPort mainPort) {
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  inbox.listen((message) {
    final reply = message[0] as SendPort;
    final bytes = message[1] as Uint8List;
    final transferSyntax = message[2] as String;
    final photometricInterpretation = message.length > 3 ? message[3] as String? : null;
    try {
      final image = _decodeEncapsulated(bytes, transferSyntax, photometricInterpretation);
      if (image == null) {
        reply.send(null);
        return;
      }
      reply.send([
        image.width,
        image.height,
        Uint8List.fromList(image.getBytes()),
        image.numChannels,
      ]);
    } catch (_) {
      reply.send(null);
    }
  });
}

class _DecodePool {
  static const int _size = 2;
  static final List<SendPort> _idle = [];
  static final List<Completer<SendPort>> _waiters = [];
  static int _started = 0;

  static Future<SendPort> acquire() async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    if (_started < _size) {
      _started++;
      try {
        return await _spawn();
      } catch (_) {
        _started--;
        rethrow;
      }
    }
    final waiter = Completer<SendPort>();
    _waiters.add(waiter);
    return waiter.future;
  }

  static void release(SendPort port) {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete(port);
        return;
      }
    }
    _idle.add(port);
  }

  static Future<SendPort> _spawn() async {
    final ready = ReceivePort();
    await Isolate.spawn(_decodeWorkerMain, ready.sendPort);
    final port = await ready.first as SendPort;
    ready.close();
    return port;
  }
}

bool _isYbrFull422(String? photometricInterpretation) {
  return photometricInterpretation?.trim().toUpperCase() == 'YBR_FULL_422';
}

/// JPEG 2000 codestream (`FF 4F`) used by DICOM transfer syntax 1.2.840.10008.1.2.4.90/91.
img.Image? _decodeDicomJpeg2000(Uint8List bytes, [String? photometricInterpretation]) {
  try {
    final jpx = JpxImage();
    jpx.parse(
      bytes,
      convertYbrFull422: _isYbrFull422(photometricInterpretation),
    );
    if (jpx.width <= 0 || jpx.height <= 0 || jpx.tiles.isEmpty) {
      return null;
    }

    if (jpx.tiles.length == 1 &&
        jpx.tiles[0].left == 0 &&
        jpx.tiles[0].top == 0 &&
        jpx.tiles[0].width == jpx.width &&
        jpx.tiles[0].height == jpx.height) {
      return img.Image.fromBytes(
        width: jpx.width,
        height: jpx.height,
        bytes: jpx.tiles[0].items.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
    }

    final image = img.Image(width: jpx.width, height: jpx.height, numChannels: 4);
    for (final tile in jpx.tiles) {
      if (tile.width <= 0 || tile.height <= 0) continue;
      final tileImg = img.Image.fromBytes(
        width: tile.width,
        height: tile.height,
        bytes: tile.items.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      img.compositeImage(image, tileImg, dstX: tile.left, dstY: tile.top);
    }
    return image;
  } catch (_) {
    return null;
  }
}
