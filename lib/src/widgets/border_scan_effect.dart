import 'package:flutter/material.dart';

import '../theme/dock_theme.dart';

/// 위젯 테두리를 따라 빛이 한 바퀴 도는 스캔 이펙트.
///
/// [BorderScanController.trigger]를 호출하면 애니메이션이 재생된다.
///
/// ```dart
/// final _scanCtrl = BorderScanController();
///
/// BorderScanEffect(
///   controller: _scanCtrl,
///   borderRadius: 6,
///   child: MyWidget(),
/// )
///
/// // 이펙트 재생
/// _scanCtrl.trigger();
/// ```
class BorderScanEffect extends StatefulWidget {
  final Widget child;
  final BorderScanController controller;

  /// 스캔 빛 색상 (기본: DockTheme 액센트 색)
  final Color? color;

  /// 한 바퀴 도는 데 걸리는 시간 (기본: 800ms)
  final Duration duration;

  /// 테두리 둥근 정도 (기본: 0)
  final double borderRadius;

  const BorderScanEffect({
    super.key,
    required this.child,
    required this.controller,
    this.color,
    this.duration = const Duration(milliseconds: 800),
    this.borderRadius = 0,
  });

  @override
  State<BorderScanEffect> createState() => BorderScanEffectState();
}

class BorderScanEffectState extends State<BorderScanEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: widget.duration, vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    widget.controller._attach(this);
  }

  @override
  void didUpdateWidget(BorderScanEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach();
      widget.controller._attach(this);
    }
    if (oldWidget.duration != widget.duration) {
      _ctrl.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    widget.controller._detach();
    _ctrl.dispose();
    super.dispose();
  }

  void trigger() => _ctrl.forward(from: 0);

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? DockTheme.of(context).colorScheme.accent;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) {
                final v = _anim.value;
                if (v == 0) return const SizedBox.shrink();
                return CustomPaint(
                  painter: _BorderScanPainter(
                    progress: v,
                    color: color,
                    borderRadius: widget.borderRadius,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 이펙트 재생을 외부에서 제어하는 컨트롤러.
///
/// [trigger]를 호출하면 연결된 [BorderScanEffect]의 애니메이션이 재생된다.
class BorderScanController {
  BorderScanEffectState? _state;

  void _attach(BorderScanEffectState state) => _state = state;
  void _detach() => _state = null;

  /// 스캔 이펙트를 처음부터 재생.
  void trigger() => _state?.trigger();
}

/// 테두리를 따라 빛이 한 바퀴 도는 스캔 페인터.
class _BorderScanPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double borderRadius;

  static const double _trailFraction = 0.28;
  static const double _strokeWidth = 2.0;
  static const int _steps = 30;

  const _BorderScanPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(borderRadius),
    );
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final total = metric.length;

    final headDist = total * progress;
    final trailLen = total * _trailFraction;

    const fadeStart = 0.85;
    final globalAlpha = progress < fadeStart
        ? 1.0
        : 1.0 - (progress - fadeStart) / (1.0 - fadeStart);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < _steps; i++) {
      final t0 = i / _steps;
      final t1 = (i + 1) / _steps;
      final d0 = (headDist - (1.0 - t0) * trailLen) % total;
      final d1 = (headDist - (1.0 - t1) * trailLen) % total;
      if (d0 < 0 || d1 < 0) continue;

      final segAlpha = (t1 * globalAlpha).clamp(0.0, 1.0);
      paint.color = color.withValues(alpha: segAlpha * 0.95);

      final Path seg;
      if (d1 >= d0) {
        seg = metric.extractPath(d0, d1);
      } else {
        seg = metric.extractPath(d0, total)
          ..addPath(metric.extractPath(0, d1), Offset.zero);
      }
      canvas.drawPath(seg, paint);
    }

    final headTangent = metric.getTangentForOffset(
      headDist.clamp(0, total - 0.1),
    );
    if (headTangent != null) {
      canvas.drawCircle(
        headTangent.position,
        3.5,
        Paint()
          ..color = color.withValues(alpha: globalAlpha * 0.6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(
        headTangent.position,
        1.5,
        Paint()..color = color.withValues(alpha: globalAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(_BorderScanPainter old) => old.progress != progress;
}
