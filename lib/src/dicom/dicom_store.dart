import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Machine-readable C-STORE error code.
enum DicomStoreErrorCode {
  emptyHost,
  invalidPort,
  emptyAeTitle,
  emptyInstances,
  noStudyFiles,
  cancelled,
  prepareFailed,
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

/// Typed exception for C-STORE operation.
class DicomStoreException implements Exception {
  final DicomStoreErrorCode code;
  final String? detail;
  final int? statusCode;

  const DicomStoreException(
    this.code, {
    this.detail,
    this.statusCode,
  });

  String get message {
    final base = switch (code) {
      DicomStoreErrorCode.emptyHost => 'DICOM server host is not specified',
      DicomStoreErrorCode.invalidPort => 'Invalid DICOM server port',
      DicomStoreErrorCode.emptyAeTitle => 'AE Title is not specified',
      DicomStoreErrorCode.emptyInstances => 'No DICOM objects to send',
      DicomStoreErrorCode.noStudyFiles => 'No DICOM study files found',
      DicomStoreErrorCode.cancelled => 'C-STORE was cancelled',
      DicomStoreErrorCode.prepareFailed => 'Unable to prepare DICOM objects',
      DicomStoreErrorCode.associationRejected =>
        'Association rejected by server (A-ASSOCIATE-RJ)',
      DicomStoreErrorCode.unsupportedSopClass =>
        'Server does not support the requested SOP Class',
      DicomStoreErrorCode.unsupportedTransferSyntax =>
        'Server proposed an unsupported Transfer Syntax',
      DicomStoreErrorCode.associationAborted =>
        'Server aborted the C-STORE association',
      DicomStoreErrorCode.protocolViolation => 'DICOM protocol violation',
      DicomStoreErrorCode.incomplete => 'C-STORE completed with errors',
      DicomStoreErrorCode.serverError => 'C-STORE returned a server error',
      DicomStoreErrorCode.timeout =>
        'Timed out waiting for a response from the DICOM server',
      DicomStoreErrorCode.connectionClosed =>
        'Connection closed by the remote server',
      DicomStoreErrorCode.unknown => 'C-STORE failed',
    };
    final extra = detail;
    if (extra == null || extra.isEmpty) return base;
    return '$base: $extra';
  }

  @override
  String toString() {
    final extra = detail;
    if (extra == null || extra.isEmpty)
      return 'DicomStoreException(${code.name})';
    return 'DicomStoreException(${code.name}: $extra)';
  }
}

/// Result of DICOM C-STORE.
class DicomStoreResult {
  final bool isSuccess;
  final int storedCount;
  final int totalCount;
  final int? statusCode;

  /// Typed error. `null` if store operation succeeded.
  final DicomStoreException? error;

  const DicomStoreResult({
    required this.isSuccess,
    this.storedCount = 0,
    this.totalCount = 0,
    this.statusCode,
    this.error,
  });

  /// Machine-readable error code. `null` on success.
  DicomStoreErrorCode? get errorCode => error?.code;

  /// Display text composed from the error or transfer counters.
  String get message {
    final failure = error;
    if (failure != null) return failure.message;
    if (isSuccess)
      return 'C-STORE succeeded (stored $storedCount of $totalCount)';
    return 'C-STORE failed';
  }

  @override
  String toString() =>
      'DicomStoreResult(success: $isSuccess, stored: $storedCount/$totalCount, message: "$message")';
}

/// Progress of C-STORE transfer.
class DicomStoreProgress {
  final int completed;
  final int total;
  final String? currentName;

  const DicomStoreProgress({
    required this.completed,
    required this.total,
    this.currentName,
  });
}

/// A single DICOM object: a file on disk or prepared bytes (with preamble).
class DicomStoreInstance {
  final String? filePath;
  final Uint8List? bytes;
  final String label;

  const DicomStoreInstance.file(this.filePath, {this.label = ''})
      : bytes = null;

  const DicomStoreInstance.bytes(this.bytes, {this.label = 'annotations'})
      : filePath = null;
}

/// Study identification attributes copied from the source DICOM.
class DicomStudyIdentity {
  final String? studyInstanceUid;
  final String? patientName;
  final String? patientId;
  final String? patientBirthDate;
  final String? patientSex;
  final String? studyDate;
  final String? studyTime;
  final String? accessionNumber;
  final String? specificCharacterSet;

  const DicomStudyIdentity({
    this.studyInstanceUid,
    this.patientName,
    this.patientId,
    this.patientBirthDate,
    this.patientSex,
    this.studyDate,
    this.studyTime,
    this.accessionNumber,
    this.specificCharacterSet,
  });

  static const empty = DicomStudyIdentity();
}

class _InstanceInfo {
  final DicomStoreInstance source;
  final String sopClassUid;
  final String sopInstanceUid;
  final String transferSyntaxUid;
  final int datasetOffset;
  final int datasetLength;

  const _InstanceInfo({
    required this.source,
    required this.sopClassUid,
    required this.sopInstanceUid,
    required this.transferSyntaxUid,
    required this.datasetOffset,
    required this.datasetLength,
  });

  String get key => '$sopClassUid|$transferSyntaxUid';

  String get label {
    if (source.label.isNotEmpty) return source.label;
    final path = source.filePath;
    if (path == null || path.isEmpty) return sopInstanceUid;
    final sep = path.lastIndexOf(Platform.pathSeparator);
    return sep >= 0 ? path.substring(sep + 1) : path;
  }
}

class _AcceptedContext {
  final int presentationContextId;
  final String sopClassUid;
  final String transferSyntaxUid;

  const _AcceptedContext({
    required this.presentationContextId,
    required this.sopClassUid,
    required this.transferSyntaxUid,
  });
}

/// DICOM C-STORE (SCU) client: association handling, P-DATA-TF fragmentation, and object transmission.
class DicomStoreClient {
  static const String applicationContextUid = '1.2.840.10008.3.1.1.1';
  static const String implicitVrLittleEndianUid = '1.2.840.10008.1.2';
  static const String explicitVrLittleEndianUid = '1.2.840.10008.1.2.1';
  static const String rawDataStorageUid = '1.2.840.10008.5.1.4.1.1.66';
  static const String implementationClassUid = '1.2.826.0.1.3680043.9.7133.1.1';
  static const String implementationVersionName = 'OMNIHISTO_1_0';
  static const int _ourMaxPdu = 16384;

