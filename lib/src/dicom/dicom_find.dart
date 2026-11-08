import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Query criteria for searching studies at the STUDY level (C-FIND).
///
/// An empty string means "no restriction". For text tags, DICOM wildcards
/// `*` and `?` can be used. [studyDate] is a date in DA format
/// (`YYYYMMDD`) or a range (`YYYYMMDD-YYYYMMDD`, `YYYYMMDD-`, `-YYYYMMDD`).
class DicomFindQuery {
  final String patientName;
  final String patientId;
  final String studyDate;
  final String accessionNumber;
  final String studyId;
  final String studyDescription;
  final String studyInstanceUid;
  final String referringPhysicianName;

  const DicomFindQuery({
    this.patientName = '',
    this.patientId = '',
    this.studyDate = '',
    this.accessionNumber = '',
    this.studyId = '',
    this.studyDescription = '',
    this.studyInstanceUid = '',
    this.referringPhysicianName = '',
  });

  bool get hasFilters =>
      patientName.trim().isNotEmpty ||
      patientId.trim().isNotEmpty ||
      studyDate.trim().isNotEmpty ||
      accessionNumber.trim().isNotEmpty ||
      studyId.trim().isNotEmpty ||
      studyDescription.trim().isNotEmpty ||
      studyInstanceUid.trim().isNotEmpty ||
      referringPhysicianName.trim().isNotEmpty;

  /// Identifier dataset for the C-FIND request.
  Uint8List toDataset({bool explicitVr = false}) {
    final values = <String>[
      patientName,
      patientId,
      studyDate,
      accessionNumber,
      studyId,
      studyDescription,
      studyInstanceUid,
      referringPhysicianName,
    ];
    final utf8Mode = values.any((value) => value.runes.any((rune) => rune > 127));
    final elements = <_Element>[];
    if (utf8Mode) {
      elements.add(_Element(0x0008, 0x0005, 'ISO_IR 192', _Vr.cs));
    }
    elements.addAll([
      _Element(0x0008, 0x0020, studyDate.trim(), _Vr.da),
      _Element(0x0008, 0x0030, '', _Vr.tm),
      _Element(0x0008, 0x0050, accessionNumber.trim(), _Vr.sh),
      _Element(0x0008, 0x0052, 'STUDY', _Vr.cs),
      _Element(0x0008, 0x0061, '', _Vr.cs),
      _Element(0x0008, 0x0090, referringPhysicianName.trim(), _Vr.pn),
      _Element(0x0008, 0x1030, studyDescription.trim(), _Vr.lo),
      _Element(0x0010, 0x0010, patientName.trim(), _Vr.pn),
      _Element(0x0010, 0x0020, patientId.trim(), _Vr.lo),
      _Element(0x0020, 0x000D, studyInstanceUid.trim(), _Vr.ui),
      _Element(0x0020, 0x0010, studyId.trim(), _Vr.sh),
    ]);
    return _encodeDataset(elements, explicitVr: explicitVr, utf8Mode: utf8Mode);
  }
}

/// A single study found by C-FIND.
class DicomStudyMatch {
  final String patientName;
  final String patientId;
  final String studyDate;
  final String studyTime;
  final String accessionNumber;
  final String studyId;
  final String studyDescription;
  final String studyInstanceUid;
  final String referringPhysicianName;
  final String modalities;

  const DicomStudyMatch({
    this.patientName = '',
    this.patientId = '',
    this.studyDate = '',
    this.studyTime = '',
    this.accessionNumber = '',
    this.studyId = '',
    this.studyDescription = '',
    this.studyInstanceUid = '',
    this.referringPhysicianName = '',
    this.modalities = '',
  });

  String get patientNameLabel => _personLabel(patientName);

  String get referringPhysicianLabel => _personLabel(referringPhysicianName);

  String get studyDateLabel {
    final raw = studyDate.trim();
    if (raw.isEmpty) return '';
    if (raw.contains('-')) {
      final parts = raw.split('-');
      final from = parts.isNotEmpty ? _formatDa(parts.first) : '';
      final to = parts.length > 1 ? _formatDa(parts[1]) : '';
      if (from.isEmpty && to.isEmpty) return raw;
      if (from.isEmpty) return 'to $to';
      if (to.isEmpty) return 'from $from';
      return '$from — $to';
    }
    return _formatDa(raw);
  }

