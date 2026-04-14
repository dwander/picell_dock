import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart' show FocusNode, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/dock_config.dart';
import '../models/dock_group.dart';
import '../models/dock_node.dart';
import '../services/dock_layout_service.dart';
import '../utils/dock_free_rect.dart';
import 'dock_node_tree.dart';
import 'dock_settings_provider.dart';
import 'dock_state.dart';
export 'dock_state.dart';

// 패키지 내부 계산에서 사용하는 기본 config 인스턴스.
const _config = DockConfig();

/// 독 상태를 관리하는 Notifier.
class DockNotifier extends Notifier<DockState> {
  late final DockLayoutService _layoutService;
  FocusNode? _rootFocusNode;
  Timer? _saveTimer;
  int _nextGroupId = 0;

  /// _setState 호출 간 layoutSettled 값을 추적.
  /// state가 미초기화 상태일 때 state.layoutSettled 읽기를 방지한다.
  bool _prevLayoutSettled = false;

  /// 보더 스캔 이펙트 대기 중인 노드 (로컬 관리).
  /// key: groupId, value: 노드 경로 (빈 리스트 = 그룹 전체).
  final Map<String, List<int>> _scanPendingNodes = {};

  /// 저장 디바운스 간격.
  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  /// 부동소수점 위치/크기 변경 감지 임계값.
  static const double _positionEpsilon = 0.5;