  /// Collects study DICOM files: a single file or a directory (including nested files).
  static Future<List<DicomStoreInstance>> collectFiles(String path) async {
    if (path.trim().isEmpty) return const [];
    final entityType = await FileSystemEntity.type(path);
    if (entityType == FileSystemEntityType.notFound) return const [];
    if (entityType == FileSystemEntityType.file) {
      return await _isDicomFile(path)
          ? [DicomStoreInstance.file(path)]
          : const [];
    }
    if (entityType != FileSystemEntityType.directory) return const [];

    final found = <String>[];
    await for (final entity
        in Directory(path).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path
          : entity.uri.pathSegments.last;
      if (name.toUpperCase() == 'DICOMDIR') continue;
      final lower = name.toLowerCase();
      if (lower.endsWith('.xml') ||
          lower.endsWith('.json') ||
          lower.endsWith('.txt')) continue;
      if (lower.endsWith('.dcm') ||
          lower.endsWith('.dicom') ||
          await _hasDicomMagic(entity.path)) {
        found.add(entity.path);
      }
    }
    found.sort();
    return found.map(DicomStoreInstance.file).toList();
  }

  /// Reads Study/Patient UID attributes from the first DICOM file found at the specified path.
  static Future<DicomStudyIdentity> readIdentity(String path) async {
    try {
      final files = await collectFiles(path);
      if (files.isEmpty || files.first.filePath == null)
        return DicomStudyIdentity.empty;
      return await _readIdentity(files.first.filePath!);
    } catch (_) {
      return DicomStudyIdentity.empty;
    }
  }

  /// Builds a DICOM Raw Data Storage object containing annotations XML.
  static Uint8List buildAnnotationDicom({
    required Uint8List xmlBytes,
    DicomStudyIdentity identity = DicomStudyIdentity.empty,
    String? sopInstanceUid,
    String? seriesInstanceUid,
  }) {
    final now = DateTime.now();
    final effectiveSopInstanceUid =
        (sopInstanceUid != null && sopInstanceUid.trim().isNotEmpty)
            ? _cleanUid(sopInstanceUid) ?? sopInstanceUid.trim()
            : _newUid();
    final studyUid = _cleanUid(identity.studyInstanceUid) ?? _newUid();
    final effectiveSeriesUid =
        (seriesInstanceUid != null && seriesInstanceUid.trim().isNotEmpty)
            ? _cleanUid(seriesInstanceUid) ?? seriesInstanceUid.trim()
            : _newUid();
    final date = _cleanDa(identity.studyDate) ?? _formatDate(now);
    final time = _cleanTm(identity.studyTime) ?? _formatTime(now);
    final patientName =
        (identity.patientName == null || identity.patientName!.trim().isEmpty)
            ? 'UNKNOWN'
            : identity.patientName!.trim();
    final patientId =
        (identity.patientId == null || identity.patientId!.trim().isEmpty)
            ? 'UNKNOWN'
            : identity.patientId!.trim();

    final dataset = BytesBuilder();
    _addExplicit(dataset, 0x00080005, 'CS', ascii.encode('ISO_IR 192'));
    _addExplicit(dataset, 0x00080012, 'DA', ascii.encode(_formatDate(now)));
    _addExplicit(dataset, 0x00080013, 'TM', ascii.encode(_formatTime(now)));
    _addExplicit(dataset, 0x00080016, 'UI', ascii.encode(rawDataStorageUid),
        pad: 0x00);
    _addExplicit(dataset, 0x00080018, 'UI', ascii.encode(effectiveSopInstanceUid),
        pad: 0x00);
    _addExplicit(dataset, 0x00080020, 'DA', ascii.encode(date));
    _addExplicit(dataset, 0x00080030, 'TM', ascii.encode(time));
    final accession = identity.accessionNumber?.trim();
    if (accession != null && accession.isNotEmpty) {
      _addExplicit(dataset, 0x00080050, 'SH', _textBytes(accession));
    }
    _addExplicit(dataset, 0x00080060, 'CS', ascii.encode('OT'));
    _addExplicit(dataset, 0x00080070, 'LO', _textBytes('OmniHisto'));
    _addExplicit(dataset, 0x00081090, 'LO', _textBytes('OmniHisto Viewer'));
    _addExplicit(dataset, 0x0008103E, 'LO', _textBytes('Annotations'));
    _addExplicit(dataset, 0x00100010, 'PN', _textBytes(patientName));
    _addExplicit(dataset, 0x00100020, 'LO', _textBytes(patientId));
    final birth = _cleanDa(identity.patientBirthDate);
    if (birth != null)
      _addExplicit(dataset, 0x00100030, 'DA', ascii.encode(birth));
    final sex = identity.patientSex?.trim();
    if (sex != null && sex.isNotEmpty) {
      _addExplicit(dataset, 0x00100040, 'CS',
          ascii.encode(sex.length > 16 ? sex.substring(0, 16) : sex));
    }
    _addExplicit(dataset, 0x0020000D, 'UI', ascii.encode(studyUid), pad: 0x00);
    _addExplicit(dataset, 0x0020000E, 'UI', ascii.encode(effectiveSeriesUid), pad: 0x00);
    _addExplicit(dataset, 0x00200011, 'IS', ascii.encode('1'));
    _addExplicit(dataset, 0x00200013, 'IS', ascii.encode('1'));
    _addExplicit(dataset, 0x00420011, 'OB', xmlBytes, pad: 0x00);
    _addExplicit(dataset, 0x00420012, 'LO', ascii.encode('text/xml'));

    return _wrapFileMeta(
      dataset: dataset.toBytes(),
      sopClassUid: rawDataStorageUid,
      sopInstanceUid: effectiveSopInstanceUid,
      transferSyntaxUid: explicitVrLittleEndianUid,
    );
  }

