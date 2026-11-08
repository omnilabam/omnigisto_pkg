import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Method for retrieving a study: typically configured from DICOM server settings.
enum DicomRetrieveMethod {
  /// Server opens a new connection to the station and sends C-STORE.
  cMove,

  /// Server sends C-STORE within the same connection as the request.
  cGet,
}

/// Machine-readable error code for C-MOVE or C-GET.
enum DicomRetrieveErrorCode {
  emptyHost,
  invalidPort,
  emptyAeTitle,
  emptyStudyUid,
  invalidListenPort,
  outputDirectoryFailed,
  listenPortUnavailable,
  storageNotAccepted,
  moveDestinationTimeout,
  noObjects,
  cancelled,
  associationRejected,
  unsupportedSopClass,
  unsupportedTransferSyntax,
  associationAborted,
  protocolViolation,
  incomplete,
  serverError,
  timeout,
  connectionClosed,
  unknown,
}

/// Typed exception for C-MOVE or C-GET operations.
class DicomRetrieveException implements Exception {
  final DicomRetrieveErrorCode code;
  final String? detail;
  final int? statusCode;

  const DicomRetrieveException(
    this.code, {
    this.detail,
    this.statusCode,
  });

  String get message {
    final base = switch (code) {
      DicomRetrieveErrorCode.emptyHost => 'DICOM server host is not specified',
      DicomRetrieveErrorCode.invalidPort => 'Invalid DICOM server port',
      DicomRetrieveErrorCode.emptyAeTitle => 'AE Title is not specified',
      DicomRetrieveErrorCode.emptyStudyUid =>
        'Study Instance UID is not specified',
      DicomRetrieveErrorCode.invalidListenPort =>
        'Invalid C-MOVE station listen port',
      DicomRetrieveErrorCode.outputDirectoryFailed =>
        'Unable to create the download directory',
      DicomRetrieveErrorCode.listenPortUnavailable =>
        'C-MOVE station listen port is unavailable',
      DicomRetrieveErrorCode.storageNotAccepted =>
        'Server did not accept C-GET storage contexts',
      DicomRetrieveErrorCode.moveDestinationTimeout =>
        'C-MOVE destination did not receive any objects',
      DicomRetrieveErrorCode.noObjects => 'No DICOM objects were received',
      DicomRetrieveErrorCode.cancelled => 'DICOM retrieval was cancelled',
      DicomRetrieveErrorCode.associationRejected =>
        'Association rejected by server (A-ASSOCIATE-RJ)',
      DicomRetrieveErrorCode.unsupportedSopClass =>
        'Server does not support C-MOVE/C-GET SOP Class',
      DicomRetrieveErrorCode.unsupportedTransferSyntax =>
        'Server proposed an unsupported Transfer Syntax',
      DicomRetrieveErrorCode.associationAborted =>
        'Server aborted the retrieval association',
      DicomRetrieveErrorCode.protocolViolation => 'DICOM protocol violation',
      DicomRetrieveErrorCode.incomplete =>
        'DICOM retrieval completed with warnings',
      DicomRetrieveErrorCode.serverError =>
        'DICOM retrieval returned a server error',
      DicomRetrieveErrorCode.timeout =>
        'Timed out waiting for a response from the DICOM server',
      DicomRetrieveErrorCode.connectionClosed =>
        'Connection closed by the remote server',
      DicomRetrieveErrorCode.unknown => 'DICOM retrieval failed',
    };
    final extra = detail;
    if (extra == null || extra.isEmpty) return base;
    return '$base: $extra';
  }

  @override
  String toString() {
    final extra = detail;
    if (extra == null || extra.isEmpty)
      return 'DicomRetrieveException(${code.name})';
    return 'DicomRetrieveException(${code.name}: $extra)';
  }
}

/// Retrieval progress. [remaining] is present only if the server provided a counter.
class DicomRetrieveProgress {
  final int receivedFiles;
  final int? remaining;
  final int? completed;
  final int? failed;
  final int? warning;

  const DicomRetrieveProgress({
    required this.receivedFiles,
    this.remaining,
    this.completed,
    this.failed,
    this.warning,
  });
}

/// Result of C-MOVE or C-GET. Files are stored in [directory] as Part 10 `.dcm`.
class DicomRetrieveResult {
  final bool isSuccess;
  final String? directory;
  final int receivedCount;
  final int? statusCode;
  final List<String> files;
  final DicomRetrieveException? error;

  const DicomRetrieveResult({
    required this.isSuccess,
    this.directory,
    this.receivedCount = 0,
    this.statusCode,
    this.files = const [],
    this.error,
  });

  /// Machine-readable error code. `null` on success without warnings.
  DicomRetrieveErrorCode? get errorCode => error?.code;

  /// Display text composed from the error or retrieval result.
  String get message {
    final failure = error;
    if (failure != null) {
      if (isSuccess && receivedCount > 0)
        return '${failure.message} (received $receivedCount files)';
      return failure.message;
    }
    if (isSuccess)
      return 'DICOM retrieval succeeded (received $receivedCount files)';
    return 'DICOM retrieval failed';
  }
}

/// Retrieves a study by Study Instance UID.
///
/// C-GET and incoming C-STORE for C-MOVE stream objects to disk,
/// without buffering the whole image in memory. Viewing is handled as a separate step.
class DicomRetrieveClient {
  static const applicationContextUid = '1.2.840.10008.3.1.1.1';
  static const explicitVrLittleEndianUid = '1.2.840.10008.1.2.1';
  static const implicitVrLittleEndianUid = '1.2.840.10008.1.2';
  static const explicitVrBigEndianUid = '1.2.840.10008.1.2.2';
  static const implementationClassUid = '1.2.826.0.1.3680043.9.7133.1.1';
  static const implementationVersionName = 'OMNIHISTO_1_0';

  static const studyRootMoveSopClassUid = '1.2.840.10008.5.1.4.1.2.2.2';
  static const studyRootGetSopClassUid = '1.2.840.10008.5.1.4.1.2.2.3';
  static const patientRootMoveSopClassUid = '1.2.840.10008.5.1.4.1.2.1.2';
  static const patientRootGetSopClassUid = '1.2.840.10008.5.1.4.1.2.1.3';

  static const wholeSlideSopClassUid = '1.2.840.10008.5.1.4.1.1.77.1.6';
  static const secondaryCaptureSopClassUid = '1.2.840.10008.5.1.4.1.1.7';

  static const _studyRootPcId = 1;
  static const _patientRootPcId = 3;