  @override
  DockState build() {
    _layoutService = DockLayoutService();
    _scanPendingNodes.clear();
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
      flashPanelId: newState.flashPanelId,
      layoutSettled: newState.layoutSettled || _prevLayoutSettled,
      displayRects: rects,
      scanPendingNodes: Map.unmodifiable(_scanPendingNodes),
    );
    _prevLayoutSettled = state.layoutSettled;
  }

  /// displayRects를 재계산하지 않는 경량 상태 갱신.
  ///
  /// dockPreview나 scanPendingNodes처럼 레이아웃에 영향 없는 필드만
  /// 변경할 때 사용. displayRects는 기존 값을 그대로 유지.
  void _setStateLight({
    DockPreview? dockPreview,
  }) {
    state = DockState(
      groups: state.groups,
      draggingGroupId: state.draggingGroupId,
      resizingGroupId: state.resizingGroupId,
      dockPreview: dockPreview ?? state.dockPreview,
      viewerSize: state.viewerSize,
      focusedPanelId: state.focusedPanelId,
      displayRects: state.displayRects,
      scanPendingNodes: Map.unmodifiable(_scanPendingNodes),
    );
  }

  /// groups 리스트에서 [id]에 해당하는 그룹을 [replacement]로 교체.
  List<DockGroup> _replaceGroup(String id, DockGroup replacement) {
    return [for (final g in state.groups) if (g.id == id) replacement else g];
  }

  /// groups 리스트에서 [id]에 해당하는 그룹을 [update] 결과로 교체.
  List<DockGroup> _updateGroup(String id, DockGroup Function(DockGroup) update) {
    return [for (final g in state.groups) if (g.id == id) update(g) else g];
  }

  /// groups 리스트에서 [removeId]를 제거.
  List<DockGroup> _removeGroup(String removeId) {
    return [for (final g in state.groups) if (g.id != removeId) g];
  }

  /// groups 리스트에서 [targetId]를 [replacement]로 교체하면서 [removeId]를 제거.
  List<DockGroup> _replaceAndRemoveGroup(
    String targetId,
    DockGroup replacement,
    String removeId,
  ) {
    return [
      for (final g in state.groups)
        if (g.id == targetId) replacement
        else if (g.id != removeId) g,
    ];
  }

  /// 저장된 레이아웃 로드 (비동기, 실패 시 기본 레이아웃 유지).
  Future<void> _loadSavedLayout() async {
    final data = await _layoutService.loadLayout();
    if (data != null && ref.mounted) {
      // 기존 그룹 ID에서 숫자 접미사를 파싱하여 _nextGroupId를 max+1로 설정.
      final groupIdPattern = RegExp(r'^group_(\d+)$');
      int maxId = -1;
      for (final group in data.groups) {
        final match = groupIdPattern.firstMatch(group.id);
        if (match != null) {
          final num = int.parse(match.group(1)!);
          if (num > maxId) maxId = num;
        }
      }
      if (maxId >= 0) _nextGroupId = maxId + 1;

      _lastPanelAloneSizes.addAll(data.lastPanelAloneSizes);

      // 저장 시 뷰포트 높이와 현재 뷰포트 높이가 다르면 엣지 패널 Split 비율 보정.
      // 이를 통해 최대화 상태에서 저장된 비율이 일반 창 크기에서 잘못 적용되는
      // 문제(재시작 시 고정 패널 크기 변동)를 방지한다.
      final savedVH = data.savedViewportHeight;
      final currentVH = state.viewerSize.height;
      final List<DockGroup> groups;
      if (savedVH != null &&
          currentVH > 0 &&
          (savedVH - currentVH).abs() > _positionEpsilon) {
        groups = [
          for (final g in data.groups)
            if (g.dockedEdge != null)
              g.copyWith(
                root: _fixSplitRatiosForResize(
                  g.root,
                  Size(g.width, savedVH),
                  Size(g.width, currentVH),
                ),
              )
            else
              g,
        ];
      } else {
        groups = data.groups;
      }

      // 그룹 변경을 먼저 적용 (layoutSettled는 아직 false).
      _setState(DockState(groups: groups, viewerSize: state.viewerSize));

      // 저장된 레이아웃의 최대화 그룹은 저장 시점의 뷰포트 기준 위치/크기이므로
      // 현재 뷰포트에 맞게 재계산 (창 크기를 다르게 실행/복귀할 때 overflow 방지).
      if (state.viewerSize != Size.zero) {
        _recomputeMaximizedGroups();
      }
    }
    // layoutSettled를 다음 프레임에 설정.
    // 같은 프레임에 설정하면 Flutter가 두 setState를 배치(batch)해서
    // didUpdateWidget이 layoutSettled=true인 상태에서 이펙트를 트리거하므로,
    // 그룹 변경이 렌더링된 다음 프레임에서 settled 처리한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.mounted) {
        _setState(DockState(
          groups: state.groups,
          viewerSize: state.viewerSize,
          layoutSettled: true,
        ));
      }
    });
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
              (g.width - rect.width).abs() > _positionEpsilon ||
              (g.height - rect.height).abs() > _positionEpsilon;
          final posChanged =
              (g.absoluteX(vs.width) - rect.left).abs() > _positionEpsilon ||
              (g.absoluteY(vs.height) - rect.top).abs() > _positionEpsilon;
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

    _scheduleSave();
  }

  /// 레이아웃 변경 후 디바운스 저장을 예약한다.
  ///
  /// 기존 타이머를 취소하고 [_saveDebounceDuration] 후 저장을 실행.
  void _scheduleSave() {
    _saveTimer?.cancel();
    final viewportH = state.viewerSize.height;
    _saveTimer = Timer(_saveDebounceDuration, () {
      _layoutService.saveLayout(
        state.groups,
        lastPanelAloneSizes: _lastPanelAloneSizes,
        viewportHeight: viewportH > 0 ? viewportH : null,
      );
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

  /// 엣지(left/right) 기준으로 패널의 뷰포트 내 Rect를 계산.
  static Rect _edgeRect(ViewportEdge edge, double width, Size vs) {
    return switch (edge) {
      ViewportEdge.left => Rect.fromLTWH(0, 0, width, vs.height),
      ViewportEdge.right => Rect.fromLTWH(vs.width - width, 0, width, vs.height),
    };
  }

  /// 0단계: 엣지 패널 위치 고정.
  void _applyEdgePanelRects(
    Map<String, Rect> rects,
    List<DockGroup> groups,
    Size vs,
  ) {
    for (final group in groups) {
      if (group.dockedEdge == null) continue;
      rects[group.id] = _edgeRect(group.dockedEdge!, group.width, vs);
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
        (group.width - rect.width).abs() > _positionEpsilon ||
        (group.height - rect.height).abs() > _positionEpsilon;
    final posChanged =
        (group.absoluteX(vs.width) - rect.left).abs() > _positionEpsilon ||
        (group.absoluteY(vs.height) - rect.top).abs() > _positionEpsilon;

    if (!sizeChanged && !posChanged) return;

    _setState(
      DockState(
        groups: _updateGroup(
          groupId,
          (g) => g
              .copyWith(width: rect.width, height: rect.height)
              .updateFromAbsolute(rect.left, rect.top, vs.width, vs.height),
        ),
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
                  root: _fixSplitRatiosForResize(
                    g.root,
                    Size(g.width, oldSize.height),
                    Size(g.width, size.height),
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
    // 최대화 상태 그룹은 새 뷰어 크기 기준으로 재배치
    _recomputeMaximizedGroups();
  }

  /// nodePath를 따라 내려가 해당 DockSplit의 실제 렌더 크기를 계산.
  ///
  /// 엣지 패널(displayRect 기준)과 플로팅 패널(group 크기 기준) 모두 지원.
  /// 중첩 Split에서 각 레벨의 separator 공간과 ratio를 적용해 정확한 크기를 계산.
  double _computeSplitSize(
    DockGroup group,
    List<int> nodePath,
    SplitAxis splitAxis,
  ) {
    final displayRect = state.displayRects[group.id];
    Size available = Size(
      displayRect?.width ?? group.width,
      displayRect?.height ?? (group.dockedEdge != null
          ? state.viewerSize.height
          : group.height),
    );

    DockNode current = group.root;
    for (final idx in nodePath) {
      if (current is! DockSplit) break;
      final isVertical = current.axis == SplitAxis.vertical;
      final sepSpace =
          (current.children.length - 1) * _config.splitSeparatorThickness;
      final main = isVertical ? available.height : available.width;
      final cross = isVertical ? available.width : available.height;
      final content = (main - sepSpace).clamp(0.0, double.infinity);
      final childMain = current.ratios[idx] * content;
      available =
          isVertical ? Size(cross, childMain) : Size(childMain, cross);
      current = current.children[idx];
    }

    return splitAxis == SplitAxis.vertical
        ? available.height
        : available.width;
  }

  /// 세로 Split 리사이즈 시 비율 보정.
  ///
  /// 접힌 자식은 [collapsedH] 고정, 비접힌 자식 중 가장 큰 것만 유동,
  /// 나머지는 이전 픽셀 크기를 유지한다.
  /// [_adjustEdgeSplitRatios]와 동일한 "가장 큰 패널이 변동분 흡수" 패턴.
  /// 수직/수평 Split 모두 동일하게 적용.
  DockNode _fixSplitRatiosForResize(
    DockNode node,
    Size oldSize,
    Size newSize,
  ) {
    if (node is! DockSplit) return node;

    // 이 Split의 축에 해당하는 크기
    final oldMain = node.axis == SplitAxis.vertical
        ? oldSize.height : oldSize.width;
    final newMain = node.axis == SplitAxis.vertical
        ? newSize.height : newSize.width;
    // 교차 축 크기 (하위 재귀용)
    final oldCross = node.axis == SplitAxis.vertical
        ? oldSize.width : oldSize.height;
    final newCross = node.axis == SplitAxis.vertical
        ? newSize.width : newSize.height;

    if (oldMain <= 0 || newMain <= 0) return node;

    // 세퍼레이터 제외한 콘텐츠 크기로 계산
    final collapsedH = _collapsedNodeHeight;
    final separatorSpace =
        (node.children.length - 1) * _config.splitSeparatorThickness;
    final oldContent = oldMain - separatorSpace;
    final newContent = newMain - separatorSpace;

    // 현재 레벨의 각 자식 현재 크기 계산 (collapse 고려)
    final sizes = <double>[];
    for (int i = 0; i < node.ratios.length; i++) {
      final isCollapsed = node.axis == SplitAxis.vertical &&
          node.children[i].isCollapsed;
      sizes.add(isCollapsed ? collapsedH : node.ratios[i] * oldContent);
    }

    // 가장 큰 비접힌 자식을 찾아 변동분 흡수
    int largestIdx = -1;
    for (int i = 0; i < sizes.length; i++) {
      final isCollapsed = node.axis == SplitAxis.vertical &&
          node.children[i].isCollapsed;
      if (!isCollapsed &&
          (largestIdx == -1 || sizes[i] > sizes[largestIdx])) {
        largestIdx = i;
      }
    }
    if (largestIdx == -1) largestIdx = 0;

    // 고정 자식 합계 (가장 큰 자식 제외)
    double fixedTotal = 0;
    for (int i = 0; i < sizes.length; i++) {
      if (i != largestIdx) fixedTotal += sizes[i];
    }
    // 가장 큰 자식이 남은 콘텐츠 공간 전부 차지
    final minSize = node.axis == SplitAxis.vertical
        ? _config.groupMinHeight : _config.groupMinWidth;
    final newSizes = List<double>.from(sizes);
    newSizes[largestIdx] = (newContent - fixedTotal)
        .clamp(minSize, double.infinity);

    // 재귀: 하위 Split도 처리 (현재 레벨의 정확한 newSize를 전달해야
    // 하위 레벨에서 불필요한 비율 재조정이 일어나지 않음)
    final adjustedChildren = [
      for (int i = 0; i < node.children.length; i++)
        _fixSplitRatiosForResize(
          node.children[i],
          node.axis == SplitAxis.vertical
              ? Size(oldCross, sizes[i])
              : Size(sizes[i], oldCross),
          node.axis == SplitAxis.vertical
              ? Size(newCross, newSizes[i])
              : Size(newSizes[i], newCross),
        ),
    ];

    return DockSplit(
      axis: node.axis,
      children: adjustedChildren,
      ratios: _ratiosFromSizes(newSizes),
    );
  }

  /// 절대 크기 배열을 정규화된 비율 배열로 변환.
  static List<double> _ratiosFromSizes(List<double> sizes) {
    final total = sizes.fold(0.0, (a, b) => a + b);
    if (total <= 0) return List.filled(sizes.length, 1.0 / sizes.length);
    return [for (final s in sizes) s / total];
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
    // 드래그 중: 절대좌표를 Left/Top 앵커로 임시 저장
    // (뷰포트 클램핑은 endDrag 시점에 적용)
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
    _setStateLight(dockPreview: preview);
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
    _setState(DockState(
      groups: state.groups,
      viewerSize: state.viewerSize,
      focusedPanelId: state.focusedPanelId,
    ));
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
          groups: _replaceGroup(draggingId, committed),
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
          groups: _replaceGroup(groupId, updated),
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
  /// [delta]는 픽셀 단위 이동량, [totalSize]는 호출자가 파악한 크기 (무시됨).
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

    // 중첩 Split에서 group.height/width가 아닌 해당 Split의 실제 렌더 크기 사용.
    // group.height를 쓰면 내부 중첩 Split에서 비율이 희석되어 드래그가 느려짐.
    final actualSize = _computeSplitSize(group, nodePath, splitNode.axis);
    final effectiveTotalSize = actualSize > 0 ? actualSize : totalSize;

    // 픽셀 기반 최소 크기를 ratio로 변환
    final minPx = splitNode.axis == SplitAxis.vertical
        ? _config.groupMinHeight
        : _config.groupMinWidth;
    final minRatio =
        effectiveTotalSize > 0 ? minPx / effectiveTotalSize : 0.1;

    // delta를 비율로 변환
    final deltaRatio = delta / effectiveTotalSize;
    final effectiveMin = math.min(minRatio, combinedRatio / 2);
    final newRatioA =
        (ratioA + deltaRatio).clamp(effectiveMin, combinedRatio - effectiveMin);
    final newRatioB = combinedRatio - newRatioA;

    final newRatios = [...splitNode.ratios];
    newRatios[i] = newRatioA;
    newRatios[i + 1] = newRatioB;

    final newSplit = DockSplit(
      axis: splitNode.axis,
      children: splitNode.children,
      ratios: newRatios,
    );

    final newRoot = replaceNodeAt(group.root, nodePath, newSplit);
    _setState(
      DockState(
        groups: _updateGroup(groupId, (g) => g.copyWith(root: newRoot)),
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

    final newRoot = replaceNodeAt(group.root, nodePath, newTabbed);
    _setState(
      DockState(
        groups: _updateGroup(groupId, (g) => g.copyWith(root: newRoot)),
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
    final newRoot = replaceNodeAt(group.root, nodePath, newTabbed);
    _setState(
      DockState(
        groups: _updateGroup(groupId, (g) => g.copyWith(root: newRoot)),
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
  ///
  /// 높이 변경 시 접힌 노드는 고정 크기를 유지하고
  /// 나머지 자식에게 변동분을 분배한다.
  void resizeGroup(
    String groupId, {
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    final group = _findGroup(state.groups, groupId);
    // 크기가 변경되면 가장 큰 패널만 유동 리사이즈, 나머지 고정
    final DockNode root;
    if (group != null &&
        ((group.height - height).abs() > _positionEpsilon ||
         (group.width - width).abs() > _positionEpsilon)) {
      root = _fixSplitRatiosForResize(
        group.root,
        Size(group.width, group.height),
        Size(width, height),
      );
    } else {
      root = group?.root ?? const DockLeaf(panelId: '');
    }
    _setState(
      DockState(
        groups: _updateGroup(
          groupId,
          (g) => g.copyWith(
            root: root,
            anchorX: AnchorX.left,
            anchorY: AnchorY.top,
            offsetX: left,
            offsetY: top,
            width: width,
            height: height,
          ),
        ),
        resizingGroupId: state.resizingGroupId,
        viewerSize: state.viewerSize,
      ),
    );
  }

  /// 리사이즈 종료: 앵커 재계산 + 접힌 노드 비율 보정.
  void endResize(String groupId) {
    final vs = state.viewerSize;
    _setState(
      DockState(
        groups: _updateGroup(groupId, (g) {
          final snapped = g
              .copyWith(width: _snap(g.width), height: _snap(g.height))
              .updateFromAbsolute(
                _snap(g.offsetX),
                _snap(g.offsetY),
                vs.width,
                vs.height,
              );
          // 접힌 노드 고정 + 가장 큰 패널만 유동 보정
          final snappedSize = Size(snapped.width, snapped.height);
          final fixedRoot = _fixSplitRatiosForResize(
            snapped.root, snappedSize, snappedSize,
          );
          return _clampToViewport(
            snapped.copyWith(root: fixedRoot),
            vs,
          );
        }),
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
        groups: _updateGroup(groupId, (g) => g.copyWith(zOrder: maxZ + 1)),
        draggingGroupId: state.draggingGroupId,
        dockPreview: state.dockPreview,
        viewerSize: state.viewerSize,
        focusedPanelId: state.focusedPanelId,
      ),
    );
  }

  /// 최대화/복귀 시 패널과의 간격 (px).
  static const double _maximizeGap = 10.0;

  /// 그룹을 엣지 패널이 점유하지 않는 최대 빈 영역으로 이동·확장.
  ///
  /// - 자기 자신(groupId)은 회피 대상에서 제외.
  /// - 엣지 도킹 상태면 먼저 플로팅으로 전환 후 최대화.
  /// - 이미 최대화 상태면 savedState를 덮어쓰지 않고 위치만 재계산.
  void maximizeGroup(String groupId) {
    var group = _findGroup(state.groups, groupId);
    if (group == null) return;

    // undock 전에 엣지 정보 캡처 — undock 후에는 dockedEdge가 null로 바뀜
    final originalEdge = group.dockedEdge;

    if (group.dockedEdge != null) {
      undockFromViewportEdge(groupId);
      group = _findGroup(state.groups, groupId)!;
    }

    final vs = state.viewerSize;

    // 이미 최대화 상태면 기존 savedState 유지, 아니면 현재 절대 위치 저장
    final saved = group.savedState ?? (
      left: group.absoluteX(vs.width),
      top: group.absoluteY(vs.height),
      width: group.width,
      height: group.height,
      dockedEdge: originalEdge,
    );

    final edges = DockFreeRect.calcEdges(
      state.displayRects,
      vs,
      excludeId: groupId,
    );

    final vw = vs.width;
    final vh = vs.height;
    final newLeft = edges.left + (edges.left > 0 ? _maximizeGap : 0.0);
    final newTop = edges.top + (edges.top > 0 ? _maximizeGap : 0.0);
    final newRight = edges.right - (edges.right < vw ? _maximizeGap : 0.0);
    final newBottom = edges.bottom - (edges.bottom < vh ? _maximizeGap : 0.0);
    final newWidth = newRight - newLeft;
    final newHeight = newBottom - newTop;

    if (newWidth <= 0 || newHeight <= 0) return;

    final newRoot =
        (group.height - newHeight).abs() > _positionEpsilon ||
            (group.width - newWidth).abs() > _positionEpsilon
        ? _fixSplitRatiosForResize(
            group.root,
            Size(group.width, group.height),
            Size(newWidth, newHeight),
          )
        : group.root;

    final maxZ = _maxZOrder();
    _setState(
      DockState(
        groups: [
          for (final g in state.groups)
            if (g.id == groupId)
              g.copyWith(
                root: newRoot,
                anchorX: AnchorX.left,
                anchorY: AnchorY.top,
                offsetX: newLeft,
                offsetY: newTop,
                width: newWidth,
                height: newHeight,
                zOrder: maxZ + 1,
                savedState: saved,
              )
            else
              g,
        ],
        viewerSize: vs,
      ),
    );
  }

  /// 최대화 이전 크기·위치로 복귀.
  ///
  /// 최대화 전 엣지 도킹 상태였고 해당 엣지가 현재 비어있으면 엣지 도킹으로 복귀.
  void restoreGroup(String groupId) {
    final group = _findGroup(state.groups, groupId);
    if (group == null || group.savedState == null) return;

    final saved = group.savedState!;
    final vs = state.viewerSize;

    // 엣지 복귀 조건: 저장된 엣지가 있고 현재 해당 엣지에 다른 패널이 없는 경우
    if (saved.dockedEdge != null &&
        state.edgePanel(saved.dockedEdge!) == null) {
      // savedState 초기화 + 원래 width 복원 → dockToViewportEdge가 그 width 사용
      _setState(
        DockState(
          groups: _updateGroup(
            groupId,
            (g) => g.copyWith(width: saved.width, clearSavedState: true),
          ),
          viewerSize: vs,
        ),
      );
      dockToViewportEdge(groupId, saved.dockedEdge!);
      return;
    }

    // 일반 위치 복귀 (플로팅이었거나 해당 엣지에 다른 패널이 있는 경우)
    final newRoot =
        (group.height - saved.height).abs() > _positionEpsilon ||
            (group.width - saved.width).abs() > _positionEpsilon
        ? _fixSplitRatiosForResize(
            group.root,
            Size(group.width, group.height),
            Size(saved.width, saved.height),
          )
        : group.root;

    _setState(
      DockState(
        groups: _updateGroup(
          groupId,
          (g) => _clampToViewport(
            g.copyWith(
              root: newRoot,
              anchorX: AnchorX.left,
              anchorY: AnchorY.top,
              offsetX: saved.left,
              offsetY: saved.top,
              width: saved.width,
              height: saved.height,
              clearSavedState: true,
            ),
            vs,
          ),
        ),
        viewerSize: vs,
      ),
    );
  }

  /// 최대화 상태인 그룹을 새 뷰어 크기에 맞게 위치·크기 재계산.
  ///
  /// [updateViewerSize] 이후 호출.
  void _recomputeMaximizedGroups() {
    final maximized = state.groups.where((g) => g.savedState != null).toList();
    if (maximized.isEmpty) return;

    final vs = state.viewerSize;
    var groups = state.groups;

    for (final group in maximized) {
      final otherRects = Map.fromEntries(
        state.displayRects.entries.where((e) => e.key != group.id),
      );
      final edges = DockFreeRect.calcEdges(otherRects, vs);
      final vw = vs.width;
      final vh = vs.height;
      final newLeft = edges.left + (edges.left > 0 ? _maximizeGap : 0.0);
      final newTop = edges.top + (edges.top > 0 ? _maximizeGap : 0.0);
      final newRight = edges.right - (edges.right < vw ? _maximizeGap : 0.0);
      final newBottom = edges.bottom - (edges.bottom < vh ? _maximizeGap : 0.0);
      final newWidth = newRight - newLeft;
      final newHeight = newBottom - newTop;

      if (newWidth <= 0 || newHeight <= 0) continue;

      final newRoot =
          (group.height - newHeight).abs() > _positionEpsilon ||
              (group.width - newWidth).abs() > _positionEpsilon
          ? _fixSplitRatiosForResize(
              group.root,
              Size(group.width, group.height),
              Size(newWidth, newHeight),
            )
          : group.root;

      groups = [
        for (final g in groups)
          if (g.id == group.id)
            g.copyWith(
              root: newRoot,
              anchorX: AnchorX.left,
              anchorY: AnchorY.top,
              offsetX: newLeft,
              offsetY: newTop,
              width: newWidth,
              height: newHeight,
            )
          else
            g,
      ];
    }

    if (!identical(groups, state.groups)) {
      _setState(DockState(groups: groups, viewerSize: vs));
    }
  }

  /// 보더 스캔 대기 목록에서 특정 그룹을 제거.
  ///
  /// DockGroupWidget이 이펙트를 트리거한 뒤 호출.
  void clearScanPending(String groupId) {
    if (_scanPendingNodes.remove(groupId) == null) return;
    _setStateLight();
  }

  /// 보더 스캔 대기 목록에 노드를 추가하는 헬퍼.
  ///
  /// [entries]는 groupId → nodePath 매핑.
  /// 빈 리스트 경로는 그룹 전체를 의미.
  void _addScanPending(Map<String, List<int>> entries) {
    _scanPendingNodes.addAll(entries);
    _setStateLight();
  }

  /// 루트 FocusNode 등록 (HomeScreen initState에서 호출)
  void setRootFocusNode(FocusNode node) => _rootFocusNode = node;

  /// 특정 패널에 포커스 설정.
  ///
  /// 논리적 포커스(focusedPanelId)와 물리적 포커스(FocusNode)를
  /// 동시에 처리하여 키보드 입력이 항상 동작하도록 보장합니다.
  void focusPanel(String panelId, {bool flash = false}) {
    if (state.focusedPanelId != panelId || flash) {
      _setState(
        DockState(
          groups: state.groups,
          viewerSize: state.viewerSize,
          focusedPanelId: panelId,
          flashPanelId: flash ? panelId : null,
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

  /// 노드 rect의 중심에서 뷰포트 중심 대비 바깥 방향으로 분리 오프셋 계산.
  static const double _undockDistance = 10.0;

  static Offset _undockOffset(Rect nodeRect, Size viewerSize) {
    final vpCenter = Offset(viewerSize.width / 2, viewerSize.height / 2);
    final diff = nodeRect.center - vpCenter;
    if (diff.distance < 1.0) {
      // 뷰포트 정중앙이면 우측으로
      return const Offset(_undockDistance, 0);
    }
    final normalized = diff / diff.distance;
    return normalized * _undockDistance;
  }

  Rect _groupRect(DockGroup g) {
    // 엣지 패널: 실제 레이아웃 좌표로 변환
    if (g.dockedEdge != null) {
      final vs = state.viewerSize;
      return _edgeRect(g.dockedEdge!, g.width, vs);
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


  DockPreview? _detectDockTarget(
    DockGroup dragging,
    List<DockGroup> groups,
    Offset? cursorPosition,
  ) {
    final dragRect = _groupRect(dragging);
    final anchor = cursorPosition ?? dragRect.topLeft;
    final allowH = ref.read(dockSettingsProvider).allowHorizontalPanelDock;

    DockPreview? best;
    double bestDist = double.infinity;

    for (final target in groups) {
      if (target.id == dragging.id) continue;

      final targetRect = _groupRect(target);

      // 커서가 타겟 안에 있으면 → 내부 노드 단위 도킹 감지
      if (targetRect.contains(anchor)) {
        final nodeRects = calcNodeRects(target.root, targetRect, const []);
        for (final nr in nodeRects) {
          if (!nr.rect.contains(anchor)) continue;
          final inner = nr.rect.deflate(_dockDetectDistance);
          // 노드 중심 → 탭 도킹
          if (inner.width > 0 && inner.height > 0 && inner.contains(anchor)) {
            return DockPreview(
              targetGroupId: target.id,
              edge: DockEdge.center,
              highlightRect: nr.rect,
              nodePath: nr.path,
            );
          }
          // 노드 외곽 → 엣지 도킹
          final edge = _nearestEdge(anchor, nr.rect, allowH);
          if (edge != null) {
            return DockPreview(
              targetGroupId: target.id,
              edge: edge,
              highlightRect: _calcHighlightRect(nr.rect, edge),
              nodePath: nr.path,
            );
          }
        }
        continue;
      }

      // 커서가 밖에 있으면 → 기존 rect 겹침 기반 엣지 도킹
      if (dragRect.intersect(targetRect).isEmpty) continue;

      final edges = <DockEdge, double>{
        if (allowH) DockEdge.left: (dragRect.right - targetRect.left).abs(),
        if (allowH) DockEdge.right: (dragRect.left - targetRect.right).abs(),
        DockEdge.top: (dragRect.bottom - targetRect.top).abs(),
        DockEdge.bottom: (dragRect.top - targetRect.bottom).abs(),
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

  /// 커서에서 가장 가까운 엣지 방향 반환.
  static DockEdge? _nearestEdge(Offset cursor, Rect rect, bool allowH) {
    final distances = <DockEdge, double>{
      if (allowH) DockEdge.left: (cursor.dx - rect.left).abs(),
      if (allowH) DockEdge.right: (rect.right - cursor.dx).abs(),
      DockEdge.top: (cursor.dy - rect.top).abs(),
      DockEdge.bottom: (rect.bottom - cursor.dy).abs(),
    };
    DockEdge? nearest;
    double best = double.infinity;
    for (final e in distances.entries) {
      if (e.value < best) {
        best = e.value;
        nearest = e.key;
      }
    }
    return nearest;
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
        groups: _replaceGroup(groupId, docked),
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
        groups: _replaceGroup(groupId, floating),
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

    // 너비가 변경되면 내부 horizontal split에서 가장 큰 패널만 유동 리사이즈.
    // 미호출 시 horizontal split 자식들이 비율 리사이즈됨.
    final vh = state.viewerSize.height;
    final root = (group.width - clamped).abs() > _positionEpsilon
        ? _fixSplitRatiosForResize(
            group.root,
            Size(group.width, vh),
            Size(clamped, vh),
          )
        : group.root;

    final updated = group.copyWith(width: clamped, root: root);

    _setState(
      DockState(
        groups: _replaceGroup(groupId, updated),
        viewerSize: state.viewerSize,
      ),
    );

    _scheduleSave();
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

  // ── 노드 트리 조작 (dock_node_tree.dart로 분리된 함수 사용) ──

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

    final newRoot = replaceNodeAt(group.root, nodePath, newNode);
    final updatedGroup = group.copyWith(
      root: newRoot,
      headerless: _resolveHeaderless(newRoot),
    );

    final maxZ = _maxZOrder();
    final vs = state.viewerSize;

    // 탭 노드의 실제 rect 계산 (Split 내부일 경우 그룹 전체가 아닌 노드 크기 사용)
    final groupRect = _groupRect(group);
    final nodeRects = calcNodeRects(group.root, groupRect, []);
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
      final offset = _undockOffset(nodeRect, vs);
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
      headerless: _resolveHeaderless(DockLeaf(panelId: removedId)),
    ).updateFromAbsolute(absX, absY, vs.width, vs.height);

    _setState(
      DockState(
        groups: [..._replaceGroup(sourceGroupId, updatedGroup), newGroup],
        viewerSize: state.viewerSize,
      ),
    );
    _addScanPending({newGroupId: const []});
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
    // 부모가 내부 노드이면 실제 부모 rect 계산, 루트이면 그룹 rect 사용
    final parentRect = parentPath.isEmpty
        ? groupRect
        : calcNodeRectAt(group.root, groupRect, parentPath);
    final childRects = calcDirectChildRects(parent, parentRect);

    final removedNode = parent.children[childIndex];
    final newParent = removeChildAt(parent, childIndex);
    final newRoot = replaceNodeAt(group.root, parentPath, newParent);

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
      final offset = _undockOffset(removedRect, vs);
      absX = removedRect.left + offset.dx;
      absY = removedRect.top + offset.dy;
    }
    final newGroupId = 'group_${_nextGroupId++}';
    final newGroup = DockGroup(
      id: newGroupId,
      root: removedNode,
      offsetX: absX,
      offsetY: absY,
      width: removedRect.width,
      height: removedRect.height,
      zOrder: maxZ + 1,
      headerless: _resolveHeaderless(removedNode),
    ).updateFromAbsolute(absX, absY, vs.width, vs.height);

    // 남는 그룹 갱신:
    // - 루트 직속 자식 분리 → 남는 영역으로 크기 축소
    // - 내부 노드 분리 → 그룹 크기 유지 (내부 레이아웃만 재배치)
    final DockGroup updatedGroup;
    if (parentPath.isEmpty) {
      final remainingRect = calcRemainingRect(parent, groupRect, childIndex);
      updatedGroup = group
          .copyWith(
            root: newRoot,
            width: remainingRect.width,
            height: remainingRect.height,
            headerless: _resolveHeaderless(newRoot),
          )
          .updateFromAbsolute(
            remainingRect.left,
            remainingRect.top,
            vs.width,
            vs.height,
          );
    } else {
      updatedGroup = group.copyWith(
        root: newRoot,
        headerless: _resolveHeaderless(newRoot),
      );
    }

    _setState(
      DockState(
        groups: [..._replaceGroup(sourceGroupId, updatedGroup), newGroup],
        viewerSize: state.viewerSize,
      ),
    );
    _addScanPending({newGroupId: const []});
    _onLayoutChanged();
    return newGroupId;
  }


  // ── 도킹 실행 ──

  /// 엣지 도킹: 타겟 그룹(또는 내부 노드)에 Split으로 합침.
  ///
  /// [nodePath]가 비어있으면 그룹 루트에 도킹 (그룹 크기 확장),
  /// 비어있지 않으면 해당 내부 노드에 도킹 (그룹 크기 유지, 내부 분할).
  void _performEdgeDock(
    String sourceId,
    String targetId,
    DockEdge edge,
    List<int> nodePath,
  ) {
    final source = _findGroup(state.groups, sourceId);
    final target = _findGroup(state.groups, targetId);
    if (source == null || target == null) return;
    _rememberAloneSize(source);
    final vs = state.viewerSize;

    final axis = (edge == DockEdge.left || edge == DockEdge.right)
        ? SplitAxis.horizontal
        : SplitAxis.vertical;
    final sourceFirst = (edge == DockEdge.left || edge == DockEdge.top);

    // ── 내부 노드 도킹: 그룹 크기 유지, 내부에서만 Split ──
    if (nodePath.isNotEmpty) {
      final targetNode = getNodeAt(target.root, nodePath);

      // 실제 크기 기반 비율 계산 (하드코딩 0.5/0.5 제거)
      final srcRect = _groupRect(source);
      final tgtGroupRect = _groupRect(target);
      final tgtNodeRect = calcNodeRectAt(target.root, tgtGroupRect, nodePath);
      final srcSize = axis == SplitAxis.horizontal
          ? srcRect.width : srcRect.height;
      final tgtSize = axis == SplitAxis.horizontal
          ? tgtNodeRect.width : tgtNodeRect.height;
      final totalSize = srcSize + tgtSize;
      final srcRatio = totalSize > 0 ? srcSize / totalSize : 0.5;

      final newSplit = DockSplit(
        axis: axis,
        children: sourceFirst
            ? [source.root, targetNode]
            : [targetNode, source.root],
        ratios: sourceFirst
            ? [srcRatio, 1.0 - srcRatio]
            : [1.0 - srcRatio, srcRatio],
      );
      final newRoot = replaceNodeAt(target.root, nodePath, newSplit);
      final mergedGroup = _clampToViewport(
        target.copyWith(root: newRoot, headerless: false),
        vs,
      );
      _setState(DockState(
        groups: _replaceAndRemoveGroup(targetId, mergedGroup, sourceId),
        viewerSize: vs,
      ));
      _addScanPending({
        targetId: [...nodePath, sourceFirst ? 0 : 1],
      });
      _onLayoutChanged();
      return;
    }

    // ── 그룹 루트 도킹: 그룹 크기 확장 ──
    final srcRect = _groupRect(source);
    final tgtRect = _groupRect(target);

    // 타겟 root가 같은 축의 Split이면 플랫하게 자식 추가
    final DockSplit mergedSplit;
    final List<int> sourceNodePath; // 합쳐진 후 소스 노드의 경로
    if (target.root is DockSplit && (target.root as DockSplit).axis == axis) {
      final existing = target.root as DockSplit;
      final srcSize = axis == SplitAxis.horizontal
          ? srcRect.width : srcRect.height;
      final tgtSize = axis == SplitAxis.horizontal
          ? tgtRect.width : tgtRect.height;
      final totalSize = tgtSize + srcSize;
      final srcRatio = srcSize / totalSize;
      final scale = tgtSize / totalSize;
      final scaledRatios = [for (final r in existing.ratios) r * scale];
      mergedSplit = DockSplit(
        axis: axis,
        children: sourceFirst
            ? [source.root, ...existing.children]
            : [...existing.children, source.root],
        ratios: sourceFirst
            ? [srcRatio, ...scaledRatios]
            : [...scaledRatios, srcRatio],
      );
      sourceNodePath = [sourceFirst ? 0 : existing.children.length];
    } else {
      final srcSize = axis == SplitAxis.horizontal
          ? srcRect.width : srcRect.height;
      final tgtSize = axis == SplitAxis.horizontal
          ? tgtRect.width : tgtRect.height;
      final totalSize = srcSize + tgtSize;
      final srcRatio = srcSize / totalSize;
      mergedSplit = DockSplit(
        axis: axis,
        children: sourceFirst
            ? [source.root, target.root]
            : [target.root, source.root],
        ratios: sourceFirst
            ? [srcRatio, 1.0 - srcRatio]
            : [1.0 - srcRatio, srcRatio],
      );
      sourceNodePath = [sourceFirst ? 0 : 1];
    }

    // 엣지 패널 타겟: 위치 유지, dockedEdge 보존
    // horizontal dock은 너비가 확장되어야 원래 패널 크기를 보존 (vertical은
    // 높이=viewport 고정이므로 유지).
    if (target.dockedEdge != null) {
      final newWidth = axis == SplitAxis.horizontal
          ? srcRect.width + tgtRect.width
          : target.width;
      final mergedGroup = _clampToViewport(
        target.copyWith(
          root: mergedSplit,
          width: newWidth,
          headerless: false,
        ),
        vs,
      );

      _setState(
        DockState(
          groups: _replaceAndRemoveGroup(targetId, mergedGroup, sourceId),
          viewerSize: vs,
        ),
      );
      _addScanPending({targetId: sourceNodePath});
      _onLayoutChanged();
      return;
    }

    final double mergedLeft;
    final double mergedTop;
    final double mergedWidth;
    final double mergedHeight;

    if (axis == SplitAxis.horizontal) {
      mergedWidth = srcRect.width + tgtRect.width;
      mergedHeight = math.max(srcRect.height, tgtRect.height);
      mergedTop = math.min(srcRect.top, tgtRect.top);
      mergedLeft = sourceFirst ? tgtRect.left - srcRect.width : tgtRect.left;
    } else {
      mergedHeight = srcRect.height + tgtRect.height;
      mergedWidth = math.max(srcRect.width, tgtRect.width);
      mergedLeft = math.min(srcRect.left, tgtRect.left);
      mergedTop = sourceFirst ? tgtRect.top - srcRect.height : tgtRect.top;
    }

    final mergedGroup = _clampToViewport(
      target
          .copyWith(
            root: mergedSplit,
            width: mergedWidth,
            height: mergedHeight,
            headerless: false,
          )
          .updateFromAbsolute(mergedLeft, mergedTop, vs.width, vs.height),
      vs,
    );

    _setState(
      DockState(
        groups: _replaceAndRemoveGroup(targetId, mergedGroup, sourceId),
        viewerSize: vs,
      ),
    );
    _addScanPending({targetId: sourceNodePath});
  }

  /// 탭 도킹: 타겟 그룹 내 특정 노드에 탭으로 합침.
  void _performTabDock(String sourceId, String targetId, List<int> nodePath) {
    final source = _findGroup(state.groups, sourceId);
    final target = _findGroup(state.groups, targetId);
    if (source == null || target == null) return;
    _rememberAloneSize(source);

    final sourceIds = source.root.collectPanelIds();
    final targetNode = getNodeAt(target.root, nodePath);
    final targetIds = targetNode.collectPanelIds();
    final allIds = [...targetIds, ...sourceIds];

    final newTabbed = DockTabbed(tabIds: allIds, activeIndex: targetIds.length);

    final newRoot = replaceNodeAt(target.root, nodePath, newTabbed);
    // 탭이 합쳐지면 헤더리스 해제 + 뷰포트 클램핑
    final mergedGroup = _clampToViewport(
      target.copyWith(root: newRoot, headerless: false),
      state.viewerSize,
    );

    _setState(
      DockState(
        groups: _replaceAndRemoveGroup(targetId, mergedGroup, sourceId),
        viewerSize: state.viewerSize,
      ),
    );
    _addScanPending({targetId: nodePath});
  }

  // ── 패널 접기/펼치기 ──

  /// 접힌 패널의 높이: 상단 여백 + 탭 바 + 하단 여백.
  double get _collapsedNodeHeight =>
      _config.groupHeaderHeight * 2 + _config.tabBarHeight;

  /// 패널 노드의 접힘 상태를 토글.
  ///
  /// 플로팅 그룹: 접힌 만큼 그룹 높이가 줄어들고, 펼치면 복원.
  /// 엣지 패널: 여유 공간을 가장 큰 패널이 흡수 (기존 리사이즈 로직과 동일).
  void toggleCollapse(
    String groupId, {
    required List<int> nodePath,
  }) {
    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final vs = state.viewerSize;

    final node = getNodeAt(group.root, nodePath);
    final isEdge = group.dockedEdge != null;

    // Leaf → Tabbed 변환 (접기 상태를 저장하기 위해)
    final DockTabbed tabbed;
    if (node is DockTabbed) {
      tabbed = node;
    } else if (node is DockLeaf) {
      tabbed = DockTabbed(tabIds: [node.panelId]);
    } else {
      return; // Split 노드는 접기 불가
    }

    final nowCollapsing = !tabbed.collapsed;
    final collapsedH = _collapsedNodeHeight;

    if (isEdge) {
      // ── 엣지 패널: 그룹 높이 고정, Split ratios 조정 ──
      _toggleCollapseEdge(
        group, nodePath, tabbed, nowCollapsing, collapsedH, vs,
      );
    } else {
      // ── 플로팅 그룹: 그룹 높이 변동 ──
      _toggleCollapseFloating(
        group, nodePath, tabbed, nowCollapsing, collapsedH, vs,
      );
    }
    _onLayoutChanged();
  }

  /// 플로팅 그룹의 접기/펼치기.
  void _toggleCollapseFloating(
    DockGroup group,
    List<int> nodePath,
    DockTabbed tabbed,
    bool collapsing,
    double collapsedH,
    Size vs,
  ) {
    final groupRect = state.displayRects[group.id] ??
        Rect.fromLTWH(
          group.absoluteX(vs.width),
          group.absoluteY(vs.height),
          group.width,
          group.height,
        );

    if (nodePath.isEmpty) {
      // 루트 노드가 직접 Tabbed인 경우
      final DockNode newNode;
      final double newHeight;
      if (collapsing) {
        newNode = tabbed.copyWith(collapsed: true, expandedHeight: groupRect.height);
        newHeight = collapsedH;
      } else {
        newNode = tabbed.copyWith(collapsed: false, clearExpandedHeight: true);
        newHeight = tabbed.expandedHeight ?? groupRect.height;
      }
      var updated = group
          .copyWith(root: newNode, height: newHeight)
          .updateFromAbsolute(
            groupRect.left,
            groupRect.top,
            vs.width,
            vs.height,
          );
      // 펼친 후 뷰포트 밖으로 벗어나��� 안쪽으로 클램핑
      if (!collapsing) updated = _clampToViewport(updated, vs);
      _setState(DockState(
        groups: _replaceGroup(group.id, updated),
        viewerSize: vs,
      ));
      return;
    }

    // Split 내부의 노드인 경우
    // 세로 Split의 자식이면 그룹 높이도 변동
    final parentPath = nodePath.sublist(0, nodePath.length - 1);
    final parent = getNodeAt(group.root, parentPath);
    final childIndex = nodePath.last;

    // 노드의 현재 픽셀 높이 계산 (세퍼레이터 공간 제외)
    final double nodePixelH;
    if (parent is DockSplit && parent.axis == SplitAxis.vertical) {
      final sepSpace = (parent.children.length - 1) * _config.splitSeparatorThickness;
      nodePixelH = (groupRect.height - sepSpace) * parent.ratios[childIndex];
    } else {
      nodePixelH = groupRect.height;
    }

    final newTabbed = collapsing
        ? tabbed.copyWith(collapsed: true, expandedHeight: nodePixelH)
        : tabbed.copyWith(collapsed: false, clearExpandedHeight: true);

    var newRoot = replaceNodeAt(group.root, nodePath, newTabbed);

    // 세로 Split 안이면 ratios 재계산 + 그룹 높이 변동
    if (parent is DockSplit && parent.axis == SplitAxis.vertical) {
      // 세퍼레이터는 Flex 레이아웃에서 고정 공간을 차지하므로 별도 계산
      final separatorSpace = (parent.children.length - 1) * _config.splitSeparatorThickness;
      final contentH = groupRect.height - separatorSpace;
      // 자식별 절대 높이 계산: 접힌 형제는 collapsedH 고정, 나머지는 현재 크기 유지
      final sizes = <double>[];
      for (int i = 0; i < parent.ratios.length; i++) {
        if (i == childIndex) {
          sizes.add(collapsing ? collapsedH : (tabbed.expandedHeight ?? contentH * parent.ratios[i]));
        } else {
          final sibling = parent.children[i];
          if (sibling.isCollapsed) {
            sizes.add(collapsedH);
          } else {
            sizes.add(contentH * parent.ratios[i]);
          }
        }
      }
      final newGroupH = sizes.fold(0.0, (a, b) => a + b) + separatorSpace;
      final newRatios = _ratiosFromSizes(sizes);
      final newSplit = DockSplit(
        axis: parent.axis,
        children: [
          for (int i = 0; i < parent.children.length; i++)
            i == childIndex ? newTabbed : parent.children[i],
        ],
        ratios: newRatios,
      );
      newRoot = replaceNodeAt(group.root, parentPath, newSplit);

      var updated = group
          .copyWith(root: newRoot, height: newGroupH)
          .updateFromAbsolute(
            groupRect.left,
            groupRect.top,
            vs.width,
            vs.height,
          );
      if (!collapsing) updated = _clampToViewport(updated, vs);
      _setState(DockState(
        groups: _replaceGroup(group.id, updated),
        viewerSize: vs,
      ));
    } else {
      // 가로 Split 또는 깊은 구조: 노드만 교체 (높이 변동 없음)
      final updated = group.copyWith(root: newRoot);
      _setState(DockState(
        groups: _replaceGroup(group.id, updated),
        viewerSize: vs,
      ));
    }
  }

  /// 엣지 패널의 접기/펼치기.
  ///
  /// 그룹 높이는 뷰포트 높이로 고정. 여유 공간을 가장 큰 패널이 흡수.
  void _toggleCollapseEdge(
    DockGroup group,
    List<int> nodePath,
    DockTabbed tabbed,
    bool collapsing,
    double collapsedH,
    Size vs,
  ) {
    final groupH = vs.height;

    // 엣지 패널 접기 — 노드만 교체하는 공통 헬퍼
    DockTabbed makeCollapsed(double? storedH) => collapsing
        ? tabbed.copyWith(collapsed: true, expandedHeight: storedH)
        : tabbed.copyWith(collapsed: false, clearExpandedHeight: true);

    if (nodePath.isEmpty) {
      // 엣지 패널의 루트 노드 — 접기만 표시 (높이 변동 없음)
      _setState(DockState(
        groups: _updateGroup(
          group.id,
          (g) => g.copyWith(root: makeCollapsed(groupH)),
        ),
        viewerSize: vs,
      ));
      return;
    }

    // Split 내부
    final parentPath = nodePath.sublist(0, nodePath.length - 1);
    final parent = getNodeAt(group.root, parentPath);
    final childIndex = nodePath.last;

    if (parent is! DockSplit || parent.axis != SplitAxis.vertical) {
      // 가로 Split: 노드만 교체
      final newRoot = replaceNodeAt(group.root, nodePath, makeCollapsed(groupH));
      _setState(DockState(
        groups: _updateGroup(group.id, (g) => g.copyWith(root: newRoot)),
        viewerSize: vs,
      ));
      return;
    }

    // 세로 Split: 가장 큰 패널이 여유 공간 흡수
    final nodePixelH = groupH * parent.ratios[childIndex];
    final targetH = collapsing ? collapsedH : (tabbed.expandedHeight ?? nodePixelH);
    final newTabbed = makeCollapsed(nodePixelH);

    // 절대 크기 계산 → 대상 변경 → 가장 큰 비접힌 패널이 delta 흡수
    final sizes = [
      for (int i = 0; i < parent.ratios.length; i++)
        groupH * parent.ratios[i],
    ];
    final delta = sizes[childIndex] - targetH;
    sizes[childIndex] = targetH;

    // 가장 큰 비접힌 자식 찾기
    int largestIdx = -1;
    double largestSize = 0;
    for (int i = 0; i < parent.children.length; i++) {
      if (i == childIndex) continue;
      final child = parent.children[i];
      final isChildCollapsed = child.isCollapsed;
      if (!isChildCollapsed && sizes[i] > largestSize) {
        largestSize = sizes[i];
        largestIdx = i;
      }
    }
    if (largestIdx == -1) largestIdx = childIndex == 0 ? 1 : 0;

    sizes[largestIdx] = (sizes[largestIdx] + delta)
        .clamp(_config.groupMinHeight, double.infinity);

    final newRatios = _ratiosFromSizes(sizes);

    final newSplit = DockSplit(
      axis: parent.axis,
      children: [
        for (int i = 0; i < parent.children.length; i++)
          i == childIndex ? newTabbed : parent.children[i],
      ],
      ratios: newRatios,
    );
    final newRoot = replaceNodeAt(group.root, parentPath, newSplit);
    _setState(DockState(
      groups: _updateGroup(group.id, (g) => g.copyWith(root: newRoot)),
      viewerSize: vs,
    ));
  }

  /// 그룹의 핀 고정 상태를 토글.
  void togglePin(String groupId) {
    final group = _findGroup(state.groups, groupId);
    if (group == null) return;
    final updated = group.copyWith(pinned: !group.pinned);
    _setState(
      DockState(
        groups: _replaceGroup(groupId, updated),
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  // ── 패널 토글 ──

  /// 패널이 단독 그룹이었을 때의 마지막 크기 (복원용, 영속 저장).
  final Map<String, Size> _lastPanelAloneSizes = {};

  /// 그룹이 단독 패널 1개만 포함할 때 크기를 기억.
  ///
  /// 탭/스플릿 도킹, 패널 닫기 등으로 그룹이 흡수·제거될 때 호출.
  /// 복수 패널 그룹은 개별 패널 크기로 분리할 수 없으므로 저장하지 않음.
  void _rememberAloneSize(DockGroup group) {
    final ids = group.root.collectPanelIds();
    if (ids.length == 1) {
      _lastPanelAloneSizes[ids.first] = Size(group.width, group.height);
    }
  }

  /// 패널 표시/숨김 토글.
  ///
  /// 패널이 트리에 존재하면 해당 탭(또는 그룹)을 제거하고,
  /// 없으면 독립 그룹으로 새로 생성한다.
  /// 제거 시 그룹 크기를 기억(영속 저장)하여 복원 시 동일 크기로 생성.
  void togglePanel(String panelId) {
    final ownerGroup = _findGroupContaining(panelId);

    if (ownerGroup != null) {
      _rememberAloneSize(ownerGroup);
      _removePanelFromGroup(ownerGroup, panelId);
    } else {
      _addPanelAsNewGroup(panelId);
    }
    _onLayoutChanged();
  }

  /// 패널이 현재 레이아웃에 존재하는지 확인.
  bool hasPanel(String panelId) => _findGroupContaining(panelId) != null;

  DockGroup? _findGroupContaining(String panelId) {
    for (final g in state.groups) {
      if (g.root.collectPanelIds().contains(panelId)) return g;
    }
    return null;
  }

  void _removePanelFromGroup(DockGroup group, String panelId) {
    final newRoot = _removePanel(group.root, panelId);

    // 루트 자체가 제거 대상 → 그룹 삭제
    if (newRoot == null) {
      _setState(DockState(
        groups: _removeGroup(group.id),
        viewerSize: state.viewerSize,
      ));
      return;
    }

    _setState(DockState(
      groups: _updateGroup(
        group.id,
        (g) => g.copyWith(
          root: newRoot,
          headerless: _resolveHeaderless(newRoot),
        ),
      ),
      viewerSize: state.viewerSize,
    ));
  }

  /// 트리에서 panelId를 재귀적으로 제거. null이면 노드 전체 삭제.
  DockNode? _removePanel(DockNode node, String panelId) {
    switch (node) {
      case DockLeaf() when node.panelId == panelId:
        return null;

      case DockTabbed(:final tabIds, :final activeIndex, :final collapsed, :final expandedHeight):
        final newTabIds = tabIds.where((id) => id != panelId).toList();
        if (newTabIds.length == tabIds.length) return node; // 미포함
        if (newTabIds.isEmpty) return null;
        if (newTabIds.length == 1) return DockLeaf(panelId: newTabIds.first);
        final newIndex = activeIndex >= newTabIds.length
            ? newTabIds.length - 1
            : activeIndex;
        return DockTabbed(
          tabIds: newTabIds,
          activeIndex: newIndex,
          collapsed: collapsed,
          expandedHeight: expandedHeight,
        );

      case DockSplit(:final axis, :final children, :final ratios):
        final newChildren = <DockNode>[];
        final newRatios = <double>[];
        var changed = false;
        for (int i = 0; i < children.length; i++) {
          final child = _removePanel(children[i], panelId);
          if (child == null) {
            changed = true;
          } else {
            if (child != children[i]) changed = true;
            newChildren.add(child);
            newRatios.add(ratios[i]);
          }
        }
        if (!changed) return node; // 미포함
        if (newChildren.isEmpty) return null;
        if (newChildren.length == 1) return newChildren.first;
        // 비율 재정규화
        final sum = newRatios.fold<double>(0, (a, b) => a + b);
        final normalized = sum > 1e-6
            ? [for (final r in newRatios) r / sum]
            : List.filled(newRatios.length, 1.0 / newRatios.length);
        return DockSplit(axis: axis, children: newChildren, ratios: normalized);

      default:
        return node;
    }
  }

  /// 독립 플로팅 그룹으로 패널을 새로 생성.
  static const double _defaultPanelWidth = 280.0;
  static const double _defaultPanelHeight = 200.0;

  void _addPanelAsNewGroup(String panelId) {
    final lastSize = _lastPanelAloneSizes[panelId];
    final w = lastSize?.width ?? _defaultPanelWidth;
    final h = lastSize?.height ?? _defaultPanelHeight;
    final vs = state.viewerSize;

    // 우측 점유 너비(엣지 + 우측 앵커 패널)를 회피한 X 좌표 계산
    final rightUsed = state.rightOccupiedWidth;
    final absX = (vs.width - rightUsed - w - _displayGap)
        .clamp(_displayGap, vs.width - w);

    final absY = _findNonOverlappingY(
      x: absX,
      width: w,
      height: h,
      startY: _displayGap,
      viewerSize: vs,
    );

    final newGroup = DockGroup(
      id: 'group_${_nextGroupId++}',
      root: DockLeaf(panelId: panelId),
      offsetX: absX,
      offsetY: absY,
      width: w,
      height: h,
      zOrder: _maxZOrder() + 1,
      headerless: _resolveHeaderless(DockLeaf(panelId: panelId)),
    ).updateFromAbsolute(absX, absY, vs.width, vs.height);
    _setState(DockState(
      groups: [...state.groups, newGroup],
      viewerSize: state.viewerSize,
      focusedPanelId: panelId,
    ));
  }

  /// 주어진 X 위치에서 기존 패널과 겹치지 않는 Y 좌표를 찾는다.
  ///
  /// [startY]부터 시작하여, 겹치는 패널이 있으면 그 아래로 밀어낸다.
  /// 뷰포트를 벗어나면 startY로 폴백.
  double _findNonOverlappingY({
    required double x,
    required double width,
    required double height,
    required double startY,
    required Size viewerSize,
  }) {
    var y = startY;
    final rects = state.displayRects;

    // 최대 패널 수만큼 반복 (무한 루프 방지)
    for (var i = 0; i < state.groups.length; i++) {
      var overlapped = false;
      for (final group in state.groups) {
        final oRect = rects[group.id] ?? _groupRect(group);
        // X축 겹침 확인
        if (x >= oRect.right || x + width <= oRect.left) continue;
        // Y축 겹침 확인
        if (y >= oRect.bottom || y + height <= oRect.top) continue;
        // 겹침 발견 — 해당 패널 아래로 밀어냄
        y = oRect.bottom + _displayGap;
        overlapped = true;
        break;
      }
      if (!overlapped) break;
    }

    // 뷰포트 하단을 벗어나면 startY로 폴백
    if (y + height > viewerSize.height) y = startY;
    return y;
  }

  /// 노드 내 패널이 1개이고 헤더리스 대상이면 true.
  ///
  /// undockTab, undockNode, togglePanel에서 공통 사용.
  bool _resolveHeaderless(DockNode root) {
    final ids = root.collectPanelIds();
    return ids.length == 1 &&
        ref.read(dockSettingsProvider).isHeaderless(ids.first);
  }

  /// 그룹을 독 시스템에서 제거.
  ///
  /// 그룹 내 패널이 단독이면 마지막 크기를 기억하여 togglePanel 복원 시 참조.
  void removeGroup(String groupId) {
    final group = _findGroup(state.groups, groupId);
    if (group != null) {
      _rememberAloneSize(group);
    }
    _setState(
      DockState(
        groups: _removeGroup(groupId),
        viewerSize: state.viewerSize,
      ),
    );
    _onLayoutChanged();
  }

  /// 그룹을 뷰포트 안쪽으로 클램핑.
  ///
  /// 도킹/합치기 후 패널이 뷰포트 밖으로 벗어나는 경우 안전하게 밀어넣음.
  ///
  /// **위치 조정 우선** 정책:
  /// 크기를 줄이기 전에 위치를 이동시켜 원래 크기를 최대한 보존한다.
  /// 뷰포트보다 큰 경우에만 크기를 축소하며, Split 비율도 함께 보정한다.
  DockGroup _clampToViewport(DockGroup group, Size vs) {
    // 1. 크기 제한: 뷰포트보다 큰 경우에만 축소 (최솟값 보장)
    final targetW = group.width > vs.width
        ? vs.width.clamp(_config.groupMinWidth, double.infinity)
        : group.width;
    final targetH = group.height > vs.height
        ? vs.height.clamp(_config.groupMinHeight, double.infinity)
        : group.height;

    // 2. 절대 위치 계산 후 위치 보정으로 뷰포트 내 맞추기 (크기 변경보다 우선)
    var x = group.absoluteX(vs.width);
    var y = group.absoluteY(vs.height);

    if (x < 0) x = 0;
    if (x + targetW > vs.width) x = vs.width - targetW;
    if (x < 0) x = 0; // targetW == vs.width 엣지 케이스

    if (y < 0) y = 0;
    if (y + targetH > vs.height) y = vs.height - targetH;
    if (y < 0) y = 0; // targetH == vs.height 엣지 케이스

    // 3. 크기가 변경된 경우 Split 비율 보정 (작은 패널 픽셀 크기 유지)
    final DockNode newRoot;
    if ((group.height - targetH).abs() > _positionEpsilon ||
        (group.width - targetW).abs() > _positionEpsilon) {
      newRoot = _fixSplitRatiosForResize(
        group.root,
        Size(group.width, group.height),
        Size(targetW, targetH),
      );
    } else {
      newRoot = group.root;
    }

    return group
        .copyWith(root: newRoot, width: targetW, height: targetH)
        .updateFromAbsolute(x, y, vs.width, vs.height);
  }

}

final dockProvider = NotifierProvider<DockNotifier, DockState>(
  DockNotifier.new,
);