  /// Sends objects to a DICOM server using C-STORE.
  static Future<DicomStoreResult> store({
    required String host,
    required int port,
    required String calledAeTitle,
    required String callingAeTitle,
    required List<DicomStoreInstance> instances,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration responseTimeout = const Duration(seconds: 90),
    bool Function()? isCancelled,
    void Function(DicomStoreProgress progress)? onProgress,
  }) async {
    final trimmedHost = host.trim();
    final calledAe = calledAeTitle.trim();
    final callingAe = callingAeTitle.trim();
    if (trimmedHost.isEmpty) {
      return const DicomStoreResult(
        isSuccess: false,
        error: DicomStoreException(DicomStoreErrorCode.emptyHost),
      );
    }
    if (port <= 0 || port > 65535) {
      return const DicomStoreResult(
        isSuccess: false,
        error: DicomStoreException(DicomStoreErrorCode.invalidPort),
      );
    }
    if (calledAe.isEmpty || callingAe.isEmpty) {
      return const DicomStoreResult(
        isSuccess: false,
        error: DicomStoreException(DicomStoreErrorCode.emptyAeTitle),
      );
    }
    if (instances.isEmpty) {
      return const DicomStoreResult(
        isSuccess: false,
        error: DicomStoreException(DicomStoreErrorCode.emptyInstances),
      );
    }

    final infos = <_InstanceInfo>[];
    final prepareErrors = <String>[];
    for (final instance in instances) {
      if (isCancelled?.call() == true) {
        return DicomStoreResult(
          isSuccess: false,
          totalCount: instances.length,
          error: DicomStoreException(DicomStoreErrorCode.cancelled),
        );
      }
      try {
        final info = await _inspect(instance);
        if (info == null) {
          prepareErrors.add(
              '${instance.label.isEmpty ? instance.filePath ?? 'object' : instance.label}: not a DICOM file');
        } else {
          infos.add(info);
        }
      } catch (e) {
        prepareErrors.add('${instance.filePath ?? instance.label}: $e');
      }
    }

    if (infos.isEmpty) {
      return DicomStoreResult(
        isSuccess: false,
        totalCount: instances.length,
        error: DicomStoreException(
          DicomStoreErrorCode.prepareFailed,
          detail: prepareErrors.take(3).join('; '),
        ),
      );
    }

    var stored = 0;
    int? lastStatus;
    final errors = <String>[...prepareErrors];
    final groups = _chunkByContext(infos, 100);

    try {
      for (final group in groups) {
        if (isCancelled?.call() == true) {
          return DicomStoreResult(
            isSuccess: false,
            storedCount: stored,
            totalCount: infos.length,
            statusCode: lastStatus,
            error: const DicomStoreException(DicomStoreErrorCode.cancelled),
          );
        }
        final session = await _storeGroup(
          host: host.trim(),
          port: port,
          calledAeTitle: calledAe,
          callingAeTitle: callingAe,
          instances: group,
          connectTimeout: connectTimeout,
          responseTimeout: responseTimeout,
          isCancelled: isCancelled,
          onProgress: (completedInGroup, name) {
            onProgress?.call(DicomStoreProgress(
              completed: stored + completedInGroup,
              total: infos.length,
              currentName: name,
            ));
          },
        );
        stored += session.storedCount;
        lastStatus = session.statusCode ?? lastStatus;
        if (session.errors.isNotEmpty) errors.addAll(session.errors);
        if (!session.associationOk) {
          return DicomStoreResult(
            isSuccess: false,
            storedCount: stored,
            totalCount: infos.length,
            statusCode: lastStatus,
            error: DicomStoreException(
              session.errorCode ?? DicomStoreErrorCode.unknown,
              detail: [
                if (session.detail != null && session.detail!.isNotEmpty)
                  session.detail!,
                ...session.errors,
              ].join('; '),
              statusCode: lastStatus,
            ),
          );
        }
      }
    } on SocketException catch (e) {
      return DicomStoreResult(
        isSuccess: false,
        storedCount: stored,
        totalCount: infos.length,
        error: DicomStoreException(
          DicomStoreErrorCode.connectionClosed,
          detail: e.message,
        ),
      );
    } on TimeoutException catch (e) {
      return DicomStoreResult(
        isSuccess: false,
        storedCount: stored,
        totalCount: infos.length,
        error: DicomStoreException(
          DicomStoreErrorCode.timeout,
          detail: e.message,
        ),
      );
    } on FormatException catch (e) {
      return DicomStoreResult(
        isSuccess: false,
        storedCount: stored,
        totalCount: infos.length,
        statusCode: lastStatus,
        error: DicomStoreException(
          DicomStoreErrorCode.protocolViolation,
          detail: e.message,
        ),
      );
    } catch (e) {
      return DicomStoreResult(
        isSuccess: false,
        storedCount: stored,
        totalCount: infos.length,
        statusCode: lastStatus,
        error: DicomStoreException(
          DicomStoreErrorCode.unknown,
          detail: e.toString(),
          statusCode: lastStatus,
        ),
      );
    }

    final ok = stored == infos.length && errors.isEmpty;
    return DicomStoreResult(
      isSuccess: ok,
      storedCount: stored,
      totalCount: infos.length,
      statusCode: lastStatus,
      error: ok
          ? null
          : DicomStoreException(
              stored == 0
                  ? DicomStoreErrorCode.serverError
                  : DicomStoreErrorCode.incomplete,
              detail: errors.take(3).join('; '),
              statusCode: lastStatus,
            ),
    );
  }

