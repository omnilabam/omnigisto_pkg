import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Machine-readable C-ECHO error code.
enum DicomEchoErrorCode {
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

/// Typed exception for C-ECHO operation.
class DicomEchoException implements Exception {
  final DicomEchoErrorCode code;
  final String? detail;
  final int? statusCode;

  const DicomEchoException(
    this.code, {
    this.detail,
    this.statusCode,
  });

  String get message {
    final base = switch (code) {
      DicomEchoErrorCode.emptyHost => 'DICOM server host is not specified',
      DicomEchoErrorCode.invalidPort => 'Invalid DICOM server port',
      DicomEchoErrorCode.emptyAeTitle => 'AE Title is not specified',
      DicomEchoErrorCode.connectionClosed => 'Connection closed by the remote server',
      DicomEchoErrorCode.timeout => 'Timed out waiting for a response from the DICOM server',
      DicomEchoErrorCode.associationRejected => 'Association rejected by server (A-ASSOCIATE-RJ)',
      DicomEchoErrorCode.unsupportedTransferSyntax => 'Server proposed an unsupported Transfer Syntax',
      DicomEchoErrorCode.unsupportedSopClass => 'Server does not support Verification SOP Class',
      DicomEchoErrorCode.associationAborted => 'Server aborted the association during C-ECHO',
      DicomEchoErrorCode.protocolViolation => 'DICOM protocol violation',
      DicomEchoErrorCode.serverError => 'C-ECHO returned an error',
      DicomEchoErrorCode.unknown => 'C-ECHO failed',
    };
    final extra = detail;
    if (extra == null || extra.isEmpty) return base;
    return '$base: $extra';
  }

  @override
  String toString() {
    final extra = detail;
    if (extra == null || extra.isEmpty) return 'DicomEchoException(${code.name})';
    return 'DicomEchoException(${code.name}: $extra)';
  }
}

/// Result of a DICOM C-ECHO (verification) operation.
///
/// The error is represented by [errorCode] and a typed [error], rather than
/// an arbitrary string. [message] compiles human-readable text for display.
class DicomEchoResult {
  final bool isSuccess;
  final int? responseTimeMs;
  final int? statusCode;

  /// Typed error. `null` if verification was successful.
  final DicomEchoException? error;

  const DicomEchoResult({
    required this.isSuccess,
    this.responseTimeMs,
    this.statusCode,
    this.error,
  });

  /// Machine-readable error code. `null` on success.
  DicomEchoErrorCode? get errorCode => error?.code;

  /// Display text composed from [error] or successful C-ECHO status.
  String get message {
    final failure = error;
    if (failure != null) return failure.message;
    final status = statusCode;
    if (status == null) return 'C-ECHO succeeded';
    final hex = status.toRadixString(16).padLeft(4, '0');
    return 'C-ECHO succeeded (status 0x$hex)';
  }

  @override
  String toString() =>
      'DicomEchoResult(success: $isSuccess, error: ${errorCode?.name}, message: "$message", responseTimeMs: $responseTimeMs, status: $statusCode)';
}

/// Client for performing DICOM C-ECHO (DICOM Verification Service)
/// over the DICOM Upper Layer Protocol (TCP).
class DicomEchoClient {
  static const String verificationSopClassUid = '1.2.840.10008.1.1';
  static const String applicationContextUid = '1.2.840.10008.3.1.1.1';
  static const String implicitVrLittleEndianUid = '1.2.840.10008.1.2';
  static const String explicitVrLittleEndianUid = '1.2.840.10008.1.2.1';
  static const String implementationClassUid = '1.2.826.0.1.3680043.9.7133.1.1';
  static const String implementationVersionName = 'OMNIHISTO_1_0';