  static Future<DicomRetrieveResult> retrieve({
    required String host,
    required int port,
    required String calledAeTitle,
    required String callingAeTitle,
    required String studyInstanceUid,
    required DicomRetrieveMethod method,
    required String outputDirectory,
    int listenPort = 11112,
    Duration timeout = const Duration(minutes: 3),
    bool Function()? isCancelled,
    void Function(DicomRetrieveProgress progress)? onProgress,
  }) {
    return _RetrieveSession(
      host: host,
      port: port,
      calledAeTitle: calledAeTitle,
      callingAeTitle: callingAeTitle,
      studyInstanceUid: studyInstanceUid,
      method: method,
      outputDirectory: outputDirectory,
      listenPort: listenPort,
      timeout: timeout,
      isCancelled: isCancelled ?? () => false,
      onProgress: onProgress,
    ).run();
  }
}

class _RetrieveSession {
  _RetrieveSession({
    required this.host,
    required this.port,
    required this.calledAeTitle,
    required this.callingAeTitle,
    required this.studyInstanceUid,
    required this.method,
    required this.outputDirectory,
    required this.listenPort,
    required this.timeout,
    required this.isCancelled,
    required this.onProgress,
  });

  final String host;
  final int port;
  final String calledAeTitle;
  final String callingAeTitle;
  final String studyInstanceUid;
  final DicomRetrieveMethod method;
  final String outputDirectory;
  final int listenPort;
  final Duration timeout;
  final bool Function() isCancelled;
  final void Function(DicomRetrieveProgress progress)? onProgress;

  final _Hub _hub = _Hub();
  final List<_Peer> _peers = [];
  final List<String> _files = [];
  ServerSocket? _listener;
  var _received = 0;
  var _index = 0;
  int? _finalStatus;
  int? _remaining;
  int? _completed;
  int? _failed;
  int? _warning;
  var _storesInFlight = 0;

  Future<DicomRetrieveResult> run() async {
    final calledAe = calledAeTitle.trim();
    final callingAe = callingAeTitle.trim();
    final studyUid = studyInstanceUid.trim();
    final trimmedHost = host.trim();
    if (trimmedHost.isEmpty) {
      return const DicomRetrieveResult(
        isSuccess: false,
        error: DicomRetrieveException(DicomRetrieveErrorCode.emptyHost),
      );
    }
    if (port <= 0 || port > 65535) {
      return const DicomRetrieveResult(
        isSuccess: false,
        error: DicomRetrieveException(DicomRetrieveErrorCode.invalidPort),
      );
    }
    if (calledAe.isEmpty || callingAe.isEmpty) {
      return const DicomRetrieveResult(
        isSuccess: false,
        error: DicomRetrieveException(DicomRetrieveErrorCode.emptyAeTitle),
      );
    }
    if (studyUid.isEmpty) {
      return const DicomRetrieveResult(
        isSuccess: false,
        error: DicomRetrieveException(DicomRetrieveErrorCode.emptyStudyUid),
      );
    }
    if (method == DicomRetrieveMethod.cMove &&
        (listenPort <= 0 || listenPort > 65535)) {
      return const DicomRetrieveResult(
        isSuccess: false,
        error: DicomRetrieveException(DicomRetrieveErrorCode.invalidListenPort),
      );
    }

    final directory = Directory(outputDirectory);
    try {
      await directory.create(recursive: true);
    } catch (e) {
      return DicomRetrieveResult(
        isSuccess: false,
        error: DicomRetrieveException(
          DicomRetrieveErrorCode.outputDirectoryFailed,
          detail: e.toString(),
        ),
      );
    }

    try {
      if (method == DicomRetrieveMethod.cMove) {
        try {
          _listener =
              await ServerSocket.bind(InternetAddress.anyIPv4, listenPort);
        } on SocketException catch (e) {
          return DicomRetrieveResult(
            isSuccess: false,
            error: DicomRetrieveException(
              DicomRetrieveErrorCode.listenPortUnavailable,
              detail: 'Port $listenPort for $callingAe: ${e.message}',
            ),
          );
        }
        _listener!.listen(
          (socket) {
            final peer = _attach(socket, store: true);
            _peers.add(peer);
          },
          onError: (Object error) => _hub.add(_Evt.failed(error)),
        );
      }

      final socket = await Socket.connect(
        trimmedHost,
        port,
        timeout: timeout < const Duration(seconds: 20)
            ? timeout
            : const Duration(seconds: 20),
      );
      final retrieve = _attach(socket, store: false);
      _peers.add(retrieve);

      final retrieveSop = method == DicomRetrieveMethod.cGet
          ? DicomRetrieveClient.studyRootGetSopClassUid
          : DicomRetrieveClient.studyRootMoveSopClassUid;
      final patientSop = method == DicomRetrieveMethod.cGet
          ? DicomRetrieveClient.patientRootGetSopClassUid
          : DicomRetrieveClient.patientRootMoveSopClassUid;
      socket.add(_buildAssociateRq(
        calledAe: calledAe,
        callingAe: callingAe,
        studyRootSop: retrieveSop,
        patientRootSop: patientSop,
        proposeStorage: method == DicomRetrieveMethod.cGet,
      ));
      await socket.flush();

      final associate = await _next();
      if (associate.kind != _EvtKind.pdu || associate.pdu?.type != 0x02) {
        if (associate.pdu?.type == 0x03) {
          return _fail(
            DicomRetrieveErrorCode.associationRejected,
            detail: _reject(associate.pdu!.data),
          );
        }
        if (associate.kind == _EvtKind.closed ||
            associate.kind == _EvtKind.failed) {
          return _fail(
            DicomRetrieveErrorCode.connectionClosed,
            detail: associate.error?.toString() ??
                'Connection closed before association was accepted',
          );
        }
        return _fail(
          DicomRetrieveErrorCode.protocolViolation,
          detail: 'Unexpected response to A-ASSOCIATE-RQ',
        );
      }
      final accepted = _acceptedContexts(associate.pdu!.data);
      final study = accepted[DicomRetrieveClient._studyRootPcId];
      final patient = accepted[DicomRetrieveClient._patientRootPcId];
      final chosen = study ?? patient;
      if (chosen == null) {
        return _fail(
          _hasTransferSyntaxRejection(associate.pdu!.data)
              ? DicomRetrieveErrorCode.unsupportedTransferSyntax
              : DicomRetrieveErrorCode.unsupportedSopClass,
          detail:
              'Server accepted no Study Root or Patient Root retrieve context',
        );
      }
      if (chosen != DicomRetrieveClient.explicitVrLittleEndianUid &&
          chosen != DicomRetrieveClient.implicitVrLittleEndianUid) {
        return _fail(
          DicomRetrieveErrorCode.unsupportedTransferSyntax,
          detail: 'Server proposed $chosen for the retrieve request',
        );
      }
      retrieve.accepted.addAll(accepted);
      retrieve.retrievePcIds.add(study != null
          ? DicomRetrieveClient._studyRootPcId
          : DicomRetrieveClient._patientRootPcId);
      retrieve.associated = true;

      if (method == DicomRetrieveMethod.cGet) {
        final storageAccepted = accepted.keys.any((id) => id != 1 && id != 3);
        if (!storageAccepted) {
          return _fail(
            DicomRetrieveErrorCode.storageNotAccepted,
            detail:
                'PACS did not accept Storage Presentation Contexts for C-GET',
          );
        }
      }

      final pcId = retrieve.retrievePcIds.single;
      final explicitVr =
          chosen == DicomRetrieveClient.explicitVrLittleEndianUid;
      final dataset = _identifier(studyUid, explicitVr: explicitVr);
      socket.add(_buildRetrieveRq(
        presentationContextId: pcId,
        sopClassUid: pcId == DicomRetrieveClient._patientRootPcId
            ? patientSop
            : retrieveSop,
        moveDestination: method == DicomRetrieveMethod.cMove ? callingAe : null,
        dataset: dataset,
      ));
      await socket.flush();

      final finished = await _loop();
      if (finished != null) return finished;
      return _resultFromStatus();
    } on _Cancelled {
      return _fail(DicomRetrieveErrorCode.cancelled, partial: true);
    } on SocketException catch (e) {
      return _fail(
        DicomRetrieveErrorCode.connectionClosed,
        detail: '$trimmedHost:$port: ${e.message}',
        partial: true,
      );
    } on TimeoutException catch (e) {
      final code = method == DicomRetrieveMethod.cMove && _received == 0
          ? DicomRetrieveErrorCode.moveDestinationTimeout
          : DicomRetrieveErrorCode.timeout;
      return _fail(code, detail: e.message, partial: true);
    } on FormatException catch (e) {
      return _fail(DicomRetrieveErrorCode.protocolViolation,
          detail: e.message, partial: true);
    } catch (e) {
      return _fail(DicomRetrieveErrorCode.unknown,
          detail: e.toString(), partial: true);
    } finally {
      await _closeAll();
    }
  }

