import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 도트 격자 ↔ 물리 픽셀 격자 무아레 프로브.
// 균일 alpha 도트를 여러 물리 배율로 렌더해, 도트 중심 밝기가 격자 위치에 따라
// 주기적으로 흔들리는지(무아레) 측정한다. 물리 픽셀 정수 간격·정렬이
// 그 흔들림을 없애는지도 확인.

const _bg = Color(0xFF1A1A1A);
const _dot = Color(0xFF666666);
const _spacing = 20.0;
const _radius = 0.8;
const _alpha = 0.3; // 균일 (페이드 없음)

Future<ui.Image> _render({
  required double dpr,
  required bool physAlign,
}) async {
  const w = 900.0;
  const h = 80.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(dpr);
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = _bg);

  final paint = Paint()
    ..style = PaintingStyle.fill
    ..color = _dot.withValues(alpha: _alpha);

  final spacing = physAlign
      ? (_spacing * dpr).roundToDouble() / dpr
      : _spacing;
  double pos(double v) =>
      physAlign ? (v * dpr).roundToDouble() / dpr : v;

  for (double x = spacing; x < w; x += spacing) {
    for (double y = spacing; y < h; y += spacing) {
      canvas.drawCircle(Offset(pos(x), pos(y)), _radius, paint);
    }
  }
  return recorder.endRecording().toImage((w * dpr).round(), (h * dpr).round());
}

/// 첫 도트 행에서 각 도트의 3x3 코어 밝기 합(green)을 수집 — 서브픽셀 AA로
/// 총 잉크량이 위치마다 달라지는 걸 잡기 위해 단일 픽셀이 아닌 코어 합을 본다.
Future<List<int>> _rowInk(ui.Image img, double dpr, bool physAlign) async {
  final data = (await img.toByteData())!;
  final pw = img.width;
  final ph = img.height;
  int coreInk(double x, double y) {
    var sum = 0;
    final cx = (x * dpr).round();
    final cy = (y * dpr).round();
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final xi = (cx + dx).clamp(0, pw - 1);
        final yi = (cy + dy).clamp(0, ph - 1);
        sum += data.getUint8((yi * pw + xi) * 4 + 1); // green
      }
    }
    return sum;
  }

  final spacing =
      physAlign ? (_spacing * dpr).roundToDouble() / dpr : _spacing;
  double pos(double v) =>
      physAlign ? (v * dpr).roundToDouble() / dpr : v;

  final out = <int>[];
  for (double x = spacing; x < 900.0; x += spacing) {
    out.add(coreInk(pos(x), pos(spacing)));
  }
  return out;
}

int _range(List<int> v) =>
    v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);

Future<int> _rangeFor(double dpr, {required bool physAlign}) async {
  final img = await _render(dpr: dpr, physAlign: physAlign);
  return _range(await _rowInk(img, dpr, physAlign));
}

// ── 타원형 페이드 프로브 ───────────────────────────────────────────────
// 실제 페인터와 동일한 방식(도트 + 캔버스 스케일 방사 그라데이션 dstIn 마스크)으로
// 렌더해, 세로로 긴 패널이 세로로 더 길게 퍼지는지(타원) 확인.

const _minFadeRadius = 200.0;
const _fadeExtentMultiplier = 3.0;
const _fadeHoldStop = 1.0 / _fadeExtentMultiplier;
const _dotMaxAlpha = 0.5;

Future<ui.Image> _renderEllipse({
  required Size panel,
  required double side,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, side, side), Paint()..color = _bg);

  final c = Offset(side / 2, side / 2);
  final rx = (panel.width * 0.5 * _fadeExtentMultiplier)
      .clamp(_minFadeRadius, double.infinity);
  final ry = (panel.height * 0.5 * _fadeExtentMultiplier)
      .clamp(_minFadeRadius, double.infinity);

  final rect = Rect.fromCenter(center: c, width: rx * 2, height: ry * 2);
  canvas.saveLayer(rect, Paint());
  final dot = Paint()
    ..style = PaintingStyle.fill
    ..color = _dot.withValues(alpha: 1.0);
  for (double x = _spacing; x < side; x += _spacing) {
    final nx = (x - c.dx) / rx;
    for (double y = _spacing; y < side; y += _spacing) {
      final ny = (y - c.dy) / ry;
      if (nx * nx + ny * ny > 1.0) continue;
      canvas.drawCircle(Offset(x, y), _radius, dot);
    }
  }
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.scale(rx, ry);
  final mask = Paint()
    ..blendMode = BlendMode.dstIn
    ..shader = RadialGradient(
      colors: [
        const Color(0xFFFFFFFF).withValues(alpha: _dotMaxAlpha),
        const Color(0xFFFFFFFF).withValues(alpha: _dotMaxAlpha),
        const Color(0x00FFFFFF),
      ],
      stops: const [0.0, _fadeHoldStop, 1.0],
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));
  canvas.drawRect(Rect.fromCircle(center: Offset.zero, radius: 1.0), mask);
  canvas.restore();
  canvas.restore();

  return recorder.endRecording().toImage(side.round(), side.round());
}

