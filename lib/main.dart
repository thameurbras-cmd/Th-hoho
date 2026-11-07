// المرحلة 1: تطبيق اختبار لـ Tesseract (ara+fra) + محلّل البطاقة.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'id_parser.dart';

void main() => runApp(const ThHohoApp());

class ThHohoApp extends StatelessWidget {
  const ThHohoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Th-hoho',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: const Directionality(
            textDirection: TextDirection.rtl, child: TestPage()),
      );
}

class Side {
  String? path;
  String text = '';
  bool busy = false;
}

class TestPage extends StatefulWidget {
  const TestPage({super.key});
  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  final front = Side(), back = Side();
  final picker = ImagePicker();
  String? error;

  Future<String> _prepare(String srcPath, {int rotate = 0}) async {
    final bytes = await File(srcPath).readAsBytes();
    var im = img.decodeImage(bytes);
    if (im == null) throw 'تعذّر قراءة الصورة';
    im = img.bakeOrientation(im);
    if (rotate != 0) im = img.copyRotate(im, angle: rotate);
    if (im.width > 2200) im = img.copyResize(im, width: 2200);
    im = img.grayscale(im);
    im = img.adjustColor(im, contrast: 1.25);
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/id_${DateTime.now().microsecondsSinceEpoch}.png';
    await File(out).writeAsBytes(img.encodePng(im));
    return out;
  }

  Future<void> _ocr(Side s) async {
    s.busy = true;
    error = null;
    setState(() {});
    try {
      s.text = await FlutterTesseractOcr.extractText(
        s.path!,
        language: 'ara+fra',
        args: {'psm': '6', 'preserve_interword_spaces': '1'},
      );
    } catch (e) {
      error = 'OCR: $e';
    }
    s.busy = false;
    if (mounted) setState(() {});
  }

  Future<void> _pick(Side s, ImageSource src) async {
    final x = await picker.pickImage(source: src);
    if (x == null) return;
    try {
      s.path = await _prepare(x.path);
      await _ocr(s);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> _rotate(Side s) async {
    if (s.path == null) return;
    try {
      s.path = await _prepare(s.path!, rotate: 90);
      await _ocr(s);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Widget _card(String title, Side s) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(
                  onPressed: s.busy ? null : () => _pick(s, ImageSource.camera),
                  child: const Text('تصوير')),
              FilledButton.tonal(
                  onPressed: s.busy ? null : () => _pick(s, ImageSource.gallery),
                  child: const Text('من المعرض')),
              OutlinedButton(
                  onPressed: s.busy || s.path == null ? null : () => _rotate(s),
                  child: const Text('تدوير 90°')),
            ]),
            if (s.busy) const LinearProgressIndicator(),
            if (s.path != null) ...[
              const SizedBox(height: 8),
              Image.file(File(s.path!), height: 140),
            ],
            if (s.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('النص المقروء (خام):'),
              SelectableText(s.text,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 12)),
            ],
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = mergeId(frontText: front.text, backText: back.text);
    return Scaffold(
      appBar: AppBar(title: const Text('Th-hoho — اختبار القراءة')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        _card('وجه البطاقة', front),
        _card('ظهر البطاقة (الشريط الآلي)', back),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('النتيجة المستخرجة',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (r.fields.isEmpty) const Text('— لا شيء بعد —'),
              for (final e in r.fields.entries)
                Text('${e.key}: ${e.value}'
                    '${r.review.contains(e.key) ? "  ⚠ راجع" : ""}'),
              if (r.conflicts.isNotEmpty)
                Text('تعارضات: ${r.conflicts.join(", ")}',
                    style: const TextStyle(color: Colors.orange)),
              if (r.missing.isNotEmpty &&
                  (front.text.isNotEmpty || back.text.isNotEmpty))
                Text('غير مقروء (يُترك فارغاً): ${r.missing.join(", ")}'),
            ]),
          ),
        ),
      ]),
    );
  }
}