  static String _personLabel(String value) {
    final cleaned = value.replaceAll('^', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
  }

  static String _formatDa(String value) {
    final digits = value.trim();
    if (digits.length < 8) return digits;
    final year = digits.substring(0, 4);
    final month = digits.substring(4, 6);
    final day = digits.substring(6, 8);
    if (int.tryParse(year) == null) return digits;
    return '$day.$month.$year';
  }
}

/// Machine-readable C-FIND error code.
enum DicomFindErrorCode {
  emptyHost,
  invalidPort,
  emptyAeTitle,
  connectionClosed,
  timeout,
  associationRejected,
  unsupportedTransferSyntax,
  unsupportedSopClass,
  associationAborted,
  protocolViolation,
  serverError,
  unknown,
}

/// Typed exception for C-FIND operation.
class DicomFindException implements Exception {
  final DicomFindErrorCode code;
  final String? detail;
  final int? statusCode;

  const DicomFindException(
    this.code, {
    this.detail,
    this.statusCode,
  });

  String get message {
    final base = switch (code) {
      DicomFindErrorCode.emptyHost => 'DICOM server host is not specified',
      DicomFindErrorCode.invalidPort => 'Invalid DICOM server port',
      DicomFindErrorCode.emptyAeTitle => 'AE Title is not specified',
      DicomFindErrorCode.connectionClosed => 'Connection closed by the remote server',
      DicomFindErrorCode.timeout => 'Timed out waiting for a response from the DICOM server',
      DicomFindErrorCode.associationRejected => 'Association rejected by server (A-ASSOCIATE-RJ)',
      DicomFindErrorCode.unsupportedTransferSyntax => 'Server proposed an unsupported Transfer Syntax',
      DicomFindErrorCode.unsupportedSopClass => 'Server does not support C-FIND (Study Root / Patient Root)',
      DicomFindErrorCode.associationAborted => 'Server aborted the association during C-FIND',
      DicomFindErrorCode.protocolViolation => 'DICOM protocol violation',
      DicomFindErrorCode.serverError => 'C-FIND returned an error',
      DicomFindErrorCode.unknown => 'C-FIND failed',
    };
    final extra = detail;
    if (extra == null || extra.isEmpty) return base;
    return '$base: $extra';
  }

  @override
  String toString() {
    final extra = detail;
    if (extra == null || extra.isEmpty) return 'DicomFindException(${code.name})';
    return 'DicomFindException(${code.name}: $extra)';
  }
}

/// Result of a C-FIND operation.
///
/// The error is represented by [errorCode] and a typed [error], rather than
/// an arbitrary string. [message] compiles human-readable text for display.
class DicomFindResult {
  final bool isSuccess;
  final List<DicomStudyMatch> studies;
  final int? statusCode;
  final bool truncated;

  /// Typed error. `null` if the operation completed without error.
  final DicomFindException? error;

  final int? _resultLimit;

  const DicomFindResult({
    required this.isSuccess,
    this.studies = const [],
    this.statusCode,
    this.truncated = false,
    this.error,
    int? resultLimit,
  }) : _resultLimit = resultLimit;

  /// Machine-readable error code. `null` on success.
  DicomFindErrorCode? get errorCode => error?.code;

  /// Display text composed from [errorCode] and result fields.
  String get message {
    final failure = error;
    if (failure != null) return failure.message;
    if (studies.isEmpty) return 'No studies found';
    final shown = _resultLimit ?? studies.length;
    final limitNote = truncated ? ' Showing the first $shown.' : '';
    return 'Studies found: ${studies.length}.$limitNote';
  }
}

/// DICOM C-FIND client (Study Root / Patient Root, STUDY level).
class DicomFindClient {
  static const String studyRootFindSopClassUid = '1.2.840.10008.5.1.4.1.2.2.1';
  static const String patientRootFindSopClassUid = '1.2.840.10008.5.1.4.1.2.1.1';
  static const String applicationContextUid = '1.2.840.10008.3.1.1.1';
  static const String implicitVrLittleEndianUid = '1.2.840.10008.1.2';
  static const String explicitVrLittleEndianUid = '1.2.840.10008.1.2.1';
  static const String implementationClassUid = '1.2.826.0.1.3680043.9.7133.1.1';
  static const String implementationVersionName = 'OMNIHISTO_1_0';

  static const int _studyRootPcId = 1;
  static const int _patientRootPcId = 3;

