# picell_dock

PiCell 플로팅 독 엔진. 패널/탭/스플릿/엣지 도킹 시스템을 재사용 가능한 로컬 path 패키지로 분리.

## 기능

- **플로팅 패널 그룹** — 8방향 리사이즈, 드래그 이동, 앵커 기반 좌표계
- **탭** — 패널 탭 바, 드래그로 순서 변경 / 분리
- **스플릿** — 수평/수직 패널 분할, 드래그 비율 조정
- **엣지 도킹** — 뷰포트 좌/우 가장자리에 패널 고정
- **패널 간 도킹** — 드래그로 탭 합치기 / 스플릿 분기
- **핀 고정 / 클린 모드** — 고정되지 않은 패널 숨김
- **레이아웃 영속성** — shared_preferences 자동 저장·복원
- **패널 줌** — 독립 줌 레벨 per 패널

## 설치

`pubspec.yaml`에 로컬 path 의존성 추가:

```yaml
dependencies:
  picell_dock:
    path: ../picell_dock
```

## 빠른 시작

### 1. ProviderScope 오버라이드

```dart
ProviderScope(
  overrides: [
    dockSettingsProvider.overrideWith((ref) => DockSettings(
      isHeaderless: MyPanelRegistry.isHeaderless,
      defaultLayout: () => _defaultGroups,
      initialFocusedPanelId: 'main-panel',
      allowAutoAvoidance:
          ref.watch(settingsProvider.select((s) => s.allowAutoAvoidance)),
    )),
  ],
  child: MyApp(),
)
```

### 2. DockTheme + DockOverlay 배치

```dart
DockTheme(
  colorScheme: const DockColorScheme(),        // 기본값: Gruvbox 다크
  config: const DockConfig(),                  // 기본값: 표준 크기
  displaySettings: DockDisplaySettings(
    hideUnpinned: ref.watch(cleanModeProvider),
    showFocusHighlight: true,
  ),
  panelDelegate: DockPanelDelegate(
    buildPanel: MyPanelRegistry.build,
    labelOf: MyPanelRegistry.displayName,
    isClosable: MyPanelRegistry.isClosable,
    buildOverlayLayout: MyPanelRegistry.buildOverlayLayout, // 선택
  ),
  child: DockOverlay(
    viewerBuilder: (size) => MyViewerWidget(viewerSize: size),
  ),
)
```

---

## API 레퍼런스

### DockOverlay

뷰어 영역 위에 모든 `DockGroup`을 렌더링하는 최상위 위젯.

| 파라미터 | 타입 | 설명 |
|---|---|---|
| `viewerBuilder` | `Widget Function(Size)` | 패널 뒤에 배치할 콘텐츠 (이미지 뷰어 등) |

`DockOverlay`는 반드시 `DockTheme`의 하위에 있어야 한다.

---

### DockTheme

`InheritedWidget`. 독 시스템 전체에 색상·설정·델리게이트를 전달.

```dart
// 하위 위젯에서 접근
final theme = DockTheme.of(context);
final cs = theme.colorScheme;
final cfg = theme.config;
```

| 파라미터 | 타입 | 설명 |
|---|---|---|
| `colorScheme` | `DockColorScheme` | 색상 팔레트 |
| `config` | `DockConfig` | 레이아웃 상수 |
| `displaySettings` | `DockDisplaySettings` | 표시 동작 설정 |
| `panelDelegate` | `DockPanelDelegate` | 패널 빌드·정보 제공 |

---

### DockColorScheme

독 시스템 색상 집합. 기본값은 Gruvbox 다크 팔레트.

```dart
DockColorScheme(
  panelBackground: Color(0xFF222222),
  accent: Color(0xFF6BA3BE),
  border: Color(0xFF353535),
  // 나머지는 기본값 사용
)
```

| 필드 | 기본값 | 용도 |
|---|---|---|
| `bg0` | `#1A1A1A` | 탭 바 배경 |
| `bg1` | `#222222` | 서브 배경 |
| `panelBackground` | `#222222` | 패널 컨테이너 배경 |
| `headerOverlay` | `#1E1E1E` | 헤더 오버레이 배경 |
| `accent` | `#6BA3BE` | 강조색 (포커스, 도킹 효과) |
| `border` | `#353535` | 패널 테두리 |
| `borderFocused` | `#4A7A91` | 포커스 테두리 |
| `textPrimary` | `#DCDCDC` | 주 텍스트 |
| `textSecondary` | `#B0B0B0` | 보조 텍스트 |
| `textMuted` | `#8A8A8A` | 흐린 텍스트 |
| `groupShadow` | 검정 그림자 | 패널 그룹 그림자 |

---

### DockConfig

레이아웃 크기 상수. `const DockConfig()`로 기본값 사용 또는 필요한 값만 재정의.

```dart
const DockConfig(
  groupMinWidth: 200.0,   // 기본 180.0
  groupMinHeight: 150.0,  // 기본 120.0
)
```