  static List<List<_InstanceInfo>> _chunkByContext(
      List<_InstanceInfo> infos, int maxContexts) {
    final batches = <List<_InstanceInfo>>[];
    final current = <_InstanceInfo>[];
    final keys = <String>{};
    for (final info in infos) {
      if (!keys.contains(info.key) && keys.length >= maxContexts) {
        batches.add(List.of(current));
        current.clear();
        keys.clear();
      }
      keys.add(info.key);
      current.add(info);
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  static Future<_GroupResult> _storeGroup({
    required String host,
    required int port,
    required String calledAeTitle,
    required String callingAeTitle,
    required List<_InstanceInfo> instances,
    required Duration connectTimeout,
    required Duration responseTimeout,
    required bool Function()? isCancelled,
    required void Function(int completedInGroup, String? name) onProgress,
  }) async {
    final contexts = <String, int>{};
    var nextId = 1;
    for (final info in instances) {
      contexts.putIfAbsent(info.key, () {
        final id = nextId;
        nextId += 2;
        return id;
      });
    }

    Socket? socket;
    StreamSubscription<List<int>>? subscription;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
      final reader = _PduReader();
      final pendingPdus = <_Pdu>[];
      final waiters = <Completer<_Pdu>>[];
      void deliver(Object? pdu, [Object? error]) {
        if (waiters.isNotEmpty) {
          final waiter = waiters.removeAt(0);
          if (error != null) {
            waiter.completeError(error);
          } else {
            waiter.complete(pdu as _Pdu);
          }
        } else if (error == null && pdu is _Pdu) {
          pendingPdus.add(pdu);
        }
      }

      subscription = socket.listen(
        (data) {
          for (final pdu in reader.append(data)) {
            deliver(pdu);
          }
        },
        onError: (Object err) => deliver(null, err),
        onDone: () => deliver(null,
            const SocketException('Connection closed by remote server')),
      );

      Future<_Pdu> nextPdu([Duration? timeout]) {
        if (pendingPdus.isNotEmpty)
          return Future<_Pdu>.value(pendingPdus.removeAt(0));
        final completer = Completer<_Pdu>();
        waiters.add(completer);
        return completer.future.timeout(timeout ?? responseTimeout,
            onTimeout: () {
          waiters.remove(completer);
          throw TimeoutException('Timed out waiting for a response from the DICOM server');
        });
      }

      socket.add(_buildAssociateRq(
        calledAe: calledAeTitle,
        callingAe: callingAeTitle,
        contexts: contexts,
        instances: instances,
      ));
      await socket.flush();

      final associate = await nextPdu();
      if (associate.type == 0x03) {
        return _GroupResult.failed(
          DicomStoreErrorCode.associationRejected,
          detail: _parseAssociateReject(associate.data),
        );
      }
      if (associate.type != 0x02) {
        return _GroupResult.failed(
          DicomStoreErrorCode.protocolViolation,
          detail:
              'Unexpected association response PDU 0x${associate.type.toRadixString(16)}',
        );
      }

      final accepted =
          _parseAssociateAccept(associate.data, contexts, instances);
      if (accepted.maxPdu < 256) {
        await _abort(socket);
        return _GroupResult.failed(
          DicomStoreErrorCode.protocolViolation,
          detail: 'Server proposed an invalid PDU size (${accepted.maxPdu})',
        );
      }
      final fragmentSize = accepted.maxPdu - 12;
      if (accepted.byKey.isEmpty) {
        await _release(socket, nextPdu);
        return _GroupResult.failed(
          accepted.errorCode,
          detail: 'Server accepted no C-STORE Presentation Contexts',
        );
      }

      final pending = BytesBuilder(copy: true);
      Future<void> flushPending({bool force = false}) async {
        if (pending.isEmpty) return;
        if (!force && pending.length < 1024 * 1024) return;
        socket!.add(pending.takeBytes());
        await socket.flush();
      }

      void addPdv(int pcId, int control, List<int> payload) {
        final pdvLen = 2 + payload.length;
        final item = BytesBuilder(copy: false);
        item.add(_uint32Be(pdvLen));
        item.addByte(pcId);
        item.addByte(control);
        item.add(payload);
        final pdv = item.toBytes();
        final pdu = BytesBuilder(copy: false);
        pdu.addByte(0x04);
        pdu.addByte(0x00);
        pdu.add(_uint32Be(pdv.length));
        pdu.add(pdv);
        pending.add(pdu.toBytes());
      }

      var stored = 0;
      int? lastStatus;
      final errors = <String>[];
      var messageId = 1;

      for (final info in instances) {
        if (isCancelled?.call() == true) {
          await flushPending(force: true);
          await _abort(socket);
          return _GroupResult(
            associationOk: false,
            storedCount: stored,
            errorCode: DicomStoreErrorCode.cancelled,
            detail: 'Cancelled after storing $stored objects',
            errors: const ['C-STORE was cancelled'],
            statusCode: lastStatus,
          );
        }
        final context = accepted.byKey[info.key];
        if (context == null) {
          errors.add(
              '${info.label}: server did not accept ${info.sopClassUid} / ${info.transferSyntaxUid}');
          continue;
        }
        onProgress(stored, info.label);

        final command = _buildStoreCommand(
          sopClassUid: info.sopClassUid,
          sopInstanceUid: info.sopInstanceUid,
          messageId: messageId,
        );
        messageId = messageId == 0xFFFF ? 1 : messageId + 1;
        addPdv(context.presentationContextId, 0x03, command);
        await flushPending();

        var remaining = info.datasetLength;
        var offset = info.datasetOffset;
        final file = info.source.filePath == null
            ? null
            : await File(info.source.filePath!).open();
        try {
          if (file != null) await file.setPosition(offset);
          while (remaining > 0) {
            if (isCancelled?.call() == true) {
              await flushPending(force: true);
              await _abort(socket);
              return _GroupResult(
                associationOk: false,
                storedCount: stored,
                errorCode: DicomStoreErrorCode.cancelled,
                detail: 'Cancelled after storing $stored objects',
                errors: const ['C-STORE was cancelled'],
                statusCode: lastStatus,
              );
            }
            final n = remaining < fragmentSize ? remaining : fragmentSize;
            final Uint8List chunk;
            if (file != null) {
              chunk = await file.read(n);
            } else {
              chunk =
                  Uint8List.sublistView(info.source.bytes!, offset, offset + n);
            }
            if (chunk.length != n) {
              throw const FileSystemException('DICOM file is truncated');
            }
            remaining -= n;
            offset += n;
            addPdv(context.presentationContextId, remaining == 0 ? 0x02 : 0x00,
                chunk);
            await flushPending();
          }
        } finally {
          await file?.close();
        }
        if (info.datasetLength == 0) {
          addPdv(context.presentationContextId, 0x02, const []);
        }
        await flushPending(force: true);

        final response = await nextPdu();
        if (response.type == 0x07) {
          return _GroupResult(
            associationOk: false,
            storedCount: stored,
            errorCode: DicomStoreErrorCode.associationAborted,
            detail: 'Server aborted after storing $stored objects',
            errors: errors,
            statusCode: lastStatus,
          );
        }
        if (response.type != 0x04) {
          return _GroupResult(
            associationOk: false,
            storedCount: stored,
            errorCode: DicomStoreErrorCode.protocolViolation,
            detail:
                'Expected C-STORE-RSP, received PDU 0x${response.type.toRadixString(16)}',
            errors: errors,
          );
        }
        final status = _parseStatus(response.data);
        if (status < 0) {
          return _GroupResult(
            associationOk: false,
            storedCount: stored,
            errorCode: DicomStoreErrorCode.protocolViolation,
            detail: 'C-STORE-RSP did not contain a valid status',
            errors: errors,
            statusCode: lastStatus,
          );
        }
        lastStatus = status;
        if (status == 0x0000 || (status & 0xF000) == 0xB000) {
          stored++;
          onProgress(stored, info.label);
        } else {
          errors.add(
            '${info.label}: status 0x${status.toRadixString(16).padLeft(4, '0')}',
          );
        }
      }

      await _release(socket, nextPdu);
      return _GroupResult(
        associationOk: true,
        storedCount: stored,
        errors: errors,
        statusCode: lastStatus,
      );
    } finally {
      await subscription?.cancel();
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  static Future<void> _release(
      Socket socket, Future<_Pdu> Function([Duration? timeout]) nextPdu) async {
    try {
      socket.add(Uint8List.fromList(
          const [0x05, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]));
      await socket.flush();
      await nextPdu(const Duration(seconds: 2));
    } catch (_) {}
  }

  static Future<void> _abort(Socket socket) async {
    try {
      socket.add(Uint8List.fromList(
          const [0x07, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]));
      await socket.flush();
    } catch (_) {}
  }

  static Future<_InstanceInfo?> _inspect(DicomStoreInstance instance) async {
    if (instance.bytes != null) {
      return _inspectBytes(instance, instance.bytes!);
    }
    final path = instance.filePath;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final raf = await file.open();
    try {
      final length = await raf.length();
      if (length < 8) return null;
      final probeLen = length < 132 ? length : 132;
      final probe = await raf.read(probeLen);
      final start = _dicmOffset(probe, length);
      if (start == null) return null;
      final meta = await _readFileMeta(raf, start, length);
      if (meta.sopClassUid == null || meta.sopInstanceUid == null) return null;
      final datasetLength = length - meta.datasetOffset;
      if (datasetLength < 0) return null;
      return _InstanceInfo(
        source: instance,
        sopClassUid: meta.sopClassUid!,
        sopInstanceUid: meta.sopInstanceUid!,
        transferSyntaxUid: meta.transferSyntaxUid ?? explicitVrLittleEndianUid,
        datasetOffset: meta.datasetOffset,
        datasetLength: datasetLength,
      );
    } finally {
      await raf.close();
    }
  }

  static _InstanceInfo? _inspectBytes(
      DicomStoreInstance instance, Uint8List bytes) {
    final start = _dicmOffset(bytes, bytes.length);
    if (start == null) return null;
    final meta = _readFileMetaBytes(bytes, start);
    if (meta.sopClassUid == null || meta.sopInstanceUid == null) return null;
    return _InstanceInfo(
      source: instance,
      sopClassUid: meta.sopClassUid!,
      sopInstanceUid: meta.sopInstanceUid!,
      transferSyntaxUid: meta.transferSyntaxUid ?? explicitVrLittleEndianUid,
      datasetOffset: meta.datasetOffset,
      datasetLength: bytes.length - meta.datasetOffset,
    );
  }

  static int? _dicmOffset(List<int> probe, int length) {
    if (probe.length >= 132 &&
        probe[128] == 0x44 &&
        probe[129] == 0x49 &&
        probe[130] == 0x43 &&
        probe[131] == 0x4D) {
      return 132;
    }
    if (probe.length >= 4 &&
        probe[0] == 0x44 &&
        probe[1] == 0x49 &&
        probe[2] == 0x43 &&
        probe[3] == 0x4D &&
        length >= 8) {
      return 4;
    }
    return null;
  }

  static Future<bool> _isDicomFile(String path) async {
    return _hasDicomMagic(path);
  }

  static Future<bool> _hasDicomMagic(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 132) return false;
    final raf = await file.open();
    try {
      final probe = await raf.read(132);
      return _dicmOffset(probe, length) != null;
    } finally {
      await raf.close();
    }
  }

  static Future<_Meta> _readFileMeta(
      RandomAccessFile raf, int start, int length) async {
    var offset = start;
    String? sopClass;
    String? sopInstance;
    String? transferSyntax;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final head = await raf.read(12);
      if (head.length < 8) break;
      final group = _u16(head, 0);
      if (group != 0x0002) break;
      final element = _u16(head, 2);
      final vr = latin1.decode(head.sublist(4, 6));
      final parsed = _explicitLengths(vr, head);
      if (parsed == null || parsed.vl < 0 || parsed.vl == 0xFFFFFFFF) break;
      final dataOffset = offset + parsed.headerSize;
      if (dataOffset + parsed.vl > length) break;
      if (parsed.vl <= 128 &&
          (element == 0x0002 || element == 0x0003 || element == 0x0010)) {
        await raf.setPosition(dataOffset);
        final raw = await raf.read(parsed.vl);
        final text = _decodeUid(raw);
        if (element == 0x0002) sopClass = text;
        if (element == 0x0003) sopInstance = text;
        if (element == 0x0010) transferSyntax = text;
      }
      offset = dataOffset + parsed.vl;
    }
    return _Meta(
      sopClassUid: sopClass,
      sopInstanceUid: sopInstance,
      transferSyntaxUid: transferSyntax,
      datasetOffset: offset,
    );
  }

  static _Meta _readFileMetaBytes(Uint8List bytes, int start) {
    var offset = start;
    String? sopClass;
    String? sopInstance;
    String? transferSyntax;
    while (offset + 8 <= bytes.length) {
      final group = _u16(bytes, offset);
      if (group != 0x0002) break;
      final element = _u16(bytes, offset + 2);
      final vr = latin1.decode(bytes.sublist(offset + 4, offset + 6));
      final head = bytes.sublist(offset, min(offset + 12, bytes.length));
      final parsed = _explicitLengths(vr, head);
      if (parsed == null || parsed.vl < 0 || parsed.vl == 0xFFFFFFFF) break;
      final dataOffset = offset + parsed.headerSize;
      if (dataOffset + parsed.vl > bytes.length) break;
      if (element == 0x0002 || element == 0x0003 || element == 0x0010) {
        final text =
            _decodeUid(bytes.sublist(dataOffset, dataOffset + parsed.vl));
        if (element == 0x0002) sopClass = text;
        if (element == 0x0003) sopInstance = text;
        if (element == 0x0010) transferSyntax = text;
      }
      offset = dataOffset + parsed.vl;
    }
    return _Meta(
      sopClassUid: sopClass,
      sopInstanceUid: sopInstance,
      transferSyntaxUid: transferSyntax,
      datasetOffset: offset,
    );
  }

  static Future<DicomStudyIdentity> _readIdentity(String path) async {
    final info = await _inspect(DicomStoreInstance.file(path));
    if (info == null) return DicomStudyIdentity.empty;
    final file = File(path);
    final raf = await file.open();
    try {
      final length = await raf.length();
      final readLen = min(2 * 1024 * 1024, length - info.datasetOffset);
      if (readLen <= 0) return DicomStudyIdentity.empty;
      await raf.setPosition(info.datasetOffset);
      final bytes = await raf.read(readLen);
      final explicitVr = info.transferSyntaxUid != implicitVrLittleEndianUid;
      final endian = info.transferSyntaxUid == '1.2.840.10008.1.2.2'
          ? Endian.big
          : Endian.little;
      if (info.transferSyntaxUid == '1.2.840.10008.1.2.1.99')
        return DicomStudyIdentity.empty;
      return _parseIdentity(bytes, explicitVr: explicitVr, endian: endian);
    } finally {
      await raf.close();
    }
  }

  static DicomStudyIdentity _parseIdentity(
    Uint8List bytes, {
    required bool explicitVr,
    required Endian endian,
  }) {
    final values = <int, Uint8List>{};
    var charset = '';
    var offset = 0;
    try {
      while (offset + 8 <= bytes.length) {
        final group = _u16e(bytes, offset, endian);
        final element = _u16e(bytes, offset + 2, endian);
        final tag = (group << 16) | element;
        if (tag == 0xFFFEE000 || tag == 0xFFFEE00D || tag == 0xFFFEE0DD) {
          final vl = _u32e(bytes, offset + 4, endian);
          offset += 8;
          if (vl != 0xFFFFFFFF) offset += vl;
          continue;
        }
        if (tag == 0x7FE00010) break;

        int vl;
        int dataOffset;
        String vr = '';
        if (explicitVr) {
          if (offset + 8 > bytes.length) break;
          vr = latin1.decode(bytes.sublist(offset + 4, offset + 6));
          if (_longVr(vr)) {
            if (offset + 12 > bytes.length) break;
            vl = _u32e(bytes, offset + 8, endian);
            dataOffset = offset + 12;
          } else {
            vl = _u16e(bytes, offset + 6, endian);
            dataOffset = offset + 8;
          }
        } else {
          vl = _u32e(bytes, offset + 4, endian);
          dataOffset = offset + 8;
        }

        if (vl == 0xFFFFFFFF) {
          if (vr == 'SQ' || !explicitVr) {
            offset = _skipUndefined(bytes, dataOffset, endian);
            continue;
          }
          break;
        }
        if (vl < 0 || dataOffset + vl > bytes.length) break;
        if (vr == 'SQ') {
          offset = dataOffset + vl;
          continue;
        }
        if (tag == 0x00080005 ||
            tag == 0x00080020 ||
            tag == 0x00080030 ||
            tag == 0x00080050 ||
            tag == 0x00100010 ||
            tag == 0x00100020 ||
            tag == 0x00100030 ||
            tag == 0x00100040 ||
            tag == 0x0020000D) {
          values[tag] =
              Uint8List.sublistView(bytes, dataOffset, dataOffset + vl);
          if (tag == 0x00080005) {
            charset = _decodeText(values[tag]!, null);
          }
        }
        offset = dataOffset + vl;
      }
    } catch (_) {
      return DicomStudyIdentity.empty;
    }

    String? text(int tag) {
      final raw = values[tag];
      if (raw == null || raw.isEmpty) return null;
      final decoded = _decodeText(raw, charset);
      return decoded.isEmpty ? null : decoded;
    }

    return DicomStudyIdentity(
      specificCharacterSet: text(0x00080005),
      studyDate: text(0x00080020),
      studyTime: text(0x00080030),
      accessionNumber: text(0x00080050),
      patientName: text(0x00100010),
      patientId: text(0x00100020),
      patientBirthDate: text(0x00100030),
      patientSex: text(0x00100040),
      studyInstanceUid: text(0x0020000D),
    );
  }

  static int _skipUndefined(Uint8List bytes, int offset, Endian endian) {
    var depth = 1;
    while (offset + 8 <= bytes.length && depth > 0) {
      final group = _u16e(bytes, offset, endian);
      final element = _u16e(bytes, offset + 2, endian);
      final vl = _u32e(bytes, offset + 4, endian);
      offset += 8;
      if (group == 0xFFFE && element == 0xE0DD) {
        depth--;
        continue;
      }
      if (group == 0xFFFE && element == 0xE000 && vl == 0xFFFFFFFF) {
        depth++;
        continue;
      }
      if (vl == 0xFFFFFFFF) return bytes.length;
      if (offset + vl > bytes.length) return bytes.length;
      offset += vl;
    }
    return offset;
  }

  static Uint8List _buildAssociateRq({
    required String calledAe,
    required String callingAe,
    required Map<String, int> contexts,
    required List<_InstanceInfo> instances,
  }) {
    final bb = BytesBuilder();
    bb.addByte(0x00);
    bb.addByte(0x01);
    bb.addByte(0x00);
    bb.addByte(0x00);
    bb.add(_padString(calledAe, 16));
    bb.add(_padString(callingAe, 16));
    bb.add(Uint8List(32));
    bb.add(_item(0x10, ascii.encode(applicationContextUid)));

    final byKey = {for (final info in instances) info.key: info};
    final ids = contexts.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in ids) {
      final info = byKey[entry.key];
      if (info == null) continue;
      final pc = BytesBuilder();
      pc.addByte(entry.value);
      pc.addByte(0x00);
      pc.addByte(0x00);
      pc.addByte(0x00);
      pc.add(_item(0x30, ascii.encode(info.sopClassUid)));
      pc.add(_item(0x40, ascii.encode(info.transferSyntaxUid)));
      bb.add(_item(0x20, pc.toBytes()));
    }

    final user = BytesBuilder();
    user.add(_item(0x51, Uint8List.fromList(_uint32Be(_ourMaxPdu))));
    user.add(_item(0x52, ascii.encode(implementationClassUid)));
    user.add(_item(0x55, ascii.encode(implementationVersionName)));
    bb.add(_item(0x50, user.toBytes()));

    final data = bb.toBytes();
    final pdu = BytesBuilder();
    pdu.addByte(0x01);
    pdu.addByte(0x00);
    pdu.add(_uint32Be(data.length));
    pdu.add(data);
    return pdu.toBytes();
  }