  /// Searches for studies on a remote DICOM node.
  ///
  /// Returns study identifiers. Image retrieval (C-MOVE / C-GET) is not
  /// performed by this method.
  static Future<DicomFindResult> find({
    required String host,
    required int port,
    required String calledAeTitle,
    required String callingAeTitle,
    required DicomFindQuery query,
    Duration timeout = const Duration(seconds: 20),
    int maxResults = 100,
  }) async {
    final calledAe = calledAeTitle.trim();
    final callingAe = callingAeTitle.trim();
    if (host.trim().isEmpty) {
      return const DicomFindResult(
        isSuccess: false,
        error: DicomFindException(DicomFindErrorCode.emptyHost),
      );
    }
    if (port <= 0 || port > 65535) {
      return const DicomFindResult(
        isSuccess: false,
        error: DicomFindException(DicomFindErrorCode.invalidPort),
      );
    }
    if (calledAe.isEmpty || callingAe.isEmpty) {
      return const DicomFindResult(
        isSuccess: false,
        error: DicomFindException(DicomFindErrorCode.emptyAeTitle),
      );
    }

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    StreamSubscription<List<int>>? subscription;
    var associated = false;

    try {
      socket = await Socket.connect(host.trim(), port, timeout: timeout);
      final reader = _PduReader();
      final pendingPdus = <_Pdu>[];
      final waiters = <Completer<_Pdu>>[];

      void deliver(List<_Pdu> pdus) {
        for (final pdu in pdus) {
          if (waiters.isNotEmpty) {
            waiters.removeAt(0).complete(pdu);
          } else {
            pendingPdus.add(pdu);
          }
        }
      }

      subscription = socket.listen(
        (data) => deliver(reader.append(data)),
        onError: (Object err) {
          while (waiters.isNotEmpty) {
            waiters.removeAt(0).completeError(err);
          }
        },
        onDone: () {
          while (waiters.isNotEmpty) {
            waiters.removeAt(0).completeError(
              const DicomFindException(DicomFindErrorCode.connectionClosed),
            );
          }
        },
      );

      Future<_Pdu> nextPdu() {
        if (pendingPdus.isNotEmpty) {
          return Future<_Pdu>.value(pendingPdus.removeAt(0));
        }
        final completer = Completer<_Pdu>();
        waiters.add(completer);
        return completer.future.timeout(timeout, onTimeout: () {
          waiters.remove(completer);
          throw DicomFindException(
            DicomFindErrorCode.timeout,
            detail: '${host.trim()}:$port',
          );
        });
      }

      socket.add(_buildAssociateRq(calledAe: calledAe, callingAe: callingAe));
      await socket.flush();

      final associateResponse = await nextPdu();
      if (associateResponse.type == 0x03) {
        return DicomFindResult(
          isSuccess: false,
          error: DicomFindException(
            DicomFindErrorCode.associationRejected,
            detail: _parseAssociateReject(associateResponse.data),
          ),
        );
      }
      if (associateResponse.type != 0x02) {
        return DicomFindResult(
          isSuccess: false,
          error: DicomFindException(
            DicomFindErrorCode.protocolViolation,
            detail: 'unexpected association response, PDU 0x${associateResponse.type.toRadixString(16)}',
          ),
        );
      }

      final accepted = _acceptedContext(associateResponse.data);
      if (accepted == null) {
        await _tryRelease(socket, nextPdu);
        return const DicomFindResult(
          isSuccess: false,
          error: DicomFindException(DicomFindErrorCode.unsupportedSopClass),
        );
      }
      final explicitVr = accepted.transferSyntax == explicitVrLittleEndianUid;
      if (!explicitVr && accepted.transferSyntax != implicitVrLittleEndianUid) {
        await _tryRelease(socket, nextPdu);
        return DicomFindResult(
          isSuccess: false,
          error: DicomFindException(
            DicomFindErrorCode.unsupportedTransferSyntax,
            detail: accepted.transferSyntax,
          ),
        );
      }
      associated = true;

      const messageId = 1;
      socket.add(_buildCFindRq(
        presentationContextId: accepted.pcId,
        messageId: messageId,
        sopClassUid: accepted.sopClassUid,
        dataset: query.toDataset(explicitVr: explicitVr),
      ));
      await socket.flush();

      final studies = <DicomStudyMatch>[];
      var truncated = false;
      var cancelSent = false;
      int? finalStatus;
      var commandBuf = BytesBuilder();
      var datasetBuf = BytesBuilder();
      var commandComplete = false;
      var datasetComplete = false;

      void resetMessage() {
        commandBuf = BytesBuilder();
        datasetBuf = BytesBuilder();
        commandComplete = false;
        datasetComplete = false;
      }

      while (true) {
        final pdu = await nextPdu();
        if (pdu.type == 0x07) {
          return DicomFindResult(
            isSuccess: studies.isNotEmpty,
            studies: studies,
            truncated: truncated,
            error: const DicomFindException(DicomFindErrorCode.associationAborted),
          );
        }
        if (pdu.type == 0x05) {
          socket.add(_releaseRp);
          await socket.flush();
          break;
        }
        if (pdu.type != 0x04) {
          return DicomFindResult(
            isSuccess: false,
            studies: studies,
            error: DicomFindException(
              DicomFindErrorCode.protocolViolation,
              detail: 'expected P-DATA-TF, received PDU 0x${pdu.type.toRadixString(16)}',
            ),
          );
        }

        for (final pdv in _splitPdvs(pdu.data)) {
          if (pdv.command) {
            commandBuf.add(pdv.fragment);
            if (pdv.last) commandComplete = true;
          } else {
            datasetBuf.add(pdv.fragment);
            if (pdv.last) datasetComplete = true;
          }
        }
        if (!commandComplete) continue;

        final commandBytes = commandBuf.toBytes();
        final status = _commandStatus(commandBytes);
        final datasetType = _commandDatasetType(commandBytes);
        final expectDataset = datasetType == null
            ? status == 0xFF00 || status == 0xFF01
            : datasetType != 0x0101;
        if (expectDataset && !datasetComplete) continue;

        finalStatus = status;
        final pending = status == 0xFF00 || status == 0xFF01;
        final dataBytes = datasetBuf.toBytes();
        resetMessage();
        if (pending) {
          if (dataBytes.isNotEmpty) {
            studies.add(_studyFromDataset(dataBytes, explicitVr: explicitVr));
          }
          if (!cancelSent && studies.length >= maxResults) {
            truncated = true;
            cancelSent = true;
            socket.add(_buildCCancelFindRq(
              presentationContextId: accepted.pcId,
              messageId: messageId,
              sopClassUid: accepted.sopClassUid,
            ));
            await socket.flush();
          }
          continue;
        }

        stopwatch.stop();
        await _tryRelease(socket, nextPdu);
        associated = false;

        if (status == 0x0000 || status == 0xFE00) {
          return DicomFindResult(
            isSuccess: true,
            studies: studies,
            statusCode: status,
            truncated: truncated,
            resultLimit: maxResults,
          );
        }

        return DicomFindResult(
          isSuccess: false,
          studies: studies,
          statusCode: status,
          truncated: truncated,
          error: DicomFindException(
            DicomFindErrorCode.serverError,
            detail: _statusMessage(status),
            statusCode: status,
          ),
        );
      }

      stopwatch.stop();
      final releasedOk = finalStatus == null || finalStatus == 0x0000 || finalStatus == 0xFE00;
      return DicomFindResult(
        isSuccess: releasedOk,
        studies: studies,
        statusCode: finalStatus,
        truncated: truncated,
        resultLimit: maxResults,
        error: releasedOk
            ? null
            : DicomFindException(
                DicomFindErrorCode.serverError,
                detail: _statusMessage(finalStatus),
                statusCode: finalStatus,
              ),
      );
    } on DicomFindException catch (e) {
      return DicomFindResult(
        isSuccess: false,
        error: e,
        statusCode: e.statusCode,
      );
    } on SocketException catch (e) {
      return DicomFindResult(
        isSuccess: false,
        error: DicomFindException(
          DicomFindErrorCode.unknown,
          detail: '${host.trim()}:$port: ${e.message}',
        ),
      );
    } on TimeoutException {
      return DicomFindResult(
        isSuccess: false,
        error: DicomFindException(
          DicomFindErrorCode.timeout,
          detail: '${host.trim()}:$port',
        ),
      );
    } catch (e) {
      return DicomFindResult(
        isSuccess: false,
        error: DicomFindException(DicomFindErrorCode.unknown, detail: '$e'),
      );
    } finally {
      stopwatch.stop();
      if (associated && socket != null) {
        try {
          socket.add(_abort);
        } catch (_) {}
      }
      await subscription?.cancel();
      try {
        await socket?.close();
      } catch (_) {}
    }
  }
}

class _AcceptedContext {
  final int pcId;
  final String sopClassUid;
  final String transferSyntax;

