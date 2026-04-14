import 'package:flutter/material.dart';

/// 상단 + 좌우 모퉁이 곡선에 그라데이션 페이드아웃을 그리는 Decoration.
///
/// 다이얼로그, 패널, 카드 등 아무 위젯에나 `foregroundDecoration`으로 적용 가능.
/// ```dart
/// Container(
///   foregroundDecoration: EdgeGlowDecoration(
///     color: Colors.blue,
///     borderRadius: 8.0,
///   ),
///   child: ...,
/// )
/// ```
class EdgeGlowDecoration extends Decoration {
  final Color color;
  final double borderRadius;
  final double strokeWidth;
  final double legLength;
  final double opacity;

  const EdgeGlowDecoration({
    required this.color,
    this.borderRadius = 6.0,
    this.strokeWidth = 1.0,
    this.legLength = 8.0,
    this.opacity = 0.5,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _EdgeGlowBoxPainter(this);
  }
}

class _EdgeGlowBoxPainter extends BoxPainter {
  final EdgeGlowDecoration _decoration;

  _EdgeGlowBoxPainter(this._decoration);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size ?? Size.zero;
    if (size == Size.zero) return;

    final sw = _decoration.strokeWidth;
    final half = sw / 2;
    final r = _decoration.borderRadius;
    final leg = _decoration.legLength;
    final bottom = r + leg;

    final path = Path()
      ..moveTo(offset.dx + half, offset.dy + bottom)
      ..lineTo(offset.dx + half, offset.dy + r)
      ..quadraticBezierTo(
        offset.dx + half,
        offset.dy + half,
        offset.dx + r,
        offset.dy + half,
      )
      ..lineTo(offset.dx + size.width - r, offset.dy + half)
      ..quadraticBezierTo(
        offset.dx + size.width - half,
        offset.dy + half,
        offset.dx + size.width - half,
        offset.dy + r,
      )
      ..lineTo(offset.dx + size.width - half, offset.dy + bottom);

    canvas.drawPath(
      path,
      Paint()
        ..strokeWidth = sw
        ..style = PaintingStyle.stroke
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _decoration.color.withValues(alpha: _decoration.opacity),
            _decoration.color.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(offset.dx, offset.dy, size.width, bottom)),
    );
  }
}
