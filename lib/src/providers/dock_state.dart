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

  /// 뷰포트 클램핑 + 1축 회피가 적용된 표시용 사각형.
  /// key: groupId, value: Rect(x, y, w, h).
  final Map<String, Rect> displayRects;

  const DockState({
    this.groups = const [],
    this.draggingGroupId,
    this.resizingGroupId,
    this.dockPreview,
    this.viewerSize = Size.zero,
    this.focusedPanelId,
    this.displayRects = const {},
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

  @override
  List<Object?> get props => [
    groups,
    draggingGroupId,
    resizingGroupId,
    dockPreview,
    viewerSize,
    focusedPanelId,
    displayRects,
  ];
}
