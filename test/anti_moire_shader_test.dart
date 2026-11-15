import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/l18n/en_US.dart';
import 'package:jhentai/src/l18n/ko_KR.dart';
import 'package:jhentai/src/l18n/pt_BR.dart';
import 'package:jhentai/src/l18n/ru_RU.dart';
import 'package:jhentai/src/l18n/zh_CN.dart';
import 'package:jhentai/src/l18n/zh_TW.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:jhentai/src/widget/anti_moire_image.dart';
import 'package:photo_view/photo_view.dart';

Future<ui.Image> _makeQuadrantImage(int w, int h) async {
  final Uint8List pixels = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int idx = (y * w + x) * 4;
      final bool left = x < w ~/ 2;
      final bool top = y < h ~/ 2;
      if (top && left) {
        pixels[idx] = 255;
        pixels[idx + 1] = 0;
        pixels[idx + 2] = 0;
        pixels[idx + 3] = 255;
      } else if (top && !left) {
        pixels[idx] = 0;
        pixels[idx + 1] = 255;
        pixels[idx + 2] = 0;
        pixels[idx + 3] = 255;
      } else if (!top && left) {
        pixels[idx] = 0;
        pixels[idx + 1] = 0;
        pixels[idx + 2] = 255;
        pixels[idx + 3] = 255;
      } else {
        pixels[idx] = 255;
        pixels[idx + 1] = 255;
        pixels[idx + 2] = 255;
        pixels[idx + 3] = 255;
      }
    }
  }
  return _rgbaToImage(pixels, w, h);
}

Future<ui.Image> _makeDiagonalScreentoneImage(int w, int h) async {
  final Uint8List pixels = Uint8List(w * h * 4);
  // 45-degree halftone period ~3.8px creates strong aliasing waves under 4x bilinear downscale.
  const double k = 2.0 * math.pi / 3.8;
  const double invSqrt2 = 0.70710678118;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double u = (x * invSqrt2 + y * invSqrt2) * k;
      final double v = (-x * invSqrt2 + y * invSqrt2) * k;
      final double dot = 0.5 * (math.cos(u) + math.cos(v));
      final int luma = dot > 0.15 ? 245 : 15;
      final int idx = (y * w + x) * 4;
      pixels[idx] = luma;
      pixels[idx + 1] = luma;
      pixels[idx + 2] = luma;
      pixels[idx + 3] = 255;
    }
  }
  return _rgbaToImage(pixels, w, h);
}

Future<ui.Image> _rgbaToImage(Uint8List pixels, int w, int h) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final ui.ImageDescriptor desc = ui.ImageDescriptor.raw(
    buffer,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final ui.Codec codec = await desc.instantiateCodec();
  final ui.FrameInfo frame = await codec.getNextFrame();
  return frame.image;
}

Future<(int width, ByteData bytes)> _captureBoundary(GlobalKey key, {double pixelRatio = 1.0}) async {
  final RenderRepaintBoundary boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image captured = await boundary.toImage(pixelRatio: pixelRatio);
  final ByteData bytes = (await captured.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final int width = captured.width;
  captured.dispose();
  return (width, bytes);
}

double _interiorLumaStdDev(ByteData bytes, int stride, int minXY, int maxXY) {
  final List<double> lumas = <double>[];
  for (int y = minXY; y < maxXY; y++) {
    for (int x = minXY; x < maxXY; x++) {
      final int i = (y * stride + x) * 4;
      lumas.add(bytes.getUint8(i).toDouble());
    }
  }
  final double mean = lumas.reduce((double a, double b) => a + b) / lumas.length;
  double sumSq = 0;
  for (final double v in lumas) {
    final double d = v - mean;
    sumSq += d * d;
  }
  return math.sqrt(sumSq / lumas.length);
}

class _RawShaderPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final ui.Image image;
  final double texelsPerPx;

  _RawShaderPainter(this.program, this.image, this.texelsPerPx);

  @override
  void paint(Canvas canvas, Size size) {
    final ui.FragmentShader shader = program.fragmentShader();
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, image.width.toDouble());
    shader.setFloat(3, image.height.toDouble());
    shader.setFloat(4, texelsPerPx);
    shader.setFloat(5, texelsPerPx);
    shader.setImageSampler(0, image);
    final Paint paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
    shader.dispose();
  }

  @override
  bool shouldRepaint(covariant _RawShaderPainter oldDelegate) => true;
}