  Future<DicomRetrieveResult?> _loop() async {
    while (true) {
      final event = await _next();
      switch (event.kind) {
        case _EvtKind.failed:
          if (_received > 0 && _finalStatus != null) return _resultFromStatus();
          final code = event.error is FormatException
              ? DicomRetrieveErrorCode.protocolViolation
              : DicomRetrieveErrorCode.connectionClosed;
          return _fail(code, detail: event.error.toString(), partial: true);
        case _EvtKind.closed:
          final peer = event.peer;
          if (peer != null && !peer.store && _finalStatus == null) {
            return _fail(
              DicomRetrieveErrorCode.connectionClosed,
              detail:
                  'Server closed the association before retrieval completed',
              partial: true,
            );
          }
          continue;
        case _EvtKind.pdu:
          final peer = event.peer;
          final pdu = event.pdu;
          if (peer == null || pdu == null) continue;
          final done = await _onPdu(peer, pdu);
          if (done != null) return done;
          if (_finalStatus != null && _storesInFlight == 0)
            return _resultFromStatus();
      }
    }
  }

  Future<DicomRetrieveResult?> _onPdu(_Peer peer, _Pdu pdu) async {
    switch (pdu.type) {
      case 0x04:
        await _onPData(peer, pdu.data);
        return null;
      case 0x05:
        peer.socket.add(_releaseRp);
        await peer.socket.flush();
        if (!peer.store && _finalStatus == null) {
          return _fail(
            DicomRetrieveErrorCode.protocolViolation,
            detail:
                'Server released the association before the retrieve response',
            partial: true,
          );
        }
        return null;
      case 0x06:
        peer.released = true;
        return null;
      case 0x07:
        if (!peer.store && _finalStatus == null) {
          return _fail(
            DicomRetrieveErrorCode.associationAborted,
            detail: 'Server sent A-ABORT before the retrieve completed',
            partial: true,
          );
        }
        return null;
      case 0x01:
        if (peer.store) {
          await _acceptStore(peer, pdu.data);
        }
        return null;
      default:
        return _fail(
          DicomRetrieveErrorCode.protocolViolation,
          detail: 'Unexpected PDU 0x${pdu.type.toRadixString(16)}',
          partial: true,
        );
    }
  }

  Future<void> _onPData(_Peer peer, Uint8List data) async {
    var offset = 0;
    while (offset + 6 <= data.length) {
      final length = _readU32be(data, offset);
      if (length < 2 || offset + 4 + length > data.length) break;
      final pcId = data[offset + 4];
      final control = data[offset + 5];
      final fragment =
          Uint8List.sublistView(data, offset + 6, offset + 4 + length);
      await _onPdv(peer, pcId, control, fragment);
      offset += 4 + length;
    }
  }

  Future<void> _onPdv(
      _Peer peer, int pcId, int control, Uint8List fragment) async {
    final command = (control & 0x01) != 0;
    final last = (control & 0x02) != 0;
    final assembly = peer.assemblies.putIfAbsent(pcId, () => _Assembly(pcId));
    if (command) {
      assembly.command.add(fragment);
      if (!last) return;
      assembly.cmd =
          _parseCommand(Uint8List.fromList(assembly.command.toBytes()));
      assembly.command.clear();
      assembly.commandDone = true;
      assembly.expectDataset = assembly.cmd!.datasetPresent;
      if (assembly.expectDataset &&
          !peer.retrievePcIds.contains(pcId) &&
          assembly.cmd!.field == 0x0001) {
        _storesInFlight += 1;
        await _openStoreFile(peer, assembly);
      }
      if (!assembly.expectDataset) {
        await _finishMessage(peer, assembly);
      }
      return;
    }

    if (!assembly.commandDone) return;
    if (assembly.file != null) {
      await assembly.file!.writeFrom(fragment);
      assembly.datasetBytes += fragment.length;
    }
    if (last) {
      await _finishMessage(peer, assembly);
    }
  }