  const _AcceptedContext({
    required this.pcId,
    required this.sopClassUid,
    required this.transferSyntax,
  });
}

enum _Vr { cs, da, tm, sh, lo, pn, ui }

class _Element {
  final int group;
  final int element;
  final String value;
  final _Vr vr;

  const _Element(this.group, this.element, this.value, this.vr);
}

class _Pdu {
  final int type;
  final Uint8List data;

  const _Pdu(this.type, this.data);
}

class _PduReader {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  List<_Pdu> append(List<int> chunk) {
    _buffer.add(chunk);
    final allBytes = _buffer.toBytes();
    final pdus = <_Pdu>[];
    var offset = 0;
    while (offset + 6 <= allBytes.length) {
      final pduType = allBytes[offset];
      final pduLen = (allBytes[offset + 2] << 24) |
          (allBytes[offset + 3] << 16) |
          (allBytes[offset + 4] << 8) |
          allBytes[offset + 5];
      if (pduLen < 0 || offset + 6 + pduLen > allBytes.length) break;
      pdus.add(_Pdu(pduType, Uint8List.sublistView(allBytes, offset + 6, offset + 6 + pduLen)));
      offset += 6 + pduLen;
    }
    if (offset > 0) {
      final remaining = allBytes.sublist(offset);
      _buffer.clear();
      if (remaining.isNotEmpty) _buffer.add(remaining);
    }
    return pdus;
  }
}

const List<int> _releaseRp = [0x06, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00];
const List<int> _abort = [0x07, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00];

Uint8List _buildAssociateRq({
  required String calledAe,
  required String callingAe,
}) {
  final bb = BytesBuilder();
  bb.addByte(0x00);
  bb.addByte(0x01);
  bb.addByte(0x00);
  bb.addByte(0x00);
  bb.add(_padAe(calledAe));
  bb.add(_padAe(callingAe));
  bb.add(Uint8List(32));

  final appCtx = ascii.encode(DicomFindClient.applicationContextUid);
  bb.addByte(0x10);
  bb.addByte(0x00);
  bb.add(_uint16Be(appCtx.length));
  bb.add(appCtx);

  void addPc(int pcId, String sop) {
    final pc = BytesBuilder();
    pc.addByte(pcId);
    pc.addByte(0x00);
    pc.addByte(0x00);
    pc.addByte(0x00);
    final abs = ascii.encode(sop);
    pc.addByte(0x30);
    pc.addByte(0x00);
    pc.add(_uint16Be(abs.length));
    pc.add(abs);
    for (final ts in [
      DicomFindClient.explicitVrLittleEndianUid,
      DicomFindClient.implicitVrLittleEndianUid,
    ]) {
      final tsBytes = ascii.encode(ts);
      pc.addByte(0x40);
      pc.addByte(0x00);
      pc.add(_uint16Be(tsBytes.length));
      pc.add(tsBytes);
    }
    final payload = pc.toBytes();
    bb.addByte(0x20);
    bb.addByte(0x00);
    bb.add(_uint16Be(payload.length));
    bb.add(payload);
  }

  addPc(DicomFindClient._studyRootPcId, DicomFindClient.studyRootFindSopClassUid);
  addPc(DicomFindClient._patientRootPcId, DicomFindClient.patientRootFindSopClassUid);

  final user = BytesBuilder();
  user.addByte(0x51);
  user.addByte(0x00);
  user.add(_uint16Be(4));
  user.add(_uint32Be(16384));
  final impl = ascii.encode(DicomFindClient.implementationClassUid);
  user.addByte(0x52);
  user.addByte(0x00);
  user.add(_uint16Be(impl.length));
  user.add(impl);
  final ver = ascii.encode(DicomFindClient.implementationVersionName);
  user.addByte(0x55);
  user.addByte(0x00);
  user.add(_uint16Be(ver.length));
  user.add(ver);
  final userPayload = user.toBytes();
  bb.addByte(0x50);
  bb.addByte(0x00);
  bb.add(_uint16Be(userPayload.length));
  bb.add(userPayload);

  final data = bb.toBytes();
  final pdu = BytesBuilder();
  pdu.addByte(0x01);
  pdu.addByte(0x00);
  pdu.add(_uint32Be(data.length));
  pdu.add(data);
  return pdu.toBytes();
}

Uint8List _buildCFindRq({
  required int presentationContextId,
  required int messageId,
  required String sopClassUid,
  required Uint8List dataset,
}) {
  final command = _commandSet(
    sopClassUid: sopClassUid,
    commandField: 0x0020,
    messageId: messageId,
    datasetPresent: true,
    priority: 0,
  );
  return _pdata(
    presentationContextId: presentationContextId,
    command: command,
    dataset: dataset,
  );
}

Uint8List _buildCCancelFindRq({
  required int presentationContextId,
  required int messageId,
  required String sopClassUid,
}) {
  final command = _commandSet(
    sopClassUid: sopClassUid,
    commandField: 0x0FFF,
    messageIdBeingRespondedTo: messageId,
    datasetPresent: false,
  );
  return _pdata(presentationContextId: presentationContextId, command: command);
}

Uint8List _commandSet({
  required String sopClassUid,
  required int commandField,
  int? messageId,
  int? messageIdBeingRespondedTo,
  int? priority,
  required bool datasetPresent,
}) {
  final body = BytesBuilder();
  void addEl(int element, int length, List<int> value) {
    body.add(_uint16Le(0x0000));
    body.add(_uint16Le(element));
    body.add(_uint32Le(length));
    body.add(value);
  }

  final sop = _padEven(ascii.encode(sopClassUid), 0x00);
  addEl(0x0002, sop.length, sop);
  addEl(0x0100, 2, _uint16Le(commandField));
  if (messageId != null) {
    addEl(0x0110, 2, _uint16Le(messageId));
  }
  if (messageIdBeingRespondedTo != null) {
    addEl(0x0120, 2, _uint16Le(messageIdBeingRespondedTo));
  }
  if (priority != null) {
    addEl(0x0700, 2, _uint16Le(priority));
  }
  addEl(0x0800, 2, _uint16Le(datasetPresent ? 0x0000 : 0x0101));

  final payload = body.toBytes();
  final full = BytesBuilder();
  full.add(_uint16Le(0x0000));
  full.add(_uint16Le(0x0000));
  full.add(_uint32Le(4));
  full.add(_uint32Le(payload.length));
  full.add(payload);
  return full.toBytes();
}

Uint8List _pdata({
  required int presentationContextId,
  required Uint8List command,
  Uint8List? dataset,
}) {
  final pdvs = BytesBuilder();
  void addPdv(Uint8List fragment, int control) {
    final length = 2 + fragment.length;
    pdvs.add(_uint32Be(length));
    pdvs.addByte(presentationContextId);
    pdvs.addByte(control);
    pdvs.add(fragment);
  }

  addPdv(command, 0x03);
  if (dataset != null) {
    // PS3.8 E.2: bit0 = command, bit1 = last fragment.
    // The last dataset fragment is 0x02. Orthanc reads 0x01 as a command.
    addPdv(dataset, 0x02);
  }
  final bytes = pdvs.toBytes();
  final pdu = BytesBuilder();
  pdu.addByte(0x04);
  pdu.addByte(0x00);
  pdu.add(_uint32Be(bytes.length));
  pdu.add(bytes);
  return pdu.toBytes();
}

_AcceptedContext? _acceptedContext(Uint8List pduData) {
  if (pduData.length < 68) return null;
  var offset = 68;
  while (offset + 4 <= pduData.length) {
    final itemType = pduData[offset];
    final itemLen = (pduData[offset + 2] << 8) | pduData[offset + 3];
    final itemStart = offset + 4;
    if (itemLen < 0 || itemStart + itemLen > pduData.length) break;
    if (itemType == 0x21 && itemLen >= 4) {
      final pcId = pduData[itemStart];
      final result = pduData[itemStart + 2];
      final wanted = pcId == DicomFindClient._studyRootPcId || pcId == DicomFindClient._patientRootPcId;
      if (wanted && result == 0) {
        var ts = DicomFindClient.implicitVrLittleEndianUid;
        var sub = itemStart + 4;
        final itemEnd = itemStart + itemLen;
        while (sub + 4 <= itemEnd) {
          final subType = pduData[sub];
          final subLen = (pduData[sub + 2] << 8) | pduData[sub + 3];
          final subStart = sub + 4;
          if (subLen < 0 || subStart + subLen > itemEnd) break;
          if (subType == 0x40 && subLen > 0) {
            ts = ascii.decode(pduData.sublist(subStart, subStart + subLen), allowInvalid: true).trim();
            break;
          }
          sub = subLen == 0 ? sub + 4 : subStart + subLen;
        }
        return _AcceptedContext(
          pcId: pcId,
          sopClassUid: pcId == DicomFindClient._patientRootPcId
              ? DicomFindClient.patientRootFindSopClassUid
              : DicomFindClient.studyRootFindSopClassUid,
          transferSyntax: ts,
        );
      }
    }
    offset = itemLen == 0 ? itemStart : itemStart + itemLen;
  }
  return null;
}

String _parseAssociateReject(Uint8List pduData) {
  if (pduData.length < 4) return 'Reason not specified';
  final result = pduData[1];
  final source = pduData[2];
  final reason = pduData[3];
  final resultStr = result == 1 ? 'Permanent' : 'Transient';
  final reasonStr = switch (reason) {
    1 => 'No reason given',
    2 => 'Application context name not supported',
    3 => 'Calling AE Title not recognized',
    7 => 'Called AE Title not recognized',
    _ => 'Code $reason',
  };
  return '$resultStr (Source: $source, Reason: $reasonStr)';
}

class _Pdv {
  final bool command;
  final bool last;
  final Uint8List fragment;

