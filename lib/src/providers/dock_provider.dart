import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart' show FocusNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/dock_config.dart';
import '../models/dock_group.dart';
import '../models/dock_node.dart';
import '../services/dock_layout_service.dart';
import 'dock_settings_provider.dart';

// 패키지 내부 계산에서 사용하는 기본 config 인스턴스.
final _config = const DockConfig();

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

/// 노드 rect 정보 (도킹 감지용).
class _NodeRect {
  final Rect rect;
  final List<int> path;
  final DockNode node;

  const _NodeRect({required this.rect, required this.path, required this.node});
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

/// 독 상태를 관리하는 Notifier.
class DockNotifier extends Notifier<DockState> {
  late final DockLayoutService _layoutService;
  FocusNode? _rootFocusNode;
  Timer? _saveTimer;
  int _nextGroupId = 0;

  /// 저장 디바운스 간격.
  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  @override
  DockState build() {
    _layoutService = DockLayoutService();
    ref.onDispose(() {
      _saveTimer?.cancel();
    });
    // DockSettings.defaultLayout이 있으면 초기 레이아웃으로 설정.
    final settings = ref.read(dockSettingsProvider);
    final defaultGroups = settings.defaultLayout?.call() ?? const [];
    if (defaultGroups.isNotEmpty) {
      _setState(DockState(
        groups: defaultGroups,
        focusedPanelId: settings.initialFocusedPanelId,
      ));
    }
    _loadSavedLayout();
    return state;
  }

  /// state를 갱신하며 displayRects를 자동 계산.
  ///
  /// focusedPanelId가 명시적으로 전달되지 않으면 기존 값을 보존합니다.
  /// 이를 통해 모든 state 갱신 지점에서 focusedPanelId 누락으로 인한
  /// 포커스 유실을 방지합니다.
  void _setState(DockState newState) {
    final rects = _computeDisplayRects(newState);
    state = DockState(
      groups: newState.groups,
      draggingGroupId: newState.draggingGroupId,
      resizingGroupId: newState.resizingGroupId,
      dockPreview: newState.dockPreview,
      viewerSize: newState.viewerSize,
      focusedPanelId: newState.focusedPanelId ?? state.focusedPanelId,
      displayRects: rects,
    );
  }

  /// 저장된 레이아웃 로드 (비동기, 실패 시 기본 레이아웃 유지).
  Future<void> _loadSavedLayout() async {
    final result = await _layoutService.loadLayout();
    if (result != null && ref.mounted) {
      // 기존 그룹 ID에서 숫자 접미사를 파싱하여 _nextGroupId를 max+1로 설정.
      final groupIdPattern = RegExp(r'^group_(\d+)$');
      int maxId = -1;
      for (final group in result) {
        final match = groupIdPattern.firstMatch(group.id);
        if (match != null) {
          final num = int.parse(match.group(1)!);
          if (num > maxId) maxId = num;
        }
      }
      if (maxId >= 0) _nextGroupId = maxId + 1;

      _setState(DockState(groups: result, viewerSize: state.viewerSize));
    }
  }

  /// 레이아웃 변경 시 디바운스 저장. 뷰포트 밖 패널도 안쪽으로 보정.
  void _onLayoutChanged() {
    // display rect를 모든 그룹에 커밋
    final displayRects = state.displayRects;
    final vs = state.viewerSize;
    final newGroups = <DockGroup>[
      for (final g in state.groups)
        () {
          final rect = displayRects[g.id];
          if (rect == null) return g;
          final sizeChanged =
              (g.width - rect.width).abs() > 0.5 ||
              (g.height - rect.height).abs() > 0.5;
          final posChanged =
              (g.absoluteX(vs.width) - rect.left).abs() > 0.5 ||
              (g.absoluteY(vs.height) - rect.top).abs() > 0.5;
          if (!sizeChanged && !posChanged) return g;
          return g
              .copyWith(width: rect.width, height: rect.height)
              .updateFromAbsolute(rect.left, rect.top, vs.width, vs.height);
        }(),
    ];

    _setState(
      DockState(
        groups: newGroups,
        viewerSize: vs,
        focusedPanelId: state.focusedPanelId,
      ),
    );

    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounceDuration, () {
      _layoutService.saveLayout(state.groups);
    });
  }

  /// 패널 간 최소 간격.
  static const double _displayGap = 10.0;

  /// 뷰포트 클램핑 + 1축 회피가 적용된 표시용 사각형을 계산.
  Map<String, Rect> _computeDisplayRects(DockState s) {
    final vs = s.viewerSize;
    if (vs == Size.zero) return {};

    final autoResize = ref.read(dockSettingsProvider).allowAutoAvoidance;
    final interactingId = s.draggingGroupId ?? s.resizingGroupId;
    final rects = <String, Rect>{};

    _applyEdgePanelRects(rects, s.groups, vs);
    _applyViewportClamping(rects, s.groups, vs, autoResize, interactingId);
    if (autoResize) _applyAutoAvoidance(rects, s.groups, interactingId);

    return rects;
  }

  /// 0단계: 엣지 패널 위치 고정.
  void _applyEdgePanelRects(
    Map<String, Rect> rects,
    List<DockGroup> groups,
    Size vs,
  ) {
    for (final group in groups) {
      if (group.dockedEdge == null) continue;
      rects[group.id] = switch (group.dockedEdge!) {
        ViewportEdge.left => Rect.fromLTWH(0, 0, group.width, vs.height),
        ViewportEdge.right => Rect.fromLTWH(
          vs.width - group.width,
          0,
          group.width,
          vs.height,
        ),
      };
    }
  }

  /// 1단계: 뷰포트 클램핑 (플로팅 그룹만).
  void _applyViewportClamping(
    Map<String, Rect> rects,
    List<DockGroup> groups,
    Size vs,
    bool autoResize,
    String? interactingId,
  ) {
    for (final group in groups) {
      if (group.dockedEdge != null) continue;
      if (!autoResize || group.id == interactingId) {
        // 자동 리사이즈 불필요 또는 드래그/리사이즈 중: 원본 좌표 사용
        rects[group.id] = Rect.fromLTWH(
          group.absoluteX(vs.width),
          group.absoluteY(vs.height),
          group.width,
          group.height,
        );
      } else {
        rects[group.id] = group.displayRect(vs.width, vs.height);
      }
    }
  }