  static _AcceptParse _parseAssociateAccept(
    Uint8List data,
    Map<String, int> contexts,
    List<_InstanceInfo> instances,
  ) {
    final byId = <int, _InstanceInfo>{};
    for (final info in instances) {
      final id = contexts[info.key];
      if (id != null) byId[id] = info;
    }
    var maxPdu = _ourMaxPdu;
    final accepted = <String, _AcceptedContext>{};
    var rejectionCode = DicomStoreErrorCode.unsupportedSopClass;
    if (data.length < 68) {
      return _AcceptParse(
        maxPdu: maxPdu,
        byKey: accepted,
        errorCode: DicomStoreErrorCode.protocolViolation,
      );
    }
    var offset = 68;
    while (offset + 4 <= data.length) {
      final itemType = data[offset];
      final itemLen = (data[offset + 2] << 8) | data[offset + 3];
      final item = offset + 4;
      if (itemLen < 0 || item + itemLen > data.length) break;
      if (itemType == 0x21 && itemLen >= 4) {
        final pcId = data[item];
        final result = data[item + 2];
        final proposed = byId[pcId];
        if (result == 0 && proposed != null) {
          final ts = _acceptedTransferSyntax(data, item + 4, item + itemLen) ??
              proposed.transferSyntaxUid;
          if (ts == proposed.transferSyntaxUid) {
            accepted[proposed.key] = _AcceptedContext(
              presentationContextId: pcId,
              sopClassUid: proposed.sopClassUid,
              transferSyntaxUid: ts,
            );
          }
        } else if (result == 4) {
          rejectionCode = DicomStoreErrorCode.unsupportedTransferSyntax;
        } else if (result == 3) {
          rejectionCode = DicomStoreErrorCode.unsupportedSopClass;
        }
      } else if (itemType == 0x50) {
        final parsed = _maxPduFromUserInfo(data, item, item + itemLen);
        if (parsed != null) {
          maxPdu = parsed == 0 ? _ourMaxPdu : min(parsed, _ourMaxPdu);
        }
      }
      offset = item + itemLen;
    }
    return _AcceptParse(
        maxPdu: maxPdu, byKey: accepted, errorCode: rejectionCode);
  }

