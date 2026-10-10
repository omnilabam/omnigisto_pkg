import 'dart:typed_data';

import 'package:image/image.dart' as img;

class HamamatsuJpegFixture {
  final Uint8List bytes;
  final List<int> restartOffsets;
  final List<List<int>> colors;
  final int sofOffset;
  final int entropyOffset;
  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;

  HamamatsuJpegFixture(
    this.bytes,
    this.restartOffsets,
    this.colors,
    this.sofOffset,
    this.entropyOffset,
    this.width,
    this.height,
    this.tileWidth,
    this.tileHeight,
  );
}

/// Builds a real sequential JPEG from independently encoded restart intervals.
/// Offsets are relative to [HamamatsuJpegFixture.bytes]; add the embedding offset
/// when passing them to HamamatsuJpeg.open for an embedded JPEG.
HamamatsuJpegFixture createHamamatsuJpegFixture({
  int columns = 3,
  int rows = 2,
  int restartInterval = 1,
  int? width,
  int? height,
  bool zeroSofDimensions = false,
  img.JpegChroma chroma = img.JpegChroma.yuv444,
}) {
  final mcu = chroma == img.JpegChroma.yuv420 ? 16 : 8;
  final tileWidth = restartInterval * mcu;
  width ??= columns * tileWidth;
  height ??= rows * mcu;
  const palette = [
    [230, 20, 30],
    [20, 220, 40],
    [30, 40, 230],
    [220, 200, 20],
    [210, 30, 210],
    [20, 210, 210],
  ];
  final output = BytesBuilder(copy: false);
  final offsets = <int>[];
  final colors = <List<int>>[];
  final encoded = <int, Uint8List>{};
  var sofOffset = 0;
  var entropyOffset = 0;
  for (var i = 0; i < columns * rows; i++) {
    final color = palette[i % palette.length];
    colors.add(color);
    final jpeg = encoded.putIfAbsent(i % palette.length, () {
      final image = img.Image(width: tileWidth, height: mcu);
      img.fill(image, color: img.ColorRgb8(color[0], color[1], color[2]));
      return img.encodeJpg(image, quality: 95, chroma: chroma);
    });
    var p = 2;
    var sosOffset = 0;
    var entropy = 0;
    while (p < jpeg.length) {
      final marker = jpeg[p + 1];
      final size = (jpeg[p + 2] << 8) | jpeg[p + 3];
      if (marker == 0xc0) sofOffset = p;
      if (marker == 0xda) {
        sosOffset = p;
        entropy = p + 2 + size;
        break;
      }
      p += size + 2;
    }
    if (i == 0) {
      final header = Uint8List.fromList(jpeg.sublist(0, entropy));
      final data = ByteData.sublistView(header);
      data.setUint16(sofOffset + 5, zeroSofDimensions ? 0 : height);
      data.setUint16(sofOffset + 7, zeroSofDimensions ? 0 : width);
      output.add(header.sublist(0, sosOffset));
      output.add([
        0xff,
        0xdd,
        0,
        4,
        restartInterval >> 8,
        restartInterval & 255,
      ]);
      output.add(header.sublist(sosOffset));
      entropyOffset = output.length;
    } else {
      output.add([0xff, 0xd0 + ((i - 1) % 8)]);
    }
    offsets.add(output.length);
    var entropyEnd = jpeg.length - 2;
    // image's encoder writes a whole stuffed padding byte when already aligned.
    // A solid block ends in EOB (00 for chroma), never an all-ones data byte.
    if (jpeg[entropyEnd - 2] == 0xff && jpeg[entropyEnd - 1] == 0) {
      entropyEnd -= 2;
    }
    output.add(jpeg.sublist(entropy, entropyEnd));
  }
  output.add([0xff, 0xd9]);
  return HamamatsuJpegFixture(
    output.takeBytes(),
    offsets,
    colors,
    sofOffset,
    entropyOffset,
    width,
    height,
    tileWidth,
    mcu,
  );
}