| 필드 | 기본값 | 설명 |
|---|---|---|
| `groupHeaderHeight` | `4.0` | 패널 그룹 상단 드래그 영역 높이 |
| `groupBorderRadius` | `8.0` | 패널 그룹 모서리 반경 |
| `groupMinWidth` | `180.0` | 패널 최소 너비 |
| `groupMinHeight` | `120.0` | 패널 최소 높이 |
| `panelHeaderHeight` | `24.0` | 단일 패널 헤더 높이 |
| `tabBarHeight` | `24.0` | 탭 바 높이 |
| `headerOverlayHeight` | `36.0` | 헤더 오버레이 높이 |
| `edgePanelDefaultSize` | `280.0` | 엣지 도킹 패널 기본 너비 |
| `edgeDetectThreshold` | `1.0` | 엣지 도킹 감지 임계값 (px) |

---

### DockSettings

앱별 동작 설정. `dockSettingsProvider`를 `ProviderScope.overrides`로 주입.

| 필드 | 기본값 | 설명 |
|---|---|---|
| `isHeaderless` | 항상 false | 헤더 없는 프레임으로 표시할 패널 판별 함수 |
| `defaultLayout` | null (빈 상태) | 저장 레이아웃 미존재 시 초기 그룹 목록 |
| `initialFocusedPanelId` | null | 초기 포커스 패널 ID |
| `allowAutoAvoidance` | false | 창 리사이즈 시 패널 겹침 방지 |
| `allowHorizontalPanelDock` | false | 좌우 패널 간 엣지 도킹 허용 |

---

### DockPanelDelegate

독 시스템이 패널 위젯·이름·동작을 요청할 때 호출하는 콜백 모음.

```dart
DockPanelDelegate(
  buildPanel: (panelId) => switch (panelId) {
    'folder-tree' => const FolderTreePanel(),
    'thumbnail'   => const ThumbnailPanel(),
    _             => PlaceholderPanel(panelId: panelId),
  },
  labelOf: (panelId) => switch (panelId) {
    'folder-tree' => '폴더 트리',
    'thumbnail'   => '썸네일',
    _             => panelId,
  },
  isClosable: (panelId) => panelId == 'histogram',
  buildOverlayLayout: (panelId, ref) { /* 헤더 오버레이 버튼 */ },
)
```

| 필드 | 타입 | 설명 |
|---|---|---|
| `buildPanel` | `Widget Function(String)` | 패널 ID → 위젯 |
| `labelOf` | `String Function(String)` | 패널 ID → 표시 이름 |
| `isClosable` | `bool Function(String)` | 닫기 버튼 표시 여부 |
| `buildOverlayLayout` | `DockOverlayLayout? Function(String, WidgetRef)?` | 헤더 오버레이 버튼 (선택) |

---

### DockDisplaySettings

런타임에 변경되는 표시 동작. `DockTheme`에 전달.

| 필드 | 기본값 | 설명 |
|---|---|---|
| `hideUnpinned` | false | true이면 핀 고정되지 않은 패널 숨김 (클린 모드) |
| `showFocusHighlight` | true | 포커스된 패널 테두리 강조 |
| `showHeaderOverlay` | true | 헤더 오버레이 버튼 활성화 |

---

### 레이아웃 모델

#### DockGroup — 플로팅 패널 그룹

```dart
DockGroup(
  id: 'my-panel',
  root: DockLeaf(panelId: 'thumbnail'),
  anchorX: AnchorX.right,   // left | center | right
  anchorY: AnchorY.top,     // top  | center | bottom
  offsetX: 8.0,
  offsetY: 8.0,
  width: 300,
  height: 500,
  zOrder: 1,
  pinned: true,
)
```

#### DockNode — 트리 노드 (sealed class)

```dart
// 단일 패널
DockLeaf(panelId: 'thumbnail')

// 수직 스플릿 (위 60% : 아래 40%)
DockSplit(
  axis: SplitAxis.vertical,
  children: [
    DockLeaf(panelId: 'folder-tree'),
    DockTabbed(tabIds: ['metadata', 'filter']),
  ],
  ratios: [0.6, 0.4],
)

// 탭 묶음
DockTabbed(tabIds: ['histogram', 'camera-info'], activeIndex: 0)
```

---

### PanelZoomWrapper

패널에 독립 줌 레벨을 적용하는 래퍼 위젯.
`panelZoomProvider`에서 줌 배율을 읽어 `Transform.scale`로 적용.

```dart
// DockPanelDelegate.buildPanel에서 사용
PanelZoomWrapper(panelId: 'folder-tree', child: const FolderTreePanel())

// 패널 내부에서 현재 배율 읽기
final scale = PanelScale.of(context);
```

---

## 레이아웃 저장·복원

`shared_preferences`를 통해 독 레이아웃을 자동으로 저장·복원한다.
저장 키는 `dock_layout_v1`. 앱을 재시작하면 마지막 레이아웃을 복원하고,
저장 데이터가 없으면 `DockSettings.defaultLayout`을 사용한다.

> **주의:** `DockGroup`/`DockNode` 모델 구조를 변경하면 기존 저장 데이터를
> 읽지 못할 수 있다. 스키마 변경 시 저장 키를 업데이트하거나 마이그레이션을 추가할 것.