  Future<void> _openStoreFile(_Peer peer, _Assembly assembly) async {
    final cmd = assembly.cmd!;
    final uid = cmd.sopInstanceUid.isEmpty
        ? '1.2.826.0.1.3680043.9.7133.9.${DateTime.now().microsecondsSinceEpoch}.${_index + 1}'
        : cmd.sopInstanceUid;
    final name = _safeFileName(uid, _index + 1);
    final path = _join(outputDirectory, name);
    final syntax = peer.accepted[assembly.pcId] ??
        DicomRetrieveClient.explicitVrLittleEndianUid;
    final header = _fileMeta(
      sopClassUid: cmd.sopClassUid.isEmpty
          ? DicomRetrieveClient.secondaryCaptureSopClassUid
          : cmd.sopClassUid,
      sopInstanceUid: uid,
      transferSyntaxUid: syntax,
    );
    final raf = await File(path).open(mode: FileMode.write);
    await raf.writeFrom(header);
    assembly.file = raf;
    assembly.path = path;
    assembly.sopInstanceUid = uid;
  }

  Future<void> _finishMessage(_Peer peer, _Assembly assembly) async {
    peer.assemblies.remove(assembly.pcId);
    final cmd = assembly.cmd;
    if (cmd == null) {
      await assembly.file?.close();
      return;
    }
    if (peer.retrievePcIds.contains(assembly.pcId)) {
      await assembly.file?.close();
      _onRetrieveResponse(cmd);
      return;
    }

    final wasStore = cmd.field == 0x0001;
    if (wasStore) {
      _storesInFlight = (_storesInFlight - 1).clamp(0, 1 << 30);
    }
    try {
      await assembly.file?.close();
      assembly.file = null;
    } catch (_) {}

    if (wasStore && assembly.path != null) {
      _files.add(assembly.path!);
      _received += 1;
      _index += 1;
      _emit();
      await _sendStoreRsp(peer, assembly.pcId, cmd, 0x0000);
      return;
    }
    if (assembly.path != null) {
      try {
        await File(assembly.path!).delete();
      } catch (_) {}
    }
    if (cmd.field == 0x0030) {
      await _sendCommand(
        peer,
        assembly.pcId,
        _responseCommand(
          sopClassUid: cmd.sopClassUid,
          sopInstanceUid: '',
          commandField: 0x8030,
          messageId: cmd.messageId,
          status: 0x0000,
        ),
      );
    } else if (cmd.field < 0x8000) {
      await _sendCommand(
        peer,
        assembly.pcId,
        _responseCommand(
          sopClassUid: cmd.sopClassUid,
          sopInstanceUid: cmd.sopInstanceUid,
          commandField: cmd.field | 0x8000,
          messageId: cmd.messageId,
          status: 0x0110,
        ),
      );
    }
  }

  void _onRetrieveResponse(_Command cmd) {
    if (cmd.remaining != null) _remaining = cmd.remaining;
    if (cmd.completed != null) _completed = cmd.completed;
    if (cmd.failed != null) _failed = cmd.failed;
    if (cmd.warning != null) _warning = cmd.warning;
    _emit();
    if (cmd.status != 0xFF00 && cmd.status != 0xFF01) {
      _finalStatus = cmd.status;
    }
  }

  Future<void> _acceptStore(_Peer peer, Uint8List rq) async {
    if (rq.length < 68) {
      peer.socket.add(_abort);
      return;
    }
    final called = ascii.decode(rq.sublist(4, 20), allowInvalid: true);
    final calling = ascii.decode(rq.sublist(20, 36), allowInvalid: true);
    final contexts = _proposedContexts(rq);
    final accepted = <int, String>{};
    for (final context in contexts) {
      if (context.transferSyntaxes.isEmpty) continue;
      accepted[context.pcId] = _selectTransferSyntax(context.transferSyntaxes);
    }
    peer.accepted.addAll(accepted);
    peer.socket.add(_buildAssociateAc(
      calledAe: called,
      callingAe: calling,
      accepted: accepted,
    ));
    await peer.socket.flush();
    peer.associated = true;
  }

  Future<void> _sendStoreRsp(_Peer peer, int pcId, _Command cmd, int status) {
    return _sendCommand(
      peer,
      pcId,
      _responseCommand(
        sopClassUid: cmd.sopClassUid,
        sopInstanceUid: cmd.sopInstanceUid,
        commandField: 0x8001,
        messageId: cmd.messageId,
        status: status,
      ),
    );
  }

  Future<void> _sendCommand(_Peer peer, int pcId, Uint8List command) async {
    try {
      peer.socket.add(_pdata(presentationContextId: pcId, command: command));
      await peer.socket.flush();
    } catch (_) {}
  }