  static String? _acceptedTransferSyntax(Uint8List data, int start, int end) {
    var offset = start;
    while (offset + 4 <= end) {
      final type = data[offset];
      final len = (data[offset + 2] << 8) | data[offset + 3];
      final item = offset + 4;
      if (item + len > end) return null;
      if (type == 0x40 && len > 0) {
        return _decodeUid(data.sublist(item, item + len));
      }
      offset = item + len;
    }
    return null;
  }

  static int? _maxPduFromUserInfo(Uint8List data, int start, int end) {
    var offset = start;
    while (offset + 4 <= end) {
      final type = data[offset];
      final len = (data[offset + 2] << 8) | data[offset + 3];
      final item = offset + 4;
      if (item + len > end || len < 0) return null;
      if (type == 0x51 && len >= 4) {
        return (data[item] << 24) |
            (data[item + 1] << 16) |
            (data[item + 2] << 8) |
            data[item + 3];
      }
      offset = item + len;
    }
    return null;
  }

  static Uint8List _buildStoreCommand({
    required String sopClassUid,
    required String sopInstanceUid,
    required int messageId,
  }) {
    final cmd = BytesBuilder();
    _addImplicitUi(cmd, 0x00000002, sopClassUid);
    _addImplicitUs(cmd, 0x00000100, 0x0001);
    _addImplicitUs(cmd, 0x00000110, messageId);
    _addImplicitUs(cmd, 0x00000700, 0x0000);
    _addImplicitUs(cmd, 0x00000800, 0x0000);
    _addImplicitUi(cmd, 0x00001000, sopInstanceUid);
    final payload = cmd.toBytes();
    final full = BytesBuilder();
    _addImplicitUl(full, 0x00000000, payload.length);
    full.add(payload);
    return full.toBytes();
  }

