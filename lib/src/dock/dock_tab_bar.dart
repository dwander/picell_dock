part of 'dock_node_widget.dart';

// ── 탭 바 (패널 헤더 겸용) ──

class _DraggableTabBar extends ConsumerStatefulWidget {
  final List<String> tabIds;
  final int activeIndex;
  final DockDragContext? dragContext;
  final List<int> nodePath;
  final Size nodeSize;
  final bool collapsed;

  const _DraggableTabBar({
    required this.tabIds,
    required this.activeIndex,
    this.dragContext,
    this.nodePath = const [],
    this.nodeSize = Size.zero,
    this.collapsed = false,
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

  /// 접힌 상태에서 헤더 전체 호버 여부.
  bool _collapsedHover = false;

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
                boxShadow: DockTheme.of(context).colorScheme.groupShadow,
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
    final isCollapsed = widget.collapsed;
    final overlayEnabled = dockTheme.displaySettings.showHeaderOverlay;
    final dockedEdge = dc == null
        ? null
        : ref.watch(dockProvider.select(
            (s) => s.groups.where((g) => g.id == dc.groupId).firstOrNull?.dockedEdge,
          ));
    // 그룹 전체에서 펼쳐진 패널이 자신뿐이면 접기 불가 (엣지/플로팅 공통)
    final isLastExpanded = dc == null || widget.nodePath.isEmpty
        ? false
        : ref.watch(dockProvider.select((s) {
            final root = s.groups
                .where((g) => g.id == dc.groupId).firstOrNull?.root;
            if (root is! DockSplit) return false;
            int countExpanded(DockNode node) => switch (node) {
              DockLeaf() => 1,
              DockTabbed(:final collapsed) => collapsed ? 0 : 1,
              DockSplit(:final children) =>
                children.fold(0, (sum, c) => sum + countExpanded(c)),
            };
            return countExpanded(root) <= 1;
          }));
    // 패널별 오버레이 버튼 레이아웃
    final activePanelId = widget.tabIds[widget.activeIndex];
    final panelLayout = dockTheme.panelDelegate.buildOverlayLayout
        ?.call(activePanelId, ref) ??
        const DockOverlayLayout();
    final showFloatButton =
        dockedEdge != null && widget.nodePath.every((i) => i == 0);
    final canShowOverlay = !isCollapsed &&
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
              final toggleCollapse = isCollapsed && dc != null
                  ? () => ref
                      .read(dockProvider.notifier)
                      .toggleCollapse(
                        dc.groupId,
                        nodePath: widget.nodePath,
                      )
                  : null;
              Widget header = Container(
                height: cfg.groupHeaderHeight + cfg.tabBarHeight,
                padding: EdgeInsets.only(top: cfg.groupHeaderHeight),
                color: isCollapsed ? null : cs.bg0,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 좌측 고정 여백: 접힌 상태/드래그 중엔 역라운드 숨김
                    (!isDragging && !isCollapsed && widget.activeIndex == 0)
                        ? _activeTabSpacer(curveOnRight: true, tabColor: activeColor, bgColor: cs.bg0)
                        : _tabSpacer(),
                    for (int i = 0; i < widget.tabIds.length; i++) ...[
                      GestureDetector(
                        key: _keyForTab(i),
                        onTap: i == widget.activeIndex || dc == null || isCollapsed
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
                            collapsed: isCollapsed,
                          ),
                        ),
                      ),
                      // 탭 간 스페이서: 접힌 상태/드래그 중엔 역라운드 숨김
                      if (isDragging || isCollapsed)
                        _tabSpacer()
                      else if (i == widget.activeIndex)
                        _activeTabSpacer(curveOnRight: false, tabColor: activeColor, bgColor: cs.bg0)
                      else if (i == widget.activeIndex - 1)
                        _activeTabSpacer(curveOnRight: true, tabColor: activeColor, bgColor: cs.bg0)
                      else
                        _tabSpacer(),
                    ],
                    // 남은 공간: 드래그로 그룹 이동 + 접기 버튼
                    Expanded(
                      child: GestureDetector(
                        onPanStart: dc == null ? null : _onGroupDragStart,
                        onPanUpdate: dc == null ? null : _onGroupDragUpdate,
                        onPanEnd: dc == null ? null : _onGroupDragEnd,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Align(
                            alignment: Alignment.centerRight,
                            // 접기 버튼 숨김 조건:
                            // - 루트 노드(스플릿 아닌 단일 패널)에서는 엣지만 숨김
                            // - 펼쳐진 패널이 자신뿐이면 접기 불가 (엣지/플로팅 공통)
                            child: dc == null ||
                                    (dockedEdge != null && widget.nodePath.isEmpty) ||
                                    (!isCollapsed && isLastExpanded)
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: _HeaderActionButton(
                                      icon: isCollapsed
                                          ? PhosphorIconsRegular.caretDown
                                          : PhosphorIconsRegular.caretUp,
                                      tooltip: isCollapsed ? '펼치기' : '접기',
                                      forceHover: isCollapsed && _collapsedHover,
                                      onPressed: () => ref
                                          .read(dockProvider.notifier)
                                          .toggleCollapse(
                                            dc.groupId,
                                            nodePath: widget.nodePath,
                                          ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
              // 접힌 상태: 헤더 전체를 클릭/호버 영역으로 확장
              if (toggleCollapse != null) {
                header = MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _collapsedHover = true),
                  onExit: (_) => setState(() => _collapsedHover = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: toggleCollapse,
                    child: header,
                  ),
                );
              }
              return header;
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
