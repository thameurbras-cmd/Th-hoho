// ============================================================================
//  ID-to-PDF Bridge — شاشة مسح بطاقة التعريف الوطنية (الواجهة الأمامية)
//
//  pubspec.yaml  →  dependencies:
//    camera: ^0.11.0
//    google_mlkit_text_recognition: ^0.15.0
//
//  Android: android/app/build.gradle  →  minSdkVersion 23
//           AndroidManifest.xml       →  <uses-permission android:name="android.permission.CAMERA"/>
//  iOS:     Info.plist                →  NSCameraUsageDescription
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const IdScannerApp());
}

// ───────────────────────────── Design tokens ─────────────────────────────

class AppColors {
  static const ink = Color(0xFF0C1117); // الخلفية
  static const panel = Color(0xFF151C25); // الأسطح
  static const line = Color(0xFF263241); // الحدود
  static const text = Color(0xFFE8EDF3);
  static const textDim = Color(0xFF8C9AAB);
  static const accent = Color(0xFF4FD1B5); // زوايا الإطار + الأزرار
  static const warn = Color(0xFFFFB454);
  static const mask = Color(0xB8000000); // التعتيم حول الإطار
}

class IdScannerApp extends StatelessWidget {
  const IdScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مسح بطاقة التعريف',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.ink,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          surface: AppColors.panel,
        ),
      ),
      // فرض اتجاه RTL دون الحاجة لحزمة flutter_localizations
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const IdScannerScreen(),
    );
  }
}

// ───────────────────────────── Data model ─────────────────────────────

/// هيكل البيانات المستخرجة من البطاقة.
/// يُرسَل إلى الحاسوب (سكربت Python) بصيغة JSON التالية:
/// ```json
/// {
///   "last_name":   "BENALI",
///   "first_name":  "MOHAMED",
///   "birth_date":  "05/03/1990",        // dd/MM/yyyy
///   "birth_place": "ALGER",
///   "national_id": "109900000000000000", // 18 رقماً
///   "issue_date":  "01/02/2022",
///   "issue_place": "ALGER",
///   "source":      "mlkit_ocr",
///   "scanned_at":  "2026-11-05T10:30:00.000"
/// }
/// ```
class IdCardData {
  const IdCardData({
    this.lastName = '',
    this.firstName = '',
    this.birthDate = '',
    this.birthPlace = '',
    this.nationalId = '',
    this.issueDate = '',
    this.issuePlace = '',
  });

  final String lastName;
  final String firstName;
  final String birthDate;
  final String birthPlace;
  final String nationalId;
  final String issueDate;
  final String issuePlace;

  Map<String, dynamic> toJson() => {
        'last_name': lastName,
        'first_name': firstName,
        'birth_date': birthDate,
        'birth_place': birthPlace,
        'national_id': nationalId,
        'issue_date': issueDate,
        'issue_place': issuePlace,
        'source': 'mlkit_ocr',
        'scanned_at': DateTime.now().toIso8601String(),
      };

  // ── محلّل النص: يحوّل نتيجة ML Kit إلى حقول منظّمة ──────────────────────
  // ملاحظة: مُتعرِّف ML Kit لا يدعم الخط العربي، لذلك نقرأ الحقول اللاتينية
  // (Nom / Prénom / Date de naissance / NIN) المطبوعة على البطاقة، ونعتمد على
  // الأرقام والتسميات اللاتينية. الشاشة التالية تتيح تصحيح أي حقل يدوياً.

  static final _firstNameLabel =
      RegExp(r'PR[EÉé]NOMS?|GIVEN\s*NAMES?', caseSensitive: false);
  static final _lastNameLabel =
      RegExp(r'\bNOM\b|SURNAME', caseSensitive: false);
  static final _dateRegex =
      RegExp(r'(\d{1,2})\s*[./\-]\s*(\d{1,2})\s*[./\-]\s*(\d{4})');
  static final _birthPlaceLabel = RegExp(
      r'(DATE\s*ET\s*)?LIEU\s*DE\s*NAISS\w*|(DATE\s*AND\s*)?PLACE\s*OF\s*BIRTH',
      caseSensitive: false);
  static final _issuePlaceLabel = RegExp(
      r'LIEU\s*DE\s*D[EÉé]LIVRANCE|PLACE\s*OF\s*ISSUE|D[EÉé]LIVR[EÉé]E?\s*PAR',
      caseSensitive: false);

