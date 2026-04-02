part of 'dock_node_widget.dart';


// ── 헤더리스 프레임 ──

/// 헤더 없이 콘텐츠만 표시하는 패널 프레임.
///
/// 히스토그램, 카메라 정보 등 독립 그룹일 때 사용.
/// 프레임 전체가 드래그 핸들 역할.
class _HeaderlessFrame extends ConsumerStatefulWidget {
  final String panelId;
  final DockDragContext? dragContext;
  final List<int> nodePath;

  const _HeaderlessFrame({
    required this.panelId,
    this.dragContext,
    this.nodePath = const [],
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

  /// 그룹 내 모든 패널이 헤더리스인지 여부.
  bool _isAllHeaderless() {
    final dc = widget.dragContext;
    if (dc == null) return false;
    final group = ref.read(dockProvider).groups
        .where((g) => g.id == dc.groupId)
        .firstOrNull;
    if (group == null) return false;
    final settings = ref.read(dockSettingsProvider);
    return group.root.collectPanelIds().every(settings.isHeaderless);
  }

  /// 혼합 그룹 분리 모드: 고스트 표시 중.
  bool _undockPending = false;
  OverlayEntry? _ghostEntry;
  Offset _ghostPosition = Offset.zero;
  Size _ghostSize = const Size(200, 120);

  void _showGhost(Offset globalPosition) {
    final dc = widget.dragContext;
    if (dc == null) return;
    // 이 노드의 실제 렌더 크기를 고스트 크기로 사용
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      _ghostSize = renderBox.size;
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
    final cs = DockTheme.of(context).colorScheme;
    final cfg = DockTheme.of(context).config;
    final delegate = DockTheme.of(context).panelDelegate;
    final label = delegate.labelOf(widget.panelId);
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
                color: cs.panelBackground,
                borderRadius: BorderRadius.circular(cfg.groupBorderRadius),
                border: Border.all(color: cs.border),
                boxShadow: cs.groupShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: cfg.panelHeaderHeight,
                    color: cs.bg0,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      style: textTheme.labelSmall?.copyWith(
                        color: cs.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onDragStart(DragStartDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    _stackOrigin = dc.stackOrigin;
    final cursorInStack = details.globalPosition - _stackOrigin;
    final notifier = ref.read(dockProvider.notifier);

    // Split 내부 + 일반 패널 혼합 → 고스트 분리 모드
    if (widget.nodePath.isNotEmpty && !_isAllHeaderless()) {
      _undockPending = true;
      _showGhost(details.globalPosition);
      return;
    }

    // 그룹 이동 드래그
    final groups = ref.read(dockProvider).groups;
    final group = groups.where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    _grabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;

    if (_undockPending) {
      _updateGhost(details.globalPosition);
      final cursorInStack = details.globalPosition - dc.stackOrigin;
      ref.read(dockProvider.notifier).updateGhostDockPreview(
        cursorInStack: cursorInStack,
        ghostSize: _ghostSize,
        excludeGroupId: dc.groupId,
      );
      return;
    }

    final cursorInStack = details.globalPosition - _stackOrigin;
    ref.read(dockProvider.notifier).updateDrag(
      dc.groupId,
      cursorInStack - _grabOffset,
      dc.viewerSize,
      cursorInStack: cursorInStack,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final dc = widget.dragContext;
    final notifier = ref.read(dockProvider.notifier);

    if (_undockPending && dc != null) {
      _removeGhost();
      final preview = ref.read(dockProvider).dockPreview;
      final cursorInStack = details.globalPosition - dc.stackOrigin;

      final newId = notifier.undockNode(
        sourceGroupId: dc.groupId,
        nodePath: widget.nodePath,
        cursorInStack: cursorInStack,
      );

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
      _undockPending = false;
    } else {
      notifier.endDrag();
    }
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
    final isInSplit = widget.nodePath.isNotEmpty;
    final allHeaderless = isInSplit && _isAllHeaderless();
    final rightButtons = [
      ...panelLayout.right,
      // 헤더리스끼리만 합쳐진 경우에만 언링크 버튼 표시
      // (일반 패널 혼합 시 바디 드래그로 분리)
      if (allHeaderless && dc != null)
        _HeaderActionButton(
          icon: PhosphorIconsRegular.linkBreak,
          tooltip: '패널 분리',
          onPressed: () => ref.read(dockProvider.notifier).undockNode(
            sourceGroupId: dc.groupId,
            nodePath: widget.nodePath,
          ),
          buttonSize: 24.0,
          iconSize: 18.0,
          flat: true,
        ),
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