  Future<_Evt> _next() async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (isCancelled()) throw const _Cancelled();
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('Timed out waiting for DICOM response');
      }
      final slice = left < const Duration(milliseconds: 400)
          ? left
          : const Duration(milliseconds: 400);
      try {
        return await _hub.next(slice);
      } on TimeoutException {
        continue;
      }
    }
  }

  void _emit() {
    onProgress?.call(DicomRetrieveProgress(
      receivedFiles: _received,
      remaining: _remaining,
      completed: _completed,
      failed: _failed,
      warning: _warning,
    ));
  }

  DicomRetrieveResult _resultFromStatus() {
    final status = _finalStatus;
    final ok = status == null || status == 0x0000 || status == 0xB000;
    if (_received > 0 && ok) {
      return DicomRetrieveResult(
        isSuccess: true,
        directory: outputDirectory,
        receivedCount: _received,
        statusCode: status,
        files: List<String>.unmodifiable(_files),
        error: status == 0xB000 || (_failed ?? 0) > 0
            ? DicomRetrieveException(
                DicomRetrieveErrorCode.incomplete,
                detail:
                    'Status ${status == null ? 'unknown' : '0x${status.toRadixString(16).padLeft(4, '0')}'}; '
                    '${_failed ?? 0} sub-operations failed',
                statusCode: status,
              )
            : null,
      );
    }
    if (_received > 0) {
      return DicomRetrieveResult(
        isSuccess: true,
        directory: outputDirectory,
        receivedCount: _received,
        statusCode: status,
        files: List<String>.unmodifiable(_files),
        error: DicomRetrieveException(
          DicomRetrieveErrorCode.serverError,
          detail:
              'Server returned status 0x${(status ?? 0).toRadixString(16).padLeft(4, '0')}',
          statusCode: status,
        ),
      );
    }
    return DicomRetrieveResult(
      isSuccess: false,
      directory: outputDirectory,
      statusCode: status,
      error: status == null || status == 0x0000 || status == 0xB000
          ? DicomRetrieveException(DicomRetrieveErrorCode.noObjects,
              statusCode: status)
          : status == 0xFE00
              ? DicomRetrieveException(DicomRetrieveErrorCode.cancelled,
                  statusCode: status)
              : DicomRetrieveException(
                  DicomRetrieveErrorCode.serverError,
                  detail:
                      'Server returned status 0x${status.toRadixString(16).padLeft(4, '0')}',
                  statusCode: status,
                ),
    );
  }

  DicomRetrieveResult _fail(
    DicomRetrieveErrorCode code, {
    String? detail,
    bool partial = false,
  }) {
    final failure =
        DicomRetrieveException(code, detail: detail, statusCode: _finalStatus);
    if (partial && _received > 0) {
      return DicomRetrieveResult(
        isSuccess: true,
        directory: outputDirectory,
        receivedCount: _received,
        statusCode: _finalStatus,
        files: List<String>.unmodifiable(_files),
        error: failure,
      );
    }
    return DicomRetrieveResult(
      isSuccess: false,
      directory: outputDirectory,
      receivedCount: _received,
      statusCode: _finalStatus,
      files: List<String>.unmodifiable(_files),
      error: failure,
    );
  }

  _Peer _attach(Socket socket, {required bool store}) {
    final peer = _Peer(socket, store: store);
    final reader = _PduReader();
    socket.done.catchError((Object _) {});
    peer.subscription = socket.listen(
      (data) {
        for (final pdu in reader.append(data)) {
          _hub.add(_Evt.pdu(peer, pdu));
        }
      },
      onError: (Object error, StackTrace _) =>
          _hub.add(_Evt.failed(error, peer)),
      onDone: () => _hub.add(_Evt.closed(peer)),
      cancelOnError: false,
    );
    return peer;
  }

  Future<void> _closeAll() async {
    for (final peer in _peers) {
      for (final assembly in peer.assemblies.values) {
        try {
          await assembly.file?.close();
        } catch (_) {}
      }
      if (peer.associated && !peer.released) {
        try {
          peer.socket.add(_finalStatus != null && !peer.store
              ? const [
                  0x05,
                  0x00,
                  0x00,
                  0x00,
                  0x00,
                  0x04,
                  0x00,
                  0x00,
                  0x00,
                  0x00
                ]
              : _abort);
        } catch (_) {}
      }
      await peer.subscription?.cancel();
      try {
        await peer.socket.close();
      } catch (_) {}
    }
    try {
      await _listener?.close();
    } catch (_) {}
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

enum _EvtKind { pdu, closed, failed }

class _Evt {
  final _EvtKind kind;
  final _Peer? peer;
  final _Pdu? pdu;
  final Object? error;

  const _Evt._(this.kind, this.peer, this.pdu, this.error);

  factory _Evt.pdu(_Peer peer, _Pdu pdu) =>
      _Evt._(_EvtKind.pdu, peer, pdu, null);

  factory _Evt.closed(_Peer peer) => _Evt._(_EvtKind.closed, peer, null, null);

  factory _Evt.failed(Object error, [_Peer? peer]) =>
      _Evt._(_EvtKind.failed, peer, null, error);
}

class _Hub {
  final _events = <_Evt>[];
  final _waiters = <Completer<_Evt>>[];

  void add(_Evt event) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(event);
    } else {
      _events.add(event);
    }
  }

  Future<_Evt> next(Duration timeout) {
    if (_events.isNotEmpty) return Future<_Evt>.value(_events.removeAt(0));
    final completer = Completer<_Evt>();
    _waiters.add(completer);
    return completer.future.timeout(timeout, onTimeout: () {
      _waiters.remove(completer);
      throw TimeoutException('slice');
    });
  }
}

class _Peer {
  _Peer(this.socket, {required this.store});

  final Socket socket;
  final bool store;
  final accepted = <int, String>{};
  final retrievePcIds = <int>{};
  final assemblies = <int, _Assembly>{};
  StreamSubscription<List<int>>? subscription;
  var associated = false;
  var released = false;
}

class _Assembly {
  _Assembly(this.pcId);

  final int pcId;
  final BytesBuilder command = BytesBuilder(copy: false);
  _Command? cmd;
  var commandDone = false;
  var expectDataset = false;
  RandomAccessFile? file;
  String? path;
  String sopInstanceUid = '';
  var datasetBytes = 0;
}

class _Command {
  int field = 0;
  int messageId = 0;
  int status = 0;
  bool datasetPresent = false;
  String sopClassUid = '';
  String sopInstanceUid = '';
  int? remaining;
  int? completed;
  int? failed;
  int? warning;
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
      final pduLen = _readU32be(allBytes, offset + 2);
      if (offset + 6 + pduLen > allBytes.length) break;
      pdus.add(_Pdu(
        pduType,
        Uint8List.fromList(allBytes.sublist(offset + 6, offset + 6 + pduLen)),
      ));
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

class _ProposedContext {
  final int pcId;
  final List<String> transferSyntaxes;

