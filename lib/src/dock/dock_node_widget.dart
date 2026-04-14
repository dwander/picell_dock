import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/dock_group.dart';
import '../models/dock_node.dart';
import '../providers/dock_node_tree.dart';
import '../providers/dock_provider.dart';
import '../providers/dock_settings_provider.dart';
import '../config/dock_panel_delegate.dart';
import '../theme/dock_color_scheme.dart';
import '../theme/dock_theme.dart';
import 'dock_drag_mixin.dart';

part 'dock_tab_bar.dart';
part 'dock_headerless_frame.dart';

/// 그룹 드래그에 필요한 컨텍스트 정보.
class DockDragContext {
  final String groupId;
  final Size viewerSize;
  final GlobalKey stackKey;

  const DockDragContext({
    required this.groupId,
    required this.viewerSize,
    required this.stackKey,
  });

  /// Stack 위젯의 글로벌 좌표 원점.
  Offset get stackOrigin {
    final renderBox = stackKey.currentContext?.findRenderObject() as RenderBox?;
    return renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
  }
}

/// DockNode 트리를 재귀적으로 렌더링하는 위젯.
///
/// sealed class의 switch 패턴 매칭으로 Leaf/Split/Tabbed를 처리.
/// 패널 헤더와 탭 바가 그룹 드래그 핸들 역할.
class DockNodeWidget extends ConsumerWidget {
  final DockNode node;
  final DockDragContext? dragContext;

  /// 이 노드의 트리 내 경로 (Split 세퍼레이터 리사이즈에 사용).
  final List<int> nodePath;