void main() {
  testWidgets('anti_moire.frag preserves orientation and local UV under offset and transform', (WidgetTester tester) async {
    late ui.FragmentProgram program;
    late ui.Image quadrant;
    await tester.runAsync(() async {
      program = await ui.FragmentProgram.fromAsset('shaders/anti_moire.frag');
      quadrant = await _makeQuadrantImage(200, 200);
    });
    addTearDown(quadrant.dispose);

    final GlobalKey boundaryKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: boundaryKey,
          child: Container(
            width: 300,
            height: 300,
            color: Colors.black,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 40,
                  top: 60,
                  child: Transform.translate(
                    offset: const Offset(15, 25),
                    child: CustomPaint(
                      size: const Size(100, 100),
                      painter: _RawShaderPainter(program, quadrant, 2.0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    late int imgW;
    late ByteData bytes;
    await tester.runAsync(() async {
      (imgW, bytes) = await _captureBoundary(boundaryKey);
    });

    (int r, int g, int b, int a) pxAt(int x, int y) {
      final int i = (y * imgW + x) * 4;
      return (bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2), bytes.getUint8(i + 3));
    }

    final (int, int, int, int) tl = pxAt(75, 105);
    final (int, int, int, int) tr = pxAt(135, 105);
    final (int, int, int, int) bl = pxAt(75, 165);
    final (int, int, int, int) br = pxAt(135, 165);

    expect(tl.$1, greaterThan(200));
    expect(tl.$2, lessThan(30));
    expect(tr.$2, greaterThan(200));
    expect(tr.$1, lessThan(30));
    expect(bl.$3, greaterThan(200));
    expect(bl.$1, lessThan(30));
    expect(br.$1, greaterThan(200));
    expect(br.$2, greaterThan(200));
    expect(br.$3, greaterThan(200));
  });

  testWidgets('anti_moire.frag preserves orientation under DPR 3.0 and Transform.scale 2.0', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late ui.FragmentProgram program;
    late ui.Image quadrant;
    await tester.runAsync(() async {
      program = await ui.FragmentProgram.fromAsset('shaders/anti_moire.frag');
      quadrant = await _makeQuadrantImage(200, 200);
    });
    addTearDown(quadrant.dispose);

    final GlobalKey boundaryKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: boundaryKey,
          child: Container(
            width: 300,
            height: 300,
            color: Colors.black,
            child: Center(
              child: Transform.scale(
                scale: 2.0,
                child: CustomPaint(
                  size: const Size(100, 100),
                  painter: _RawShaderPainter(program, quadrant, 2.0),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    late int imgW;
    late ByteData bytes;
    await tester.runAsync(() async {
      (imgW, bytes) = await _captureBoundary(boundaryKey, pixelRatio: 3.0);
    });

    (int r, int g, int b, int a) pxAt(int x, int y) {
      final int i = (y * imgW + x) * 4;
      return (bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2), bytes.getUint8(i + 3));
    }

    final (int, int, int, int) tl = pxAt(250, 250);
    final (int, int, int, int) tr = pxAt(650, 250);
    final (int, int, int, int) bl = pxAt(250, 650);
    final (int, int, int, int) br = pxAt(650, 650);

    expect(tl.$1, greaterThan(200));
    expect(tl.$2, lessThan(30));
    expect(tr.$2, greaterThan(200));
    expect(tr.$1, lessThan(30));
    expect(bl.$3, greaterThan(200));
    expect(bl.$1, lessThan(30));
    expect(br.$1, greaterThan(200));
    expect(br.$2, greaterThan(200));
    expect(br.$3, greaterThan(200));
  });

  testWidgets('AntiMoireImage suppresses screentone moire when downscaled and restores sharpness when zoomed', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(200, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late ui.Image screentone;
    await tester.runAsync(() async {
      await AntiMoireShader.ensureLoaded();
      screentone = await _makeDiagonalScreentoneImage(400, 400);
    });
    addTearDown(screentone.dispose);

    // 1. Baseline: FilterQuality.low raw image downscaled 4x shows strong moire aliasing ripple.
    final GlobalKey rawKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: rawKey,
          child: SizedBox(
            width: 100,
            height: 100,
            child: RawImage(
              image: screentone,
              width: 100,
              height: 100,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    late int rawW;
    late ByteData rawBytes;
    await tester.runAsync(() async {
      (rawW, rawBytes) = await _captureBoundary(rawKey);
    });
    final double rawStdDev = _interiorLumaStdDev(rawBytes, rawW, 15, 85);

    // 2. AntiMoireImage at zoom 1.0 (downscale 4.0x) suppresses moire ripple markedly.
    final PhotoViewController zoomController = PhotoViewController()..scale = 1.0;
    addTearDown(zoomController.dispose);
    final GlobalKey shaderKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1.0),
          child: PhotoViewZoomBridge(
            controller: zoomController,
            child: RepaintBoundary(
              key: shaderKey,
              child: AntiMoireImage(
                image: screentone,
                width: 100,
                height: 100,
                fallbackBuilder: (_) => const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    late int shaderW;
    late ByteData shaderDownscaledBytes;
    await tester.runAsync(() async {
      (shaderW, shaderDownscaledBytes) = await _captureBoundary(shaderKey);
    });
    final double antiMoireStdDev = _interiorLumaStdDev(shaderDownscaledBytes, shaderW, 15, 85);

    expect(rawStdDev, greaterThan(45.0));
    expect(antiMoireStdDev, lessThan(rawStdDev * 0.35));

    // 3. Zooming in via PhotoViewController moves texelsPerPx <= 1.0 -> shader passes through crisp native texture.
    zoomController.scale = 4.5;
    await tester.pump();
    await tester.pump();
    late int zoomedW;
    late ByteData zoomedBytes;
    await tester.runAsync(() async {
      (zoomedW, zoomedBytes) = await _captureBoundary(shaderKey);
    });
    final double zoomedStdDev = _interiorLumaStdDev(zoomedBytes, zoomedW, 15, 85);
    expect(zoomedStdDev, greaterThan(antiMoireStdDev * 3.0));
  });

  testWidgets('PhotoViewZoomBridge propagates live scale updates into ReadZoomScope', (WidgetTester tester) async {
    final PhotoViewController controller = PhotoViewController();
    addTearDown(controller.dispose);
    double? observedScale;
    int buildCount = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PhotoViewZoomBridge(
          controller: controller,
          child: Builder(
            builder: (BuildContext context) {
              buildCount++;
              observedScale = ReadZoomScope.scaleOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(observedScale, 1.0);
    expect(buildCount, 1);

    controller.scale = 2.25;
    await tester.pump();
    expect(ReadZoomScope.listenableOf(tester.element(find.byType(SizedBox)))?.value, 2.25);
    // Changing scale notifies CustomPainter via ValueListenable without rebuilding widgets.
    expect(buildCount, 1);
  });

  testWidgets('ReadSetting persists enableAntiMoireFilter and defaults safely on older configs', (WidgetTester tester) async {
    final ReadSetting setting = ReadSetting();
    expect(setting.enableAntiMoireFilter.value, isFalse);

    setting.enableAntiMoireFilter.value = true;
    final String serialized = setting.toConfigString();
    final Map<String, dynamic> decoded = jsonDecode(serialized) as Map<String, dynamic>;
    expect(decoded['enableAntiMoireFilter'], isTrue);

    final ReadSetting restored = ReadSetting();
    restored.applyBeanConfig(serialized);
    expect(restored.enableAntiMoireFilter.value, isTrue);

    decoded.remove('enableAntiMoireFilter');
    final ReadSetting legacy = ReadSetting();
    legacy.applyBeanConfig(jsonEncode(decoded));
    expect(legacy.enableAntiMoireFilter.value, isFalse);
  });

  test('All locale bundles provide non-empty anti-moire filter labels', () {
    final List<Map<String, String>> bundles = <Map<String, String>>[
      zh_CN.keys(),
      zh_TW.keys(),
      en_US.keys(),
      ko_KR.keys(),
      pt_BR.keys(),
      ru_RU.keys(),
    ];

    for (final Map<String, String> bundle in bundles) {
      expect(bundle['enableAntiMoireFilter'], isNotNull);
      expect(bundle['enableAntiMoireFilter']!.trim(), isNotEmpty);
      expect(bundle['enableAntiMoireFilterHint'], isNotNull);
      expect(bundle['enableAntiMoireFilterHint']!.trim(), isNotEmpty);
    }
  });
}