  const _ProposedContext(this.pcId, this.transferSyntaxes);
}

Uint8List _buildAssociateRq({
  required String calledAe,
  required String callingAe,
  required String studyRootSop,
  required String patientRootSop,
  required bool proposeStorage,
}) {
  final bb = BytesBuilder();
  bb.addByte(0x00);
  bb.addByte(0x01);
  bb.addByte(0x00);
  bb.addByte(0x00);
  bb.add(_padAe(calledAe));
  bb.add(_padAe(callingAe));
  bb.add(Uint8List(32));
  _addUidItem(bb, 0x10, DicomRetrieveClient.applicationContextUid);

  final offers = proposeStorage ? _storageOffers() : const <_StorageOffer>[];
  _addPresentationContext(
      bb, DicomRetrieveClient._studyRootPcId, studyRootSop, const [
    DicomRetrieveClient.explicitVrLittleEndianUid,
    DicomRetrieveClient.implicitVrLittleEndianUid,
  ]);
  _addPresentationContext(
      bb, DicomRetrieveClient._patientRootPcId, patientRootSop, const [
    DicomRetrieveClient.explicitVrLittleEndianUid,
    DicomRetrieveClient.implicitVrLittleEndianUid,
  ]);
  var pcId = 5;
  for (final offer in offers) {
    if (pcId > 255) break;
    _addPresentationContext(bb, pcId, offer.sop, offer.syntaxes);
    pcId += 2;
  }

  final user = BytesBuilder();
  user.addByte(0x51);
  user.addByte(0x00);
  user.add(_u16be(4));
  user.add(_u32be(16384));
  _addUidItem(user, 0x52, DicomRetrieveClient.implementationClassUid);
  final version = ascii.encode(DicomRetrieveClient.implementationVersionName);
  user.addByte(0x55);
  user.addByte(0x00);
  user.add(_u16be(version.length));
  user.add(version);
  if (proposeStorage) {
    final roles = <String>{for (final offer in offers) offer.sop};
    for (final sop in roles) {
      if (pcId > 255 && !offers.any((offer) => offer.sop == sop)) continue;
      user.add(_roleSelection(sop, scu: 0, scp: 1));
    }
  }
  final userPayload = user.toBytes();
  bb.addByte(0x50);
  bb.addByte(0x00);
  bb.add(_u16be(userPayload.length));
  bb.add(userPayload);

  return _pdu(0x01, bb.toBytes());
}

Uint8List _buildAssociateAc({
  required String calledAe,
  required String callingAe,
  required Map<int, String> accepted,
}) {
  final bb = BytesBuilder();
  bb.addByte(0x00);
  bb.addByte(0x01);
  bb.addByte(0x00);
  bb.addByte(0x00);
  bb.add(_padAe(calledAe.trim()));
  bb.add(_padAe(callingAe.trim()));
  bb.add(Uint8List(32));
  _addUidItem(bb, 0x10, DicomRetrieveClient.applicationContextUid);
  for (final entry in accepted.entries) {
    final ts = ascii.encode(entry.value);
    final item = BytesBuilder();
    item.addByte(entry.key);
    item.addByte(0x00);
    item.addByte(0x00);
    item.addByte(0x00);
    item.addByte(0x40);
    item.addByte(0x00);
    item.add(_u16be(ts.length));
    item.add(ts);
    final payload = item.toBytes();
    bb.addByte(0x21);
    bb.addByte(0x00);
    bb.add(_u16be(payload.length));
    bb.add(payload);
  }
  final user = BytesBuilder();
  user.addByte(0x51);
  user.addByte(0x00);
  user.add(_u16be(4));
  user.add(_u32be(16384));
  _addUidItem(user, 0x52, DicomRetrieveClient.implementationClassUid);
  final version = ascii.encode(DicomRetrieveClient.implementationVersionName);
  user.addByte(0x55);
  user.addByte(0x00);
  user.add(_u16be(version.length));
  user.add(version);
  final userPayload = user.toBytes();
  bb.addByte(0x50);
  bb.addByte(0x00);
  bb.add(_u16be(userPayload.length));
  bb.add(userPayload);
  return _pdu(0x02, bb.toBytes());
}

void _addPresentationContext(
    BytesBuilder bb, int pcId, String sop, List<String> syntaxes) {
  final pc = BytesBuilder();
  pc.addByte(pcId);
  pc.addByte(0x00);
  pc.addByte(0x00);
  pc.addByte(0x00);
  _addUidItem(pc, 0x30, sop);
  for (final syntax in syntaxes) {
    _addUidItem(pc, 0x40, syntax);
  }
  final payload = pc.toBytes();
  bb.addByte(0x20);
  bb.addByte(0x00);
  bb.add(_u16be(payload.length));
  bb.add(payload);
}

void _addUidItem(BytesBuilder bb, int type, String uid) {
  final bytes = ascii.encode(uid);
  bb.addByte(type);
  bb.addByte(0x00);
  bb.add(_u16be(bytes.length));
  bb.add(bytes);
}

Uint8List _roleSelection(String sop, {required int scu, required int scp}) {
  final uid = ascii.encode(sop);
  final item = BytesBuilder();
  item.addByte(0x54);
  item.addByte(0x00);
  item.add(_u16be(2 + uid.length + 2));
  item.add(_u16be(uid.length));
  item.add(uid);
  item.addByte(scu);
  item.addByte(scp);
  return item.toBytes();
}

Uint8List _buildRetrieveRq({
  required int presentationContextId,
  required String sopClassUid,
  required String? moveDestination,
  required Uint8List dataset,
}) {
  final command = _requestCommand(
    sopClassUid: sopClassUid,
    commandField: moveDestination == null ? 0x0010 : 0x0021,
    messageId: 1,
    moveDestination: moveDestination,
  );
  return _pdata(
    presentationContextId: presentationContextId,
    command: command,
    dataset: dataset,
  );
}

Uint8List _requestCommand({
  required String sopClassUid,
  required int commandField,
  required int messageId,
  String? moveDestination,
}) {
  final body = BytesBuilder();
  void addEl(int element, List<int> value) {
    body.add(_u16le(0x0000));
    body.add(_u16le(element));
    body.add(_u32le(value.length));
    body.add(value);
  }

  addEl(0x0002, _padEven(ascii.encode(sopClassUid), 0x00));
  addEl(0x0100, _u16le(commandField));
  addEl(0x0110, _u16le(messageId));
  if (moveDestination != null) {
    addEl(0x0600, _padAe(moveDestination));
  }
  addEl(0x0700, _u16le(0));
  addEl(0x0800, _u16le(0x0000));
  return _withGroupLength(body.toBytes());
}

Uint8List _responseCommand({
  required String sopClassUid,
  required String sopInstanceUid,
  required int commandField,
  required int messageId,
  required int status,
}) {
  final body = BytesBuilder();
  void addEl(int element, List<int> value) {
    body.add(_u16le(0x0000));
    body.add(_u16le(element));
    body.add(_u32le(value.length));
    body.add(value);
  }

  if (sopClassUid.isNotEmpty) {
    addEl(0x0002, _padEven(ascii.encode(sopClassUid), 0x00));
  }
  addEl(0x0100, _u16le(commandField));
  addEl(0x0120, _u16le(messageId));
  addEl(0x0800, _u16le(0x0101));
  addEl(0x0900, _u16le(status));
  if (sopInstanceUid.isNotEmpty) {
    addEl(0x1000, _padEven(ascii.encode(sopInstanceUid), 0x00));
  }
  return _withGroupLength(body.toBytes());
}

Uint8List _withGroupLength(Uint8List payload) {
  final full = BytesBuilder();
  full.add(_u16le(0x0000));
  full.add(_u16le(0x0000));
  full.add(_u32le(4));
  full.add(_u32le(payload.length));
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
    pdvs.add(_u32be(2 + fragment.length));
    pdvs.addByte(presentationContextId);
    pdvs.addByte(control);
    pdvs.add(fragment);
  }

  // PS3.8 E.2: bit 0 — command, bit 1 — last fragment.
  addPdv(command, 0x03);
  if (dataset != null) addPdv(dataset, 0x02);
  return _pdu(0x04, pdvs.toBytes());
}

