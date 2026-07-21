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
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _GridPainter(
            center: center,
            panelSize: panelSize,
            colorScheme: cs,
            devicePixelRatio: dpr,
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Offset? center;
  final Size? panelSize;
  final DockColorScheme colorScheme;
  final double devicePixelRatio;

  _GridPainter({
    this.center,
    this.panelSize,
    required this.colorScheme,
    required this.devicePixelRatio,
  });

  static const double _dotSpacing = 20.0;
  static const double _dotRadius = 0.8;

  /// 축별 페이드 반경 하한 (작은 패널에서도 최소한의 도트 영역 확보).
  static const double _minFadeRadius = 200.0;

  /// 페이드 타원 반경 = 패널 절반 크기 × 이 배율 (가로·세로 각각).
  /// 패널 비율을 그대로 따라가므로 세로로 긴 패널은 도트도 세로로 길게 퍼진다.
  static const double _fadeExtentMultiplier = 3.0;

  /// 최대 밝기를 유지하는 정규화 반경(0~1). 배율의 역수 = 패널 가장자리 위치.
  /// 이 안쪽(패널에 붙은 도트)은 풀 밝기, 바깥에서만 페이드해 시인성 확보.
  static const double _fadeHoldStop = 1.0 / _fadeExtentMultiplier;

  /// 도트 최대 불투명도 (중심부 기준).
  static const double _dotMaxAlpha = 0.5;

  /// 앵커 구역 경계선 불투명도.
  static const double _anchorLineAlpha = 0.3;

  @override
  void paint(Canvas canvas, Size size) {
    _drawDots(canvas, size);
    _drawAnchorZones(canvas, size);
  }

  void _drawDots(Canvas canvas, Size size) {
    final c = center ?? Offset(size.width / 2, size.height / 2);
    final baseColor = colorScheme.textHint;

    // 패널 비율을 따라가는 **타원형** 페이드 반경 (가로·세로 독립).
    // 세로로 긴 패널이면 fadeRadiusY > fadeRadiusX 가 되어 도트가 세로로 길게,
    // 좌우로는 좁게 퍼진다.
    final halfW = (panelSize?.width ?? 0.0) * 0.5;
    final halfH = (panelSize?.height ?? 0.0) * 0.5;
    final fadeRadiusX = math.max(_minFadeRadius, halfW * _fadeExtentMultiplier);
    final fadeRadiusY = math.max(_minFadeRadius, halfH * _fadeExtentMultiplier);

    // 도트 격자를 **물리 픽셀 정수 간격 + 위치 스냅**으로 맞춘다.
    // `_dotSpacing * dpr`가 비정수면 도트가 픽셀 격자와 어긋나 도트마다
    // 안티에일리어싱 잉크량이 주기적으로 달라지고, 그 비트(beat)가 화면 고정
    // 좌표의 넓은 밝기 밴드(무아레)로 보인다. 특히 고해상도(고DPR)에서 도트가
    // 또렷해 더 잘 드러난다. 물리 픽셀에 정렬하면 모든 도트가 동일하게
    // 래스터화돼 무아레가 사라진다. (정수 배율에선 no-op)
    final dpr = devicePixelRatio;
    final spacing = dpr > 0
        ? math.max(1.0, (_dotSpacing * dpr).roundToDouble()) / dpr
        : _dotSpacing;
    double snap(double v) =>
        dpr > 0 ? (v * dpr).roundToDouble() / dpr : v;

    // 그리기 범위를 타원 반경으로 제한
    final minX = math.max(spacing, (c.dx - fadeRadiusX) ~/ spacing * spacing);
    final maxX = math.min(size.width, c.dx + fadeRadiusX + spacing);
    final minY = math.max(spacing, (c.dy - fadeRadiusY) ~/ spacing * spacing);
    final maxY = math.min(size.height, c.dy + fadeRadiusY + spacing);

    // 페이드 영역(그라데이션 마스크 & 레이어 범위)을 캔버스로 클램프.
    final fadeRect = Rect.fromCenter(
      center: c,
      width: fadeRadiusX * 2,
      height: fadeRadiusY * 2,
    ).intersect(Offset.zero & size);
    if (fadeRect.isEmpty) return;

    // 도트를 별도 레이어에 **균일 불투명도**로 그린 뒤, 타원형 그라데이션을
    // dstIn 마스크로 곱해 페이드를 per-pixel(GPU)로 적용한다.
    //
    // 도트마다 alpha를 계산·합성하면 8비트 양자화 계단이 생긴다. 페이드를
    // 그라데이션으로 분리하면 모든 도트가 동일하게 그려지고 페이드만 매끄러운
    // 그라데이션으로 처리돼 계단이 사라진다.
    canvas.saveLayer(fadeRect, Paint());

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = baseColor.withValues(alpha: 1.0);
    for (double x = minX; x < maxX; x += spacing) {
      final nx = (x - c.dx) / fadeRadiusX;
      for (double y = minY; y < maxY; y += spacing) {
        final ny = (y - c.dy) / fadeRadiusY;
        if (nx * nx + ny * ny > 1.0) continue; // 타원 밖 제외
        canvas.drawCircle(Offset(snap(x), snap(y)), _dotRadius, dotPaint);
      }
    }

    // 패널 가장자리(_fadeHoldStop)까지 _dotMaxAlpha 유지 → 타원 경계 0 으로 페이드.
    // 원형 그라데이션을 캔버스 스케일로 타원으로 변형 (반경 X·Y 독립 적용).
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(fadeRadiusX, fadeRadiusY);
    final maskPaint = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFFFFF).withValues(alpha: _dotMaxAlpha),
          const Color(0xFFFFFFFF).withValues(alpha: _dotMaxAlpha),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.0, _fadeHoldStop, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));
    canvas.drawRect(
      Rect.fromCircle(center: Offset.zero, radius: 1.0),
      maskPaint,
    );
    canvas.restore();

    canvas.restore();
  }

  void _drawAnchorZones(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colorScheme.textMuted.withValues(alpha: _anchorLineAlpha)
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
      colorScheme != oldDelegate.colorScheme ||
      devicePixelRatio != oldDelegate.devicePixelRatio;
}