Future<(double h, double v)> _extents(ui.Image img, double side) async {
  final data = (await img.toByteData())!;
  final pw = img.width;
  int green(int x, int y) =>
      data.getUint8((y.clamp(0, img.height - 1) * pw +
              x.clamp(0, pw - 1)) *
          4 +
      1);
  final cx = (side / 2).round();
  final cy = (side / 2).round();
  // bg green = 0x1A = 26; 임계 32 = 명확히 도트가 있는 지점.
  double farthest(int dxStep, int dyStep) {
    var far = 0.0;
    for (var s = 1; s < side ~/ 2; s++) {
      if (green(cx + dxStep * s, cy + dyStep * s) > 32) far = s.toDouble();
    }
    return far;
  }

  final h = [farthest(1, 0), farthest(-1, 0)].reduce((a, b) => a > b ? a : b);
  final v = [farthest(0, 1), farthest(0, -1)].reduce((a, b) => a > b ? a : b);
  return (h, v);
}

/// (cx,cy) 주변 창에서 최대 green — 가장 가까운 도트 밝기를 잡는다.
Future<int> _maxGreenNear(ui.Image img, double x, double y) async {
  final data = (await img.toByteData())!;
  final pw = img.width;
  var best = 0;
  for (var dy = -12; dy <= 12; dy++) {
    for (var dx = -12; dx <= 12; dx++) {
      final xi = (x + dx).round().clamp(0, pw - 1);
      final yi = (y + dy).round().clamp(0, img.height - 1);
      final g = data.getUint8((yi * pw + xi) * 4 + 1);
      if (g > best) best = g;
    }
  }
  return best;
}

void main() {
  test('패널 가장자리 도트는 풀 밝기를 유지한다(plateau)', () async {
    const side = 1000.0;
    // 정사각 300 → 반경 max(200, 150*3)=450, 중심 (500,500), holdStop=1/3.
    final img = await _renderEllipse(panel: const Size(300, 300), side: side);
    final r = 450.0;
    const bg = 26; // 0x1A
    // 정규화 반경 0.15(안쪽), 0.30(패널 가장자리≈holdStop), 0.85(바깥).
    final inner = await _maxGreenNear(img, 500 + 0.15 * r, 500);
    final edge = await _maxGreenNear(img, 500 + 0.30 * r, 500);
    final far = await _maxGreenNear(img, 500 + 0.85 * r, 500);
    // ignore: avoid_print
    print('plateau: inner=$inner edge=$edge far=$far');
    // 패널 가장자리(edge)가 안쪽(inner)과 비슷하게 밝아야 함 (선형이면 뚝 떨어짐).
    expect(edge - bg, greaterThan((inner - bg) * 0.82),
        reason: 'plateau 구간은 밝기가 평평해야 함');
    // 바깥은 확실히 어두워야 함(페이드 동작 확인).
    expect(far, lessThan(edge - 4), reason: '타원 바깥으로 갈수록 페이드');
  });

  test('세로로 긴 패널은 도트가 세로로 더 길게 퍼진다(타원형 페이드)', () async {
    const side = 800.0;
    final tall = await _extents(
      await _renderEllipse(panel: const Size(200, 700), side: side),
      side,
    );
    // ignore: avoid_print
    print('tall panel: h-extent=${tall.$1}  v-extent=${tall.$2}');
    expect(tall.$2, greaterThan(tall.$1 * 1.8),
        reason: '세로 확산이 가로보다 뚜렷하게 커야 함');
  });

  test('정사각 패널은 도트가 원형으로 퍼진다', () async {
    const side = 800.0;
    final sq = await _extents(
      await _renderEllipse(panel: const Size(300, 300), side: side),
      side,
    );
    // ignore: avoid_print
    print('square panel: h-extent=${sq.$1}  v-extent=${sq.$2}');
    expect((sq.$1 - sq.$2).abs(), lessThan(sq.$1 * 0.15),
        reason: '정사각은 가로·세로 확산이 비슷해야 함');
  });

  test('정수 물리 간격(20*dpr 정수)에서는 무아레가 없다', () async {
    for (final dpr in [1.5, 1.75, 2.0]) {
      expect(await _rangeFor(dpr, physAlign: false), 0,
          reason: '20*$dpr = ${20 * dpr} (정수) → 도트 균일해야 함');
    }
  });

  test('비정수 물리 간격에서는 무아레(밝기 흔들림)가 발생한다', () async {
    for (final dpr in [1.53, 1.77]) {
      expect(await _rangeFor(dpr, physAlign: false), greaterThan(0),
          reason: '20*$dpr = ${20 * dpr} (비정수) → 격자 무아레 발생');
    }
  });

  test('물리 픽셀 정렬이 모든 배율에서 무아레를 제거한다', () async {
    for (final dpr in [1.5, 1.53, 1.75, 1.77, 2.0]) {
      expect(await _rangeFor(dpr, physAlign: true), 0,
          reason: 'physAlign → dpr=$dpr 에서도 도트 균일해야 함');
    }
  });
}
