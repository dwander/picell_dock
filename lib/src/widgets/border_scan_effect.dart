import 'package:flutter/material.dart';

import '../theme/dock_theme.dart';
import '_border_effect_base.dart';

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
  State<BorderScanEffect> createState() => _BorderScanEffectState();
}

class _BorderScanEffectState extends State<BorderScanEffect>
    with SingleTickerProviderStateMixin, BorderEffectMixin<BorderScanEffect> {
  @override
  Duration get effectDuration => widget.duration;

  @override
  Curve get effectCurve => Curves.easeInOut;

  @override
  void onAttach() => widget.controller._attach(playEffect);

  @override
  void onDetach() => widget.controller._detach();

  @override
  void didUpdateWidget(BorderScanEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      handleControllerChange(true);
    }
    if (oldWidget.duration != widget.duration) {
      handleDurationChange();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? DockTheme.of(context).colorScheme.accent;
    return BorderEffectScaffold(
      animation: effectAnim,
      painterBuilder: (v) => _BorderScanPainter(
        progress: v,
        color: color,
        borderRadius: widget.borderRadius,
      ),
      child: widget.child,
    );
  }
}

/// 이펙트 재생을 외부에서 제어하는 컨트롤러.
///
/// [trigger]를 호출하면 연결된 [BorderScanEffect]의 애니메이션이 재생된다.
class BorderScanController {
  VoidCallback? _trigger;

  void _attach(VoidCallback trigger) => _trigger = trigger;
  void _detach() => _trigger = null;

  /// 스캔 이펙트를 처음부터 재생.
  void trigger() => _trigger?.call();
}

/// 테두리를 따라 빛이 한 바퀴 도는 스캔 페인터.
class _BorderScanPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double borderRadius;

  static const double _trailFraction = 0.28;
  static const double _strokeWidth = 2.0;
  static const int _steps = 30;

  /// RRect 1px 인셋 (테두리가 클리핑되지 않도록).
  static const double _rrectInset = 1.0;

  /// 스캔 헤드 외곽 원 반경.
  static const double _scanHeadOuterRadius = 3.5;

  /// 스캔 헤드 코어 원 반경.
  static const double _scanHeadCoreRadius = 1.5;

  /// 스캔 헤드 글로우 MaskFilter 블러 반경.
  static const double _scanHeadBlur = 4.0;

  const _BorderScanPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(_rrectInset, _rrectInset, size.width - _rrectInset * 2, size.height - _rrectInset * 2),
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
        _scanHeadOuterRadius,
        Paint()
          ..color = color.withValues(alpha: globalAlpha * 0.6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _scanHeadBlur),
      );
      canvas.drawCircle(
        headTangent.position,
        _scanHeadCoreRadius,
        Paint()..color = color.withValues(alpha: globalAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(_BorderScanPainter old) => old.progress != progress;
}