  static int _parseStatus(Uint8List pduData) {
    var offset = 0;
    var status = -1;
    while (offset + 6 <= pduData.length) {
      final pdvLen = (pduData[offset] << 24) |
          (pduData[offset + 1] << 16) |
          (pduData[offset + 2] << 8) |
          pduData[offset + 3];
      if (pdvLen < 2 || offset + 4 + pdvLen > pduData.length) break;
      final control = pduData[offset + 5];
      final payload =
          Uint8List.sublistView(pduData, offset + 6, offset + 4 + pdvLen);
      if ((control & 0x01) != 0) {
        final parsed = _statusFromCommand(payload);
        if (parsed != null) status = parsed;
      }
      offset += 4 + pdvLen;
    }
    return status;
  }

  static int? _statusFromCommand(Uint8List cmd) {
    var offset = 0;
    final bd = ByteData.sublistView(cmd);
    while (offset + 8 <= cmd.length) {
      final group = bd.getUint16(offset, Endian.little);
      final element = bd.getUint16(offset + 2, Endian.little);
      final vl = bd.getUint32(offset + 4, Endian.little);
      final value = offset + 8;
      if (value + vl > cmd.length) return null;
      if (group == 0x0000 && element == 0x0900 && vl >= 2) {
        return bd.getUint16(value, Endian.little);
      }
      offset = value + vl;
    }
    return null;
  }

  static String _parseAssociateReject(Uint8List pduData) {
    if (pduData.length < 4) return 'Reason not specified';
    final result = pduData[1] == 1 ? 'Permanent' : 'Transient';
    final reason = switch (pduData[3]) {
      1 => 'No reason given',
      2 => 'Application context name not supported',
      3 => 'Calling AE Title not recognized',
      7 => 'Called AE Title not recognized',
      _ => 'Code ${pduData[3]}',
    };
    return '$result (Source: ${pduData[2]}, Reason: $reason)';
  }

  static Uint8List _wrapFileMeta({
    required Uint8List dataset,
    required String sopClassUid,
    required String sopInstanceUid,
    required String transferSyntaxUid,
  }) {
    final body = BytesBuilder();
    _addExplicit(body, 0x00020001, 'OB', Uint8List.fromList(const [0x00, 0x01]),
        pad: 0x00);
    _addExplicit(body, 0x00020002, 'UI', ascii.encode(sopClassUid), pad: 0x00);
    _addExplicit(body, 0x00020003, 'UI', ascii.encode(sopInstanceUid),
        pad: 0x00);
    _addExplicit(body, 0x00020010, 'UI', ascii.encode(transferSyntaxUid),
        pad: 0x00);
    _addExplicit(body, 0x00020012, 'UI', ascii.encode(implementationClassUid),
        pad: 0x00);
    _addExplicit(
        body, 0x00020013, 'SH', ascii.encode(implementationVersionName));
    final metaBody = body.toBytes();
    final meta = BytesBuilder();
    _addExplicit(
        meta, 0x00020000, 'UL', Uint8List.fromList(_uint32Le(metaBody.length)));
    meta.add(metaBody);
    final file = BytesBuilder();
    file.add(Uint8List(128));
    file.add(ascii.encode('DICM'));
    file.add(meta.toBytes());
    file.add(dataset);
    return file.toBytes();
  }