  const _Pdv({
    required this.command,
    required this.last,
    required this.fragment,
  });
}

List<_Pdv> _splitPdvs(Uint8List pduData) {
  final pdvs = <_Pdv>[];
  var offset = 0;
  final bd = ByteData.sublistView(pduData);
  while (offset + 6 <= pduData.length) {
    final length = bd.getUint32(offset);
    if (length < 2 || offset + 4 + length > pduData.length) break;
    final control = pduData[offset + 5];
    final fragment = Uint8List.sublistView(pduData, offset + 6, offset + 4 + length);
    pdvs.add(_Pdv(
      // PS3.8 E.2: bit 0 — command, bit 1 — last fragment.
      command: (control & 0x01) != 0,
      last: (control & 0x02) != 0,
      fragment: fragment,
    ));
    offset += 4 + length;
  }
  return pdvs;
}

int? _commandElement(Uint8List cmd, int wantedElement) {
  if (cmd.length < 8) return null;
  final bd = ByteData.sublistView(cmd);
  var offset = 0;
  while (offset + 8 <= cmd.length) {
    final group = bd.getUint16(offset, Endian.little);
    final element = bd.getUint16(offset + 2, Endian.little);
    final length = bd.getUint32(offset + 4, Endian.little);
    final valueAt = offset + 8;
    if (length < 0 || valueAt + length > cmd.length) break;
    if (group == 0x0000 && element == wantedElement && length >= 2) {
      return bd.getUint16(valueAt, Endian.little);
    }
    offset = valueAt + length;
  }
  return null;
}

int _commandStatus(Uint8List cmd) => _commandElement(cmd, 0x0900) ?? 0x0000;

int? _commandDatasetType(Uint8List cmd) => _commandElement(cmd, 0x0800);

DicomStudyMatch _studyFromDataset(Uint8List data, {required bool explicitVr}) {
  final values = <int, Uint8List>{};
  String? charset;
  void walk(Uint8List bytes, bool explicit) {
    final bd = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + 8 <= bytes.length) {
      final group = bd.getUint16(offset, Endian.little);
      final element = bd.getUint16(offset + 2, Endian.little);
      if (group == 0xFFFE) break;
      int length;
      int valueAt;
      if (explicit) {
        if (offset + 6 > bytes.length) break;
        final vr = ascii.decode(bytes.sublist(offset + 4, offset + 6), allowInvalid: true);
        if (_longVr(vr)) {
          if (offset + 12 > bytes.length) break;
          length = bd.getUint32(offset + 8, Endian.little);
          valueAt = offset + 12;
        } else {
          length = bd.getUint16(offset + 6, Endian.little);
          valueAt = offset + 8;
        }
      } else {
        length = bd.getUint32(offset + 4, Endian.little);
        valueAt = offset + 8;
      }
      if (length == 0xFFFFFFFF) {
        final end = _skipUndefined(bytes, valueAt);
        offset = end;
        continue;
      }
      if (length < 0 || valueAt + length > bytes.length) break;
      final raw = Uint8List.sublistView(bytes, valueAt, valueAt + length);
      final tag = (group << 16) | element;
      if (tag == 0x00080005) {
        charset = _decodeText(raw, null);
      }
      values[tag] = raw;
      offset = valueAt + length;
    }
  }