  factory IdCardData.fromRecognizedText(RecognizedText recognized) {
    // 1) تسطيح النص: كل سطر معترف به في قائمة واحدة
    final lines = <String>[
      for (final block in recognized.blocks)
        for (final line in block.lines) line.text.trim(),
    ].where((l) => l.isNotEmpty).toList();

    // 2) رقم التعريف الوطني: 18 رقماً متتالياً (بعد حذف المسافات)
    final compact = lines.join('\n').replaceAll(RegExp(r'\s'), '');
    final nationalId = RegExp(r'\d{18}').firstMatch(compact)?.group(0) ?? '';

    // 3) تاريخ الازدياد: أقدم تاريخ صالح على الوجه الأمامي
    //    (تاريخا الإصدار والانتهاء أحدث دائماً من تاريخ الازدياد)
    final dates = <DateTime>{};
    for (final m in _dateRegex.allMatches(lines.join('\n'))) {
      final d = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final y = int.parse(m.group(3)!);
      if (y < 1900 || y > DateTime.now().year || mo < 1 || mo > 12) continue;
      if (d < 1 || d > 31) continue;
      dates.add(DateTime(y, mo, d));
    }
    final sorted = dates.toList()..sort();
    String fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
    final birthDate = sorted.isEmpty ? '' : fmt(sorted.first);
    // تاريخ الصدور: التاريخ الأوسط فقط حين تظهر ثلاثة تواريخ (ازدياد/صدور/انتهاء)
    final issueDate = sorted.length >= 3 ? fmt(sorted[sorted.length - 2]) : '';

    // 4) الاسم واللقب: القيمة بعد التسمية في نفس السطر أو في السطر التالي
    String lastName = '';
    String firstName = '';
    String birthPlace = '';
    String issuePlace = '';
    for (var i = 0; i < lines.length; i++) {
      final upper = lines[i].toUpperCase();
      // نفحص "الاسم" أولاً لأن كلمة PRÉNOM تحتوي على NOM
      if (firstName.isEmpty && _firstNameLabel.hasMatch(upper)) {
        firstName = _valueNearLabel(lines, i, _firstNameLabel) ?? '';
      } else if (birthPlace.isEmpty && _birthPlaceLabel.hasMatch(upper)) {
        birthPlace = _valueNearLabel(lines, i, _birthPlaceLabel) ?? '';
      } else if (issuePlace.isEmpty && _issuePlaceLabel.hasMatch(upper)) {
        issuePlace = _valueNearLabel(lines, i, _issuePlaceLabel) ?? '';
      } else if (lastName.isEmpty && _lastNameLabel.hasMatch(upper)) {
        lastName = _valueNearLabel(lines, i, _lastNameLabel) ?? '';
      }
    }

    return IdCardData(
      lastName: lastName,
      firstName: firstName,
      birthDate: birthDate,
      birthPlace: birthPlace,
      nationalId: nationalId,
      issueDate: issueDate,
      issuePlace: issuePlace,
    );
  }

  static String? _valueNearLabel(List<String> lines, int i, RegExp label) {
    final sameLine = _cleanName(lines[i].replaceAll(label, ' '));
    if (sameLine.length >= 2) return sameLine;
    if (i + 1 < lines.length) {
      final next = lines[i + 1];
      final isAnotherLabel = _firstNameLabel.hasMatch(next) ||
          _lastNameLabel.hasMatch(next) ||
          _birthPlaceLabel.hasMatch(next) ||
          _issuePlaceLabel.hasMatch(next);
      final cleaned = _cleanName(next);
      if (!isAnotherLabel && cleaned.length >= 2) return cleaned;
    }
    return null;
  }

  /// يُبقي الحروف اللاتينية والفراغ والواصلة فقط.
  static String _cleanName(String s) => s
      .replaceAll(RegExp(r"[^A-Za-zÀ-ÿ' \-]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toUpperCase();
}

// ───────────────────────────── Scanner screen ─────────────────────────────

class IdScannerScreen extends StatefulWidget {
  const IdScannerScreen({super.key});

  @override
  State<IdScannerScreen> createState() => _IdScannerScreenState();
}

class _IdScannerScreenState extends State<IdScannerScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;

  /// محرك قراءة النصوص (TextRecognizer): يعمل بالكامل على الجهاز بلا إنترنت.
  /// نستخدم النص اللاتيني (TextRecognitionScript.latin).
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  bool _isProcessing = false;
  bool _torchOn = false;
  String? _errorMessage;
  String _serverAddress = ''; // عنوان الحاسوب، مثل 192.168.1.10:8000

  // ── دورة الحياة ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose(); // تحرير الكاميرا
    _recognizer.close(); // تحرير موارد ML Kit
    super.dispose();
  }