  static void _addExplicit(
      BytesBuilder out, int tag, String vr, List<int> value,
      {int pad = 0x20}) {
    out.add(_uint16Le((tag >> 16) & 0xFFFF));
    out.add(_uint16Le(tag & 0xFFFF));
    out.add(ascii.encode(vr));
    final even = value.length.isOdd ? [...value, pad] : value;
    if (_longVr(vr)) {
      out.addByte(0x00);
      out.addByte(0x00);
      out.add(_uint32Le(even.length));
    } else {
      out.add(_uint16Le(even.length));
    }
    out.add(even);
  }

  static void _addImplicitUi(BytesBuilder out, int tag, String uid) {
    final bytes = _padEven(ascii.encode(uid), 0x00);
    _addImplicit(out, tag, bytes);
  }

  static void _addImplicitUs(BytesBuilder out, int tag, int value) {
    _addImplicit(out, tag, _uint16Le(value));
  }

  static void _addImplicitUl(BytesBuilder out, int tag, int value) {
    _addImplicit(out, tag, _uint32Le(value));
  }

  static void _addImplicit(BytesBuilder out, int tag, List<int> value) {
    out.add(_uint16Le((tag >> 16) & 0xFFFF));
    out.add(_uint16Le(tag & 0xFFFF));
    out.add(_uint32Le(value.length));
    out.add(value);
  }

  static List<int> _item(int type, List<int> payload) {
    return [
      type,
      0x00,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
      ...payload
    ];
  }

  static bool _longVr(String vr) {
    return const {
      'OB',
      'OW',
      'OF',
      'SQ',
      'UT',
      'UN',
      'OD',
      'OL',
      'OV',
      'UC',
      'UR',
      'SV',
      'UV'
    }.contains(vr);
  }

  static _VrLen? _explicitLengths(String vr, List<int> head) {
    if (_longVr(vr)) {
      if (head.length < 12) return null;
      return _VrLen(_u32(head, 8), 12);
    }
    if (head.length < 8) return null;
    return _VrLen(_u16(head, 6), 8);
  }

  static String _decodeUid(List<int> raw) {
    final end = raw.lastIndexWhere((b) => b != 0x00 && b != 0x20);
    if (end < 0) return '';
    return ascii.decode(raw.sublist(0, end + 1), allowInvalid: true).trim();
  }

  static String _decodeText(Uint8List raw, String? charset) {
    var end = raw.length;
    while (end > 0 && (raw[end - 1] == 0x00 || raw[end - 1] == 0x20)) {
      end--;
    }
    final slice = raw.sublist(0, end);
    final upper = charset?.toUpperCase() ?? '';
    if (upper.contains('192') || upper.contains('UTF')) {
      return utf8.decode(slice, allowMalformed: true);
    }
    return latin1.decode(slice);
  }

  static List<int> _textBytes(String value) => utf8.encode(value);

  static String? _cleanUid(String? value) {
    if (value == null) return null;
    final uid = value.trim();
    if (uid.isEmpty || uid.length > 64) return null;
    return uid;
  }

  static String? _cleanDa(String? value) {
    if (value == null) return null;
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 8) return null;
    return digits.substring(0, 8);
  }

  static String? _cleanTm(String? value) {
    if (value == null) return null;
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 6) return null;
    return digits.substring(0, 6);
  }

  static String _formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}${value.month.toString().padLeft(2, '0')}${value.day.toString().padLeft(2, '0')}';

  static String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}${value.minute.toString().padLeft(2, '0')}${value.second.toString().padLeft(2, '0')}';

  static String _newUid() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = Random().nextInt(1 << 30);
    return '1.2.826.0.1.3680043.9.7133.2.$now.$rand';
  }

  static List<int> _padString(String value, int length) {
    final codes = ascii.encode(value);
    final out = List<int>.filled(length, 0x20);
    for (var i = 0; i < codes.length && i < length; i++) {
      out[i] = codes[i];
    }
    return out;
  }

  static List<int> _padEven(List<int> bytes, int pad) {
    if (bytes.length.isEven) return bytes;
    return [...bytes, pad];
  }

  static int _u16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);
  static int _u32(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _u16e(Uint8List bytes, int offset, Endian endian) =>
      ByteData.sublistView(bytes).getUint16(offset, endian);

  static int _u32e(Uint8List bytes, int offset, Endian endian) =>
      ByteData.sublistView(bytes).getUint32(offset, endian);

  static List<int> _uint16Le(int value) => [value & 0xFF, (value >> 8) & 0xFF];
  static List<int> _uint32Le(int value) => [
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ];
  static List<int> _uint32Be(int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];
}

class _Meta {
  final String? sopClassUid;
  final String? sopInstanceUid;
  final String? transferSyntaxUid;
  final int datasetOffset;

  const _Meta({
    required this.sopClassUid,
    required this.sopInstanceUid,
    required this.transferSyntaxUid,
    required this.datasetOffset,
  });
}

class _VrLen {
  final int vl;
  final int headerSize;
  const _VrLen(this.vl, this.headerSize);
}

class _AcceptParse {
  final int maxPdu;
  final Map<String, _AcceptedContext> byKey;
  final DicomStoreErrorCode errorCode;
  const _AcceptParse(
      {required this.maxPdu, required this.byKey, required this.errorCode});
}

class _GroupResult {
  final bool associationOk;
  final int storedCount;
  final DicomStoreErrorCode? errorCode;
  final String? detail;
  final List<String> errors;
  final int? statusCode;

  const _GroupResult({
    required this.associationOk,
    required this.storedCount,
    this.errorCode,
    this.detail,
    this.errors = const [],
    this.statusCode,
  });

  factory _GroupResult.failed(DicomStoreErrorCode code, {String? detail}) =>
      _GroupResult(
        associationOk: false,
        storedCount: 0,
        errorCode: code,
        detail: detail,
      );
}

class _Pdu {
  final int type;
  final Uint8List data;
  const _Pdu(this.type, this.data);
}

class _PduReader {
  final BytesBuilder _buffer = BytesBuilder();

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
      if (pduLen < 0 || pduLen > 16 * 1024 * 1024) {
        throw const FormatException('Invalid DICOM PDU length');
      }
      if (offset + 6 + pduLen <= allBytes.length) {
        pdus.add(_Pdu(
            pduType,
            Uint8List.fromList(
                allBytes.sublist(offset + 6, offset + 6 + pduLen))));
        offset += 6 + pduLen;
      } else {
        break;
      }
    }
    if (offset > 0) {
      final remaining = allBytes.sublist(offset);
      _buffer.clear();
      _buffer.add(remaining);
    }
    return pdus;
  }
}
