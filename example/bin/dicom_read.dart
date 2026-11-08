// Reads a DICOM WSI instance or a folder of instances.
//
//   dart run example/bin/dicom_read.dart /path/to/slide.dcm
//   dart run example/bin/dicom_read.dart /path/to/slide_folder --tile 0,0 --region 0,0,512,512
//
// Run from the package root so the path dependency resolves.

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:omnigisto_pkg/omnigisto_pkg.dart';

Future<void> main(List<String> args) async {
  final parsed = _Args.parse(args);
  if (parsed.path == null) {
    stderr.writeln(
      'Usage: dart run example/bin/dicom_read.dart <file-or-folder> '
      '[--series <uid>] [--tile x,y] [--region x,y,w,h] [--level n] [--out file.jpg]',
    );
    exitCode = 64;
    return;
  }

  final slide = await openDicomSlide(
    parsed.path!,
    seriesInstanceUid: parsed.series,
  );
  if (slide == null) {
    stderr.writeln('Not a readable DICOM slide: ${parsed.path}');
    exitCode = 1;
    return;
  }

  try {
    final full = slide.fullMetadata();
    stdout.writeln('levels: ${full.levels.length}');
    for (var i = 0; i < full.levels.length; i++) {
      final level = full.levels[i];
      stdout.writeln(
        '  [$i] ${level.width}x${level.height} '
        'tile ${level.tileWidth}x${level.tileHeight} '
        'downsample ${level.downsample}',
      );
    }
    if (full.associations.isNotEmpty) {
      stdout.writeln('associations: ${full.associations.keys.join(', ')}');
    }

    final level = parsed.level;
    if (level < 0 || level >= slide.levels.length) {
      stderr.writeln('Level $level is outside 0..${slide.levels.length - 1}');
      exitCode = 1;
      return;
    }

    if (parsed.tile != null) {
      final bytes = await slide.readTile(level, parsed.tile!.$1, parsed.tile!.$2);
      stdout.writeln(
        'tile ${parsed.tile}: ${bytes == null ? 'missing' : '${bytes.length} bytes'}',
      );
    }

    if (parsed.region != null) {
      final region = parsed.region!;
      final image = await slide.readRegion(level, region.$1, region.$2, region.$3, region.$4);
      if (image == null) {
        stderr.writeln('Region could not be decoded');
        exitCode = 1;
        return;
      }
      final out = parsed.out ?? 'dicom_region.jpg';
      await File(out).writeAsBytes(img.encodeJpg(image, quality: 90));
      stdout.writeln('wrote $out (${image.width}x${image.height})');
    }
  } finally {
    await slide.close();
  }
}

class _Args {
  final String? path;
  final String? series;
  final int level;
  final (int, int)? tile;
  final (int, int, int, int)? region;
  final String? out;

  const _Args({
    this.path,
    this.series,
    this.level = 0,
    this.tile,
    this.region,
    this.out,
  });

  static _Args parse(List<String> args) {
    String? path;
    String? series;
    var level = 0;
    (int, int)? tile;
    (int, int, int, int)? region;
    String? out;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String next() => i + 1 < args.length ? args[++i] : '';
      switch (arg) {
        case '--series':
          series = next();
        case '--level':
          level = int.tryParse(next()) ?? 0;
        case '--tile':
          final parts = next().split(',');
          if (parts.length == 2) {
            tile = (int.parse(parts[0]), int.parse(parts[1]));
          }
        case '--region':
          final parts = next().split(',');
          if (parts.length == 4) {
            region = (
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2]),
              int.parse(parts[3]),
            );
          }
        case '--out':
          out = next();
        default:
          path ??= arg;
      }
    }
    return _Args(path: path, series: series, level: level, tile: tile, region: region, out: out);
  }
}