  /// عند الذهاب للخلفية نحرّر الكاميرا، وعند العودة نعيد تشغيلها.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _controller = null;
      controller.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_controller != null) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorMessage = 'لم يتم العثور على كاميرا في هذا الجهاز.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh, // دقة عالية لقراءة الأحرف الصغيرة
        enableAudio: false,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);

      // قد تُغلق الشاشة أثناء التهيئة → نتجنّب تسريب الكاميرا
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _torchOn = false;
        _errorMessage = null;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.code == 'CameraAccessDenied'
            ? 'يلزم السماح بالوصول إلى الكاميرا من إعدادات الهاتف.'
            : 'تعذّر تشغيل الكاميرا (${e.code}).';
      });
    }
  }

  // ── الإجراءات ────────────────────────────────────────────────────────────

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = !_torchOn;
    await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
    setState(() => _torchOn = next);
  }

  Future<void> _captureAndRead() async {
    final controller = _controller;
    if (_isProcessing || controller == null || !controller.value.isInitialized) {
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _isProcessing = true);

    File? photo;
    try {
      final shot = await controller.takePicture();
      photo = File(shot.path);

      // ← هنا تُمرَّر الصورة إلى محرك الـ OCR
      final input = InputImage.fromFilePath(photo.path);
      final recognized = await _recognizer.processImage(input);
      final data = IdCardData.fromRecognizedText(recognized);

      if (!mounted) return;
      setState(() => _isProcessing = false);
      await _showResultSheet(data);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showSnack('تعذّرت قراءة البطاقة. أعد المحاولة في إضاءة أفضل.');
    } finally {
      // خصوصية: لا نُبقي صورة البطاقة على الهاتف بعد المعالجة
      try {
        await photo?.delete();
      } catch (_) {}
    }
  }

  Future<void> _showResultSheet(IdCardData data) async {
    final confirmed = await showModalBottomSheet<IdCardData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => ResultSheet(initial: data),
    );
    if (confirmed != null) await _onConfirmed(confirmed);
  }

  /// الخطوة التالية بعد مراجعة المستخدم.
  /// مكان إرسال JSON إلى سكربت Python على الحاسوب عبر الـ Wi-Fi المحلي.
  Future<void> _onConfirmed(IdCardData data) async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => _AddressDialog(initial: _serverAddress),
    );
    if (address == null || address.isEmpty) return;
    _serverAddress = address;

    setState(() => _isProcessing = true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client
          .postUrl(Uri.parse('http://$address/fill'))
          .timeout(const Duration(seconds: 8));
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(data.toJson())));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      final reply = jsonDecode(body) as Map<String, dynamic>;
      if (!mounted) return;
      _showSnack(reply['message']?.toString() ?? 'تم الإرسال.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('تعذّر الاتصال بالحاسوب. تأكد أن البرنامج يعمل '
          'وأن الهاتف على نفس شبكة Wi-Fi.');
    } finally {
      client.close();
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.panel,
      ));
  }

  // ── البناء ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _errorMessage != null
          ? _ErrorView(message: _errorMessage!, onRetry: _initCamera)
          : _controller == null || !_controller!.value.isInitialized
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.accent))
              : _buildScanner(),
    );
  }

  Widget _buildScanner() {
    final preview = _controller!.value.previewSize!;
    return Stack(
      fit: StackFit.expand,
      children: [
        // معاينة الكاميرا بملء الشاشة (قصّ بدل التمطيط)
        ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: preview.height, // الأبعاد معكوسة في الوضع العمودي
              height: preview.width,
              child: CameraPreview(_controller!),
            ),
          ),
        ),

        // القناع + زوايا الإطار
        LayoutBuilder(builder: (context, box) {
          final frame = ScanFrame.rectFor(box.biggest);
          return Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: ScanMaskPainter(
                  frame: frame,
                  cornerColor:
                      _isProcessing ? AppColors.warn : AppColors.accent,
                ),
              ),
              Positioned(
                top: frame.top - 92,
                left: 24,
                right: 24,
                child: _HintText(isProcessing: _isProcessing),
              ),
            ],
          );
        }),

        // الشريط العلوي
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  tooltip: 'إغلاق',
                ),
                const Spacer(),
                IconButton(
                  onPressed: _toggleTorch,
                  icon: Icon(
                    _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                    color: _torchOn ? AppColors.warn : Colors.white,
                  ),
                  tooltip: 'المصباح',
                ),
              ],
            ),
          ),
        ),

        // زر الالتقاط
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Center(
                child: CaptureButton(
                  busy: _isProcessing,
                  onTap: _captureAndRead,
                ),
              ),
            ),
          ),
        ),

        // طبقة التحميل
        _LoadingOverlay(visible: _isProcessing),
      ],
    );
  }
}