  walk(data, explicitVr);
  String text(int tag) => _decodeText(values[tag] ?? Uint8List(0), charset);
  return DicomStudyMatch(
    patientName: text(0x00100010),
    patientId: text(0x00100020),
    studyDate: text(0x00080020),
    studyTime: text(0x00080030),
    accessionNumber: text(0x00080050),
    studyId: text(0x00200010),
    studyDescription: text(0x00081030),
    studyInstanceUid: text(0x0020000D),
    referringPhysicianName: text(0x00080090),
    modalities: text(0x00080061).replaceAll('\\', ', '),
  );
}

bool _longVr(String vr) {
  const long = {'OB', 'OD', 'OF', 'OL', 'OV', 'OW', 'SQ', 'SV', 'UC', 'UN', 'UR', 'UT', 'UV'};
  return long.contains(vr);
}

int _skipUndefined(Uint8List bytes, int offset) {
  final bd = ByteData.sublistView(bytes);
  var depth = 1;
  var cursor = offset;
  while (cursor + 8 <= bytes.length && depth > 0) {
    final group = bd.getUint16(cursor, Endian.little);
    final element = bd.getUint16(cursor + 2, Endian.little);
    final length = bd.getUint32(cursor + 4, Endian.little);
    if (group == 0xFFFE && element == 0xE0DD) {
      depth -= 1;
      cursor += 8;
      continue;
    }
    if (group == 0xFFFE && element == 0xE000 && length == 0xFFFFFFFF) {
      depth += 1;
      cursor += 8;
      continue;
    }
    if (length == 0xFFFFFFFF) {
      cursor += 8;
      continue;
    }
    cursor += 8 + length;
  }
  return cursor;
}

