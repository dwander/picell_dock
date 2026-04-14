part of 'dock_node_widget.dart';

// ── 탭 바 (패널 헤더 겸용) ──

/// 그룹의 루트 [DockNode]에서 펼쳐진 리프 개수를 재귀적으로 센다.
int _countExpanded(DockNode node) => switch (node) {
  DockLeaf() => 1,
  DockTabbed(:final collapsed) => collapsed ? 0 : 1,
  DockSplit(:final children) =>
    children.fold(0, (sum, c) => sum + _countExpanded(c)),
};

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
    with TickerProviderStateMixin, DockDragMixin {
  final _tabKeys = <int, GlobalKey>{};

  /// 탭 드래그 상태.
  int? _draggingTabIndex;
  double _dragStartGlobalX = 0;
  double _dragDeltaX = 0;
  Rect? _tabBarRect;

  /// 접힌 상태에서 헤더 전체 호버 여부.
  bool _collapsedHover = false;

  @override
  DockDragContext? get dragContext => widget.dragContext;

  @override
  void initState() {
    super.initState();
    initDragMixin();
  }

  @override
  void dispose() {
    removeGhost();
    disposeDragMixin();
    super.dispose();
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

    stackOrigin = dc.stackOrigin;
    final cursorInStack = details.globalPosition - stackOrigin;
    final group = ref.read(dockProvider).groups
        .where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    grabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void _onGroupDragUpdate(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    final cursorInStack = details.globalPosition - stackOrigin;
    ref.read(dockProvider.notifier).updateDrag(
      dc.groupId,
      cursorInStack - grabOffset,
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

  /// 분리 모드 진행 처리: 고스트 업데이트 + 도킹 감지 or 헤더 복귀.
  void _handleTabDragUndock(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    final tabBarRect = _getTabBarRect();
    final insideTabBar = tabBarRect.contains(details.globalPosition);

    if (insideTabBar) {
      // 헤더 영역으로 복귀 → 분리 취소, 리오더 모드로 복원
      removeGhost();
      ref.read(dockProvider.notifier).clearGhostDockPreview();
      undockPending = false;
      _dragDeltaX = details.globalPosition.dx - _dragStartGlobalX;
      setState(() {});
    } else {
      // 고스트 업데이트 + 도킹 감지
      updateGhost(details.globalPosition);
      final cursorInStack = details.globalPosition - dc.stackOrigin;
      ref.read(dockProvider.notifier).updateGhostDockPreview(
        cursorInStack: cursorInStack,
        ghostSize: ghostSize,
        excludeGroupId: dc.groupId,
      );
    }
  }

  /// 탭바 밖으로 나갈 때 분리 모드 진입 처리.
  void _handleTabDragEnterUndock(DragUpdateDetails details) {
    final canUndock =
        widget.tabIds.length > 1 || widget.nodePath.isNotEmpty;
    if (canUndock) {
      undockPending = true;
      final label = DockTheme.of(context).panelDelegate.labelOf(
        widget.tabIds[_draggingTabIndex!],
      );
      showGhost(label, details.globalPosition, nodeSize: widget.nodeSize);
      setState(() {});
    }
  }

  /// 탭바 안에서 탭 리오더 판정 처리.
  void _handleTabDragReorder(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;

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

  /// 탭 드래그 업데이트 라우터: 상태에 따라 적절한 핸들러에 위임.
  void _onTabPanUpdate(DragUpdateDetails details) {
    if (_draggingTabIndex == null) return;
    if (widget.dragContext == null) return;

    if (undockPending) {
      _handleTabDragUndock(details);
      return;
    }

    final tabBarRect = _getTabBarRect();
    final insideTabBar = tabBarRect.contains(details.globalPosition);

    // 헤더 영역 벗어남 → 분리 모드 진입 (고스트 표시)
    // 탭 2개 이상이면 탭 분리, 탭 1개 + Split 내부면 노드 분리
    if (!insideTabBar) {
      _handleTabDragEnterUndock(details);
      return;
    }

    _handleTabDragReorder(details);
  }

  void _onTabPanEnd(DragEndDetails details) {
    final dc = widget.dragContext;
    final notifier = ref.read(dockProvider.notifier);

    if (undockPending && dc != null && _draggingTabIndex != null) {
      removeGhost();

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

      // 도킹 대상이 있으면 즉시 도킹, 없으면 preview 초기화만
      if (newId != null) {
        commitDockPreview(newId, preview, notifier);
      } else {
        notifier.clearGhostDockPreview();
      }
    } else {
      removeGhost();
    }

    setState(() {
      _draggingTabIndex = null;
      _dragDeltaX = 0;
      undockPending = false;
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

  /// 탭 목록 Row 조각 (for 루프 + GestureDetector + Transform + _TabItem).
  List<Widget> _buildTabList({
    required DockDragContext? dc,
    required bool isDragging,
    required bool isCollapsed,
    required Color activeColor,
    required double overlayProgress,
    required TextTheme textTheme,
    required DockColorScheme cs,
  }) {
    final isSingleTab =
        widget.tabIds.length <= 1 && widget.nodePath.isEmpty;

    // 드래그 콜백을 미리 결정 (삼항 중첩 반복 방지)
    final GestureDragUpdateCallback? panUpdate = dc == null
        ? null
        : (isSingleTab ? _onGroupDragUpdate : _onTabPanUpdate);
    final GestureDragEndCallback? panEnd = dc == null
        ? null
        : (isSingleTab ? _onGroupDragEnd : _onTabPanEnd);

    final items = <Widget>[];
    for (int i = 0; i < widget.tabIds.length; i++) {
      final GestureDragStartCallback? tabPanStart = dc == null
          ? null
          : (isSingleTab ? _onGroupDragStart : (d) => _onTabPanStart(i, d));

      items.add(GestureDetector(
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
        onPanStart: tabPanStart,
        onPanUpdate: panUpdate,
        onPanEnd: panEnd,
        child: Transform.translate(
          offset: isDragging && _draggingTabIndex == i
              ? Offset(_dragDeltaX, 0)
              : Offset.zero,
          child: _TabItem(
            label: DockTheme.of(context).panelDelegate.labelOf(widget.tabIds[i]),
            isActive: i == widget.activeIndex,
            isReordering: isDragging && _draggingTabIndex == i,
            overlayProgress: overlayProgress,
            textTheme: textTheme,
            collapsed: isCollapsed,
          ),
        ),
      ));

      // 탭 간 스페이서: 접힌 상태/드래그 중엔 역라운드 숨김
      if (isDragging || isCollapsed) {
        items.add(_tabSpacer());
      } else if (i == widget.activeIndex) {
        items.add(_activeTabSpacer(
          curveOnRight: false,
          tabColor: activeColor,
          bgColor: cs.bg0,
        ));
      } else if (i == widget.activeIndex - 1) {
        items.add(_activeTabSpacer(
          curveOnRight: true,
          tabColor: activeColor,
          bgColor: cs.bg0,
        ));
      } else {
        items.add(_tabSpacer());
      }
    }
    return items;
  }

  /// 헤더 우측 영역: 그룹 드래그 + 최대화/접기 버튼.
  Widget _buildHeaderRightArea({
    required DockDragContext? dc,
    required bool isCollapsed,
    required bool isLastExpanded,
    required bool showMaximize,
    required bool isMaximized,
    required ViewportEdge? dockedEdge,
  }) {
    return Expanded(
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 최대화/복귀 토글 버튼
                  if (showMaximize) ...[
                    _HeaderActionButton(
                      icon: isMaximized
                          ? PhosphorIconsRegular.arrowsIn
                          : PhosphorIconsRegular.square,
                      tooltip: isMaximized ? '이전 크기로' : '최대화',
                      onPressed: () {
                        final notifier = ref.read(dockProvider.notifier);
                        if (isMaximized) {
                          notifier.restoreGroup(dc!.groupId);
                        } else {
                          notifier.maximizeGroup(dc!.groupId);
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                  // 접기 버튼 숨김 조건:
                  // - 루트 노드(스플릿 아닌 단일 패널)에서는 엣지만 숨김
                  // - 펼쳐진 패널이 자신뿐이면 접기 불가 (엣지/플로팅 공통)
                  if (dc != null &&
                      !(dockedEdge != null && widget.nodePath.isEmpty) &&
                      !(!isCollapsed && isLastExpanded))
                    _HeaderActionButton(
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 헤더 Container + Row (탭 목록 + 우측 버튼 영역 조합).
  Widget _buildHeader(
    BuildContext context, {
    required DockDragContext? dc,
    required bool isDragging,
    required bool isCollapsed,
    required bool isLastExpanded,
    required bool showMaximize,
    required bool isMaximized,
    required Color activeColor,
    required double overlayProgress,
    required TextTheme textTheme,
    required DockTheme dockTheme,
    required ViewportEdge? dockedEdge,
  }) {
    final cs = dockTheme.colorScheme;
    final cfg = dockTheme.config;

    final toggleCollapse = isCollapsed && dc != null
        ? () => ref
            .read(dockProvider.notifier)
            .toggleCollapse(dc.groupId, nodePath: widget.nodePath)
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
              ? _activeTabSpacer(
                  curveOnRight: true,
                  tabColor: activeColor,
                  bgColor: cs.bg0,
                )
              : _tabSpacer(),
          ..._buildTabList(
            dc: dc,
            isDragging: isDragging,
            isCollapsed: isCollapsed,
            activeColor: activeColor,
            overlayProgress: overlayProgress,
            textTheme: textTheme,
            cs: cs,
          ),
          _buildHeaderRightArea(
            dc: dc,
            isCollapsed: isCollapsed,
            isLastExpanded: isLastExpanded,
            showMaximize: showMaximize,
            isMaximized: isMaximized,
            dockedEdge: dockedEdge,
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
  }

  /// hover 시 표시되는 오버레이 패널.
  Widget _buildOverlayPanel({
    required DockOverlayLayout panelLayout,
    required DockTheme dockTheme,
  }) {
    final cs = dockTheme.colorScheme;
    final cfg = dockTheme.config;

    return SizeTransition(
      sizeFactor: overlayAnimation,
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
          right: panelLayout.right,
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
    final isCollapsed = widget.collapsed;
    final overlayEnabled = dockTheme.displaySettings.showHeaderOverlay;

    final dockedEdge = dc == null
        ? null
        : ref.watch(dockProvider.select(
            (s) => s.groups
                .where((g) => g.id == dc.groupId)
                .firstOrNull
                ?.dockedEdge,
          ));

    // 그룹 전체에서 펼쳐진 패널이 자신뿐이면 접기 불가 (엣지/플로팅 공통)
    final isLastExpanded = dc == null || widget.nodePath.isEmpty
        ? false
        : ref.watch(dockProvider.select((s) {
            final root = s.groups
                .where((g) => g.id == dc.groupId)
                .firstOrNull
                ?.root;
            if (root is! DockSplit) return false;
            return _countExpanded(root) <= 1;
          }));

    // 패널별 오버레이 버튼 레이아웃
    final activePanelId = widget.tabIds[widget.activeIndex];
    final panelLayout = dockTheme.panelDelegate.buildOverlayLayout
            ?.call(activePanelId, ref) ??
        const DockOverlayLayout();
    final canShowOverlay =
        !isCollapsed && overlayEnabled && dc != null && panelLayout.isNotEmpty;
    final isDragging = _draggingTabIndex != null;

    // 최대화/복귀 버튼: 탭 중 하나라도 maximizable 패널이면 표시.
    final maximizablePanelIds = dc == null
        ? const <String>{}
        : ref.watch(
            dockSettingsProvider.select((s) => s.maximizablePanelIds),
          );
    final showMaximize =
        dc != null && widget.tabIds.any(maximizablePanelIds.contains);
    final isMaximized = showMaximize &&
        ref.watch(dockProvider.select(
          (s) =>
              s.groups
                  .where((g) => g.id == dc.groupId)
                  .firstOrNull
                  ?.savedState !=
              null,
        ));

    return MouseRegion(
      onEnter: canShowOverlay ? (_) => onHoverChanged(true) : null,
      onExit: canShowOverlay ? (_) => onHoverChanged(false) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: overlayAnimation,
            builder: (context, _) {
              final progress =
                  canShowOverlay ? overlayAnimation.value : 0.0;
              final activeColor = Color.lerp(
                cs.panelBackground,
                cs.headerOverlay,
                progress,
              )!;
              return _buildHeader(
                context,
                dc: dc,
                isDragging: isDragging,
                isCollapsed: isCollapsed,
                isLastExpanded: isLastExpanded,
                showMaximize: showMaximize,
                isMaximized: isMaximized,
                activeColor: activeColor,
                overlayProgress: progress,
                textTheme: textTheme,
                dockTheme: dockTheme,
                dockedEdge: dockedEdge,
              );
            },
          ),
          if (canShowOverlay)
            _buildOverlayPanel(
              panelLayout: panelLayout,
              dockTheme: dockTheme,
            ),
        ],
      ),
    );
  }
}
