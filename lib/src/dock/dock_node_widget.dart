import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/dock_node.dart';
import '../providers/dock_provider.dart';
import '../theme/dock_theme.dart';

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
        axis,
        children,
        ratios,
      ),
      DockTabbed(:final tabIds, :final activeIndex) => _buildTabbed(
        tabIds,
        activeIndex,
        ref,
      ),
    };
  }

  Widget _buildLeaf(String panelId, WidgetRef ref) {
    // 헤더리스 그룹: 독립 그룹(nodePath 비어있음)이고 그룹이 headerless이면 프레임만 표시
    if (nodePath.isEmpty && dragContext != null) {
      final isHeaderless = ref.watch(dockProvider.select(
        (s) => s.groups
            .where((g) => g.id == dragContext!.groupId)
            .firstOrNull
            ?.headerless ?? false,
      ));
      if (isHeaderless) {
        return _HeaderlessFrame(
          panelId: panelId,
          dragContext: dragContext,
        );
      }
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
    SplitAxis axis,
    List<DockNode> children,
    List<double> ratios,
  ) {
    final direction = axis == SplitAxis.horizontal
        ? Axis.horizontal
        : Axis.vertical;

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

  Widget _buildTabbed(List<String> tabIds, int activeIndex, WidgetRef ref) {
    final activePanelId = tabIds[activeIndex];
    return Listener(
      onPointerDown: (_) => _focusPanel(ref, activePanelId),
      behavior: HitTestBehavior.translucent,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: DockTheme.of(context).config.groupHeaderHeight +
                      DockTheme.of(context).config.tabBarHeight,
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
        ),
      ),
    );
  }
}

// ── 탭 바 (패널 헤더 겸용) ──

class _DraggableTabBar extends ConsumerStatefulWidget {
  final List<String> tabIds;
  final int activeIndex;
  final DockDragContext? dragContext;
  final List<int> nodePath;
  final Size nodeSize;

  const _DraggableTabBar({
    required this.tabIds,
    required this.activeIndex,
    this.dragContext,
    this.nodePath = const [],
    this.nodeSize = Size.zero,
  });

  @override
  ConsumerState<_DraggableTabBar> createState() => _DraggableTabBarState();
}

