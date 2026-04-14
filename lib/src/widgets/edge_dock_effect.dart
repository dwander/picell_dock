import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/dock_group.dart';
import '../theme/dock_theme.dart';
import '_border_effect_base.dart';

/// 엣지 패널 전환 시 도킹 방향 테두리에서 펄스 글로우가 나타나는 이펙트.
///
/// 중앙에서 위아래로 퍼지며, 밝아졌다 어두워지고 사라진다.
///
/// ```dart
/// final ctrl = EdgeDockEffectController();
///
/// EdgeDockEffect(
///   controller: ctrl,
///   child: MyWidget(),
/// )
///
/// ctrl.trigger(ViewportEdge.left);
/// ```
class EdgeDockEffect extends StatefulWidget {
  final Widget child;
  final EdgeDockEffectController controller;

  /// 글로우 색상 (기본: DockTheme 액센트 색)
  final Color? color;

  /// 애니메이션 전체 길이 (기본: 600ms)
  final Duration duration;

  /// 테두리 둥근 정도 (기본: 0)
  final double borderRadius;

  const EdgeDockEffect({
    super.key,
    required this.child,
    required this.controller,
    this.color,
    this.duration = const Duration(milliseconds: 600),
    this.borderRadius = 0,
  });

  @override
  State<EdgeDockEffect> createState() => _EdgeDockEffectState();
}

class _EdgeDockEffectState extends State<EdgeDockEffect>
    with SingleTickerProviderStateMixin, BorderEffectMixin<EdgeDockEffect> {
  ViewportEdge _edge = ViewportEdge.left;

  @override
  Duration get effectDuration => widget.duration;

  @override
  Curve get effectCurve => Curves.easeOut;

  @override
  void onAttach() => widget.controller._attach(_triggerWithEdge);

  @override
  void onDetach() => widget.controller._detach();

  void _triggerWithEdge(ViewportEdge edge) {
    _edge = edge;
    playEffect();
  }

  @override
  void didUpdateWidget(EdgeDockEffect oldWidget) {
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
      painterBuilder: (v) => _EdgeDockPainter(
        progress: v,
        color: color,
        edge: _edge,
        borderRadius: widget.borderRadius,
      ),
      child: widget.child,
    );
  }
}

/// [EdgeDockEffect] 외부 제어 컨트롤러.
class EdgeDockEffectController {
  void Function(ViewportEdge)? _trigger;

  void _attach(void Function(ViewportEdge) trigger) => _trigger = trigger;
  void _detach() => _trigger = null;

  /// 지정한 엣지 방향에서 글로우 펄스 재생.
  void trigger(ViewportEdge edge) => _trigger?.call(edge);
}

/// 도킹 방향 테두리에서 중앙 → 상하로 퍼지며 밝아졌다 사라지는 페인터.
///
/// 애니메이션 3단계:
/// - 0.0 ~ 0.35: 중앙에서 위아래로 확장 + 밝아짐
/// - 0.35 ~ 0.55: 전체 길이, 최대 밝기 유지
/// - 0.55 ~ 1.0: 페이드아웃
class _EdgeDockPainter extends CustomPainter {
  final double progress;
  final Color color;
  final ViewportEdge edge;
  final double borderRadius;

  /// 글로우 두께 (메인 스트로크)
  static const double _strokeWidth = 2.0;

  /// 블러 글로우 확산 반경
  static const double _glowRadius = 6.0;

  /// 글로우 MaskFilter 블러 반경.
  static const double _glowBlur = 5.0;

  /// 끝 하이라이트 MaskFilter 블러 반경.
  static const double _tipBlur = 3.0;

  /// 끝 하이라이트 최대 원 반경.
  static const double _tipMaxRadius = 3.0;

  /// 엣지 기준 X 좌표 인셋 (테두리 안쪽 1px).
  static const double _edgeInset = 1.0;

  /// 확장 완료 시점
  static const double _expandEnd = 0.35;

  /// 최대 밝기 유지 종료 시점
  static const double _holdEnd = 0.55;

  const _EdgeDockPainter({
    required this.progress,
    required this.color,
    required this.edge,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    // ── 엣지 방향 좌표 ──
    final isLeft = edge == ViewportEdge.left;
    final x = isLeft ? _edgeInset : size.width - _edgeInset;
    final centerY = size.height / 2;

    // ── 단계별 파라미터 ──
    final double extent; // 중앙에서 위아래로 퍼지는 거리 (0~halfHeight)
    final double alpha; // 전체 투명도

    final halfHeight = size.height / 2;
    // 코너 부분을 감안해 살짝 안쪽까지만 확장
    final maxExtent = halfHeight - borderRadius * 0.5;

    if (progress < _expandEnd) {
      // 단계 1: 확장 + 밝아짐
      final t = progress / _expandEnd;
      final easedT = Curves.easeOutCubic.transform(t);
      extent = maxExtent * easedT;
      // 밝기: 0.3 → 1.0
      alpha = 0.3 + 0.7 * easedT;
    } else if (progress < _holdEnd) {
      // 단계 2: 유지
      extent = maxExtent;
      alpha = 1.0;
    } else {
      // 단계 3: 페이드아웃
      final t = (progress - _holdEnd) / (1.0 - _holdEnd);
      final easedT = Curves.easeInCubic.transform(t);
      extent = maxExtent;
      alpha = 1.0 - easedT;
    }

    if (alpha <= 0) return;

    final yTop = centerY - extent;
    final yBottom = centerY + extent;

    // ── 글로우 (블러된 넓은 선) ──
    final glowPaint = Paint()
      ..color = color.withValues(alpha: alpha * 0.35)
      ..strokeWidth = _glowRadius
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _glowBlur);
    canvas.drawLine(Offset(x, yTop), Offset(x, yBottom), glowPaint);

    // ── 메인 라인 (선명한 코어) ──
    final corePaint = Paint()
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    // 중앙이 가장 밝고 끝으로 갈수록 어두운 그라데이션
    const segments = 16;
    for (int i = 0; i < segments; i++) {
      final t0 = i / segments;
      final t1 = (i + 1) / segments;

      // 중앙(0.5)에서 멀어질수록 어두워짐
      final midT = (t0 + t1) / 2;
      final distFromCenter = (midT - 0.5).abs() * 2; // 0~1
      final segAlpha = alpha * (1.0 - distFromCenter * 0.5);

      corePaint.color = color.withValues(alpha: segAlpha.clamp(0.0, 1.0));

      final segTop = yTop + (yBottom - yTop) * t0;
      final segBottom = yTop + (yBottom - yTop) * t1;
      canvas.drawLine(Offset(x, segTop), Offset(x, segBottom), corePaint);
    }

    // ── 양 끝 하이라이트 (퍼지는 느낌) ──
    final tipAlpha = alpha * 0.5;
    final tipPaint = Paint()
      ..color = color.withValues(alpha: tipAlpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _tipBlur);
    final tipRadius = math.min(_tipMaxRadius, extent * 0.15);
    canvas.drawCircle(Offset(x, yTop), tipRadius, tipPaint);
    canvas.drawCircle(Offset(x, yBottom), tipRadius, tipPaint);
  }

  @override
  bool shouldRepaint(_EdgeDockPainter old) =>
      old.progress != progress || old.edge != edge;
}
