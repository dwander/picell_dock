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
    with TickerProviderStateMixin, DockDragMixin {
  static const Duration _overlayDuration = Duration(milliseconds: 200);

  @override
  DockDragContext? get dragContext => widget.dragContext;

  @override
  void initState() {
    super.initState();
    initDragMixin(duration: _overlayDuration);
  }

  @override
  void dispose() {
    removeGhost();
    disposeDragMixin();
    super.dispose();
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

  void _onDragStart(DragStartDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    stackOrigin = dc.stackOrigin;
    final cursorInStack = details.globalPosition - stackOrigin;
    final notifier = ref.read(dockProvider.notifier);

    // Split 내부 + 일반 패널 혼합 → 고스트 분리 모드
    if (widget.nodePath.isNotEmpty && !_isAllHeaderless()) {
      undockPending = true;
      final renderBox = context.findRenderObject() as RenderBox?;
      final nodeSize = (renderBox != null && renderBox.hasSize)
          ? renderBox.size
          : null;
      final label = DockTheme.of(context).panelDelegate.labelOf(widget.panelId);
      showGhost(label, details.globalPosition, nodeSize: nodeSize);
      return;
    }

    // 그룹 이동 드래그
    final groups = ref.read(dockProvider).groups;
    final group = groups.where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    grabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;

    if (undockPending) {
      updateGhost(details.globalPosition);
      final cursorInStack = details.globalPosition - dc.stackOrigin;
      ref.read(dockProvider.notifier).updateGhostDockPreview(
        cursorInStack: cursorInStack,
        ghostSize: ghostSize,
        excludeGroupId: dc.groupId,
      );
      return;
    }

    final cursorInStack = details.globalPosition - stackOrigin;
    ref.read(dockProvider.notifier).updateDrag(
      dc.groupId,
      cursorInStack - grabOffset,
      dc.viewerSize,
      cursorInStack: cursorInStack,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final dc = widget.dragContext;
    final notifier = ref.read(dockProvider.notifier);

    if (undockPending && dc != null) {
      removeGhost();
      final preview = ref.read(dockProvider).dockPreview;
      final cursorInStack = details.globalPosition - dc.stackOrigin;

      final newId = notifier.undockNode(
        sourceGroupId: dc.groupId,
        nodePath: widget.nodePath,
        cursorInStack: cursorInStack,
      );

      // 도킹 대상이 있으면 즉시 도킹, 없으면 preview 초기화만
      if (newId != null) {
        commitDockPreview(newId, preview, notifier);
      } else {
        notifier.clearGhostDockPreview();
      }
      undockPending = false;
    } else {
      notifier.endDrag();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dc = widget.dragContext;
    final delegate = DockTheme.of(context).panelDelegate;
    final panelLayout = delegate.buildOverlayLayout?.call(widget.panelId, ref) ?? const DockOverlayLayout();
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
        onEnter: hasOverlay ? (_) => onHoverChanged(true) : null,
        onExit: hasOverlay ? (_) => onHoverChanged(false) : null,
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
