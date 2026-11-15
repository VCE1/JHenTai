import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// Loads and caches the compiled runtime shader used to suppress moire patterns
/// when high-resolution manga scans are downscaled on small or lower-DPI displays.
class AntiMoireShader {
  AntiMoireShader._();

  static const String assetPath = 'shaders/anti_moire.frag';

  static Future<ui.FragmentProgram?>? _loadFuture;
  static ui.FragmentProgram? cachedProgram;
  static final ValueNotifier<int> readyNotifier = ValueNotifier<int>(0);

  /// Loads and caches the fragment program once. Returns null if runtime shaders
  /// are unavailable or fail to load so callers can fall back cleanly.
  static Future<ui.FragmentProgram?> ensureLoaded() {
    if (cachedProgram != null) {
      return Future<ui.FragmentProgram?>.value(cachedProgram);
    }
    return _loadFuture ??= _loadInternal();
  }

  static Future<ui.FragmentProgram?> _loadInternal() async {
    try {
      final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(assetPath);
      cachedProgram = program;
      readyNotifier.value++;
      return program;
    } catch (_) {
      return null;
    }
  }
}

/// Provides the enclosing reader viewport's live zoom scale to descendant image widgets
/// without rebuilding the widget subtree during pinch or double-tap zoom animations.
class ReadZoomScope extends InheritedWidget {
  const ReadZoomScope({
    super.key,
    required this.scaleListenable,
    required super.child,
  });

  final ValueListenable<double> scaleListenable;

  static ValueListenable<double>? listenableOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ReadZoomScope>()?.scaleListenable;
  }

  static double scaleOf(BuildContext context) {
    return listenableOf(context)?.value ?? 1.0;
  }

  @override
  bool updateShouldNotify(ReadZoomScope oldWidget) {
    return scaleListenable != oldWidget.scaleListenable;
  }
}

/// Bridges a [PhotoViewControllerBase]'s scale stream into a [ReadZoomScope].
class PhotoViewZoomBridge extends StatefulWidget {
  const PhotoViewZoomBridge({
    super.key,
    required this.controller,
    required this.child,
  });

  final PhotoViewControllerBase controller;
  final Widget child;

  @override
  State<PhotoViewZoomBridge> createState() => _PhotoViewZoomBridgeState();
}

class _PhotoViewZoomBridgeState extends State<PhotoViewZoomBridge> {
  late final ValueNotifier<double> _scaleNotifier;
  StreamSubscription<PhotoViewControllerValue>? _subscription;

  static double _normalizeScale(double? rawScale) {
    if (rawScale == null || !rawScale.isFinite || rawScale <= 0) {
      return 1.0;
    }
    return rawScale;
  }

  @override
  void initState() {
    super.initState();
    _scaleNotifier = ValueNotifier<double>(_normalizeScale(widget.controller.value.scale));
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant PhotoViewZoomBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _subscription?.cancel();
      _updateScale(_normalizeScale(widget.controller.value.scale));
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.controller.outputStateStream.listen((PhotoViewControllerValue value) {
      _updateScale(_normalizeScale(value.scale));
    });
  }

  void _updateScale(double nextScale) {
    if ((nextScale - _scaleNotifier.value).abs() > 0.002) {
      _scaleNotifier.value = nextScale;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scaleNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ReadZoomScope(
      scaleListenable: _scaleNotifier,
      child: widget.child,
    );
  }
}

/// Renders a decoded [ui.Image] through the adaptive anti-moire GPU fragment shader
/// and automatically falls back to [fallbackBuilder] while the shader loads or if unavailable.
class AntiMoireImage extends StatefulWidget {
  const AntiMoireImage({
    super.key,
    required this.image,
    required this.width,
    required this.height,
    required this.fallbackBuilder,
  });

  final ui.Image image;
  final double? width;
  final double? height;
  final WidgetBuilder fallbackBuilder;

  @override
  State<AntiMoireImage> createState() => _AntiMoireImageState();
}

class _AntiMoireImageState extends State<AntiMoireImage> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _syncShader();
    AntiMoireShader.readyNotifier.addListener(_onShaderReadyChanged);
    if (AntiMoireShader.cachedProgram == null) {
      unawaited(AntiMoireShader.ensureLoaded());
    }
  }

  void _onShaderReadyChanged() {
    if (!mounted) {
      return;
    }
    if (_shader == null && AntiMoireShader.cachedProgram != null) {
      setState(_syncShader);
    }
  }

  void _syncShader() {
    final ui.FragmentProgram? program = AntiMoireShader.cachedProgram;
    if (program == null || _shader != null) {
      return;
    }
    _shader = program.fragmentShader();
  }

  @override
  void dispose() {
    AntiMoireShader.readyNotifier.removeListener(_onShaderReadyChanged);
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui.FragmentShader? shader = _shader;
    final double? width = widget.width;
    final double? height = widget.height;
    if (shader == null || width == null || height == null || width <= 0 || height <= 0) {
      return widget.fallbackBuilder(context);
    }

    final ValueListenable<double>? zoomListenable = ReadZoomScope.listenableOf(context);
    final double devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;

    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        size: Size(width, height),
        painter: _AntiMoirePainter(
          shader: shader,
          image: widget.image,
          devicePixelRatio: devicePixelRatio,
          zoomListenable: zoomListenable,
        ),
      ),
    );
  }
}

class _AntiMoirePainter extends CustomPainter {
  _AntiMoirePainter({
    required this.shader,
    required this.image,
    required this.devicePixelRatio,
    required this.zoomListenable,
  }) : super(repaint: zoomListenable);

  final ui.FragmentShader shader;
  final ui.Image image;
  final double devicePixelRatio;
  final ValueListenable<double>? zoomListenable;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || image.width <= 0 || image.height <= 0) {
      return;
    }

    final double dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
    final double rawZoom = zoomListenable?.value ?? 1.0;
    final double zoom = rawZoom.isFinite && rawZoom > 0 ? rawZoom : 1.0;

    final double dstPhysW = math.max(1.0, size.width * dpr * zoom);
    final double dstPhysH = math.max(1.0, size.height * dpr * zoom);
    final double srcW = image.width.toDouble();
    final double srcH = image.height.toDouble();

    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, srcW);
    shader.setFloat(3, srcH);
    shader.setFloat(4, srcW / dstPhysW);
    shader.setFloat(5, srcH / dstPhysH);
    shader.setImageSampler(0, image, filterQuality: FilterQuality.medium);

    final Paint paint = Paint()
      ..shader = shader
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;

    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _AntiMoirePainter oldDelegate) {
    return !identical(oldDelegate.shader, shader) ||
        !identical(oldDelegate.image, image) ||
        oldDelegate.devicePixelRatio != devicePixelRatio ||
        oldDelegate.zoomListenable != zoomListenable;
  }
}