  /// 2단계: 1축 회피 — 인접 패널과의 겹침을 한 방향으로 해소.
  void _applyAutoAvoidance(
    Map<String, Rect> rects,
    List<DockGroup> groups,
    String? interactingId,
  ) {
    for (final group in groups) {
      if (group.id == interactingId) continue;

      final rect = rects[group.id]!;
      var gx = rect.left;
      var gy = rect.top;
      var gw = rect.width;
      var gh = rect.height;

      // Y축 회피: 같은 AnchorX, 이 그룹이 상대보다 세로로 더 큰 경우만
      for (final other in groups) {
        if (other.id == group.id || other.anchorX != group.anchorX) continue;
        if (group.height <= other.height) continue;
        final oRect = rects[other.id]!;

        final xOverlap = gx < oRect.right && gx + gw > oRect.left;
        if (!xOverlap) continue;

        // group이 other 위에 있는데 아래로 침범
        if (gy < oRect.top && gy + gh + _displayGap > oRect.top) {
          final newH = (oRect.top - _displayGap - gy).clamp(
            _config.groupMinHeight,
            gh,
          );
          if (newH < gh) {
            gh = newH;
            break;
          }
        }

        // group이 other 아래에 있는데 위로 침범
        if (gy < oRect.bottom + _displayGap &&
            gy + gh > oRect.bottom &&
            gy >= oRect.top) {
          final newY = oRect.bottom + _displayGap;
          final newH = (gy + gh - newY).clamp(
            _config.groupMinHeight,
            gh,
          );
          if (newY != gy || newH < gh) {
            gy = newY;
            gh = newH;
            break;
          }
        }
      }

      // X축 회피: 같은 AnchorY, 이 그룹이 상대보다 가로로 더 큰 경우만
      for (final other in groups) {
        if (other.id == group.id || other.anchorY != group.anchorY) continue;
        if (group.width <= other.width) continue;
        final oRect = rects[other.id]!;

        final yOverlap = gy < oRect.bottom && gy + gh > oRect.top;
        if (!yOverlap) continue;

        // group이 other 왼쪽에 있는데 오른쪽으로 침범
        if (gx < oRect.left && gx + gw + _displayGap > oRect.left) {
          final newW = (oRect.left - _displayGap - gx).clamp(
            _config.groupMinWidth,
            gw,
          );
          if (newW < gw) {
            gw = newW;
            break;
          }
        }

        // group이 other 오른쪽에 있는데 왼쪽으로 침범
        if (gx < oRect.right + _displayGap &&
            gx + gw > oRect.right &&
            gx >= oRect.left) {
          final newX = oRect.right + _displayGap;
          final newW = (gx + gw - newX).clamp(
            _config.groupMinWidth,
            gw,
          );
          if (newX != gx || newW < gw) {
            gx = newX;
            gw = newW;
            break;
          }
        }
      }

      rects[group.id] = Rect.fromLTWH(gx, gy, gw, gh);
    }
  }

