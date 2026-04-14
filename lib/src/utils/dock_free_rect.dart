import 'dart:math' as math;
import 'dart:ui';

/// 패널 회피 영역 계산 유틸리티.
///
/// [DockState.displayRects]를 분석해 패널이 점유하지 않는
/// 최대 빈 영역의 경계(left, right, top, bottom)를 반환한다.
///
/// 마진은 포함하지 않는 원시 좌표를 반환 — 호출 측에서 여백 적용.
abstract final class DockFreeRect {
  /// [displayRects]에서 [excludeId] 그룹을 제외한 나머지 기준으로
  /// 패널이 점유하지 않는 최대 빈 영역의 경계를 반환한다.
  ///
  /// - [excludeId]: 자기 자신을 회피 대상에서 제외할 때 사용 (최대화 등).
  /// - 반환값은 `(left, right, top, bottom)` 형태의 레코드.
  ///   각 값은 뷰포트 내 좌표이며 마진 없는 원시값.
  static ({double left, double right, double top, double bottom}) calcEdges(
    Map<String, Rect> displayRects,
    Size viewerSize, {
    String? excludeId,
  }) {
    final vw = viewerSize.width;
    final vh = viewerSize.height;

    final rects = excludeId != null
        ? Map.fromEntries(
            displayRects.entries.where((e) => e.key != excludeId),
          )
        : displayRects;

    if (rects.isEmpty) {
      return (left: 0.0, right: vw, top: 0.0, bottom: vh);
    }

    final midX = vw / 2;
    final midY = vh / 2;

    Rect? largestLeft, largestTop, largestBottom;
    double areaLeft = 0, areaTop = 0, areaBottom = 0;
    double maxRightArea = 0;
    double rightUsed = 0;

    // 뷰포트 경계에 인접한 패널은 중심점 계산 전에 엣지 방향으로 확정.
    // 엣지 패널이 중앙 영역까지 침범해도 중심점이 반대편으로 넘어가서
    // 방향이 오판되는 문제를 방지한다.
    const edgeThreshold = 1.0;

    for (final rect in rects.values) {
      final area = rect.width * rect.height;
      final cy = rect.center.dy;

      final coversVerticalCenter = rect.top < midY && rect.bottom > midY;
      final coversHorizontalCenter = rect.left < midX && rect.right > midX;

      final attachedLeft = rect.left <= edgeThreshold;
      final attachedRight = rect.right >= vw - edgeThreshold;

      if (attachedLeft && !attachedRight) {
        // 왼쪽 경계에 붙은 패널 → left로 확정
        if (coversVerticalCenter && area > areaLeft) {
          areaLeft = area;
          largestLeft = rect;
        }
      } else if (attachedRight && !attachedLeft) {
        // 오른쪽 경계에 붙은 패널 → right로 확정
        if (coversVerticalCenter && area > maxRightArea) {
          maxRightArea = area;
          rightUsed = vw - rect.left;
        }
      } else if (attachedLeft && attachedRight) {
        // 양쪽 경계 모두에 닿는 패널(거의 전체 너비) → top/bottom만 반영
        final distTop = cy;
        final distBottom = vh - cy;
        if (distTop <= distBottom) {
          if (coversHorizontalCenter && area > areaTop) {
            areaTop = area;
            largestTop = rect;
          }
        } else {
          if (coversHorizontalCenter && area > areaBottom) {
            areaBottom = area;
            largestBottom = rect;
          }
        }
      } else {
        // 경계에 닿지 않은 플로팅 패널 → 중심점 기반 판별
        final cx = rect.center.dx;
        final distLeft = cx;
        final distRight = vw - cx;
        final distTop = cy;
        final distBottom = vh - cy;
        final minDist =
            [distLeft, distRight, distTop, distBottom].reduce(math.min);

        if (minDist == distLeft && coversVerticalCenter && area > areaLeft) {
          areaLeft = area;
          largestLeft = rect;
        } else if (minDist == distRight &&
            coversVerticalCenter &&
            area > maxRightArea) {
          maxRightArea = area;
          rightUsed = vw - rect.left;
        } else if (minDist == distTop &&
            coversHorizontalCenter &&
            area > areaTop) {
          areaTop = area;
          largestTop = rect;
        } else if (minDist == distBottom &&
            coversHorizontalCenter &&
            area > areaBottom) {
          areaBottom = area;
          largestBottom = rect;
        }
      }
    }

    return (
      left: largestLeft?.right ?? 0.0,
      right: rightUsed > 0 ? vw - rightUsed : vw,
      top: largestTop?.bottom ?? 0.0,
      bottom: largestBottom?.top ?? vh,
    );
  }
}
