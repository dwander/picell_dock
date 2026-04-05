import 'dart:ui';

import 'package:equatable/equatable.dart';

import '../models/dock_group.dart';

/// 도킹 방향.
enum DockEdge { top, right, bottom, left, center }

/// 드래그 중 도킹 프리뷰 정보.
class DockPreview extends Equatable {
  final String targetGroupId;
  final DockEdge edge;
  final Rect highlightRect;

  /// 그룹 내 도킹 대상 노드의 경로 (Split의 자식 인덱스 리스트).
  /// 빈 리스트면 그룹 루트에 도킹.
  final List<int> nodePath;

  /// true면 뷰포트 엣지 도킹 프리뷰 (패널 간 도킹과 구별).
  final bool isViewportEdge;

  const DockPreview({
    required this.targetGroupId,
    required this.edge,
    required this.highlightRect,
    this.nodePath = const [],
    this.isViewportEdge = false,
  });

  @override
  List<Object?> get props => [
    targetGroupId,
    edge,
    highlightRect,
    nodePath,
    isViewportEdge,
  ];
}

/// 독 시스템의 전체 상태.
class DockState extends Equatable {
  final List<DockGroup> groups;
  final String? draggingGroupId;
  final String? resizingGroupId;
  final DockPreview? dockPreview;
  final Size viewerSize;

  /// 현재 포커스된 그룹 ID.
  final String? focusedPanelId;

  /// 키보드 포커스 전환 시 플래시 이펙트를 트리거할 패널 ID.
  ///
  /// 클릭 포커스와 구분하기 위해 [DockNotifier.focusPanel]에서
  /// `flash: true`일 때만 설정된다.
  final String? flashPanelId;

  /// 저장된 레이아웃 로드가 완료되었는지 여부.
  ///
  /// `true`가 된 이후에만 엣지 도킹/언도킹 이펙트가 재생된다.
  /// 앱 초기화 중 레이아웃 복원 시 이펙트가 트리거되는 것을 방지한다.
  final bool layoutSettled;

  /// 뷰포트 클램핑 + 1축 회피가 적용된 표시용 사각형.
  /// key: groupId, value: Rect(x, y, w, h).
  final Map<String, Rect> displayRects;

  /// 보더 스캔 이펙트 대기 중인 노드 목록.
  ///
  /// key: groupId, value: 스캔 대상 노드 경로 (빈 리스트 = 그룹 전체).
  /// 도킹/언도킹 시 DockNotifier가 설정하고,
  /// DockGroupWidget이 소비 후 [DockNotifier.clearScanPending]으로 제거.
  final Map<String, List<int>> scanPendingNodes;

  const DockState({
    this.groups = const [],
    this.draggingGroupId,
    this.resizingGroupId,
    this.dockPreview,
    this.viewerSize = Size.zero,
    this.focusedPanelId,
    this.flashPanelId,
    this.layoutSettled = false,
    this.displayRects = const {},
    this.scanPendingNodes = const {},
  });

  /// 드래그 또는 리사이즈가 활성 상태인지.
  bool get isInteracting => draggingGroupId != null || resizingGroupId != null;

  /// 플로팅 그룹만 반환.
  List<DockGroup> get floatingGroups =>
      groups.where((g) => g.dockedEdge == null).toList();

  /// 렌더링 순서 정렬: 엣지 패널 먼저(하단), 플로팅은 zOrder 오름차순.
  List<DockGroup> get sortedGroups => [
    ...groups.where((g) => g.dockedEdge != null),
    ...(groups.where((g) => g.dockedEdge == null).toList()
      ..sort((a, b) => a.zOrder.compareTo(b.zOrder))),
  ];

  /// 특정 엣지에 도킹된 패널 반환.
  DockGroup? edgePanel(ViewportEdge edge) =>
      groups.where((g) => g.dockedEdge == edge).firstOrNull;

  /// 우측에 위치한 패널(엣지 도킹 또는 우측 앵커)이 점유하는 너비.
  ///
  /// displayRects 기반으로 실제 렌더링 위치의 중심점이 우측 절반에 있고,
  /// 세로 중심을 가로지르는 패널 중 면적이 가장 큰 패널의 너비를 반환.
  /// 뷰어 free rect 계산, 새 패널 배치 등에서 공통으로 사용.
  double get rightOccupiedWidth {
    if (displayRects.isEmpty || viewerSize == Size.zero) return 0;

    final vw = viewerSize.width;
    final midX = vw / 2;
    final midY = viewerSize.height / 2;

    double maxArea = 0;
    double resultWidth = 0;

    for (final rect in displayRects.values) {
      final cx = rect.center.dx;
      final coversVerticalCenter = rect.top < midY && rect.bottom > midY;

      // 중심이 우측 절반에 있고 세로 중심을 관통하는 패널만 대상
      if (cx > midX && coversVerticalCenter) {
        final area = rect.width * rect.height;
        if (area > maxArea) {
          maxArea = area;
          resultWidth = vw - rect.left;
        }
      }
    }
    return resultWidth;
  }

  @override
  List<Object?> get props => [
    groups,
    draggingGroupId,
    resizingGroupId,
    dockPreview,
    viewerSize,
    focusedPanelId,
    flashPanelId,
    layoutSettled,
    displayRects,
    scanPendingNodes,
  ];
}
