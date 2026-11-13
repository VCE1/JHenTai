import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/string_extension.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/setting/preference_setting.dart';
import 'package:jhentai/src/widget/eh_gallery_detail_dialog.dart';

void main() {
  test('hideGalleryRating defaults to false and round-trips through config serialization', () {
    final PreferenceSetting setting = PreferenceSetting();
    expect(setting.hideGalleryRating.value, isFalse);

    setting.hideGalleryRating.value = true;
    final String serialized = setting.toConfigString();

    final PreferenceSetting restored = PreferenceSetting();
    expect(restored.hideGalleryRating.value, isFalse);
    restored.applyBeanConfig(serialized);
    expect(restored.hideGalleryRating.value, isTrue);
  });

  test('all locales include hideGalleryRating translations', () {
    final Map<String, Map<String, String>> keys = LocaleText().keys;
    for (final entry in keys.entries) {
      expect(entry.value['hideGalleryRating'], isNotEmpty, reason: 'Missing hideGalleryRating for ${entry.key}');
      expect(entry.value['hideGalleryRatingHint'], isNotEmpty, reason: 'Missing hideGalleryRatingHint for ${entry.key}');
    }
  });

  testWidgets('EHGalleryDetailDialog hides rating and ratingCount immediately when hideGalleryRating is true', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      preferenceSetting.hideGalleryRating.value = false;
    });
    preferenceSetting.hideGalleryRating.value = false;

    final GalleryDetail detail = GalleryDetail(
      galleryUrl: const GalleryUrl(isEH: true, gid: 123456, token: 'abcdef1234'),
      rawTitle: 'Test Gallery Title',
      japaneseTitle: 'テストギャラリー',
      category: 'Doujinshi',
      cover: GalleryImage(url: 'https://example.com/cover.jpg'),
      pageCount: 24,
      rating: 4.5,
      realRating: 4.78,
      hasRated: false,
      ratingCount: 321,
      favoriteCount: 99,
      language: 'Chinese',
      uploader: 'tester',
      publishTime: '2026-01-01 00:00',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
      size: '10.0 MiB',
      torrentCount: '0',
      torrentPageUrl: 'https://e-hentai.org/gallerytorrents.php?gid=123456&t=abcdef1234',
      archivePageUrl: 'https://e-hentai.org/archiver.php?gid=123456&token=abcdef1234',
      comments: const [],
      thumbnails: const [],
      thumbnailsPageCount: 1,
    );

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: EHGalleryDetailDialog(galleryDetail: detail),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ratingCount'.tr), findsOneWidget);
    expect(find.text('rating'.tr), findsOneWidget);
    expect(find.text('321'.breakWord), findsOneWidget);
    expect(find.text('4.78'.breakWord), findsOneWidget);

    preferenceSetting.hideGalleryRating.value = true;
    await tester.pumpAndSettle();

    expect(find.text('ratingCount'.tr), findsNothing);
    expect(find.text('rating'.tr), findsNothing);
    expect(find.text('321'.breakWord), findsNothing);
    expect(find.text('4.78'.breakWord), findsNothing);
    expect(find.text('99'.breakWord), findsOneWidget);
  });
}