  /// 보정된 displayRect를 원본 그룹에 커밋 (크기 점프 방지).
  ///
  /// 드래그/리사이즈 시작 시 호출하여,
  /// 사용자가 보고 있는 축소된 크기를 원본에 반영.
  void _commitDisplayRect(String groupId) {
    final displayRects = state.displayRects;
    final rect = displayRects[groupId];
    if (rect == null) return;

    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final vs = state.viewerSize;

    final sizeChanged =
        (group.width - rect.width).abs() > 0.5 ||
        (group.height - rect.height).abs() > 0.5;
    final posChanged =
        (group.absoluteX(vs.width) - rect.left).abs() > 0.5 ||
        (group.absoluteY(vs.height) - rect.top).abs() > 0.5;

    if (!sizeChanged && !posChanged) return;

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId)
              g
                  .copyWith(width: rect.width, height: rect.height)
                  .updateFromAbsolute(rect.left, rect.top, vs.width, vs.height)
            else
              g,
        ],
        viewerSize: vs,
      ),
    );
  }

  // ── 뷰포트 ──

  /// 뷰어 크기 업데이트 (LayoutBuilder에서 호출).
  void updateViewerSize(Size size) {
    if (state.viewerSize == size) return;
    final oldSize = state.viewerSize;
    // 엣지 패널의 Split ratios를 재조정하여 가장 큰 패널만 크기 변동 흡수
    final adjustedGroups = oldSize == Size.zero
        ? state.groups
        : [
            for (final g in state.groups)
              if (g.dockedEdge != null)
                g.copyWith(
                  root: _adjustEdgeSplitRatios(
                    g.root,
                    oldSize.height,
                    size.height,
                  ),
                )
              else
                g,
          ];
    _setState(
      DockState(
        groups: adjustedGroups,
        draggingGroupId: state.draggingGroupId,
        dockPreview: state.dockPreview,
        viewerSize: size,
      ),
    );
  }

  /// 엣지 패널의 세로 Split에서 가장 큰 자식만 크기 변동을 흡수하도록
  /// ratios를 재계산.
  ///
  /// 가로 Split이나 Split이 아닌 노드는 그대로 반환.
  DockNode _adjustEdgeSplitRatios(
    DockNode node,
    double oldHeight,
    double newHeight,
  ) {
    if (node is! DockSplit) return node;
    if (oldHeight <= 0 || newHeight <= 0) return node;

    // 재귀적으로 하위 Split도 처리
    final adjustedChildren = [
      for (final child in node.children)
        _adjustEdgeSplitRatios(child, oldHeight, newHeight),
    ];

    // 가로 Split은 높이 변동과 무관 — 자식만 재귀 처리
    if (node.axis == SplitAxis.horizontal) {
      return DockSplit(
        axis: node.axis,
        children: adjustedChildren,
        ratios: node.ratios,
      );
    }

    // 세로 Split: 절대 크기 복원 → 가장 큰 자식이 변동분 흡수
    final delta = newHeight - oldHeight;
    final sizes = [
      for (final r in node.ratios) r * oldHeight,
    ];

    // 가장 큰 자식 찾기
    int largestIdx = 0;
    for (int i = 1; i < sizes.length; i++) {
      if (sizes[i] > sizes[largestIdx]) largestIdx = i;
    }

    // 가장 큰 자식에 변동분 흡수
    sizes[largestIdx] = (sizes[largestIdx] + delta)
        .clamp(_config.groupMinHeight, double.infinity);

    // 새 ratios 계산
    final totalSize = sizes.fold(0.0, (a, b) => a + b);
    final newRatios = [
      for (final s in sizes) s / totalSize,
    ];

    return DockSplit(
      axis: node.axis,
      children: adjustedChildren,
      ratios: newRatios,
    );
  }

  // ── 드래그 ──

  void startDrag(String groupId) {
    _commitDisplayRect(groupId);
    _setState(
      DockState(
        groups: state.groups,
        draggingGroupId: groupId,
        viewerSize: state.viewerSize,
      ),
    );
  }

  /// [cursorInStack]은 Stack 로컬 좌표계의 커서 위치.
  /// 도킹 감지 시 헤더 기준점으로 사용.
  void updateDrag(
    String groupId,
    Offset position,
    Size viewerSize, {
    Offset? cursorInStack,
  }) {
    // 커서가 뷰포트 밖이면 드래그 종료
    if (cursorInStack != null) {
      final viewerRect = Offset.zero & viewerSize;
      if (!viewerRect.contains(cursorInStack)) {
        endDrag();
        return;
      }
    }

    // 드래그 중: 절대좌표를 Left/Top 앵커로 임시 저장
    final newGroups = [
      for (final g in state.groups)
        if (g.id == groupId)
          g.copyWith(
            anchorX: AnchorX.left,
            anchorY: AnchorY.top,
            offsetX: position.dx,
            offsetY: position.dy,
          )
        else
          g,
    ];

    final dragging = _findGroup(newGroups, groupId);
    if (dragging == null) return;
    final preview =
        _detectViewportEdgeDock(dragging, viewerSize) ??
        _detectDockTarget(dragging, newGroups, cursorInStack);

    _setState(
      DockState(
        groups: newGroups,
        draggingGroupId: groupId,
        dockPreview: preview,
        viewerSize: viewerSize,
      ),
    );
  }

  /// 고스트 드래그 중 도킹 대상 감지 + 프리뷰 설정.
  ///
  /// 실제 그룹이 아직 없으므로 가상 rect로 감지.
  /// [excludeGroupId]는 소속 그룹 (자기 자신에 도킹 방지).
  void updateGhostDockPreview({
    required Offset cursorInStack,
    required Size ghostSize,
    required String excludeGroupId,
  }) {
    // 고스트 시각 위치와 동일하게 rect 배치
    // (가로: 커서 중심, 세로: 커서에서 10px 아래가 상단)
    const grabOffsetY = 10.0;
    final ghostLeft = cursorInStack.dx - ghostSize.width / 2;
    final ghostTop = cursorInStack.dy - grabOffsetY;

    final virtualGroup = DockGroup(
      id: '__ghost__',
      root: const DockLeaf(panelId: ''),
      offsetX: ghostLeft,
      offsetY: ghostTop,
      width: ghostSize.width,
      height: ghostSize.height,
    );

    final targets = state.groups.where((g) => g.id != excludeGroupId).toList();
    final preview = _detectDockTarget(virtualGroup, targets, cursorInStack);

    // 프리뷰만 갱신 (그룹 이동 없음)
    state = DockState(
      groups: state.groups,
      dockPreview: preview,
      viewerSize: state.viewerSize,
      focusedPanelId: state.focusedPanelId,
      displayRects: state.displayRects,
    );
  }

  /// 외부에서 탭 도킹 수행 (고스트 드롭 등).
  void performTabDock(String sourceId, String targetId, List<int> nodePath) =>
      _performTabDock(sourceId, targetId, nodePath);

  /// 외부에서 엣지 도킹 수행 (고스트 드롭 등).
  void performEdgeDock(
    String sourceId,
    String targetId,
    DockEdge edge,
    List<int> nodePath,
  ) => _performEdgeDock(sourceId, targetId, edge, nodePath);

  /// 고스트 도킹 프리뷰 초기화.
  void clearGhostDockPreview() {
    if (state.dockPreview == null) return;
    state = DockState(
      groups: state.groups,
      viewerSize: state.viewerSize,
      focusedPanelId: state.focusedPanelId,
      displayRects: state.displayRects,
    );
  }

  void endDrag() {
    final preview = state.dockPreview;
    final draggingId = state.draggingGroupId;
    final vs = state.viewerSize;

    if (preview != null && draggingId != null) {
      if (preview.isViewportEdge) {
        final edge = switch (preview.edge) {
          DockEdge.left => ViewportEdge.left,
          DockEdge.right => ViewportEdge.right,
          _ => null,
        };
        if (edge != null) dockToViewportEdge(draggingId, edge);
      } else if (preview.edge == DockEdge.center) {
        _performTabDock(draggingId, preview.targetGroupId, preview.nodePath);
      } else {
        _performEdgeDock(
          draggingId,
          preview.targetGroupId,
          preview.edge,
          preview.nodePath,
        );
      }
    } else if (draggingId != null) {
      // 드래그 종료: 10px 스냅 + 앵커 재계산 + 뷰포트 클램핑
      final dragged = _findGroup(state.groups, draggingId);
      if (dragged == null) return;
      final snapped = dragged.updateFromAbsolute(
        _snap(dragged.offsetX),
        _snap(dragged.offsetY),
        vs.width,
        vs.height,
      );
      final committed = _clampToViewport(snapped, vs);

      _setState(
        DockState(
          groups: [
            for (final g in state.groups)
              if (g.id == draggingId) committed else g,
          ],
          viewerSize: vs,
        ),
      );
    }
    _onLayoutChanged();
  }

  void moveGroupTo(String groupId, Offset position, Size viewerSize) {
    if (state.draggingGroupId == groupId) {
      updateDrag(groupId, position, viewerSize);
    } else {
      // 절대좌표로 이동 후 앵커 재계산
      final group = _findGroup(state.groups, groupId);
      if (group == null) return;
      final updated = group
          .copyWith(
            anchorX: AnchorX.left,
            anchorY: AnchorY.top,
            offsetX: position.dx,
            offsetY: position.dy,
          )
          .updateFromAbsolute(
            position.dx,
            position.dy,
            viewerSize.width,
            viewerSize.height,
          );
      _setState(
        DockState(
          groups: [
            for (final g in state.groups)
              if (g.id == groupId) updated else g,
          ],
          viewerSize: viewerSize,
        ),
      );
    }
  }

  // ── 리사이즈 ──

  /// Split 노드의 비율을 변경 (세퍼레이터 드래그용).
  ///
  /// [nodePath]는 대상 Split 노드의 경로,
  /// [separatorIndex]는 조절할 세퍼레이터 위치 (children[index]와 [index+1] 사이),
  /// [delta]는 픽셀 단위 이동량, [totalSize]는 Split 방향의 전체 크기.
  void resizeSplit(
    String groupId, {
    required List<int> nodePath,
    required int separatorIndex,
    required double delta,
    required double totalSize,
  }) {
    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final splitNode = getNodeAt(group.root, nodePath);
    if (splitNode is! DockSplit) return;

    final i = separatorIndex;
    final ratioA = splitNode.ratios[i];
    final ratioB = splitNode.ratios[i + 1];
    final combinedRatio = ratioA + ratioB;

    // delta를 비율로 변환
    final deltaRatio = delta / totalSize;
    final newRatioA = (ratioA + deltaRatio).clamp(0.1, combinedRatio - 0.1);
    final newRatioB = combinedRatio - newRatioA;

    final newRatios = [...splitNode.ratios];
    newRatios[i] = newRatioA;
    newRatios[i + 1] = newRatioB;

    final newSplit = DockSplit(
      axis: splitNode.axis,
      children: splitNode.children,
      ratios: newRatios,
    );

    final newRoot = _replaceNodeAt(group.root, nodePath, newSplit);
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) g.copyWith(root: newRoot) else g,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  /// 탭 그룹의 활성 탭을 전환한다.
  void switchTab(
    String groupId, {
    required List<int> nodePath,
    required int tabIndex,
  }) {
    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final node = getNodeAt(group.root, nodePath);
    if (node is! DockTabbed) return;
    if (tabIndex < 0 || tabIndex >= node.tabIds.length) return;
    if (tabIndex == node.activeIndex) return;

    final newTabbed = DockTabbed(tabIds: node.tabIds, activeIndex: tabIndex);

    final newRoot = _replaceNodeAt(group.root, nodePath, newTabbed);
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) g.copyWith(root: newRoot) else g,
        ],
        viewerSize: state.viewerSize,
        focusedPanelId: node.tabIds[tabIndex],
      ),
    );
    _onLayoutChanged();
  }

  /// 탭 그룹 내에서 탭 순서를 변경한다.
  void reorderTab(
    String groupId, {
    required List<int> nodePath,
    required int oldIndex,
    required int newIndex,
  }) {
    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final node = getNodeAt(group.root, nodePath);
    if (node is! DockTabbed) return;
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= node.tabIds.length) return;
    if (newIndex < 0 || newIndex >= node.tabIds.length) return;

    final newTabIds = [...node.tabIds];
    final movedId = newTabIds.removeAt(oldIndex);
    newTabIds.insert(newIndex, movedId);

    // 활성 탭이 이동한 탭이면 새 인덱스로, 아니면 위치 추적
    final int newActiveIndex;
    if (node.activeIndex == oldIndex) {
      newActiveIndex = newIndex;
    } else {
      final activeId = node.tabIds[node.activeIndex];
      newActiveIndex = newTabIds.indexOf(activeId);
    }

    final newTabbed = DockTabbed(
      tabIds: newTabIds,
      activeIndex: newActiveIndex,
    );
    final newRoot = _replaceNodeAt(group.root, nodePath, newTabbed);
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) g.copyWith(root: newRoot) else g,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  void startResize(String groupId) {
    // 엣지 패널은 displayRect.height = vs.height이므로 커밋하면 group.height가
    // 뷰포트 높이로 덮어써져 이후 undock 시 패널이 비정상적으로 커짐.
    final group = _findGroup(state.groups, groupId);
    if (group?.dockedEdge == null) _commitDisplayRect(groupId);
    _setState(
      DockState(
        groups: state.groups,
        resizingGroupId: groupId,
        viewerSize: state.viewerSize,
      ),
    );
  }

  /// 리사이즈 중: Left/Top 앵커로 임시 저장 (앵커 재계산 안함).
  void resizeGroup(
    String groupId, {
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId)
              g.copyWith(
                anchorX: AnchorX.left,
                anchorY: AnchorY.top,
                offsetX: left,
                offsetY: top,
                width: width,
                height: height,
              )
            else
              g,
        ],
        resizingGroupId: state.resizingGroupId,
        viewerSize: state.viewerSize,
      ),
    );
  }

  /// 리사이즈 종료: 앵커 재계산.
  void endResize(String groupId) {
    final vs = state.viewerSize;
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId)
              _clampToViewport(
                g
                    .copyWith(width: _snap(g.width), height: _snap(g.height))
                    .updateFromAbsolute(
                      _snap(g.offsetX),
                      _snap(g.offsetY),
                      vs.width,
                      vs.height,
                    ),
                vs,
              )
            else
              g,
        ],
        viewerSize: vs,
      ),
    );
    _onLayoutChanged();
  }

  // ── z-order ──

  int _maxZOrder() =>
      state.groups.fold<int>(0, (m, g) => g.zOrder > m ? g.zOrder : m);

  void bringToFront(String groupId) {
    final maxZ = _maxZOrder();

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) g.copyWith(zOrder: maxZ + 1) else g,
        ],
        draggingGroupId: state.draggingGroupId,
        dockPreview: state.dockPreview,
        viewerSize: state.viewerSize,
        focusedPanelId: state.focusedPanelId,
      ),
    );
  }

  /// 루트 FocusNode 등록 (HomeScreen initState에서 호출)
  void setRootFocusNode(FocusNode node) => _rootFocusNode = node;

  /// 특정 패널에 포커스 설정.
  ///
  /// 논리적 포커스(focusedPanelId)와 물리적 포커스(FocusNode)를
  /// 동시에 처리하여 키보드 입력이 항상 동작하도록 보장합니다.
  void focusPanel(String panelId) {
    if (state.focusedPanelId != panelId) {
      _setState(
        DockState(
          groups: state.groups,
          viewerSize: state.viewerSize,
          focusedPanelId: panelId,
        ),
      );
    }
    _rootFocusNode?.requestFocus();
  }

  // ── 도킹 감지 ──

  /// 10px 그리드에 스냅.
  static const double _snapInterval = 5.0;

  static double _snap(double value) =>
      (value / _snapInterval).round() * _snapInterval;

  static const double _dockDetectDistance = 30.0;

  /// 그룹의 절대 좌표 rect를 계산.
  /// 앵커 위치에 따라 뷰포트 중앙 방향으로 분리 오프셋을 계산.
  static const double _undockDistance = 20.0;

  static Offset _undockOffset(DockGroup group, Size viewerSize) {
    final dx = switch (group.anchorX) {
      AnchorX.left => _undockDistance,
      AnchorX.center => 0.0,
      AnchorX.right => -_undockDistance,
    };
    final dy = switch (group.anchorY) {
      AnchorY.top => _undockDistance,
      AnchorY.center => 0.0,
      AnchorY.bottom => -_undockDistance,
    };
    return Offset(dx, dy);
  }

  Rect _groupRect(DockGroup g) {
    // 엣지 패널: 실제 레이아웃 좌표로 변환
    if (g.dockedEdge != null) {
      final vs = state.viewerSize;
      return switch (g.dockedEdge!) {
        ViewportEdge.left => Rect.fromLTWH(0, 0, g.width, vs.height),
        ViewportEdge.right => Rect.fromLTWH(
          vs.width - g.width,
          0,
          g.width,
          vs.height,
        ),
      };
    }
    // display rect가 있으면 보정된 좌표 사용 (자동 리사이즈 반영)
    final displayRect = state.displayRects[g.id];
    if (displayRect != null) return displayRect;
    final vs = state.viewerSize;
    return Rect.fromLTWH(
      g.absoluteX(vs.width),
      g.absoluteY(vs.height),
      g.width,
      g.height,
    );
  }

  /// 그룹 ID로 안전하게 검색. 없으면 null.
  static DockGroup? _findGroup(List<DockGroup> groups, String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// 그룹 내 개별 패널(리프/탭) rect를 재귀적으로 계산.
  List<_NodeRect> _calcNodeRects(
    DockNode node,
    Rect rect,
    List<int> parentPath,
  ) {
    return switch (node) {
      DockLeaf() ||
      DockTabbed() => [_NodeRect(rect: rect, path: parentPath, node: node)],
      DockSplit(:final axis, :final children, :final ratios) => () {
        final results = <_NodeRect>[];
        double offset = 0;
        for (int i = 0; i < children.length; i++) {
          final childRect = axis == SplitAxis.horizontal
              ? Rect.fromLTWH(
                  rect.left + offset,
                  rect.top,
                  rect.width * ratios[i],
                  rect.height,
                )
              : Rect.fromLTWH(
                  rect.left,
                  rect.top + offset,
                  rect.width,
                  rect.height * ratios[i],
                );
          results.addAll(
            _calcNodeRects(children[i], childRect, [...parentPath, i]),
          );
          offset += axis == SplitAxis.horizontal
              ? rect.width * ratios[i]
              : rect.height * ratios[i];
        }
        return results;
      }(),
    };
  }

  DockPreview? _detectDockTarget(
    DockGroup dragging,
    List<DockGroup> groups,
    Offset? cursorPosition,
  ) {
    final dragRect = _groupRect(dragging);
    final anchor = cursorPosition ?? dragRect.topLeft;

    DockPreview? best;
    double bestDist = double.infinity;

    for (final target in groups) {
      if (target.id == dragging.id) continue;

      final targetRect = _groupRect(target);

      // 기준점이 타겟 그룹의 중심 영역에 있으면 → 탭 도킹 감지
      if (targetRect.contains(anchor)) {
        final centerZone = targetRect.deflate(_dockDetectDistance);
        if (centerZone.width > 0 &&
            centerZone.height > 0 &&
            centerZone.contains(anchor)) {
          final nodeRects = _calcNodeRects(target.root, targetRect, const []);
          for (final nr in nodeRects) {
            if (nr.rect.deflate(_dockDetectDistance).contains(anchor)) {
              return DockPreview(
                targetGroupId: target.id,
                edge: DockEdge.center,
                highlightRect: nr.rect,
                nodePath: nr.path,
              );
            }
          }
        }
      }

      // 겹치는 영역이 있어야 엣지 도킹 후보
      if (dragRect.intersect(targetRect).isEmpty) continue;

      // 엣지 패널: 좌우 패널은 상하 split만 허용
      final allowH = ref.read(dockSettingsProvider).allowHorizontalPanelDock;
      final edges = switch (target.dockedEdge) {
        ViewportEdge.left || ViewportEdge.right => <DockEdge, double>{
          DockEdge.top: (dragRect.bottom - targetRect.top).abs(),
          DockEdge.bottom: (dragRect.top - targetRect.bottom).abs(),
        },
        null => <DockEdge, double>{
          if (allowH) DockEdge.left: (dragRect.right - targetRect.left).abs(),
          if (allowH) DockEdge.right: (dragRect.left - targetRect.right).abs(),
          DockEdge.top: (dragRect.bottom - targetRect.top).abs(),
          DockEdge.bottom: (dragRect.top - targetRect.bottom).abs(),
        },
      };

      for (final entry in edges.entries) {
        if (entry.value < bestDist && entry.value < _dockDetectDistance) {
          bestDist = entry.value;
          best = DockPreview(
            targetGroupId: target.id,
            edge: entry.key,
            highlightRect: _calcHighlightRect(targetRect, entry.key),
          );
        }
      }
    }

    return best;
  }

  // ── 뷰포트 엣지 감지 ──

  static const String _viewportEdgeId = '__viewport__';

  /// 커서가 뷰포트 가장자리 임계값 안에 있으면 엣지 도킹 프리뷰 반환.
  /// 이미 해당 엣지에 패널이 있으면 null (탭 합치기는 별도 처리).
  /// 헤더리스 그룹은 엣지 도킹 불가.
  DockPreview? _detectViewportEdgeDock(DockGroup dragging, Size viewerSize) {
    if (dragging.headerless) return null;
    final t = _config.edgeDetectThreshold;
    final w = viewerSize.width;
    final h = viewerSize.height;
    final dragRect = _groupRect(dragging);

    ViewportEdge? edge;
    // 패널의 해당 방향 엣지 면이 뷰포트 임계값 안에 닿으면 감지
    if (dragRect.left < t && state.edgePanel(ViewportEdge.left) == null) {
      edge = ViewportEdge.left;
    } else if (dragRect.right > w - t &&
        state.edgePanel(ViewportEdge.right) == null) {
      edge = ViewportEdge.right;
    }
    if (edge == null) return null;

    final highlightRect = switch (edge) {
      ViewportEdge.left => Rect.fromLTWH(
        0,
        0,
        _config.edgePanelDefaultSize,
        h,
      ),
      ViewportEdge.right => Rect.fromLTWH(
        w - _config.edgePanelDefaultSize,
        0,
        _config.edgePanelDefaultSize,
        h,
      ),
    };

    final dockEdge = switch (edge) {
      ViewportEdge.left => DockEdge.left,
      ViewportEdge.right => DockEdge.right,
    };

    return DockPreview(
      targetGroupId: _viewportEdgeId,
      edge: dockEdge,
      highlightRect: highlightRect,
      isViewportEdge: true,
    );
  }

  // ── 뷰포트 엣지 도킹 실행 ──

  /// 그룹을 뷰포트 엣지에 고정.
  ///
  /// 헤더리스 그룹은 엣지 도킹 불가 — 플로팅 복귀 수단이 없으므로.
  void dockToViewportEdge(String groupId, ViewportEdge edge) {
    final group = _findGroup(state.groups, groupId);
    if (group == null || group.headerless) return;

    final clampedSize = group.width.clamp(
      _config.edgePanelMinSize,
      double.infinity,
    );

    final docked = group.copyWith(dockedEdge: edge, width: clampedSize);

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) docked else g,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  /// 엣지 패널을 플로팅으로 전환.
  void undockFromViewportEdge(String groupId) {
    final group = _findGroup(state.groups, groupId);
    if (group == null || group.dockedEdge == null) return;
    final vs = state.viewerSize;

    // 원래 엣지 위치에서 5px 안쪽에 배치, 크기 유지
    const double inset = 5.0;
    final x = switch (group.dockedEdge!) {
      ViewportEdge.left => inset,
      ViewportEdge.right => vs.width - group.width - inset,
    };
    // anchorY/anchorX를 직접 고정해서 zone 계산 오류 우회
    final floating = group.copyWith(
      clearDockedEdge: true,
      anchorX: AnchorX.left,
      offsetX: x,
      anchorY: AnchorY.top,
      offsetY: 0,
    );

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) floating else g,
        ],
        viewerSize: vs,
      ),
    );
    _onLayoutChanged();
  }

  /// 엣지 패널 크기 조정.
  void resizeEdgePanel(String groupId, double newSize) {
    final group = _findGroup(state.groups, groupId);
    if (group == null || group.dockedEdge == null) return;

    final clamped = newSize.clamp(
      _config.edgePanelMinSize,
      double.infinity,
    );
    final updated = group.copyWith(width: clamped);

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) updated else g,
        ],
        viewerSize: state.viewerSize,
      ),
    );

    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounceDuration, () {
      _layoutService.saveLayout(state.groups);
    });
  }

  static const double _highlightThickness = 40.0;

  Rect _calcHighlightRect(Rect targetRect, DockEdge edge) {
    final hw = math.min(_highlightThickness, targetRect.width / 3);
    final hh = math.min(_highlightThickness, targetRect.height / 3);
    return switch (edge) {
      DockEdge.left => Rect.fromLTWH(
        targetRect.left,
        targetRect.top,
        hw,
        targetRect.height,
      ),
      DockEdge.right => Rect.fromLTWH(
        targetRect.right - hw,
        targetRect.top,
        hw,
        targetRect.height,
      ),
      DockEdge.top => Rect.fromLTWH(
        targetRect.left,
        targetRect.top,
        targetRect.width,
        hh,
      ),
      DockEdge.bottom => Rect.fromLTWH(
        targetRect.left,
        targetRect.bottom - hh,
        targetRect.width,
        hh,
      ),
      DockEdge.center => targetRect,
    };
  }

  // ── 노드 트리 조작 ──

  /// 경로를 따라 노드를 찾아 반환.
  DockNode getNodeAt(DockNode root, List<int> path) {
    DockNode current = root;
    for (final index in path) {
      if (current is DockSplit) {
        assert(
          index >= 0 && index < current.children.length,
          'getNodeAt: index $index out of bounds (children: ${current.children.length})',
        );
        if (index < 0 || index >= current.children.length) return current;
        current = current.children[index];
      } else {
        assert(
          false,
          'getNodeAt: expected DockSplit but got ${current.runtimeType} with remaining path',
        );
        return current;
      }
    }
    return current;
  }

  /// 경로의 노드를 새 노드로 교체한 트리를 반환.
  DockNode _replaceNodeAt(DockNode root, List<int> path, DockNode newNode) {
    if (path.isEmpty) return newNode;

    if (root is DockSplit) {
      final index = path.first;
      assert(
        index >= 0 && index < root.children.length,
        '_replaceNodeAt: index $index out of bounds (children: ${root.children.length})',
      );
      if (index < 0 || index >= root.children.length) return root;
      final newChildren = [
        for (int i = 0; i < root.children.length; i++)
          if (i == index)
            _replaceNodeAt(root.children[i], path.sublist(1), newNode)
          else
            root.children[i],
      ];
      return DockSplit(
        axis: root.axis,
        children: newChildren,
        ratios: root.ratios,
      );
    }
    return newNode;
  }

  /// Split 노드에서 자식을 제거하고 트리를 정리.
  ///
  /// 자식이 1개만 남으면 해당 자식으로 대체 (Split 해소).
  DockNode _removeChildAt(DockSplit split, int childIndex) {
    final newChildren = [...split.children]..removeAt(childIndex);
    final newRatios = [...split.ratios]..removeAt(childIndex);

    // 비율 재정규화
    final sum = newRatios.fold<double>(0, (a, b) => a + b);
    final normalizedRatios = sum > 1e-6
        ? [for (final r in newRatios) r / sum]
        : [for (int i = 0; i < newRatios.length; i++) 1.0 / newRatios.length];

    if (newChildren.length == 1) return newChildren.first;

    return DockSplit(
      axis: split.axis,
      children: newChildren,
      ratios: normalizedRatios,
    );
  }

  /// 탭 그룹에서 특정 탭을 분리하여 새 독립 그룹으로 생성.
  /// 생성된 그룹의 ID를 반환. 실패 시 null.
  ///
  /// [cursorInStack]이 전달되면 커서 위치에 그룹을 배치하고
  /// 즉시 드래그 상태로 전환 (드래그 분리용).
  String? undockTab({
    required String sourceGroupId,
    required List<int> nodePath,
    required int tabIndex,
    Offset? cursorInStack,
  }) {
    final group = _findGroup(state.groups, sourceGroupId);
    if (group == null) return null;
    final node = getNodeAt(group.root, nodePath);
    if (node is! DockTabbed) return null;
    if (node.tabIds.length <= 1) return null;

    final removedId = node.tabIds[tabIndex];
    final remainingIds = [...node.tabIds]..removeAt(tabIndex);
    final newActiveIndex = tabIndex >= remainingIds.length
        ? remainingIds.length - 1
        : tabIndex;

    // 탭이 1개만 남으면 DockLeaf로 변환
    final DockNode newNode = remainingIds.length == 1
        ? DockLeaf(panelId: remainingIds.first)
        : DockTabbed(tabIds: remainingIds, activeIndex: newActiveIndex);

    final newRoot = _replaceNodeAt(group.root, nodePath, newNode);
    // 남은 패널이 1개이고 헤더리스 대상이면 그룹도 헤더리스로 전환
    final remainingPanelIds = collectPanelIds(newRoot);
    final shouldBeHeaderless = remainingPanelIds.length == 1 &&
        ref.read(dockSettingsProvider).isHeaderless(remainingPanelIds.first);
    final updatedGroup = group.copyWith(
      root: newRoot,
      headerless: shouldBeHeaderless,
    );

    final maxZ = _maxZOrder();
    final vs = state.viewerSize;

    // 탭 노드의 실제 rect 계산 (Split 내부일 경우 그룹 전체가 아닌 노드 크기 사용)
    final groupRect = _groupRect(group);
    final nodeRects = _calcNodeRects(group.root, groupRect, []);
    final nodeRect =
        nodeRects
            .where((nr) => listEquals(nr.path, nodePath))
            .firstOrNull
            ?.rect ??
        groupRect;

    // 커서 위치 기반 배치 (드래그 분리) vs 오프셋 배치 (버튼 분리)
    final double absX;
    final double absY;
    if (cursorInStack != null) {
      absX = cursorInStack.dx - nodeRect.width / 2;
      absY = cursorInStack.dy - 10;
    } else {
      final offset = _undockOffset(group, vs);
      absX = nodeRect.left + offset.dx;
      absY = nodeRect.top + offset.dy;
    }

    final newGroupId = 'group_${_nextGroupId++}';
    final newGroup = DockGroup(
      id: newGroupId,
      root: DockLeaf(panelId: removedId),
      offsetX: absX,
      offsetY: absY,
      width: nodeRect.width,
      height: nodeRect.height,
      zOrder: maxZ + 1,
      headerless: ref.read(dockSettingsProvider).isHeaderless(removedId),
    ).updateFromAbsolute(absX, absY, vs.width, vs.height);

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == sourceGroupId) updatedGroup else g,
          newGroup,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
    return newGroupId;
  }

  /// 노드를 그룹에서 분리하여 새 독립 그룹으로 생성.
  ///
  /// 구분선 위치에서 딱 잘린 것처럼 양쪽 크기를 유지.
  /// 떼어낸 쪽은 앵커 기준 중앙 방향으로 비켜서 배치.
  /// 생성된 그룹의 ID를 반환. 실패 시 null.
  String? undockNode({
    required String sourceGroupId,
    required List<int> nodePath,
    Offset? cursorInStack,
  }) {
    if (nodePath.isEmpty) return null;

    final group = _findGroup(state.groups, sourceGroupId);
    if (group == null) return null;
    final parentPath = nodePath.sublist(0, nodePath.length - 1);
    final childIndex = nodePath.last;
    final parent = getNodeAt(group.root, parentPath);

    if (parent is! DockSplit) return null;

    final groupRect = _groupRect(group);
    final childRects = _calcDirectChildRects(parent, groupRect);

    final removedNode = parent.children[childIndex];
    final newParent = _removeChildAt(parent, childIndex);
    final newRoot = _replaceNodeAt(group.root, parentPath, newParent);

    // 남는 쪽의 크기를 계산 — 나머지 자식들의 영역
    final remainingRect = _calcRemainingRect(parent, groupRect, childIndex);

    final maxZ = _maxZOrder();

    final vs = state.viewerSize;
    final removedRect = childRects[childIndex];

    // 커서 위치 기반 배치 (드래그 분리) vs 오프셋 배치 (버튼 분리)
    final double absX;
    final double absY;
    if (cursorInStack != null) {
      absX = cursorInStack.dx - removedRect.width / 2;
      absY = cursorInStack.dy - 10;
    } else {
      final offset = _undockOffset(group, vs);
      absX = removedRect.left + offset.dx;
      absY = removedRect.top + offset.dy;
    }
    final newGroupId = 'group_${_nextGroupId++}';
    final removedIds = collectPanelIds(removedNode);
    final newGroup = DockGroup(
      id: newGroupId,
      root: removedNode,
      offsetX: absX,
      offsetY: absY,
      width: removedRect.width,
      height: removedRect.height,
      zOrder: maxZ + 1,
      headerless: removedIds.length == 1 &&
          ref.read(dockSettingsProvider).isHeaderless(removedIds.first),
    ).updateFromAbsolute(absX, absY, vs.width, vs.height);

    // 남는 그룹도 크기를 축소 + 헤더리스 재판정
    final remainingIds = collectPanelIds(newRoot);
    final updatedGroup = group
        .copyWith(
          root: newRoot,
          width: remainingRect.width,
          height: remainingRect.height,
          headerless: remainingIds.length == 1 &&
              ref.read(dockSettingsProvider).isHeaderless(remainingIds.first),
        )
        .updateFromAbsolute(
          remainingRect.left,
          remainingRect.top,
          vs.width,
          vs.height,
        );

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == sourceGroupId) updatedGroup else g,
          newGroup,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
    return newGroupId;
  }

  /// Split의 직속 자식별 rect를 계산.
  List<Rect> _calcDirectChildRects(DockSplit split, Rect rect) {
    final rects = <Rect>[];
    double offset = 0;
    for (int i = 0; i < split.children.length; i++) {
      final childRect = split.axis == SplitAxis.horizontal
          ? Rect.fromLTWH(
              rect.left + offset,
              rect.top,
              rect.width * split.ratios[i],
              rect.height,
            )
          : Rect.fromLTWH(
              rect.left,
              rect.top + offset,
              rect.width,
              rect.height * split.ratios[i],
            );
      rects.add(childRect);
      offset += split.axis == SplitAxis.horizontal
          ? rect.width * split.ratios[i]
          : rect.height * split.ratios[i];
    }
    return rects;
  }

  /// 자식 제거 후 나머지 영역의 rect를 계산.
  Rect _calcRemainingRect(DockSplit split, Rect rect, int removedIndex) {
    final childRects = _calcDirectChildRects(split, rect);
    double left = double.infinity, top = double.infinity;
    double right = 0, bottom = 0;
    for (int i = 0; i < childRects.length; i++) {
      if (i == removedIndex) continue;
      final r = childRects[i];
      left = math.min(left, r.left);
      top = math.min(top, r.top);
      right = math.max(right, r.right);
      bottom = math.max(bottom, r.bottom);
    }
    if (left == double.infinity) return rect;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  // ── 도킹 실행 ──

  /// 엣지 도킹: 타겟 그룹의 루트에 Split으로 합침 (크기 유지).
  void _performEdgeDock(
    String sourceId,
    String targetId,
    DockEdge edge,
    List<int> nodePath,
  ) {
    final source = _findGroup(state.groups, sourceId);
    final target = _findGroup(state.groups, targetId);
    if (source == null || target == null) return;
    final vs = state.viewerSize;

    // 절대 좌표로 계산
    final srcRect = _groupRect(source);
    final tgtRect = _groupRect(target);

    final axis = (edge == DockEdge.left || edge == DockEdge.right)
        ? SplitAxis.horizontal
        : SplitAxis.vertical;
    final sourceFirst = (edge == DockEdge.left || edge == DockEdge.top);

    final children = sourceFirst
        ? [source.root, target.root]
        : [target.root, source.root];

    // 엣지 패널 타겟: 위치/크기 유지, dockedEdge 보존
    if (target.dockedEdge != null) {
      final totalSize = axis == SplitAxis.horizontal
          ? tgtRect.width
          : tgtRect.height;
      final srcSize = axis == SplitAxis.horizontal
          ? srcRect.width
          : srcRect.height;
      final ratio = (srcSize / totalSize).clamp(0.1, 0.9);
      final ratios = sourceFirst ? [ratio, 1.0 - ratio] : [1.0 - ratio, ratio];

      final mergedGroup = _clampToViewport(
        target.copyWith(
          root: DockSplit(axis: axis, children: children, ratios: ratios),
          headerless: false,
        ),
        vs,
      );

      _setState(
        DockState(
          groups: [
            for (final g in state.groups)
              if (g.id == targetId) mergedGroup else if (g.id != sourceId) g,
          ],
          viewerSize: vs,
        ),
      );
      return;
    }

    final double mergedLeft;
    final double mergedTop;
    final double mergedWidth;
    final double mergedHeight;
    final double ratio;

    if (axis == SplitAxis.horizontal) {
      mergedWidth = srcRect.width + tgtRect.width;
      mergedHeight = math.max(srcRect.height, tgtRect.height);
      mergedTop = math.min(srcRect.top, tgtRect.top);
      mergedLeft = sourceFirst ? tgtRect.left - srcRect.width : tgtRect.left;
      ratio = srcRect.width / mergedWidth;
    } else {
      mergedHeight = srcRect.height + tgtRect.height;
      mergedWidth = math.max(srcRect.width, tgtRect.width);
      mergedLeft = math.min(srcRect.left, tgtRect.left);
      mergedTop = sourceFirst ? tgtRect.top - srcRect.height : tgtRect.top;
      ratio = srcRect.height / mergedHeight;
    }

    final ratios = sourceFirst ? [ratio, 1.0 - ratio] : [1.0 - ratio, ratio];

    final mergedGroup = _clampToViewport(
      target
          .copyWith(
            root: DockSplit(axis: axis, children: children, ratios: ratios),
            width: mergedWidth,
            height: mergedHeight,
            headerless: false,
          )
          .updateFromAbsolute(mergedLeft, mergedTop, vs.width, vs.height),
      vs,
    );

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == targetId) mergedGroup else if (g.id != sourceId) g,
        ],
        viewerSize: vs,
      ),
    );
  }

  /// 탭 도킹: 타겟 그룹 내 특정 노드에 탭으로 합침.
  void _performTabDock(String sourceId, String targetId, List<int> nodePath) {
    final source = _findGroup(state.groups, sourceId);
    final target = _findGroup(state.groups, targetId);
    if (source == null || target == null) return;

    final sourceIds = collectPanelIds(source.root);
    final targetNode = getNodeAt(target.root, nodePath);
    final targetIds = collectPanelIds(targetNode);
    final allIds = [...targetIds, ...sourceIds];

    final newTabbed = DockTabbed(tabIds: allIds, activeIndex: targetIds.length);

    final newRoot = _replaceNodeAt(target.root, nodePath, newTabbed);
    // 탭이 합쳐지면 헤더리스 해제 + 뷰포트 클램핑
    final mergedGroup = _clampToViewport(
      target.copyWith(root: newRoot, headerless: false),
      state.viewerSize,
    );

    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == targetId) mergedGroup else if (g.id != sourceId) g,
        ],
        viewerSize: state.viewerSize,
      ),
    );
  }

  /// 그룹의 핀 고정 상태를 토글.
  void togglePin(String groupId) {
    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final updated = group.copyWith(pinned: !group.pinned);
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId) updated else g,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  /// 그룹을 독 시스템에서 제거.
  void removeGroup(String groupId) {
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id != groupId) g,
        ],
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  /// 그룹을 뷰포트 안쪽으로 클램핑.
  ///
  /// 도킹/합치기 후 패널이 뷰포트 밖으로 벗어나는 경우 안전하게 밀어넣음.
  DockGroup _clampToViewport(DockGroup group, Size vs) {
    final clamped = group.displayRect(vs.width, vs.height);
    return group
        .copyWith(width: clamped.width, height: clamped.height)
        .updateFromAbsolute(clamped.left, clamped.top, vs.width, vs.height);
  }

  /// DockNode 트리에서 모든 패널 ID를 수집.
  List<String> collectPanelIds(DockNode node) {
    return switch (node) {
      DockLeaf(:final panelId) => [panelId],
      DockSplit(:final children) => [
        for (final child in children) ...collectPanelIds(child),
      ],
      DockTabbed(:final tabIds) => [...tabIds],
    };
  }
}

final dockProvider = NotifierProvider<DockNotifier, DockState>(
  DockNotifier.new,
);