  const DockNodeWidget({
    super.key,
    required this.node,
    this.dragContext,
    this.nodePath = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (node) {
      DockLeaf(:final panelId) => _buildLeaf(panelId, ref),
      DockSplit(:final axis, :final children, :final ratios) => _buildSplit(
        context,
        axis,
        children,
        ratios,
      ),
      DockTabbed(:final tabIds, :final activeIndex, :final collapsed) =>
        _buildTabbed(tabIds, activeIndex, ref, collapsed: collapsed),
    };
  }

  Widget _buildLeaf(String panelId, WidgetRef ref) {
    final isHeaderless =
        ref.watch(dockSettingsProvider.select((s) => s.isHeaderless(panelId)));
    if (isHeaderless) {
      return _HeaderlessFrame(
        panelId: panelId,
        dragContext: dragContext,
        nodePath: nodePath,
      );
    }
    // Leaf를 탭 1개짜리 Tabbed와 동일하게 렌더링 → 디자인 + UX 통일
    return _buildTabbed([panelId], 0, ref);
  }

  void _focusPanel(WidgetRef ref, String panelId) {
    final dc = dragContext;
    if (dc != null) {
      ref.read(dockProvider.notifier).bringToFront(dc.groupId);
    }
    ref.read(dockProvider.notifier).focusPanel(panelId);
  }

  Widget _buildSplit(
    BuildContext context,
    SplitAxis axis,
    List<DockNode> children,
    List<double> ratios,
  ) {
    final direction = axis == SplitAxis.horizontal
        ? Axis.horizontal
        : Axis.vertical;
    final isVertical = axis == SplitAxis.vertical;
    final collapsedH = isVertical
        ? DockTheme.of(context).config.groupHeaderHeight * 2 +
            DockTheme.of(context).config.tabBarHeight
        : 0.0;

    return Flex(
      direction: direction,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0)
            _DraggableSplitSeparator(
              axis: axis,
              separatorIndex: i - 1,
              splitPath: nodePath,
              dragContext: dragContext,
            ),
          // 세로 Split에서 접힌 자식은 고정 픽셀 크기 (Flexible 비율 떨림 방지)
          if (isVertical && children[i].isCollapsed)
            SizedBox(
              height: collapsedH,
              child: DockNodeWidget(
                node: children[i],
                dragContext: dragContext,
                nodePath: [...nodePath, i],
              ),
            )
          else
            Flexible(
              flex: (ratios[i] * 1000).round(),
              child: DockNodeWidget(
                node: children[i],
                dragContext: dragContext,
                nodePath: [...nodePath, i],
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildTabbed(
    List<String> tabIds,
    int activeIndex,
    WidgetRef ref, {
    bool collapsed = false,
  }) {
    final activePanelId = tabIds[activeIndex];
    return Listener(
      onPointerDown: (_) => _focusPanel(ref, activePanelId),
      behavior: HitTestBehavior.translucent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cfg = DockTheme.of(context).config;

          if (collapsed) {
            // 접힌 상태: 탭 바 + 하단 여백만 표시
            return Column(
              children: [
                _DraggableTabBar(
                  tabIds: tabIds,
                  activeIndex: activeIndex,
                  dragContext: dragContext,
                  nodePath: nodePath,
                  nodeSize: Size(constraints.maxWidth, constraints.maxHeight),
                  collapsed: true,
                ),
                SizedBox(height: cfg.groupHeaderHeight),
              ],
            );
          }

          return Stack(
            children: [
              Column(
                children: [
                  SizedBox(
                    height: cfg.groupHeaderHeight + cfg.tabBarHeight,
                  ),
                  Expanded(child: DockTheme.of(context).panelDelegate.buildPanel(activePanelId)),
                ],
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _DraggableTabBar(
                  tabIds: tabIds,
                  activeIndex: activeIndex,
                  dragContext: dragContext,
                  nodePath: nodePath,
                  nodeSize: Size(constraints.maxWidth, constraints.maxHeight),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── 공통 위젯 ──

/// 오버레이 버튼을 좌·중·우 세 구역으로 나눠 배치하는 Row.
///
/// 각 구역은 동일한 Expanded 비율을 가지며, 좌는 좌정렬,
/// 중앙은 중앙정렬, 우는 우정렬로 표시된다.
class _OverlayZoneRow extends StatelessWidget {
  final List<Widget> left;
  final List<Widget> center;
  final List<Widget> right;

  const _OverlayZoneRow({
    this.left = const [],
    this.center = const [],
    this.right = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: left),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: center),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: right),
          ),
        ),
      ],
    );
  }
}

/// 드래그 가능한 스플릿 구분선 (리사이즈 전용).
class _DraggableSplitSeparator extends ConsumerStatefulWidget {
  final SplitAxis axis;
  final int separatorIndex;
  final List<int> splitPath;
  final DockDragContext? dragContext;

  const _DraggableSplitSeparator({
    required this.axis,
    required this.separatorIndex,
    required this.splitPath,
    this.dragContext,
  });

  @override
  ConsumerState<_DraggableSplitSeparator> createState() =>
      _DraggableSplitSeparatorState();
}

class _DraggableSplitSeparatorState
    extends ConsumerState<_DraggableSplitSeparator> {
  bool _isHovered = false;

  /// 인접 자식 중 하나라도 접혀 있으면 드래그 차단.
  bool _hasCollapsedAdjacent(DockGroup group) {
    final splitNode = getNodeAt(group.root, widget.splitPath);
    if (splitNode is! DockSplit) return false;
    final i = widget.separatorIndex;
    return splitNode.children[i].isCollapsed ||
        splitNode.children[i + 1].isCollapsed;
  }

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == SplitAxis.horizontal;
    final dc = widget.dragContext;

    // 인접 자식이 접혀 있으면 드래그 불가
    final bool disabled;
    if (dc != null) {
      final group = ref.watch(dockProvider.select(
        (s) => s.groups.where((g) => g.id == dc.groupId).firstOrNull,
      ));
      disabled = group != null && _hasCollapsedAdjacent(group);
    } else {
      disabled = false;
    }

    return MouseRegion(
      cursor: disabled
          ? SystemMouseCursors.basic
          : isHorizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: dc == null || disabled
            ? null
            : (_) {
                // drag 중 auto avoidance가 group 크기를 변경하여 비율이
                // 꼬이는 현상을 방지하기 위해 resizing 상태 설정.
                ref.read(dockProvider.notifier).beginSplitResize(dc.groupId);
              },
        onPanUpdate: dc == null || disabled
            ? null
            : (details) {
                final group = ref
                    .read(dockProvider)
                    .groups
                    .where((g) => g.id == dc.groupId)
                    .firstOrNull;
                if (group == null) return;
                final totalSize = isHorizontal ? group.width : group.height;
                final delta = isHorizontal
                    ? details.delta.dx
                    : details.delta.dy;
                ref
                    .read(dockProvider.notifier)
                    .resizeSplit(
                      dc.groupId,
                      nodePath: widget.splitPath,
                      separatorIndex: widget.separatorIndex,
                      delta: delta,
                      totalSize: totalSize,
                    );
              },
        onPanEnd: dc == null || disabled
            ? null
            : (_) {
                ref.read(dockProvider.notifier).endSplitResize();
              },
        onPanCancel: dc == null || disabled
            ? null
            : () {
                ref.read(dockProvider.notifier).endSplitResize();
              },
        child: SizedBox(
          width: isHorizontal ? DockTheme.of(context).config.splitSeparatorThickness : null,
          height: isHorizontal ? null : DockTheme.of(context).config.splitSeparatorThickness,
          child: Center(
            child: SizedBox(
              width: isHorizontal ? 2 : double.infinity,
              height: isHorizontal ? double.infinity : 2,
              child: Builder(
                builder: (context) {
                  final cs = DockTheme.of(context).colorScheme;
                  return ColoredBox(
                    color: _isHovered ? cs.separatorHover : cs.separator,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 헤더 오버레이 액션 버튼.
class _HeaderActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double buttonSize;
  final double iconSize;
  final bool flat;
  final bool forceHover;

  /// 버튼 호버 배경 모서리 반경.
  static const double _borderRadius = 4.0;

  const _HeaderActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.buttonSize = 18.0,
    this.iconSize = 12.0,
    this.flat = false,
    this.forceHover = false,
  });

  @override
  State<_HeaderActionButton> createState() => _HeaderActionButtonState();
}

class _HeaderActionButtonState extends State<_HeaderActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Builder(
            builder: (context) {
              final cs = DockTheme.of(context).colorScheme;
              final hovered = _isHovered || widget.forceHover;
              return Container(
                width: widget.buttonSize,
                height: widget.buttonSize,
                decoration: widget.flat
                    ? null
                    : BoxDecoration(
                        color: hovered ? cs.hover : null,
                        borderRadius: BorderRadius.circular(_HeaderActionButton._borderRadius),
                      ),
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: hovered ? cs.textPrimary : cs.textMuted,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 개별 탭 아이템.
class _TabItem extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isReordering;
  final double overlayProgress;
  final TextTheme textTheme;
  final bool collapsed;

  const _TabItem({
    required this.label,
    required this.isActive,
    this.isReordering = false,
    this.overlayProgress = 0.0,
    required this.textTheme,
    this.collapsed = false,
  });

  static const double _activeTabRadius = 6.0;
  static const double _tabSpacing = 8.0;

  @override
  Widget build(BuildContext context) {
    final cs = DockTheme.of(context).colorScheme;
    final activeColor = Color.lerp(
      cs.panelBackground,
      cs.headerOverlay,
      overlayProgress,
    )!;

    // 접힌 상태: 활성 탭은 상하 모두 둥근 모서리
    final BorderRadius? borderRadius;
    if (!isActive) {
      borderRadius = null;
    } else if (collapsed) {
      borderRadius = BorderRadius.circular(_activeTabRadius);
    } else {
      borderRadius = const BorderRadius.only(
        topLeft: Radius.circular(_activeTabRadius),
        topRight: Radius.circular(_activeTabRadius),
      );
    }

    // 접힌 상태: bg0으로 그룹 배경(panelBackground)과 구분
    final Color? bgColor;
    if (!isActive) {
      bgColor = null;
    } else if (collapsed) {
      bgColor = cs.bg0;
    } else {
      bgColor = activeColor;
    }

    final tab = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          color: isActive ? cs.textSecondary : cs.textMuted,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );

    return Opacity(opacity: isReordering ? 0.5 : 1.0, child: tab);
  }
}

/// 활성 탭 옆 역라운드 코너를 그리는 페인터.
///
/// 하단 구분선이 곡선을 따라 자연스럽게 이어진다.
class _InverseCornerPainter extends CustomPainter {
  final bool curveOnRight;
  final Color tabColor;
  final Color bgColor;
  final double radius;

  const _InverseCornerPainter({
    required this.curveOnRight,
    required this.tabColor,
    required this.bgColor,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = radius;

    // 원이 할당 영역 밖으로 넘치지 않도록 클리핑
    canvas.clipRect(Rect.fromLTWH(0, 0, w, h));

    // 1) 전체를 bg0로 채움
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = bgColor,
    );

    // 2) 하단 코너에 탭 색상 채움 + bg0 원으로 역라운드
    if (curveOnRight) {
      canvas.drawRect(
        Rect.fromLTWH(w - r, h - r, r, r),
        Paint()..color = tabColor,
      );
      canvas.drawCircle(
        Offset(w - r, h - r),
        r,
        Paint()..color = bgColor,
      );
    } else {
      canvas.drawRect(
        Rect.fromLTWH(0, h - r, r, r),
        Paint()..color = tabColor,
      );
      canvas.drawCircle(
        Offset(r, h - r),
        r,
        Paint()..color = bgColor,
      );
    }
  }

  @override
  bool shouldRepaint(_InverseCornerPainter oldDelegate) =>
      curveOnRight != oldDelegate.curveOnRight ||
      tabColor != oldDelegate.tabColor ||
      bgColor != oldDelegate.bgColor ||
      radius != oldDelegate.radius;
}

