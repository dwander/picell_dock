/// 독 시스템 표시 설정.
class DockDisplaySettings {
  /// 클린 모드: true이면 핀 고정되지 않은 패널 숨김. 핀된 패널은 유지.
  final bool hideUnpinned;

  /// 전체 숨김: true이면 핀 상태와 무관하게 모든 패널 숨김 (전체화면 등).
  final bool hideAll;

  /// 포커스된 패널 그룹 테두리 하이라이트 표시 여부.
  final bool showFocusHighlight;

  /// 패널 헤더 호버 시 오버레이 버튼 표시 여부.
  final bool showHeaderOverlay;

  /// hideUnpinned/hideAll 전환 시 슬라이드/페이드 애니메이션 사용 여부.
  ///
  /// false이면 애니메이션 없이 즉시 전환된다.
  final bool animateHide;

  const DockDisplaySettings({
    this.hideUnpinned = false,
    this.hideAll = false,
    this.showFocusHighlight = true,
    this.showHeaderOverlay = true,
    this.animateHide = true,
  });

  /// 지정한 필드만 변경한 복사본 생성.
  DockDisplaySettings copyWith({
    bool? hideUnpinned,
    bool? hideAll,
    bool? showFocusHighlight,
    bool? showHeaderOverlay,
    bool? animateHide,
  }) {
    return DockDisplaySettings(
      hideUnpinned: hideUnpinned ?? this.hideUnpinned,
      hideAll: hideAll ?? this.hideAll,
      showFocusHighlight: showFocusHighlight ?? this.showFocusHighlight,
      showHeaderOverlay: showHeaderOverlay ?? this.showHeaderOverlay,
      animateHide: animateHide ?? this.animateHide,
    );
  }
}
