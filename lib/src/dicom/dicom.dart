import 'package:image/image.dart' as img;
import 'dart:io';
import 'dart:typed_data';
import '../../types/types.dart';

/// Represents an open DICOM file handle and metadata parsed from its header.

class DicomFile {
  final RandomAccessFile raf;
  final Endian endian;
  final Map<int, dynamic> tags;
  final List<int> basicOffsetTable;
  final int firstFragmentOffset;
  final bool isEncapsulated;
  final String transferSyntax;
  final int pixelDataLength;

  final List<RandomAccessFile> _allHandles = [];
  final List<RandomAccessFile> _availableHandles = [];
  final List<RandomAccessFile> _busyHandles = [];
  final int _maxConcurrency;
  bool _isClosed = false;
  final String? filePath;

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
  ]) : _maxConcurrency = maxConcurrency < 1 ? 1 : maxConcurrency {
    _allHandles.add(raf);
    _availableHandles.add(raf);
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
    if (_allHandles.length < _maxConcurrency && effectivePath != null) {
      try {
        final newHandle = await File(effectivePath).open(mode: FileMode.read);
        _allHandles.add(newHandle);
        _busyHandles.add(newHandle);
        return newHandle;
      } catch (_) {}
    }
    return raf;
  }

  void _releaseHandle(RandomAccessFile handle) {
    if (_isClosed) {
      handle.close();
      return;
    }
    _busyHandles.remove(handle);
    if (!_availableHandles.contains(handle)) {
      _availableHandles.add(handle);
    }
  }

  Future<Uint8List> readBytesAt(int offset, int count, {CancellationToken? cancelToken}) async {
    if (_isClosed) throw StateError('Closed');
    final handle = await _acquireHandle(cancelToken: cancelToken);
    if (handle == null) return Uint8List(0);
    try {
      await handle.setPosition(offset);
      return await handle.read(count);
    } finally {
      if (handle != raf) {
        _releaseHandle(handle);
      }
    }
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    final handlesToClose = List<RandomAccessFile>.from(_allHandles);
    _allHandles.clear();
    _availableHandles.clear();
    _busyHandles.clear();
    for (final h in handlesToClose) {
      h.close();
    }
  }
}

class DicomTag {
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
  static const int sharedFunctionalGroupsSequence = 0x52009229;
  static const int pixelMeasuresSequence = 0x00289110;
  static const int pixelData = 0x7FE00010;
}

