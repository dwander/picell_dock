import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dart:ui';

import '../models/dock_group.dart';

/// 레이아웃 로드 결과: 그룹 목록 + 패널별 마지막 단독 크기 + 저장 시 뷰포트 높이.
class DockLayoutData {
  final List<DockGroup> groups;
  final Map<String, Size> lastPanelAloneSizes;

  /// 레이아웃이 저장될 당시의 뷰포트 높이.
  ///
  /// 재시작 시 엣지 패널 Split 비율을 현재 뷰포트에 맞게 재조정하는 데 사용.
  final double? savedViewportHeight;

  /// 레이아웃과 함께 저장된 썸네일 크기. null이면 현재 설정 유지.
  final double? thumbnailSize;

  const DockLayoutData({
    required this.groups,
    this.lastPanelAloneSizes = const {},
    this.savedViewportHeight,
    this.thumbnailSize,
  });
}

/// 독 레이아웃 상태를 JSON 파일로 저장·복원하는 서비스.
///
/// 파일 구조:
/// ```json
/// {
///   "version": 1,
///   "currentLayout": { "groups": [...] },
///   "presets": {}
/// }
/// ```
///
/// 순수 Dart — Flutter 위젯 의존성 없음.
class DockLayoutService {
  static const String _fileName = 'dock_layout.json';
  static const int _version = 2;

  String? _filePath;

  /// 저장 파일 경로를 초기화하고 반환.
  Future<String> _getFilePath() async {
    if (_filePath != null) return _filePath!;
    final appDir = await getApplicationSupportDirectory();
    _filePath = p.join(appDir.path, _fileName);
    return _filePath!;
  }

  /// 저장된 레이아웃 로드. 그룹 목록 + 패널별 마지막 단독 크기를 반환.
  Future<DockLayoutData?> loadLayout() async {
    try {
      final path = await _getFilePath();
      final file = File(path);
      if (!file.existsSync()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      final version = json['version'] as int? ?? 0;
      // v1: dockedEdge 없음 → fromJson에서 null로 처리되므로 그대로 로드
      if (version < 1 || version > _version) return null;

      final layout = json['currentLayout'] as Map<String, dynamic>?;
      if (layout == null) return null;

      final groupsJson = layout['groups'] as List?;
      if (groupsJson == null || groupsJson.isEmpty) return null;

      final groups = [
        for (final g in groupsJson)
          DockGroup.fromJson(g as Map<String, dynamic>),
      ];

      // 패널별 마지막 단독 크기 복원
      final sizesJson =
          json['lastPanelAloneSizes'] as Map<String, dynamic>? ?? {};
      final sizes = <String, Size>{};
      for (final entry in sizesJson.entries) {
        final v = entry.value as Map<String, dynamic>;
        sizes[entry.key] = Size(
          (v['width'] as num).toDouble(),
          (v['height'] as num).toDouble(),
        );
      }

      final savedViewportHeight =
          (json['viewportHeight'] as num?)?.toDouble();

      final thumbnailSize = (json['thumbnailSize'] as num?)?.toDouble();

      return DockLayoutData(
        groups: groups,
        lastPanelAloneSizes: sizes,
        savedViewportHeight: savedViewportHeight,
        thumbnailSize: thumbnailSize,
      );
    } catch (e, st) {
      dev.log(
        '레이아웃 로드 실패',
        error: e,
        stackTrace: st,
        name: 'DockLayoutService',
      );
      return null;
    }
  }

  /// 현재 레이아웃(그룹 목록 + 패널별 마지막 단독 크기 + 뷰포트 높이)을 저장.
  Future<void> saveLayout(
    List<DockGroup> groups, {
    Map<String, Size> lastPanelAloneSizes = const {},
    double? viewportHeight,
    double? thumbnailSize,
  }) async {
    final path = await _getFilePath();
    final file = File(path);

    // 기존 파일에서 presets 등 다른 데이터 유지
    Map<String, dynamic> existing = {};
    try {
      if (file.existsSync()) {
        existing =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (e, st) {
      dev.log(
        '기존 레이아웃 파싱 실패, 새로 생성',
        error: e,
        stackTrace: st,
        name: 'DockLayoutService',
      );
    }

    existing['version'] = _version;
    existing['currentLayout'] = {
      'groups': [for (final g in groups) g.toJson()],
    };
    if (viewportHeight != null) {
      existing['viewportHeight'] = viewportHeight;
    }
    if (thumbnailSize != null) {
      existing['thumbnailSize'] = thumbnailSize;
    }
    existing['lastPanelAloneSizes'] = {
      for (final entry in lastPanelAloneSizes.entries)
        entry.key: {
          'width': entry.value.width,
          'height': entry.value.height,
        },
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(existing);
    await file.writeAsString(jsonStr);
  }
}
