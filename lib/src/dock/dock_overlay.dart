import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dock_group.dart';
import '../providers/dock_provider.dart';
import '../theme/dock_theme.dart';
import 'dock_drop_indicator.dart';
import 'dock_grid_overlay.dart';
import 'dock_group_widget.dart';

/// 뷰어 영역 위에 모든 DockGroup을 렌더링하는 오버레이.
///
/// [viewerBuilder]로 뷰어 내용을 주입하고, LayoutBuilder로 뷰어 크기를 얻으며,
/// GlobalKey로 Stack의 글로벌 좌표를 드래그 좌표 보정에 사용.
///
/// **주의:** 앱 전체에서 `DockOverlay`는 한 번만 사용해야 합니다.
/// 여러 인스턴스를 생성하면 `stackKey`가 동일한 GlobalKey를 공유하므로
/// "Multiple widgets used the same GlobalKey" 오류가 발생합니다.
class DockOverlay extends ConsumerWidget {
  /// 뷰어 영역 빌더 — 패널 뒤쪽에 배치되는 콘텐츠 (예: ImageViewerContainer).
  final Widget Function(Size viewerSize) viewerBuilder;

  const DockOverlay({super.key, required this.viewerBuilder});

  /// 드래그/리사이즈 좌표 보정에 사용하는 Stack의 GlobalKey.
  ///
  /// **경고:** `DockOverlay`가 두 개 이상 존재하면 이 키가 충돌합니다.
  /// 앱 위젯 트리에 `DockOverlay`를 단 하나만 배치하세요.
  static final stackKey = GlobalKey();

  /// 드래그/리사이즈 중 이미지 뷰어 위에 까는 어두운 백드롭 불투명도.
  static const double _backdropAlpha = 0.45;

  /// 백드롭 페이드 인/아웃 지속 시간.
  static const Duration _backdropDuration = Duration(milliseconds: 200);

  /// 활성(드래그/리사이즈 중) 그룹을 찾아 반환.
  static DockGroup? _getActiveGroup(DockState state) {
    final activeId = state.draggingGroupId ?? state.resizingGroupId;
    if (activeId == null) return null;
    return state.groups.firstWhereOrNull((g) => g.id == activeId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dockState = ref.watch(dockProvider);
    final sortedGroups = dockState.sortedGroups;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewerSize = Size(constraints.maxWidth, constraints.maxHeight);
        // 뷰어 크기가 변경됐을 때만 Provider에 전달 (빌드 중 setState 방지를 위해 지연 호출)
        if (dockState.viewerSize != viewerSize) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(dockProvider.notifier).updateViewerSize(viewerSize);
          });
        }
        return Stack(
          key: stackKey,
          children: [
            // 뷰어 컨테이너 (최하단)
            viewerBuilder(viewerSize),
            // 드래그/리사이즈 중 스냅 도트 가시성을 높이기 위한 백드롭
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: dockState.isInteracting ? _backdropAlpha : 0.0,
                  duration: _backdropDuration,
                  child: ColoredBox(
                    color: DockTheme.of(context).colorScheme.bg0,
                  ),
                ),
              ),
            ),
            // 스냅 그리드 + 앵커 구역 (드래그/리사이즈 중 뷰어 위에 오버레이)
            if (dockState.isInteracting)
              () {
                final g = _getActiveGroup(dockState);
                final rect = g != null ? dockState.displayRects[g.id] : null;
                return DockGridOverlay(
                  center: rect != null
                      ? Offset(
                          rect.left + rect.width / 2,
                          rect.top + rect.height / 2,
                        )
                      : null,
                  panelSize: rect != null
                      ? Size(rect.width, rect.height)
                      : null,
                );
              }(),
            for (final group in sortedGroups)
              DockGroupWidget(
                key: ValueKey(group.id),
                group: group,
                viewerSize: viewerSize,
                stackKey: stackKey,
              ),
            // 드래그 중 — 비어있는 엣지 감지 구역 표시 (헤더리스 그룹은 제외)
            if (dockState.draggingGroupId != null &&
                _getActiveGroup(dockState)?.headerless != true) ...[
              if (dockState.edgePanel(ViewportEdge.left) == null)
                _EdgeZoneHint(edge: ViewportEdge.left, viewerSize: viewerSize),
              if (dockState.edgePanel(ViewportEdge.right) == null)
                _EdgeZoneHint(edge: ViewportEdge.right, viewerSize: viewerSize),
            ],
            // 도킹 프리뷰 하이라이트
            if (dockState.dockPreview != null)
              DockDropIndicator(
                rect: dockState.dockPreview!.highlightRect,
                isViewportEdge: dockState.dockPreview!.isViewportEdge,
              ),
          ],
        );
      },
    );
  }
}

/// 드래그 중 뷰포트 엣지 감지 구역을 액센트 스트립으로 표시.
class _EdgeZoneHint extends StatelessWidget {
  final ViewportEdge edge;
  final Size viewerSize;

  /// 힌트 스트립의 시작 위치 비율 (뷰포트 높이 기준).
  static const double _hintStartRatio = 0.25;

  /// 힌트 스트립의 높이 비율 (뷰포트 높이 기준).
  static const double _hintHeightRatio = 0.5;

  const _EdgeZoneHint({required this.edge, required this.viewerSize});

  @override
  Widget build(BuildContext context) {
    final cs = DockTheme.of(context).colorScheme;
    final cfg = DockTheme.of(context).config;
    final thickness = cfg.edgeHintWidth;
    final w = viewerSize.width;
    final h = viewerSize.height;

    final rect = switch (edge) {
      ViewportEdge.left  => Rect.fromLTWH(0, h * _hintStartRatio, thickness, h * _hintHeightRatio),
      ViewportEdge.right => Rect.fromLTWH(w - thickness, h * _hintStartRatio, thickness, h * _hintHeightRatio),
    };

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        child: ColoredBox(
          color: cs.accent.withValues(alpha: 0.25),
        ),
      ),
    );
  }
}