Uint8List _identifier(String studyUid, {required bool explicitVr}) {
  final bb = BytesBuilder();
  _addText(bb, 0x0008, 0x0052, 'CS', 'STUDY', explicitVr: explicitVr);
  _addText(bb, 0x0020, 0x000D, 'UI', studyUid, explicitVr: explicitVr);
  return bb.toBytes();
}

void _addText(
  BytesBuilder bb,
  int group,
  int element,
  String vr,
  String value, {
  required bool explicitVr,
}) {
  final pad = vr == 'UI' ? 0x00 : 0x20;
  final encoded = _padEven(ascii.encode(value), pad);
  bb.add(_u16le(group));
  bb.add(_u16le(element));
  if (explicitVr) {
    bb.add(ascii.encode(vr));
    bb.add(_u16le(encoded.length));
  } else {
    bb.add(_u32le(encoded.length));
  }
  bb.add(encoded);
}

Map<int, String> _acceptedContexts(Uint8List pduData) {
  final result = <int, String>{};
  if (pduData.length < 68) return result;
  var offset = 68;
  while (offset + 4 <= pduData.length) {
    final itemType = pduData[offset];
    final itemLen = _u16beAt(pduData, offset + 2);
    final itemStart = offset + 4;
    if (itemStart + itemLen > pduData.length) break;
    if (itemType == 0x21 && itemLen >= 4 && pduData[itemStart + 2] == 0) {
      final pcId = pduData[itemStart];
      var syntax = DicomRetrieveClient.implicitVrLittleEndianUid;
      var sub = itemStart + 4;
      final itemEnd = itemStart + itemLen;
      while (sub + 4 <= itemEnd) {
        final subType = pduData[sub];
        final subLen = _u16beAt(pduData, sub + 2);
        final subStart = sub + 4;
        if (subStart + subLen > itemEnd) break;
        if (subType == 0x40 && subLen > 0) {
          syntax = ascii
              .decode(pduData.sublist(subStart, subStart + subLen),
                  allowInvalid: true)
              .trim();
          break;
        }
        sub = subStart + subLen;
      }
      result[pcId] = syntax;
    }
    offset = itemStart + itemLen;
  }
  return result;
}

bool _hasTransferSyntaxRejection(Uint8List pduData) {
  if (pduData.length < 68) return false;
  var offset = 68;
  while (offset + 4 <= pduData.length) {
    final itemType = pduData[offset];
    final itemLen = _u16beAt(pduData, offset + 2);
    final itemStart = offset + 4;
    if (itemStart + itemLen > pduData.length) return false;
    if (itemType == 0x21 && itemLen >= 4 && pduData[itemStart + 2] == 4)
      return true;
    offset = itemStart + itemLen;
  }
  return false;
}

List<_ProposedContext> _proposedContexts(Uint8List pduData) {
  final contexts = <_ProposedContext>[];
  if (pduData.length < 68) return contexts;
  var offset = 68;
  while (offset + 4 <= pduData.length) {
    final itemType = pduData[offset];
    final itemLen = _u16beAt(pduData, offset + 2);
    final itemStart = offset + 4;
    if (itemStart + itemLen > pduData.length) break;
    if (itemType == 0x20 && itemLen >= 4) {
      final pcId = pduData[itemStart];
      final syntaxes = <String>[];
      var sub = itemStart + 4;
      final itemEnd = itemStart + itemLen;
      while (sub + 4 <= itemEnd) {
        final subType = pduData[sub];
        final subLen = _u16beAt(pduData, sub + 2);
        final subStart = sub + 4;
        if (subStart + subLen > itemEnd) break;
        if (subType == 0x40 && subLen > 0) {
          syntaxes.add(ascii
              .decode(pduData.sublist(subStart, subStart + subLen),
                  allowInvalid: true)
              .trim());
        }
        sub = subStart + subLen;
      }
      contexts.add(_ProposedContext(pcId, syntaxes));
    }
    offset = itemStart + itemLen;
  }
  return contexts;
}

_Command _parseCommand(Uint8List data) {
  final cmd = _Command();
  var offset = 0;
  final view = ByteData.sublistView(data);
  while (offset + 8 <= data.length) {
    final group = view.getUint16(offset, Endian.little);
    final element = view.getUint16(offset + 2, Endian.little);
    final length = view.getUint32(offset + 4, Endian.little);
    if (length == 0xFFFFFFFF || offset + 8 + length > data.length) break;
    final value = Uint8List.sublistView(data, offset + 8, offset + 8 + length);
    if (group == 0x0000) {
      switch (element) {
        case 0x0002:
          cmd.sopClassUid = _trimUid(value);
        case 0x0100:
          if (value.length >= 2)
            cmd.field = ByteData.sublistView(value).getUint16(0, Endian.little);
        case 0x0110:
        case 0x0120:
          if (value.length >= 2)
            cmd.messageId =
                ByteData.sublistView(value).getUint16(0, Endian.little);
        case 0x0800:
          if (value.length >= 2) {
            final type =
                ByteData.sublistView(value).getUint16(0, Endian.little);
            cmd.datasetPresent = type != 0x0101;
          }
        case 0x0900:
          if (value.length >= 2)
            cmd.status =
                ByteData.sublistView(value).getUint16(0, Endian.little);
        case 0x1000:
          cmd.sopInstanceUid = _trimUid(value);
        case 0x1020:
          cmd.remaining = _u16(value);
        case 0x1021:
          cmd.completed = _u16(value);
        case 0x1022:
          cmd.failed = _u16(value);
        case 0x1023:
          cmd.warning = _u16(value);
      }
    }
    offset += 8 + length;
  }
  return cmd;
}

Uint8List _fileMeta({
  required String sopClassUid,
  required String sopInstanceUid,
  required String transferSyntaxUid,
}) {
  final body = BytesBuilder();
  body.add(_metaOb(0x0002, 0x0001, [0x00, 0x01]));
  body.add(_metaUi(0x0002, 0x0002, sopClassUid));
  body.add(_metaUi(0x0002, 0x0003, sopInstanceUid));
  body.add(_metaUi(0x0002, 0x0010, transferSyntaxUid));
  body.add(_metaUi(0x0002, 0x0012, DicomRetrieveClient.implementationClassUid));
  body.add(
      _metaSh(0x0002, 0x0013, DicomRetrieveClient.implementationVersionName));
  final payload = body.toBytes();
  final meta = BytesBuilder();
  meta.add(_metaUl(0x0002, 0x0000, payload.length));
  meta.add(payload);
  final file = BytesBuilder();
  file.add(Uint8List(128));
  file.add(ascii.encode('DICM'));
  file.add(meta.toBytes());
  return file.toBytes();
}