// ───────────────────────────── Overlay pieces ─────────────────────────────

class ScanFrame {
  /// نسبة بطاقة التعريف (ISO/IEC 7810 ID-1): 85.60 × 53.98 مم
  static const double aspect = 85.60 / 53.98;

  static Rect rectFor(Size size) {
    final width = size.width * 0.88;
    final height = width / aspect;
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: width,
      height: height,
    );
  }
}

class ScanMaskPainter extends CustomPainter {
  ScanMaskPainter({required this.frame, required this.cornerColor});

  final Rect frame;
  final Color cornerColor;

  static const double _radius = 20;
  static const double _arm = 34;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(frame, const Radius.circular(_radius));

    // 1) تعتيم كل الشاشة ما عدا داخل الإطار
    final dim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(rrect),
    );
    canvas.drawPath(dim, Paint()..color = AppColors.mask);

    // 2) حدّ خافت للإطار كاملاً
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x40FFFFFF),
    );

    // 3) أربع زوايا مضيئة
    final corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..color = cornerColor;

    final l = frame.left, t = frame.top, r = frame.right, b = frame.bottom;
    const rad = _radius;

    Path arc(double x, double y, double sx, double sy) => Path()
      ..moveTo(x, y + sy * _arm)
      ..lineTo(x, y + sy * rad)
      ..quadraticBezierTo(x, y, x + sx * rad, y)
      ..lineTo(x + sx * _arm, y);

    canvas.drawPath(arc(l, t, 1, 1), corner); // أعلى اليسار
    canvas.drawPath(arc(r, t, -1, 1), corner); // أعلى اليمين
    canvas.drawPath(arc(l, b, 1, -1), corner); // أسفل اليسار
    canvas.drawPath(arc(r, b, -1, -1), corner); // أسفل اليمين
  }

  @override
  bool shouldRepaint(ScanMaskPainter old) =>
      old.frame != frame || old.cornerColor != cornerColor;
}