Future<DicomFile?> openDicomFile(String path, {int maxConcurrency = 4}) async {
  final file = File(path);
  if (!await file.exists()) return null;

  final raf = await file.open(mode: FileMode.read);
  bool success = false;
  try {
    if (await raf.length() < 132) {
      await raf.close();
      return null;
    }
    await raf.setPosition(128);
    final magic = await raf.read(4);
    if (String.fromCharCodes(magic) != 'DICM') {
      await raf.close();
      return null;
    }

    final tags = <int, dynamic>{};
    String transferSyntax = '1.2.840.10008.1.2.1'; 
    bool isExplicitVR = true;
    Endian endian = Endian.little;
    bool isEncapsulated = false;
    List<int> basicOffsetTable = [];
    int firstFragmentOffset = 0;
    int pixelDataLength = 0;

    int offset = 132;
    final length = await raf.length();
    
    // We maintain a stack of sequences to know if we are inside one, 
    // to map nested tags uniquely if we want, but for WSI PixelSpacing is what we care about.
    while (offset < length) {
      await raf.setPosition(offset);
      final head = await raf.read(12);
      if (head.length < 8) break;
      final bd = head.buffer.asByteData();

      final group = bd.getUint16(0, endian);
      final element = bd.getUint16(2, endian);
      final tag = (group << 16) | element;

      String vr = '';
      int vl = 0;
      int dataOffset = offset + 8;

      if (tag == 0xFFFEE000 || tag == 0xFFFEE00D || tag == 0xFFFEE0DD) {
        // Item or Delimitation Item
        vl = bd.getUint32(4, endian);
        offset += 8;
        if (vl != 0xFFFFFFFF) offset += vl;
        continue;
      }

      if (group == 0x0002) {
        vr = String.fromCharCodes(head.sublist(4, 6));
        vl = bd.getUint16(6, Endian.little);
      } else {
        if (isExplicitVR) {
          vr = String.fromCharCodes(head.sublist(4, 6));
          if (['OB', 'OW', 'OF', 'SQ', 'UT', 'UN'].contains(vr)) {
            vl = bd.getUint32(8, endian);
            dataOffset = offset + 12;
          } else {
            vl = bd.getUint16(6, endian);
          }
        } else {
          vl = bd.getUint32(4, endian);
        }
      }

      if (vl == 0xFFFFFFFF) {
        if (tag == DicomTag.pixelData) {
          isEncapsulated = true;
          await raf.setPosition(dataOffset);
          final botItem = await raf.read(8);
          final botTag = botItem.buffer.asByteData().getUint32(0, endian);
          if (botTag == 0xFFFEE000) { 
            final botLen = botItem.buffer.asByteData().getUint32(4, endian);
            if (botLen > 0) {
              final botData = await raf.read(botLen);
              for (int i = 0; i < botLen; i += 4) {
                basicOffsetTable.add(botData.buffer.asByteData().getUint32(i, endian));
              }
            }
            firstFragmentOffset = dataOffset + 8 + botLen;
          }
          break;
        }
        offset = dataOffset;
        continue;
      }

      if (tag == DicomTag.pixelData) {
        pixelDataLength = vl;
        firstFragmentOffset = dataOffset;
        break; 
      }

      if (vl > 0 && vl < 1024 * 1024 && vr != 'SQ') { 
        await raf.setPosition(dataOffset);
        final valBytes = await raf.read(vl);
        
        dynamic value;
        if (vr == 'UI' || vr == 'SH' || vr == 'LO' || vr == 'CS' || vr == 'PN' || vr == 'IS' || vr == 'DS' || vr == 'AS') {
          value = String.fromCharCodes(valBytes).replaceAll('\x00', '').trim();
          if (vr == 'IS' || vr == 'DS') {
            final parts = (value as String).split('\\').map((e) => e.trim()).toList();
            if (parts.length == 1) {
              value = vr == 'IS' ? int.tryParse(parts[0]) : double.tryParse(parts[0]);
            } else {
              value = parts.map((e) => vr == 'IS' ? int.tryParse(e) : double.tryParse(e)).toList();
            }
          } else {
            final parts = (value as String).split('\\');
            if (parts.length > 1) {
              value = parts;
            }
          }
        } else if (vr == 'US' || vr == 'UL') {
          if (vl == 2) {
             value = valBytes.buffer.asByteData().getUint16(0, endian);
          } else if (vl == 4) {
             value = valBytes.buffer.asByteData().getUint32(0, endian);
          }
        } else {
           value = valBytes;
        }

        tags[tag] = value;

        if (tag == DicomTag.transferSyntaxUid) {
          if (value is String) {
            transferSyntax = value;
            if (transferSyntax == '1.2.840.10008.1.2') {
              isExplicitVR = false;
            } else if (transferSyntax == '1.2.840.10008.1.2.2') {
              isExplicitVR = true;
              endian = Endian.big;
            }
          }
        }
      } else if (vr == 'SQ' && vl > 0) {
        // If we encounter a sequence with known length, we could step into it or skip it.
        // For simplicity, we step into it by not advancing past it, just advancing the header.
        offset = dataOffset;
        continue;
      }

      offset = dataOffset + vl;
    }

    success = true;
    return DicomFile(raf, endian, tags, basicOffsetTable, firstFragmentOffset, isEncapsulated, transferSyntax, pixelDataLength, path, maxConcurrency);
  } finally {
    if (!success) {
      await raf.close();
    }
  }
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
  
  // If it's a pyramid level, typically VOLUME. Otherwise LABEL, OVERVIEW, etc.
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
  });
  
  @override
  String toString() => 'DicomMetadata(type: $type, frames: $numberOfFrames, matrix: ${totalPixelMatrixColumns}x$totalPixelMatrixRows, tile: ${columns}x$rows)';
}