  /// Performs a C-ECHO verification with a remote DICOM server.
  ///
  /// Success is indicated by status `0x0000` and `error == null`. Failures return
  /// a [DicomEchoErrorCode] and [DicomEchoException] rather than an arbitrary string.
  static Future<DicomEchoResult> echo({
    required String host,
    required int port,
    required String calledAeTitle,
    required String callingAeTitle,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final calledAe = calledAeTitle.trim();
    final callingAe = callingAeTitle.trim();
    final trimmedHost = host.trim();
    if (trimmedHost.isEmpty) {
      return const DicomEchoResult(
        isSuccess: false,
        error: DicomEchoException(DicomEchoErrorCode.emptyHost),
      );
    }
    if (port <= 0 || port > 65535) {
      return const DicomEchoResult(
        isSuccess: false,
        error: DicomEchoException(DicomEchoErrorCode.invalidPort),
      );
    }
    if (calledAe.isEmpty || callingAe.isEmpty) {
      return const DicomEchoResult(
        isSuccess: false,
        error: DicomEchoException(DicomEchoErrorCode.emptyAeTitle),
      );
    }

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    StreamSubscription<List<int>>? subscription;

    DicomEchoResult failed(DicomEchoException error, {int? statusCode}) {
      stopwatch.stop();
      return DicomEchoResult(
        isSuccess: false,
        responseTimeMs: stopwatch.elapsedMilliseconds,
        statusCode: statusCode ?? error.statusCode,
        error: error,
      );
    }

    try {
      socket = await Socket.connect(trimmedHost, port, timeout: timeout);
      final reader = _PduReader();
      final pduCompleterQueue = <Completer<_Pdu>>[];

      subscription = socket.listen(
        (data) {
          final pdus = reader.append(data);
          for (final pdu in pdus) {
            if (pduCompleterQueue.isNotEmpty) {
              pduCompleterQueue.removeAt(0).complete(pdu);
            }
          }
        },
        onError: (err) {
          while (pduCompleterQueue.isNotEmpty) {
            pduCompleterQueue.removeAt(0).completeError(err);
          }
        },
        onDone: () {
          while (pduCompleterQueue.isNotEmpty) {
            pduCompleterQueue.removeAt(0).completeError(
              const DicomEchoException(DicomEchoErrorCode.connectionClosed),
            );
          }
        },
      );

      Future<_Pdu> nextPdu() {
        final completer = Completer<_Pdu>();
        pduCompleterQueue.add(completer);
        return completer.future.timeout(timeout, onTimeout: () {
          pduCompleterQueue.remove(completer);
          throw DicomEchoException(
            DicomEchoErrorCode.timeout,
            detail: '$trimmedHost:$port',
          );
        });
      }

      // 1. Send A-ASSOCIATE-RQ
      final associateRqBytes = _buildAssociateRq(
        calledAe: calledAe,
        callingAe: callingAe,
      );
      socket.add(associateRqBytes);
      await socket.flush();

      // 2. Wait for A-ASSOCIATE-AC or A-ASSOCIATE-RJ
      final associateResponse = await nextPdu();
      if (associateResponse.type == 0x07) {
        return failed(const DicomEchoException(DicomEchoErrorCode.associationAborted));
      }
      if (associateResponse.type == 0x03) {
        return failed(DicomEchoException(
          DicomEchoErrorCode.associationRejected,
          detail: _parseAssociateReject(associateResponse.data),
        ));
      }
      if (associateResponse.type != 0x02) {
        await _tryReleaseAndClose(socket, nextPdu);
        return failed(DicomEchoException(
          DicomEchoErrorCode.protocolViolation,
          detail: 'unexpected association response, PDU 0x${associateResponse.type.toRadixString(16)}',
        ));
      }

      final transferSyntax = _acceptedTransferSyntax(associateResponse.data, 1);
      if (transferSyntax == null) {
        await _tryReleaseAndClose(socket, nextPdu);
        return failed(const DicomEchoException(DicomEchoErrorCode.unsupportedSopClass));
      }
      if (transferSyntax != implicitVrLittleEndianUid &&
          transferSyntax != explicitVrLittleEndianUid) {
        await _tryReleaseAndClose(socket, nextPdu);
        return failed(DicomEchoException(
          DicomEchoErrorCode.unsupportedTransferSyntax,
          detail: transferSyntax,
        ));
      }

      // 3. Send C-ECHO-RQ
      final cEchoRqBytes = _buildCEchoRq(presentationContextId: 1, messageId: 1);
      socket.add(cEchoRqBytes);
      await socket.flush();

      // 4. Wait for C-ECHO-RSP (P-DATA-TF, type 0x04)
      final echoRspPdu = await nextPdu();
      if (echoRspPdu.type == 0x07) {
        return failed(const DicomEchoException(DicomEchoErrorCode.associationAborted));
      }
      if (echoRspPdu.type != 0x04) {
        await _tryReleaseAndClose(socket, nextPdu);
        return failed(DicomEchoException(
          DicomEchoErrorCode.protocolViolation,
          detail: 'expected P-DATA-TF, received PDU 0x${echoRspPdu.type.toRadixString(16)}',
        ));
      }

      final status = _parseCEchoRspStatus(echoRspPdu.data);

      // 5. Release association A-RELEASE
      await _tryReleaseAndClose(socket, nextPdu);
      stopwatch.stop();

      if (status == 0x0000) {
        return DicomEchoResult(
          isSuccess: true,
          responseTimeMs: stopwatch.elapsedMilliseconds,
          statusCode: status,
        );
      }
      if (status < 0) {
        return failed(const DicomEchoException(
          DicomEchoErrorCode.protocolViolation,
          detail: 'C-ECHO response has no status',
        ));
      }
      final hex = status.toRadixString(16).padLeft(4, '0');
      return failed(
        DicomEchoException(
          DicomEchoErrorCode.serverError,
          detail: '0x$hex',
          statusCode: status,
        ),
        statusCode: status,
      );
    } on DicomEchoException catch (e) {
      return failed(e);
    } on SocketException catch (e) {
      return failed(DicomEchoException(
        DicomEchoErrorCode.unknown,
        detail: '$trimmedHost:$port: ${e.message}',
      ));
    } on TimeoutException {
      return failed(DicomEchoException(
        DicomEchoErrorCode.timeout,
        detail: '$trimmedHost:$port',
      ));
    } catch (e) {
      return failed(DicomEchoException(DicomEchoErrorCode.unknown, detail: '$e'));
    } finally {
      await subscription?.cancel();
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  static Future<void> _tryReleaseAndClose(Socket socket, Future<_Pdu> Function() nextPdu) async {
    try {
      final releaseRq = Uint8List.fromList([
        0x05, 0x00, // Type 0x05 A-RELEASE-RQ
        0x00, 0x00, 0x00, 0x04, // Length 4
        0x00, 0x00, 0x00, 0x00, // Reserved
      ]);
      socket.add(releaseRq);
      await socket.flush();
      await nextPdu().timeout(const Duration(seconds: 2), onTimeout: () => _Pdu(0x06, Uint8List(0)));
    } catch (_) {}
  }

  static Uint8List _buildAssociateRq({
    required String calledAe,
    required String callingAe,
  }) {
    final bb = BytesBuilder();

    // Protocol version (1)
    bb.addByte(0x00);
    bb.addByte(0x01);
    // Reserved (0x0000)
    bb.addByte(0x00);
    bb.addByte(0x00);

    // Called AE Title (16 bytes, space padded)
    bb.add(_padString(calledAe, 16));
    // Calling AE Title (16 bytes, space padded)
    bb.add(_padString(callingAe, 16));
    // 32 reserved bytes
    bb.add(Uint8List(32));

    // Variable Items:
    // Item 1: Application Context Item (0x10)
    final appCtxBytes = applicationContextUid.codeUnits;
    bb.addByte(0x10);
    bb.addByte(0x00);
    bb.add(_uint16Be(appCtxBytes.length));
    bb.add(appCtxBytes);

    // Item 2: Presentation Context Item (0x20)
    final pcItemBuilder = BytesBuilder();
    pcItemBuilder.addByte(0x01); // Presentation Context ID (1)
    pcItemBuilder.addByte(0x00); // Reserved
    pcItemBuilder.addByte(0x00); // Reserved
    pcItemBuilder.addByte(0x00); // Reserved

    // Sub-item: Abstract Syntax (0x30)
    final absSyntaxBytes = verificationSopClassUid.codeUnits;
    pcItemBuilder.addByte(0x30);
    pcItemBuilder.addByte(0x00);
    pcItemBuilder.add(_uint16Be(absSyntaxBytes.length));
    pcItemBuilder.add(absSyntaxBytes);

    // Sub-item: Transfer Syntax Implicit VR Little Endian (0x40)
    final tsImplicitBytes = implicitVrLittleEndianUid.codeUnits;
    pcItemBuilder.addByte(0x40);
    pcItemBuilder.addByte(0x00);
    pcItemBuilder.add(_uint16Be(tsImplicitBytes.length));
    pcItemBuilder.add(tsImplicitBytes);

    // Sub-item: Transfer Syntax Explicit VR Little Endian (0x40)
    final tsExplicitBytes = explicitVrLittleEndianUid.codeUnits;
    pcItemBuilder.addByte(0x40);
    pcItemBuilder.addByte(0x00);
    pcItemBuilder.add(_uint16Be(tsExplicitBytes.length));
    pcItemBuilder.add(tsExplicitBytes);

    final pcPayload = pcItemBuilder.toBytes();
    bb.addByte(0x20);
    bb.addByte(0x00);
    bb.add(_uint16Be(pcPayload.length));
    bb.add(pcPayload);

    // Item 3: User Information Item (0x50)
    final userItemBuilder = BytesBuilder();

    // Sub-item: Maximum Length (0x51)
    userItemBuilder.addByte(0x51);
    userItemBuilder.addByte(0x00);
    userItemBuilder.add(_uint16Be(4));
    userItemBuilder.add(_uint32Be(16384)); // Max PDU size

    // Sub-item: Implementation Class UID (0x52)
    final implClassBytes = implementationClassUid.codeUnits;
    userItemBuilder.addByte(0x52);
    userItemBuilder.addByte(0x00);
    userItemBuilder.add(_uint16Be(implClassBytes.length));
    userItemBuilder.add(implClassBytes);

    // Sub-item: Implementation Version Name (0x55)
    final implVerBytes = implementationVersionName.codeUnits;
    userItemBuilder.addByte(0x55);
    userItemBuilder.addByte(0x00);
    userItemBuilder.add(_uint16Be(implVerBytes.length));
    userItemBuilder.add(implVerBytes);

    final userPayload = userItemBuilder.toBytes();
    bb.addByte(0x50);
    bb.addByte(0x00);
    bb.add(_uint16Be(userPayload.length));
    bb.add(userPayload);

    final data = bb.toBytes();

    // PDU Header
    final pdu = BytesBuilder();
    pdu.addByte(0x01); // A-ASSOCIATE-RQ
    pdu.addByte(0x00); // Reserved
    pdu.add(_uint32Be(data.length));
    pdu.add(data);

    return pdu.toBytes();
  }

  static Uint8List _buildCEchoRq({
    required int presentationContextId,
    required int messageId,
  }) {
    // DICOM Command Set (Implicit VR Little Endian)
    final cmdBuilder = BytesBuilder();

    // (0000, 0002) Affected SOP Class UID (UI)
    final sopBytes = _padEven(verificationSopClassUid.codeUnits);
    cmdBuilder.add([0x00, 0x00, 0x02, 0x00]); // Tag (0000, 0002)
    cmdBuilder.add(_uint32Le(sopBytes.length));
    cmdBuilder.add(sopBytes);

    // (0000, 0100) Command Field: 0x0030 (C-ECHO-RQ)
    cmdBuilder.add([0x00, 0x00, 0x00, 0x01]); // Tag (0000, 0100)
    cmdBuilder.add(_uint32Le(2));
    cmdBuilder.add(_uint16Le(0x0030));

    // (0000, 0110) Message ID (US)
    cmdBuilder.add([0x00, 0x00, 0x10, 0x01]); // Tag (0000, 0110)
    cmdBuilder.add(_uint32Le(2));
    cmdBuilder.add(_uint16Le(messageId));

    // (0000, 0800) Command Data Set Type: 0x0101 (no dataset)
    cmdBuilder.add([0x00, 0x00, 0x00, 0x08]); // Tag (0000, 0800)
    cmdBuilder.add(_uint32Le(2));
    cmdBuilder.add(_uint16Le(0x0101));

    final cmdPayload = cmdBuilder.toBytes();

    // (0000, 0000) Command Group Length (UL)
    final fullCmd = BytesBuilder();
    fullCmd.add([0x00, 0x00, 0x00, 0x00]); // Tag (0000, 0000)
    fullCmd.add(_uint32Le(4));
    fullCmd.add(_uint32Le(cmdPayload.length));
    fullCmd.add(cmdPayload);

    final cmdBytes = fullCmd.toBytes();

    // PDV: 4 bytes length, 1 byte Context ID, 1 byte Control Header (0x03), payload
    final pdvLength = 2 + cmdBytes.length;
    final pdv = BytesBuilder();
    pdv.add(_uint32Be(pdvLength));
    pdv.addByte(presentationContextId);
    pdv.addByte(0x03); // Command, Last fragment
    pdv.add(cmdBytes);

    final pdvBytes = pdv.toBytes();

    // P-DATA-TF PDU
    final pdu = BytesBuilder();
    pdu.addByte(0x04); // P-DATA-TF
    pdu.addByte(0x00);
    pdu.add(_uint32Be(pdvBytes.length));
    pdu.add(pdvBytes);

    return pdu.toBytes();
  }

  static int _parseCEchoRspStatus(Uint8List pduData) {
    if (pduData.length < 6) return -1;
    // Skip PDV length (4) + Context ID (1) + Control Header (1) = 6 bytes
    final cmdData = pduData.sublist(6);
    final bd = ByteData.sublistView(cmdData);

    int offset = 0;
    while (offset + 8 <= cmdData.length) {
      final group = bd.getUint16(offset, Endian.little);
      final element = bd.getUint16(offset + 2, Endian.little);
      final vl = bd.getUint32(offset + 4, Endian.little);
      final valOffset = offset + 8;

      if (group == 0x0000 && element == 0x0900) {
        // Status element
        if (valOffset + 2 <= cmdData.length) {
          return bd.getUint16(valOffset, Endian.little);
        }
      }

      offset = valOffset + vl;
    }
    return 0x0000;
  }

  /// Transfer Syntax of the accepted Verification SOP Class, or `null` if the context was rejected.
  ///
  /// An empty Transfer Syntax sub-item is treated as Implicit VR Little Endian.
  static String? _acceptedTransferSyntax(Uint8List pduData, int targetPcId) {
    if (pduData.length < 68) return null;
    var offset = 68;

    while (offset + 4 <= pduData.length) {
      final itemType = pduData[offset];
      final itemLen = (pduData[offset + 2] << 8) | pduData[offset + 3];
      final itemDataOffset = offset + 4;
      if (itemLen < 0 || itemDataOffset + itemLen > pduData.length) break;

      if (itemType == 0x21 && itemLen >= 4) {
        final pcId = pduData[itemDataOffset];
        final result = pduData[itemDataOffset + 2];
        if (pcId == targetPcId) {
          if (result != 0) return null;
          var transferSyntax = implicitVrLittleEndianUid;
          var sub = itemDataOffset + 4;
          final itemEnd = itemDataOffset + itemLen;
          while (sub + 4 <= itemEnd) {
            final subType = pduData[sub];
            final subLen = (pduData[sub + 2] << 8) | pduData[sub + 3];
            final subStart = sub + 4;
            if (subLen < 0 || subStart + subLen > itemEnd) break;
            if (subType == 0x40 && subLen > 0) {
              transferSyntax = String.fromCharCodes(pduData.sublist(subStart, subStart + subLen)).trim();
              break;
            }
            sub = subLen == 0 ? sub + 4 : subStart + subLen;
          }
          return transferSyntax;
        }
      }

      offset = itemLen == 0 ? itemDataOffset : itemDataOffset + itemLen;
    }

    return null;
  }

  static String _parseAssociateReject(Uint8List pduData) {
    if (pduData.length < 4) return 'No reason given';
    final result = pduData[1];
    final source = pduData[2];
    final reason = pduData[3];

    final resultStr = result == 1 ? 'Permanent' : 'Transient';
    String reasonStr;
    switch (reason) {
      case 1:
        reasonStr = 'No reason given';
        break;
      case 2:
        reasonStr = 'Application context name not supported';
        break;
      case 3:
        reasonStr = 'Calling AE Title not recognized';
        break;
      case 7:
        reasonStr = 'Called AE Title not recognized';
        break;
      default:
        reasonStr = 'Code $reason';
    }

    return '$resultStr (Source: $source, Reason: $reasonStr)';
  }

  static List<int> _padString(String s, int length) {
    final codes = s.codeUnits;
    if (codes.length >= length) {
      return codes.sublist(0, length);
    }
    final res = List<int>.filled(length, 0x20);
    for (int i = 0; i < codes.length; i++) {
      res[i] = codes[i];
    }
    return res;
  }

  static List<int> _padEven(List<int> bytes) {
    if (bytes.length % 2 == 0) return bytes;
    return [...bytes, 0x00];
  }

  static List<int> _uint16Be(int val) => [(val >> 8) & 0xFF, val & 0xFF];
  static List<int> _uint32Be(int val) => [
        (val >> 24) & 0xFF,
        (val >> 16) & 0xFF,
        (val >> 8) & 0xFF,
        val & 0xFF,
      ];
  static List<int> _uint16Le(int val) => [val & 0xFF, (val >> 8) & 0xFF];
  static List<int> _uint32Le(int val) => [
        val & 0xFF,
        (val >> 8) & 0xFF,
        (val >> 16) & 0xFF,
        (val >> 24) & 0xFF,
      ];
}

class _Pdu {
  final int type;
  final Uint8List data;
  _Pdu(this.type, this.data);
}

class _PduReader {
  final BytesBuilder _buffer = BytesBuilder();

  List<_Pdu> append(List<int> chunk) {
    _buffer.add(chunk);
    final pdus = <_Pdu>[];
    final allBytes = _buffer.toBytes();
    int offset = 0;

    while (offset + 6 <= allBytes.length) {
      final pduType = allBytes[offset];
      final pduLen = (allBytes[offset + 2] << 24) |
          (allBytes[offset + 3] << 16) |
          (allBytes[offset + 4] << 8) |
          allBytes[offset + 5];

      if (offset + 6 + pduLen <= allBytes.length) {
        final pduData = Uint8List.sublistView(allBytes, offset + 6, offset + 6 + pduLen);
        pdus.add(_Pdu(pduType, pduData));
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