List<int> _metaUl(int group, int element, int value) {
  return [
    ..._u16le(group),
    ..._u16le(element),
    ...ascii.encode('UL'),
    ..._u16le(4),
    ..._u32le(value)
  ];
}

List<int> _metaOb(int group, int element, List<int> value) {
  final padded = value.length.isOdd ? [...value, 0] : value;
  return [
    ..._u16le(group),
    ..._u16le(element),
    ...ascii.encode('OB'),
    0x00,
    0x00,
    ..._u32le(padded.length),
    ...padded,
  ];
}

List<int> _metaUi(int group, int element, String value) {
  final padded = _padEven(ascii.encode(value), 0x00);
  return [
    ..._u16le(group),
    ..._u16le(element),
    ...ascii.encode('UI'),
    ..._u16le(padded.length),
    ...padded
  ];
}

List<int> _metaSh(int group, int element, String value) {
  final padded = _padEven(ascii.encode(value), 0x20);
  return [
    ..._u16le(group),
    ..._u16le(element),
    ...ascii.encode('SH'),
    ..._u16le(padded.length),
    ...padded
  ];
}

class _StorageOffer {
  final String sop;
  final List<String> syntaxes;

  const _StorageOffer(this.sop, this.syntaxes);
}

const _richSyntaxes = <String>[
  DicomRetrieveClient.explicitVrLittleEndianUid,
  DicomRetrieveClient.implicitVrLittleEndianUid,
  DicomRetrieveClient.explicitVrBigEndianUid,
  '1.2.840.10008.1.2.4.50',
  '1.2.840.10008.1.2.4.57',
  '1.2.840.10008.1.2.4.70',
  '1.2.840.10008.1.2.4.80',
  '1.2.840.10008.1.2.4.90',
  '1.2.840.10008.1.2.4.91',
  '1.2.840.10008.1.2.5',
];

const _basicSyntaxes = <String>[
  DicomRetrieveClient.explicitVrLittleEndianUid,
  DicomRetrieveClient.implicitVrLittleEndianUid,
  '1.2.840.10008.1.2.4.50',
  '1.2.840.10008.1.2.4.90',
];

const _richSops = <String>[
  DicomRetrieveClient.wholeSlideSopClassUid,
  '1.2.840.10008.5.1.4.1.1.77.1.3',
  '1.2.840.10008.5.1.4.1.1.77.1.2',
  '1.2.840.10008.5.1.4.1.1.77.1.4',
  DicomRetrieveClient.secondaryCaptureSopClassUid,
  '1.2.840.10008.5.1.4.1.1.7.4',
  '1.2.840.10008.5.1.4.1.1.2',
  '1.2.840.10008.5.1.4.1.1.4',
];

const _basicSops = <String>[
  '1.2.840.10008.5.1.4.1.1.1',
  '1.2.840.10008.5.1.4.1.1.1.1',
  '1.2.840.10008.5.1.4.1.1.1.1.1',
  '1.2.840.10008.5.1.4.1.1.2.1',
  '1.2.840.10008.5.1.4.1.1.4.1',
  '1.2.840.10008.5.1.4.1.1.6.1',
  '1.2.840.10008.5.1.4.1.1.3.1',
  '1.2.840.10008.5.1.4.1.1.12.1',
  '1.2.840.10008.5.1.4.1.1.20',
  '1.2.840.10008.5.1.4.1.1.128',
  '1.2.840.10008.5.1.4.1.1.66',
  '1.2.840.10008.5.1.4.1.1.77.1.1',
  '1.2.840.10008.5.1.4.1.1.1.2',
  '1.2.840.10008.5.1.4.1.1.77.1.5.1',
  '1.2.840.10008.5.1.4.1.1.7.2',
  '1.2.840.10008.5.1.4.1.1.7.3',
];

List<_StorageOffer> _storageOffers() {
  final offers = <_StorageOffer>[];
  for (final sop in _richSops) {
    for (final syntax in _richSyntaxes) {
      offers.add(_StorageOffer(sop, [syntax]));
    }
  }
  for (final sop in _basicSops) {
    offers.add(_StorageOffer(sop, _basicSyntaxes));
  }
  return offers;
}

String _selectTransferSyntax(List<String> offered) {
  for (final preferred in _richSyntaxes) {
    if (offered.contains(preferred)) return preferred;
  }
  for (final preferred in _basicSyntaxes) {
    if (offered.contains(preferred)) return preferred;
  }
  return offered.first;
}

String _reject(Uint8List data) {
  if (data.length < 4) return 'no reason given';
  return 'result=${data[1]} source=${data[2]} reason=${data[3]}';
}

String _trimUid(Uint8List raw) {
  var end = raw.length;
  while (end > 0 && (raw[end - 1] == 0 || raw[end - 1] == 0x20)) {
    end -= 1;
  }
  if (end <= 0) return '';
  return ascii.decode(raw.sublist(0, end), allowInvalid: true).trim();
}

int? _u16(Uint8List value) {
  if (value.length < 2) return null;
  return ByteData.sublistView(value).getUint16(0, Endian.little);
}

String _safeFileName(String uid, int index) {
  final safe = uid.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
  if (safe.isEmpty) return 'instance_$index.dcm';
  return '$safe.dcm';
}

String _join(String dir, String name) {
  final sep = Platform.pathSeparator;
  return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
}

Uint8List _pdu(int type, Uint8List data) {
  final pdu = BytesBuilder();
  pdu.addByte(type);
  pdu.addByte(0x00);
  pdu.add(_u32be(data.length));
  pdu.add(data);
  return pdu.toBytes();
}

List<int> _padAe(String value) {
  final codes = ascii.encode(value);
  final padded = List<int>.filled(16, 0x20);
  for (var i = 0; i < codes.length && i < 16; i++) {
    padded[i] = codes[i];
  }
  return padded;
}

List<int> _padEven(List<int> bytes, int pad) {
  if (bytes.length.isEven) return bytes;
  return [...bytes, pad];
}

int _readU32be(Uint8List bytes, int offset) {
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _u16beAt(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

List<int> _u16be(int value) => [(value >> 8) & 0xFF, value & 0xFF];

List<int> _u32be(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> _u16le(int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> _u32le(int value) => [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];

const List<int> _releaseRp = [
  0x06,
  0x00,
  0x00,
  0x00,
  0x00,
  0x04,
  0x00,
  0x00,
  0x00,
  0x00
];
const List<int> _abort = [
  0x07,
  0x00,
  0x00,
  0x00,
  0x00,
  0x04,
  0x00,
  0x00,
  0x00,
  0x00
];
