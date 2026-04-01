import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/dock_color_scheme.dart';
import '../theme/dock_theme.dart';

/// 드래그/리사이즈 중 뷰어 배경에 표시되는 스냅 그리드 + 앵커 구역 오버레이.
///
/// 도트는 활성 패널 주변에만 방사형 그라데이션으로 페이드.
/// 방사 반경은 패널 대각선 크기에 비례.
class DockGridOverlay extends StatelessWidget {
  /// 도트 그라데이션의 중심점 (패널 중앙 절대좌표).
  final Offset? center;

  /// 활성 패널의 크기 (방사 반경 계산용).
  final Size? panelSize;

  const DockGridOverlay({super.key, this.center, this.panelSize});

  @override
  Widget build(BuildContext context) {
    final cs = DockTheme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _GridPainter(center: center, panelSize: panelSize, colorScheme: cs),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Offset? center;
  final Size? panelSize;
  final DockColorScheme colorScheme;

  _GridPainter({this.center, this.panelSize, required this.colorScheme});

  static const double _dotSpacing = 20.0;
  static const double _dotRadius = 0.8;
  static const double _minFadeRadius = 200.0;
  static const double _fadeRadiusMultiplier = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    _drawDots(canvas, size);
    _drawAnchorZones(canvas, size);
  }

  void _drawDots(Canvas canvas, Size size) {
    final c = center ?? Offset(size.width / 2, size.height / 2);
    final baseColor = colorScheme.fg4;

    // 패널 대각선에 비례한 방사 반경
    final diagonal = panelSize != null
        ? math.sqrt(
            panelSize!.width * panelSize!.width +
                panelSize!.height * panelSize!.height,
          )
        : 0.0;
    final fadeRadius = math.max(
      _minFadeRadius,
      diagonal * _fadeRadiusMultiplier,
    );
    final fadeRadiusSq = fadeRadius * fadeRadius;

    // 그리기 범위를 방사 반경으로 제한
    final minX = math.max(
      _dotSpacing,
      (c.dx - fadeRadius) ~/ _dotSpacing * _dotSpacing,
    );
    final maxX = math.min(size.width, c.dx + fadeRadius + _dotSpacing);
    final minY = math.max(
      _dotSpacing,
      (c.dy - fadeRadius) ~/ _dotSpacing * _dotSpacing,
    );
    final maxY = math.min(size.height, c.dy + fadeRadius + _dotSpacing);

    for (double x = minX; x < maxX; x += _dotSpacing) {
      for (double y = minY; y < maxY; y += _dotSpacing) {
        final dx = x - c.dx;
        final dy = y - c.dy;
        final distSq = dx * dx + dy * dy;
        if (distSq > fadeRadiusSq) continue;

        final alpha = (1.0 - math.sqrt(distSq) / fadeRadius) * 0.4;
        final paint = Paint()
          ..color = baseColor.withValues(alpha: alpha)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(x, y), _dotRadius, paint);
      }
    }
  }

  void _drawAnchorZones(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colorScheme.fg3.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final zone1X = size.width / 3;
    final zone2X = size.width * 2 / 3;
    final zone1Y = size.height / 3;
    final zone2Y = size.height * 2 / 3;

    canvas.drawLine(Offset(zone1X, 0), Offset(zone1X, size.height), paint);
    canvas.drawLine(Offset(zone2X, 0), Offset(zone2X, size.height), paint);
    canvas.drawLine(Offset(0, zone1Y), Offset(size.width, zone1Y), paint);
    canvas.drawLine(Offset(0, zone2Y), Offset(size.width, zone2Y), paint);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      center != oldDelegate.center ||
      panelSize != oldDelegate.panelSize ||
      colorScheme != oldDelegate.colorScheme;
}
