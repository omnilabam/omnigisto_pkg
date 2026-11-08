// Talks to a DICOM node: C-ECHO, C-FIND, C-GET/C-MOVE, C-STORE.
//
//   dart run example/bin/dicom_pacs.dart echo --host 127.0.0.1 --port 4242 --called ORTHANC --calling OMNI
//   dart run example/bin/dicom_pacs.dart find --host 127.0.0.1 --port 4242 --called ORTHANC --calling OMNI --name "Doe*"
//   dart run example/bin/dicom_pacs.dart get  --host 127.0.0.1 --port 4242 --called ORTHANC --calling OMNI --study <uid> --out /tmp/study
//   dart run example/bin/dicom_pacs.dart store --host 127.0.0.1 --port 4242 --called ORTHANC --calling OMNI --path /path/to/slide
//
// Run from the package root. Network examples need a reachable PACS.

import 'dart:io';

import 'package:omnigisto_pkg/omnigisto_pkg.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }

  final command = args.first;
  final flags = _Flags(args.skip(1).toList());
  switch (command) {
    case 'echo':
      await _echo(flags);
    case 'find':
      await _find(flags);
    case 'get':
      await _retrieve(flags, DicomRetrieveMethod.cGet);
    case 'move':
      await _retrieve(flags, DicomRetrieveMethod.cMove);
    case 'store':
      await _store(flags);
    default:
      _usage();
      exitCode = 64;
  }
}

Future<void> _echo(_Flags flags) async {
  if (!_hasNode(flags)) return;
  final result = await DicomEchoClient.echo(
    host: flags.host,
    port: flags.port,
    calledAeTitle: flags.called,
    callingAeTitle: flags.calling,
  );
  if (result.errorCode != null) {
    stderr.writeln(result.errorCode!.name);
  }
  stdout.writeln(result.message);
  if (!result.isSuccess) exitCode = 1;
}

Future<void> _find(_Flags flags) async {
  if (!_hasNode(flags)) return;
  final result = await DicomFindClient.find(
    host: flags.host,
    port: flags.port,
    calledAeTitle: flags.called,
    callingAeTitle: flags.calling,
    query: DicomFindQuery(
      patientName: flags.get('name') ?? '',
      patientId: flags.get('patient-id') ?? '',
      studyDate: flags.get('date') ?? '',
      studyInstanceUid: flags.get('study') ?? '',
    ),
  );
  if (result.errorCode != null) {
    stderr.writeln(result.errorCode!.name);
  }
  stdout.writeln(result.message);
  for (final study in result.studies) {
    stdout.writeln(
      '${study.studyDate}  ${study.patientName}  ${study.studyInstanceUid}  ${study.modalities}',
    );
  }
  if (!result.isSuccess) exitCode = 1;
}

Future<void> _retrieve(_Flags flags, DicomRetrieveMethod method) async {
  if (!_hasNode(flags)) return;
  final study = flags.get('study');
  final out = flags.get('out') ?? 'dicom_out';
  if (study == null || study.isEmpty) {
    stderr.writeln('--study <uid> is required');
    exitCode = 64;
    return;
  }
  final result = await DicomRetrieveClient.retrieve(
    host: flags.host,
    port: flags.port,
    calledAeTitle: flags.called,
    callingAeTitle: flags.calling,
    studyInstanceUid: study,
    method: method,
    outputDirectory: out,
    listenPort: int.tryParse(flags.get('listen') ?? '') ?? 11112,
    onProgress: (progress) {
      stdout.writeln(
        'received ${progress.receivedFiles}, remaining ${progress.remaining ?? '-'}',
      );
    },
  );
  if (result.errorCode != null) {
    stderr.writeln(result.errorCode!.name);
  }
  stdout.writeln(
    '${result.message} (${result.receivedCount} files in ${result.directory})',
  );
  if (!result.isSuccess) exitCode = 1;
}

Future<void> _store(_Flags flags) async {
  if (!_hasNode(flags)) return;
  final path = flags.get('path');
  if (path == null || path.isEmpty) {
    stderr.writeln('--path <file-or-folder> is required');
    exitCode = 64;
    return;
  }
  final instances = await DicomStoreClient.collectFiles(path);
  if (instances.isEmpty) {
    stderr.writeln(DicomStoreErrorCode.noStudyFiles.name);
    stderr.writeln('No DICOM files at $path');
    exitCode = 1;
    return;
  }
  final result = await DicomStoreClient.store(
    host: flags.host,
    port: flags.port,
    calledAeTitle: flags.called,
    callingAeTitle: flags.calling,
    instances: instances,
    onProgress: (progress) {
      stdout.writeln(
        '${progress.completed}/${progress.total} ${progress.currentName ?? ''}',
      );
    },
  );
  if (result.errorCode != null) {
    stderr.writeln(result.errorCode!.name);
  }
  stdout.writeln(result.message);
  if (!result.isSuccess) exitCode = 1;
}

bool _hasNode(_Flags flags) {
  if (flags.host.isEmpty ||
      flags.called.isEmpty ||
      flags.calling.isEmpty ||
      flags.port <= 0) {
    stderr.writeln('--host, --port, --called and --calling are required');
    exitCode = 64;
    return false;
  }
  return true;
}

void _usage() {
  stderr.writeln(
    'Usage: dart run example/bin/dicom_pacs.dart <echo|find|get|move|store> '
    '--host <ip> --port <n> --called <ae> --calling <ae> '
    '[--name q] [--date YYYYMMDD] [--study uid] [--path dir] [--out dir] [--listen 11112]',
  );
}

class _Flags {
  final Map<String, String> values = {};

  _Flags(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) continue;
      final key = arg.substring(2);
      values[key] = i + 1 < args.length && !args[i + 1].startsWith('--')
          ? args[++i]
          : '';
    }
  }

  String get host => values['host'] ?? '';
  int get port => int.tryParse(values['port'] ?? '') ?? 0;
  String get called => values['called'] ?? '';
  String get calling => values['calling'] ?? '';
  String? get(String key) => values[key];
}