String _decodeText(Uint8List raw, String? charset) {
  var end = raw.length;
  while (end > 0 && (raw[end - 1] == 0x00 || raw[end - 1] == 0x20)) {
    end -= 1;
  }
  if (end <= 0) return '';
  final bytes = raw.sublist(0, end);
  final cs = (charset ?? '').toUpperCase();
  if (cs.contains('ISO_IR 192') || cs.contains('UTF-8')) {
    return utf8.decode(bytes, allowMalformed: true).trim();
  }
  if (cs.contains('ISO_IR 144')) {
    return _decodeIso88595(bytes).trim();
  }
  if (bytes.any((b) => b >= 0x80)) {
    try {
      final decoded = utf8.decode(bytes);
      if (!decoded.contains('\uFFFD')) return decoded.trim();
    } catch (_) {}
  }
  return latin1.decode(bytes).trim();
}

String _decodeIso88595(List<int> bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0xA0) {
      out.writeCharCode(byte);
    } else if (byte == 0xAD) {
      out.writeCharCode(0x00AD);
    } else if (byte >= 0xA1 && byte <= 0xAC) {
      out.writeCharCode(0x0401 + (byte - 0xA1));
    } else if (byte == 0xAE || byte == 0xAF) {
      out.writeCharCode(0x040E + (byte - 0xAE));
    } else if (byte >= 0xB0) {
      out.writeCharCode(0x0410 + (byte - 0xB0));
    } else {
      out.writeCharCode(byte);
    }
  }
  return out.toString();
}