class _DraggableTabBarState extends ConsumerState<_DraggableTabBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _overlayController;
  late final Animation<double> _overlayAnimation;

  final _tabKeys = <int, GlobalKey>{};

  /// 탭 드래그 상태.
  int? _draggingTabIndex;
  double _dragStartGlobalX = 0;
  double _dragDeltaX = 0;
  Rect? _tabBarRect;

  /// 분리 모드: 헤더 영역 벗어남 → 고스트 표시 중.
  /// 실제 undock는 panEnd 시점에 수행.
  bool _undockPending = false;
  OverlayEntry? _ghostEntry;
  Offset _ghostPosition = Offset.zero;
  Size _ghostSize = const Size(200, 120);
  String _ghostLabel = '';

  @override
  void initState() {
    super.initState();
    _overlayController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _overlayAnimation = CurvedAnimation(
      parent: _overlayController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
  }

  @override
  void dispose() {
    _removeGhost();
    _overlayController.dispose();
    super.dispose();
  }

  void _showGhost(int tabIndex, Offset globalPosition) {
    _ghostLabel = DockTheme.of(context).panelDelegate.labelOf(widget.tabIds[tabIndex]);

    // 소속 노드 영역의 실제 크기
    if (widget.nodeSize.width > 0 && widget.nodeSize.height > 0) {
      _ghostSize = widget.nodeSize;
    }

    _ghostPosition = Offset(
      globalPosition.dx - _ghostSize.width / 2,
      globalPosition.dy - 10,
    );

    _ghostEntry = OverlayEntry(builder: (_) => _buildGhost());
    Overlay.of(context).insert(_ghostEntry!);
  }

  void _updateGhost(Offset globalPosition) {
    _ghostPosition = Offset(
      globalPosition.dx - _ghostSize.width / 2,
      globalPosition.dy - 10,
    );
    _ghostEntry?.markNeedsBuild();
  }

  void _removeGhost() {
    _ghostEntry?.remove();
    _ghostEntry = null;
  }

  Widget _buildGhost() {
    final textTheme = Theme.of(context).textTheme;
    return Positioned(
      left: _ghostPosition.dx,
      top: _ghostPosition.dy,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.85,
            child: Container(
              width: _ghostSize.width,
              height: _ghostSize.height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: DockTheme.of(context).colorScheme.panelBackground,
                borderRadius: BorderRadius.circular(
                  DockTheme.of(context).config.groupBorderRadius,
                ),
                border: Border.all(color: DockTheme.of(context).colorScheme.border),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 패널 헤더 (이름 표시)
                  Container(
                    height: DockTheme.of(context).config.panelHeaderHeight,
                    color: DockTheme.of(context).colorScheme.bg0,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _ghostLabel,
                      style: textTheme.labelSmall?.copyWith(
                        color: DockTheme.of(context).colorScheme.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 빈 패널 영역
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onHoverChanged(bool hovered) {
    if (hovered) {
      _overlayController.forward();
    } else {
      _overlayController.reverse();
    }
  }

  GlobalKey _keyForTab(int index) =>
      _tabKeys.putIfAbsent(index, () => GlobalKey());

  /// 탭 바의 글로벌 Rect를 캐시.
  Rect _getTabBarRect() {
    if (_tabBarRect != null) return _tabBarRect!;
    final ctx = context;
    final renderBox = ctx.findRenderObject() as RenderBox?;
    if (renderBox == null) return Rect.zero;
    final pos = renderBox.localToGlobal(Offset.zero);
    _tabBarRect = Rect.fromLTWH(
      pos.dx,
      pos.dy,
      renderBox.size.width,
      DockTheme.of(context).config.tabBarHeight,
    );
    return _tabBarRect!;
  }

  /// 글로벌 X에서 탭 인덱스를 계산.
  int? _indexAtPosition(double globalX) {
    for (int i = 0; i < widget.tabIds.length; i++) {
      final key = _tabKeys[i];
      final renderBox = key?.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) continue;
      final pos = renderBox.localToGlobal(Offset.zero);
      final size = renderBox.size;
      if (globalX >= pos.dx && globalX < pos.dx + size.width) {
        return i;
      }
    }
    return null;
  }

  // ── 빈 공간 드래그 → 그룹 이동 ──

  Offset _groupGrabOffset = Offset.zero;
  Offset _groupStackOrigin = Offset.zero;

  void _onGroupDragStart(DragStartDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    final notifier = ref.read(dockProvider.notifier);

    // 엣지 패널이면 먼저 플로팅으로 전환
    final initialGroup = ref.read(dockProvider).groups
        .where((g) => g.id == dc.groupId).firstOrNull;
    if (initialGroup?.dockedEdge != null) {
      notifier.undockFromViewportEdge(dc.groupId);
    }

    _groupStackOrigin = dc.stackOrigin;
    final cursorInStack = details.globalPosition - _groupStackOrigin;
    final group = ref.read(dockProvider).groups
        .where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    _groupGrabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void _onGroupDragUpdate(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    final cursorInStack = details.globalPosition - _groupStackOrigin;
    ref.read(dockProvider.notifier).updateDrag(
      dc.groupId,
      cursorInStack - _groupGrabOffset,
      dc.viewerSize,
      cursorInStack: cursorInStack,
    );
  }

  void _onGroupDragEnd(DragEndDetails details) {
    ref.read(dockProvider.notifier).endDrag();
  }

  // ── 탭 드래그 ──

  void _onTabPanStart(int tabIndex, DragStartDetails details) {
    _tabBarRect = null; // 캐시 초기화
    _dragStartGlobalX = details.globalPosition.dx;
    setState(() {
      _draggingTabIndex = tabIndex;
      _dragDeltaX = 0;
    });
  }

  void _onTabPanUpdate(DragUpdateDetails details) {
    if (_draggingTabIndex == null) return;
    final dc = widget.dragContext;
    if (dc == null) return;

    final tabBarRect = _getTabBarRect();
    final insideTabBar = tabBarRect.contains(details.globalPosition);

    // 분리 모드 중
    if (_undockPending) {
      if (insideTabBar) {
        // 헤더 영역으로 복귀 → 분리 취소, 리오더 모드로 복원
        _removeGhost();
        ref.read(dockProvider.notifier).clearGhostDockPreview();
        _undockPending = false;
        _dragDeltaX = details.globalPosition.dx - _dragStartGlobalX;
        setState(() {});
      } else {
        // 고스트 업데이트 + 도킹 감지
        _updateGhost(details.globalPosition);
        final cursorInStack = details.globalPosition - dc.stackOrigin;
        ref.read(dockProvider.notifier).updateGhostDockPreview(
          cursorInStack: cursorInStack,
          ghostSize: _ghostSize,
          excludeGroupId: dc.groupId,
        );
      }
      return;
    }

    // 헤더 영역 벗어남 → 분리 모드 진입 (고스트 표시)
    // 탭 2개 이상이면 탭 분리, 탭 1개 + Split 내부면 노드 분리
    if (!insideTabBar) {
      final canUndock =
          widget.tabIds.length > 1 || widget.nodePath.isNotEmpty;
      if (canUndock) {
        _undockPending = true;
        _showGhost(_draggingTabIndex!, details.globalPosition);
        setState(() {});
      }
      return;
    }

    // 커서 기준 절대 오프셋 계산 (탭이 항상 커서에 붙어있음)
    _dragDeltaX = details.globalPosition.dx - _dragStartGlobalX;

    // 좌우 리오더: 커서가 인접 탭 위에 오면 순서 변경
    final targetIndex = _indexAtPosition(details.globalPosition.dx);
    if (targetIndex != null && targetIndex != _draggingTabIndex) {
      final targetKey = _tabKeys[targetIndex];
      final targetBox =
          targetKey?.currentContext?.findRenderObject() as RenderBox?;
      if (targetBox != null) {
        final shift = targetBox.size.width + _TabItem._tabSpacing;
        final direction = targetIndex < _draggingTabIndex! ? -1.0 : 1.0;
        _dragStartGlobalX += direction * shift;
        _dragDeltaX = details.globalPosition.dx - _dragStartGlobalX;
      }
      ref
          .read(dockProvider.notifier)
          .reorderTab(
            dc.groupId,
            nodePath: widget.nodePath,
            oldIndex: _draggingTabIndex!,
            newIndex: targetIndex,
          );
      _draggingTabIndex = targetIndex;
    }

    setState(() {});
  }

  void _onTabPanEnd(DragEndDetails details) {
    final dc = widget.dragContext;
    final notifier = ref.read(dockProvider.notifier);

    if (_undockPending && dc != null && _draggingTabIndex != null) {
      _removeGhost();

      final preview = ref.read(dockProvider).dockPreview;
      final cursorInStack = details.globalPosition - dc.stackOrigin;

      // 탭 분리 또는 노드 분리
      final String? newId;
      if (widget.tabIds.length > 1) {
        newId = notifier.undockTab(
          sourceGroupId: dc.groupId,
          nodePath: widget.nodePath,
          tabIndex: _draggingTabIndex!,
          cursorInStack: cursorInStack,
        );
      } else {
        newId = notifier.undockNode(
          sourceGroupId: dc.groupId,
          nodePath: widget.nodePath,
          cursorInStack: cursorInStack,
        );
      }

      // 도킹 대상이 있으면 즉시 도킹
      if (newId != null && preview != null) {
        if (preview.edge == DockEdge.center) {
          notifier.performTabDock(
            newId, preview.targetGroupId, preview.nodePath);
        } else {
          notifier.performEdgeDock(
            newId, preview.targetGroupId, preview.edge, preview.nodePath);
        }
      }

      notifier.clearGhostDockPreview();
    } else {
      _removeGhost();
    }

    setState(() {
      _draggingTabIndex = null;
      _dragDeltaX = 0;
      _undockPending = false;
      _tabBarRect = null;
    });
  }

  static Widget _tabSpacer() {
    return SizedBox(width: _TabItem._tabSpacing);
  }

  static Widget _activeTabSpacer({
    required bool curveOnRight,
    required Color tabColor,
    required Color bgColor,
  }) {
    return SizedBox(
      width: _TabItem._tabSpacing,
      child: CustomPaint(
        painter: _InverseCornerPainter(
          curveOnRight: curveOnRight,
          tabColor: tabColor,
          bgColor: bgColor,
          radius: _TabItem._activeTabRadius,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dc = widget.dragContext;
    final textTheme = Theme.of(context).textTheme;
    final dockTheme = DockTheme.of(context);
    final cs = dockTheme.colorScheme;
    final cfg = dockTheme.config;
    final overlayEnabled = dockTheme.displaySettings.showHeaderOverlay;
    final dockedEdge = dc == null
        ? null
        : ref.watch(dockProvider.select(
            (s) => s.groups.where((g) => g.id == dc.groupId).firstOrNull?.dockedEdge,
          ));
    // 패널별 오버레이 버튼 레이아웃
    final activePanelId = widget.tabIds[widget.activeIndex];
    final panelLayout = dockTheme.panelDelegate.buildOverlayLayout
        ?.call(activePanelId, ref) ??
        const DockOverlayLayout();
    final showFloatButton =
        dockedEdge != null && widget.nodePath.every((i) => i == 0);
    final canShowOverlay =
        overlayEnabled && dc != null && (panelLayout.isNotEmpty || showFloatButton);
    final isDragging = _draggingTabIndex != null;

    return MouseRegion(
      onEnter: canShowOverlay ? (_) => _onHoverChanged(true) : null,
      onExit: canShowOverlay ? (_) => _onHoverChanged(false) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _overlayAnimation,
            builder: (context, _) {
              final progress = canShowOverlay
                  ? _overlayAnimation.value
                  : 0.0;
              final activeColor = Color.lerp(
                cs.panelBackground,
                cs.headerOverlay,
                progress,
              )!;
              return Container(
                height: cfg.groupHeaderHeight + cfg.tabBarHeight,
                padding: EdgeInsets.only(top: cfg.groupHeaderHeight),
                color: cs.bg0,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 좌측 고정 여백: 드래그 중엔 역라운드 숨김
                    (!isDragging && widget.activeIndex == 0)
                        ? _activeTabSpacer(curveOnRight: true, tabColor: activeColor, bgColor: cs.bg0)
                        : _tabSpacer(),
                    for (int i = 0; i < widget.tabIds.length; i++) ...[
                      GestureDetector(
                        key: _keyForTab(i),
                        onTap: i == widget.activeIndex || dc == null
                            ? null
                            : () {
                                ref
                                    .read(dockProvider.notifier)
                                    .switchTab(
                                      dc.groupId,
                                      nodePath: widget.nodePath,
                                      tabIndex: i,
                                    );
                              },
                        onPanStart: dc == null
                            ? null
                            : (widget.tabIds.length <= 1 &&
                                    widget.nodePath.isEmpty)
                                ? _onGroupDragStart
                                : (details) => _onTabPanStart(i, details),
                        onPanUpdate: dc == null
                            ? null
                            : (widget.tabIds.length <= 1 &&
                                    widget.nodePath.isEmpty)
                                ? _onGroupDragUpdate
                                : _onTabPanUpdate,
                        onPanEnd: dc == null
                            ? null
                            : (widget.tabIds.length <= 1 &&
                                    widget.nodePath.isEmpty)
                                ? _onGroupDragEnd
                                : _onTabPanEnd,
                        child: Transform.translate(
                          offset: isDragging && _draggingTabIndex == i
                              ? Offset(_dragDeltaX, 0)
                              : Offset.zero,
                          child: _TabItem(
                            label: dockTheme.panelDelegate.labelOf(widget.tabIds[i]),
                            isActive: i == widget.activeIndex,
                            isReordering:
                                isDragging && _draggingTabIndex == i,
                            overlayProgress: progress,
                            textTheme: textTheme,
                          ),
                        ),
                      ),
                      // 탭 간 스페이서: 드래그 중엔 역라운드 숨김
                      if (isDragging)
                        _tabSpacer()
                      else if (i == widget.activeIndex)
                        _activeTabSpacer(curveOnRight: false, tabColor: activeColor, bgColor: cs.bg0)
                      else if (i == widget.activeIndex - 1)
                        _activeTabSpacer(curveOnRight: true, tabColor: activeColor, bgColor: cs.bg0)
                      else
                        _tabSpacer(),
                    ],
                    // 남은 공간: 드래그로 그룹 이동 + 우측 액션 버튼
                    Expanded(
                      child: GestureDetector(
                        onPanStart: dc == null ? null : _onGroupDragStart,
                        onPanUpdate: dc == null ? null : _onGroupDragUpdate,
                        onPanEnd: dc == null ? null : _onGroupDragEnd,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _HeaderActionButton(
                                icon: PhosphorIconsRegular.caretUp,
                                tooltip: '접기',
                                onPressed: () {
                                  // TODO: 접기 동작 구현
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (canShowOverlay)
            SizeTransition(
              sizeFactor: _overlayAnimation,
              axisAlignment: -1.0,
              child: Container(
                height: cfg.headerOverlayHeight,
                decoration: BoxDecoration(
                  color: cs.headerOverlay,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(cfg.headerOverlayRadius),
                    bottomRight: Radius.circular(cfg.headerOverlayRadius),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _OverlayZoneRow(
                  left: panelLayout.left,
                  center: panelLayout.center,
                  right: [
                    if (showFloatButton)
                      _HeaderActionButton(
                        icon: PhosphorIconsRegular.pictureInpicture,
                        tooltip: '플로팅 모드로 전환',
                        onPressed: () => ref
                            .read(dockProvider.notifier)
                            .undockFromViewportEdge(dc.groupId),
                        buttonSize: 24.0,
                        iconSize: 18.0,
                        flat: true,
                      ),
                    ...panelLayout.right,
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 헤더리스 프레임 ──

/// 헤더 없이 콘텐츠만 표시하는 패널 프레임.
///
/// 히스토그램, 카메라 정보 등 독립 그룹일 때 사용.
/// 프레임 전체가 드래그 핸들 역할.
class _HeaderlessFrame extends ConsumerStatefulWidget {
  final String panelId;
  final DockDragContext? dragContext;

  const _HeaderlessFrame({
    required this.panelId,
    this.dragContext,
  });

  @override
  ConsumerState<_HeaderlessFrame> createState() => _HeaderlessFrameState();
}

class _HeaderlessFrameState extends ConsumerState<_HeaderlessFrame>
    with SingleTickerProviderStateMixin {
  Offset _grabOffset = Offset.zero;
  Offset _stackOrigin = Offset.zero;

  late final AnimationController _overlayCtrl;
  late final CurvedAnimation _overlayAnim;

  static const Duration _overlayDuration = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _overlayCtrl = AnimationController(
      duration: _overlayDuration,
      vsync: this,
    );
    _overlayAnim = CurvedAnimation(
      parent: _overlayCtrl,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _overlayCtrl.dispose();
    super.dispose();
  }

  void _onHoverChanged(bool hovering) {
    if (hovering) {
      _overlayCtrl.forward();
    } else {
      _overlayCtrl.reverse();
    }
  }

  void _onDragStart(DragStartDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    _stackOrigin = dc.stackOrigin;
    final cursorInStack = details.globalPosition - _stackOrigin;
    final groups = ref.read(dockProvider).groups;
    final group = groups.where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    _grabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );
    final notifier = ref.read(dockProvider.notifier);
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    final cursorInStack = details.globalPosition - _stackOrigin;
    ref.read(dockProvider.notifier).updateDrag(
      dc.groupId,
      cursorInStack - _grabOffset,
      dc.viewerSize,
      cursorInStack: cursorInStack,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    ref.read(dockProvider.notifier).endDrag();
  }

  @override
  Widget build(BuildContext context) {
    final dc = widget.dragContext;
    final delegate = DockTheme.of(context).panelDelegate;
    final panelLayout = delegate.buildOverlayLayout?.call(widget.panelId, ref) ?? const DockOverlayLayout();
    final dockedEdge = dc == null
        ? null
        : ref.watch(dockProvider.select(
            (s) => s.groups
                .where((g) => g.id == dc.groupId)
                .firstOrNull
                ?.dockedEdge,
          ));
    final rightButtons = [
      ...panelLayout.right,
      if (dockedEdge != null)
        _HeaderActionButton(
          icon: PhosphorIconsRegular.pictureInpicture,
          tooltip: '플로팅 모드로 전환',
          onPressed: () => ref
              .read(dockProvider.notifier)
              .undockFromViewportEdge(dc!.groupId),
          buttonSize: 24.0,
          iconSize: 18.0,
          flat: true,
        ),
    ];
    final hasOverlay = panelLayout.isNotEmpty || rightButtons.isNotEmpty;

    return Listener(
      onPointerDown: (_) {
        if (dc != null) {
          ref.read(dockProvider.notifier).bringToFront(dc.groupId);
        }
        ref.read(dockProvider.notifier).focusPanel(widget.panelId);
      },
      behavior: HitTestBehavior.translucent,
      child: MouseRegion(
        onEnter: hasOverlay ? (_) => _onHoverChanged(true) : null,
        onExit: hasOverlay ? (_) => _onHoverChanged(false) : null,
        child: GestureDetector(
          onPanStart: dc == null ? null : _onDragStart,
          onPanUpdate: dc == null ? null : _onDragUpdate,
          onPanEnd: dc == null ? null : _onDragEnd,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Builder(
              builder: (context) {
                final cs = DockTheme.of(context).colorScheme;
                final cfg = DockTheme.of(context).config;
                return Stack(
                  children: [
                    delegate.buildPanel(widget.panelId),
                    if (hasOverlay)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: SizeTransition(
                          sizeFactor: _overlayAnim,
                          axisAlignment: -1.0,
                          child: Container(
                            height: cfg.headerOverlayHeight,
                            decoration: BoxDecoration(
                              color: cs.headerOverlay,
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(cfg.headerOverlayRadius),
                                bottomRight: Radius.circular(cfg.headerOverlayRadius),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: _OverlayZoneRow(
                              left: panelLayout.left,
                              center: panelLayout.center,
                              right: rightButtons,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == SplitAxis.horizontal;
    final dc = widget.dragContext;

    return MouseRegion(
      cursor: isHorizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: dc == null
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
        child: SizedBox(
          width: isHorizontal ? 5 : null,
          height: isHorizontal ? null : 5,
          child: Center(
            child: SizedBox(
              width: isHorizontal ? 1 : double.infinity,
              height: isHorizontal ? double.infinity : 1,
              child: Builder(
                builder: (context) {
                  final cs = DockTheme.of(context).colorScheme;
                  return ColoredBox(
                    color: _isHovered ? cs.separatorHover : cs.border,
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

  const _HeaderActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.buttonSize = 18.0,
    this.iconSize = 12.0,
    this.flat = false,
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
              return Container(
                width: widget.buttonSize,
                height: widget.buttonSize,
                decoration: widget.flat
                    ? null
                    : BoxDecoration(
                        color: _isHovered ? cs.hover : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: _isHovered ? cs.textPrimary : cs.textMuted,
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

  const _TabItem({
    required this.label,
    required this.isActive,
    this.isReordering = false,
    this.overlayProgress = 0.0,
    required this.textTheme,
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

    final tab = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isActive ? activeColor : null,
        borderRadius: isActive
            ? const BorderRadius.only(
                topLeft: Radius.circular(_activeTabRadius),
                topRight: Radius.circular(_activeTabRadius),
              )
            : null,
      ),
      foregroundDecoration: null,
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