Future<DicomMetadata?> readDicomMetadata(DicomFile dicom) async {
  try {
    final sopClass = dicom.tags[DicomTag.sopClassUid] as String? ?? '';
    final sopInst = dicom.tags[DicomTag.sopInstanceUid] as String? ?? '';
    final studyUid = dicom.tags[DicomTag.studyInstanceUid] as String? ?? '';
    final seriesUid = dicom.tags[DicomTag.seriesInstanceUid] as String? ?? '';
    
    dynamic imgTypeRaw = dicom.tags[DicomTag.imageType];
    List<String> imgType = [];
    if (imgTypeRaw is String) imgType = [imgTypeRaw];
    else if (imgTypeRaw is List) imgType = imgTypeRaw.map((e) => e.toString()).toList();

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
    );
  } catch (e) {
    return null;
  }
}

Future<Uint8List?> extractDicomFrame(DicomFile dicom, int frameIndex, {CancellationToken? cancelToken}) async {
  if (frameIndex < 0) return null;
  final numFrames = dicom.tags[DicomTag.numberOfFrames] as int? ?? 1;
  if (frameIndex >= numFrames) return null;

  if (dicom.isEncapsulated) {
    // For encapsulated pixel data, we use the basic offset table if available
    int offset = dicom.firstFragmentOffset;
    if (dicom.basicOffsetTable.isNotEmpty && frameIndex < dicom.basicOffsetTable.length) {
      offset += dicom.basicOffsetTable[frameIndex];
    } else if (frameIndex > 0) {
      // Missing BOT, we can't reliably jump. In WSI, BOT is usually present.
      return null;
    }

    final raf = await dicom._acquireHandle(cancelToken: cancelToken);
    if (raf == null) return null;
    try {
      await raf.setPosition(offset);
      final itemHead = await raf.read(8);
      if (itemHead.length < 8) return null;
      
      final tag = itemHead.buffer.asByteData().getUint32(0, dicom.endian);
      if (tag == 0xFFFEE000) {
        final len = itemHead.buffer.asByteData().getUint32(4, dicom.endian);
        return await raf.read(len);
      }
    } finally {
      if (raf != dicom.raf) dicom._releaseHandle(raf);
    }
  } else {
    // Uncompressed
    final rows = dicom.tags[DicomTag.rows] as int? ?? 0;
    final columns = dicom.tags[DicomTag.columns] as int? ?? 0;
    final samples = dicom.tags[DicomTag.samplesPerPixel] as int? ?? 1;
    final bitsAlloc = dicom.tags[DicomTag.bitsAllocated] as int? ?? 8;
    final bytesPerPixel = (bitsAlloc / 8).ceil() * samples;
    final frameSize = rows * columns * bytesPerPixel;

    final offset = dicom.firstFragmentOffset + frameIndex * frameSize;
    return await dicom.readBytesAt(offset, frameSize, cancelToken: cancelToken);
  }
  return null;
}

Future<img.Image?> extractDicomFrameAsImage(DicomFile dicom, int frameIndex, {CancellationToken? cancelToken}) async {
  final bytes = await extractDicomFrame(dicom, frameIndex, cancelToken: cancelToken);
  if (bytes == null || bytes.isEmpty) return null;

  if (dicom.isEncapsulated) {
    // For jpeg, jpeg2000, etc.
    return img.decodeImage(bytes);
  } else {
    // Uncompressed
    final rows = dicom.tags[DicomTag.rows] as int? ?? 0;
    final columns = dicom.tags[DicomTag.columns] as int? ?? 0;
    final samples = dicom.tags[DicomTag.samplesPerPixel] as int? ?? 1;
    final bitsAlloc = dicom.tags[DicomTag.bitsAllocated] as int? ?? 8;
    final photoInterp = dicom.tags[DicomTag.photometricInterpretation] as String? ?? 'MONOCHROME2';

    if (bitsAlloc == 8 && samples == 3 && photoInterp == 'RGB') {
      return img.Image.fromBytes(width: columns, height: rows, bytes: bytes.buffer, order: img.ChannelOrder.rgb);
    } else if (bitsAlloc == 8 && samples == 1) {
      final image = img.Image.fromBytes(width: columns, height: rows, bytes: bytes.buffer, order: img.ChannelOrder.red);
      // For MONOCHROME1 we might need to invert, for now just returning the red channel grayscale equivalent
      return image;
    }
    // We could add more formats (16-bit, YBR, etc.) but let's stick to basics for this PR
    return null; // Unsupported uncompressed format
  }
}