class _HintText extends StatelessWidget {
  const _HintText({required this.isProcessing});
  final bool isProcessing;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Column(
        key: ValueKey(isProcessing),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isProcessing ? 'جارٍ قراءة البطاقة…' : 'ضع بطاقة التعريف داخل الإطار',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isProcessing
                ? 'أبقِ الهاتف ثابتاً'
                : 'اجعل البطاقة مسطّحة وواضحة وتجنّب انعكاس الضوء',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textDim,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class CaptureButton extends StatelessWidget {
  const CaptureButton({super.key, required this.onTap, required this.busy});

  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'التقاط صورة البطاقة',
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: Container(
          width: 80,
          height: 80,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            margin: EdgeInsets.all(busy ? 14 : 0),
            decoration: BoxDecoration(
              color: busy ? AppColors.textDim : AppColors.accent,
              borderRadius: BorderRadius.circular(busy ? 10 : 40),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay({required this.visible});
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Container(
          color: const Color(0x99000000),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.line),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    color: AppColors.accent,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'جارٍ استخراج البيانات',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                size: 56, color: AppColors.textDim),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text, fontSize: 17),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.ink,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              ),
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── Results sheet ─────────────────────────────

/// نافذة مراجعة البيانات: كل حقل قابل للتعديل قبل الاعتماد.
/// تُرجِع [IdCardData] عند الاعتماد، أو null عند "إعادة المسح".
class ResultSheet extends StatefulWidget {
  const ResultSheet({super.key, required this.initial});
  final IdCardData initial;

  @override
  State<ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<ResultSheet> {
  late final TextEditingController _lastName;
  late final TextEditingController _firstName;
  late final TextEditingController _birthDate;
  late final TextEditingController _nationalId;
  late final TextEditingController _birthPlace;
  late final TextEditingController _issueDate;
  late final TextEditingController _issuePlace;

  @override
  void initState() {
    super.initState();
    _lastName = TextEditingController(text: widget.initial.lastName);
    _firstName = TextEditingController(text: widget.initial.firstName);
    _birthDate = TextEditingController(text: widget.initial.birthDate);
    _nationalId = TextEditingController(text: widget.initial.nationalId);
    _birthPlace = TextEditingController(text: widget.initial.birthPlace);
    _issueDate = TextEditingController(text: widget.initial.issueDate);
    _issuePlace = TextEditingController(text: widget.initial.issuePlace);
  }

  @override
  void dispose() {
    _lastName.dispose();
    _firstName.dispose();
    _birthDate.dispose();
    _nationalId.dispose();
    _birthPlace.dispose();
    _issueDate.dispose();
    _issuePlace.dispose();
    super.dispose();
  }

  bool get _hasMissing => [
        _lastName,
        _firstName,
        _birthDate,
        _birthPlace,
        _nationalId,
        _issueDate,
        _issuePlace,
      ].any((c) => c.text.trim().isEmpty);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 12, 24, 20 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'راجع البيانات المستخرجة',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _hasMissing
                  ? 'بعض الحقول لم تُقرأ. أكملها يدوياً قبل المتابعة.'
                  : 'صحّح أي حقل إن لزم، ثم اعتمد البيانات.',
              style: TextStyle(
                color: _hasMissing ? AppColors.warn : AppColors.textDim,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            _Field(label: 'اللقب', controller: _lastName, latin: true),
            _Field(label: 'الاسم', controller: _firstName, latin: true),
            _Field(
              label: 'تاريخ الازدياد',
              controller: _birthDate,
              hint: 'يوم/شهر/سنة',
              keyboard: TextInputType.datetime,
            ),
            _Field(label: 'مكان الازدياد', controller: _birthPlace, latin: true),
            _Field(
              label: 'رقم التعريف الوطني',
              controller: _nationalId,
              hint: '18 رقماً',
              keyboard: TextInputType.number,
              maxLength: 18,
            ),
            _Field(
              label: 'تاريخ الصدور',
              controller: _issueDate,
              hint: 'يوم/شهر/سنة',
              keyboard: TextInputType.datetime,
            ),
            _Field(label: 'مكان الإصدار', controller: _issuePlace, latin: true),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.line),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('إعادة المسح'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(IdCardData(
                      lastName: _lastName.text.trim(),
                      firstName: _firstName.text.trim(),
                      birthDate: _birthDate.text.trim(),
                      birthPlace: _birthPlace.text.trim(),
                      nationalId: _nationalId.text.trim(),
                      issueDate: _issueDate.text.trim(),
                      issuePlace: _issuePlace.text.trim(),
                    )),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.ink,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('اعتماد وإرسال إلى الحاسوب'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboard,
    this.maxLength,
    this.latin = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboard;
  final int? maxLength;
  final bool latin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        maxLength: maxLength,
        textCapitalization:
            latin ? TextCapitalization.characters : TextCapitalization.none,
        // القيم اللاتينية والأرقام تُعرض من اليسار إلى اليمين لسهولة المراجعة
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
        style: const TextStyle(
          color: AppColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          counterText: '',
          filled: true,
          fillColor: AppColors.ink,
          labelStyle: const TextStyle(color: AppColors.textDim),
          hintStyle: const TextStyle(color: AppColors.line),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.accent, width: 1.6),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Address dialog ─────────────────────────────

/// نافذة إدخال عنوان الحاسوب (يظهره البرنامج على شاشة الحاسوب).
class _AddressDialog extends StatefulWidget {
  const _AddressDialog({required this.initial});
  final String initial;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: widget.initial.isEmpty ? '192.168.1.' : widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: const Text('عنوان الحاسوب'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'اكتب العنوان الظاهر في برنامج الحاسوب.',
            style: TextStyle(color: AppColors.textDim),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: '192.168.1.10:8000'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.ink,
          ),
          child: const Text('إرسال'),
        ),
      ],
    );
  }
}