String _statusMessage(int status) {
  final hex = '0x${status.toRadixString(16).padLeft(4, '0')}';
  return switch (status) {
    0xA700 => '$hex Out of Resources',
    0xA900 => '$hex Identifier does not match SOP Class',
    0xC000 => '$hex Unable to process',
    0xFE00 => '$hex Cancel',
    _ => hex,
  };
}

Uint8List _encodeDataset(List<_Element> elements, {required bool explicitVr, required bool utf8Mode}) {
  final bb = BytesBuilder();
  for (final element in elements) {
    final pad = element.vr == _Vr.ui ? 0x00 : 0x20;
    final encoded = element.value.isEmpty
        ? const <int>[]
        : _padEven(utf8Mode ? utf8.encode(element.value) : latin1.encode(element.value), pad);
    bb.add(_uint16Le(element.group));
    bb.add(_uint16Le(element.element));
    if (explicitVr) {
      bb.add(ascii.encode(_vrName(element.vr)));
      bb.add(_uint16Le(encoded.length));
    } else {
      bb.add(_uint32Le(encoded.length));
    }
    bb.add(encoded);
  }
  return bb.toBytes();
}

String _vrName(_Vr vr) {
  return switch (vr) {
    _Vr.cs => 'CS',
    _Vr.da => 'DA',
    _Vr.tm => 'TM',
    _Vr.sh => 'SH',
    _Vr.lo => 'LO',
    _Vr.pn => 'PN',
    _Vr.ui => 'UI',
  };
}

Future<void> _tryRelease(Socket socket, Future<_Pdu> Function() nextPdu) async {
  try {
    socket.add(const [0x05, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]);
    await socket.flush();
    await nextPdu().timeout(const Duration(seconds: 2));
  } catch (_) {}
}

List<int> _padAe(String value) {
  final codes = ascii.encode(value);
  final res = List<int>.filled(16, 0x20);
  for (var i = 0; i < codes.length && i < 16; i++) {
    res[i] = codes[i];
  }
  return res;
}

List<int> _padEven(List<int> bytes, int pad) {
  if (bytes.length.isEven) return bytes;
  return [...bytes, pad];
}

List<int> _uint16Be(int value) => [(value >> 8) & 0xFF, value & 0xFF];

List<int> _uint32Be(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> _uint16Le(int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> _uint32Le(int value) => [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
