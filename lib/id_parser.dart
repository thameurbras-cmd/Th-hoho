// محلّل بطاقة التعريف الجزائرية - نفس منطق id_parser.py (النموذج المُختبَر).
// القاعدة: أي حقل غير مؤكَّد يبقى null. لا تخمين.
// ملاحظة: هذا الملف لم يُشغَّل بعد (لا يوجد Dart في بيئة الكتابة)؛
// شغّل: flutter test test/id_parser_test.dart

class Dmy {
  final int d, m, y;
  const Dmy(this.d, this.m, this.y);
  @override
  bool operator ==(Object o) => o is Dmy && o.d == d && o.m == m && o.y == y;
  @override
  int get hashCode => Object.hash(d, m, y);
  String get text =>
      '${d.toString().padLeft(2, '0')}/${m.toString().padLeft(2, '0')}/$y';
  int get sortKey => y * 10000 + m * 100 + d;
}

String normDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    var i = ar.indexOf(c);
    if (i < 0) i = fa.indexOf(c);
    b.write(i >= 0 ? '$i' : c);
  }
  return b.toString();
}

Dmy? _mk(int y, int mo, int d) {
  if (y < 1900 || y > 2100) return null;
  final t = DateTime(y, mo, d);
  if (t.year != y || t.month != mo || t.day != d) return null;
  return Dmy(d, mo, y);
}

/// يقبل yyyy.mm.dd أو dd/mm/yyyy. null إن كان غير صالح.
Dmy? parseDate(String input) {
  final s = normDigits(input);
  var m = RegExp(r'(\d{4})\s*[./\-]\s*(\d{1,2})\s*[./\-]\s*(\d{1,2})').firstMatch(s);
  if (m != null) {
    return _mk(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
  m = RegExp(r'(\d{1,2})\s*[./\-]\s*(\d{1,2})\s*[./\-]\s*(\d{4})').firstMatch(s);
  if (m != null) {
    return _mk(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
  }
  return null;
}

// ---------- الشريط الآلي (TD1) ----------
int? mrzCheck(String s) {
  const w = [7, 3, 1];
  var t = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    int v;
    if (c >= 48 && c <= 57) {
      v = c - 48;
    } else if (s[i] == '<') {
      v = 0;
    } else if (c >= 65 && c <= 90) {
      v = c - 55;
    } else {
      return null;
    }
    t += v * w[i % 3];
  }
  return t % 10;
}

const _conf = r'0-9OQDIZSBG/'; // أحرف قد تُقرأ بدل أرقام (و"/" بدل 7)

String _fix(String s) {
  const from = 'OQDIZSBG/', to = '000125867';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

String _cleanMrzLine(String raw) => raw
    .toUpperCase()
    .replaceAll(RegExp('[«»‹›]'), '<')
    .replaceAll(RegExp(r'[^A-Z0-9</]'), '');

bool _isDigits(String s) => RegExp(r'^\d+$').hasMatch(s);

Dmy? _yymmdd(String s, bool expiry, DateTime today) {
  if (!RegExp(r'^\d{6}$').hasMatch(s)) return null;
  final yy = int.parse(s.substring(0, 2));
  final mm = int.parse(s.substring(2, 4));
  final dd = int.parse(s.substring(4));
  final y = expiry
      ? 2000 + yy
      : (yy <= today.year % 100 ? 2000 + yy : 1900 + yy);
  return _mk(y, mm, dd);
}

class Mrz {
  String? docNumber, nomFr, prenomFr, sex;
  Dmy? birth, expiry;
  bool compositeOk = false;
}

Mrz parseMrz(String text, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final out = Mrz();
  final lines = text
      .split('\n')
      .map(_cleanMrzLine)
      .where((l) => l.length >= 15)
      .toList();

  // السطر 2: yymmdd + تحقق + جنس + yymmdd + تحقق (يُبحث عنه بالنمط)
  final pat2 = RegExp('([$_conf]{6})([$_conf])([MF<])([$_conf]{6})([$_conf])');
  String? l2;
  RegExpMatch? m2;
  for (final ln in lines) {
    final m = pat2.firstMatch(ln);
    if (m == null) continue;
    l2 = ln;
    m2 = m;
    final bSeg = _fix(m[1]!), bChk = _fix(m[2]!);
    if (mrzCheck(bSeg) == int.parse(bChk)) {
      out.birth = _yymmdd(bSeg, false, today);
    }
    final eSeg = _fix(m[4]!), eChk = _fix(m[5]!);
    if (mrzCheck(eSeg) == int.parse(eChk)) {
      out.expiry = _yymmdd(eSeg, true, today);
    }
    if (m[3] == 'M' || m[3] == 'F') out.sex = m[3];
    break;
  }

  // السطر 1 (اختياري): IDDZA + رقم الوثيقة + تحقق
  final pat1 = RegExp('IDDZA([$_conf<]{9})([$_conf])');
  for (final ln in lines) {
    final m = pat1.firstMatch(ln);
    if (m == null) continue;
    final num = _fix(m[1]!), chk = _fix(m[2]!);
    if (_isDigits(num) && mrzCheck(num) == int.parse(chk)) out.docNumber = num;
    if (l2 != null && m2 != null && out.birth != null && out.expiry != null) {
      final l1n = ln.substring(m.start).padRight(30, '<').substring(0, 30);
      final l2n = l2.substring(m2.start).padRight(30, '<').substring(0, 30);
      final comp = _fix(l1n.substring(5, 30)) +
          _fix(l2n.substring(0, 7)) +
          _fix(l2n.substring(8, 15)) +
          _fix(l2n.substring(18, 29));
      final cc = _fix(l2n[29]);
      if (_isDigits(cc) && mrzCheck(comp) == int.parse(cc)) {
        out.compositeOk = true;
      }
    }
    break;
  }

  // السطر 3: NOM<<PRENOM<PRENOM
  final pat3 = RegExp(r'([A-Z]{2,}(?:<[A-Z]{2,})*)<<([A-Z]+(?:<[A-Z]+)*)');
  for (final ln in lines) {
    final m = pat3.firstMatch(ln);
    if (m == null) continue;
    out.nomFr = m[1]!.replaceAll('<', ' ').trim();
    out.prenomFr = m[2]!.replaceAll('<', ' ').trim();
    break;
  }
  return out;
}

// ---------- الوجه (عربي) ----------
String _al(String p) => p.replaceAll('ا', '[اأإآ]');

final Map<String, String> _labels = {
  'prenom_ar': _al(r'الاسم'),
  'nom_ar': _al(r'اللقب'),
  'date_naissance': _al(r'تاريخ\s*الميلاد'),
  'lieu_naissance': _al(r'مكان\s*الميلاد'),
  'date_delivrance': _al(r'تاريخ\s*الاصدار'),
  'date_expiration': _al(r'تاريخ\s*الانتهاء'),
  'lieu_delivrance': _al(r'سلطة\s*الاصدار'),
  'nin_label': _al(r'رقم\s*التعريف\s*الوطني'),
};
final RegExp _anyLabel =
    RegExp(_labels.values.map((p) => '(?:$p)').join('|'));

String _valueAfter(List<String> lines, int idx, String pat) {
  final m = RegExp('$pat\\s*[:：]?\\s*(.*)\$').firstMatch(lines[idx]);
  var val = (m?.group(1) ?? '').trim();
  if (val.isEmpty && idx + 1 < lines.length && !_anyLabel.hasMatch(lines[idx + 1])) {
    val = lines[idx + 1].trim();
  }
  return val;
}

const _stop = {'ابن', 'بن', 'بنت', 'ال', 'و'};

String? _cleanAr(String v) {
  final s = v
      .replaceAll(RegExp(r'[^\u0621-\u064A\s\-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[ \-]+|[ \-]+$'), '');
  if (s.replaceAll(' ', '').length < 2) return null;
  // قيمة كلها كلمات ربط أو حروف مفردة = قراءة ناقصة، تُترك فارغة
  if (s.split(' ').every((t) => _stop.contains(t) || t.length == 1)) return null;
  return s;
}

class Front {
  String? cni, prenomAr, nomAr, lieuNaissance, lieuDelivrance;
  Dmy? dateNaissance, dateDelivrance, dateExpiration;
}

Front parseFront(String text) {
  final out = Front();
  final lines = text
      .split('\n')
      .map((l) => normDigits(l).trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final nins = RegExp(r'(?<!\d)\d{18}(?!\d)')
      .allMatches(lines.join('\n'))
      .map((m) => m[0]!)
      .toSet();
  if (nins.length == 1) out.cni = nins.first;

  Dmy? date(String key) {
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(_labels[key]!).hasMatch(lines[i])) {
        return parseDate(_valueAfter(lines, i, _labels[key]!));
      }
    }
    return null;
  }

  out.dateNaissance = date('date_naissance');
  out.dateDelivrance = date('date_delivrance');
  out.dateExpiration = date('date_expiration');

  String? txt(String key) {
    for (var i = 0; i < lines.length; i++) {
      if (key == 'prenom_ar' && RegExp(_labels['nom_ar']!).hasMatch(lines[i])) {
        continue;
      }
      if (RegExp(_labels[key]!).hasMatch(lines[i])) {
        return _cleanAr(_valueAfter(lines, i, _labels[key]!));
      }
    }
    return null;
  }

  out.prenomAr = txt('prenom_ar');
  out.nomAr = txt('nom_ar');
  out.lieuNaissance = txt('lieu_naissance');
  out.lieuDelivrance = txt('lieu_delivrance');
  return out;
}

({String? nom, String? prenom}) parseBackLabels(String text) {
  final n = RegExp(r"Nom\s*[:：]\s*([A-Z][A-Z \-']+)").firstMatch(text);
  final p = RegExp(r"Pr[ée]nom\(?s?\)?\s*[:：]\s*([A-Z][A-Z \-']+)").firstMatch(text);
  return (nom: n?[1]?.trim(), prenom: p?[1]?.trim());
}

// ---------- الدمج ----------
class IdResult {
  final Map<String, String> fields = {};
  final List<String> review = [];
  final List<String> conflicts = [];
  final List<String> missing = [];

  /// مفاتيح fill_pdf.py (الحقول غير المتوفرة تبقى فارغة).
  Map<String, String> toFormData() {
    const keys = [
      'prenom_ar', 'nom_ar', 'date_naissance', 'lieu_naissance',
      'cni', 'date_delivrance', 'lieu_delivrance'
    ];
    return {for (final k in keys) if (fields.containsKey(k)) k: fields[k]!};
  }
}

IdResult mergeId({String frontText = '', String backText = '', DateTime? now}) {
  final f = frontText.isEmpty ? Front() : parseFront(frontText);
  final mz = backText.isEmpty ? Mrz() : parseMrz(backText, now: now);
  final bl = backText.isEmpty ? (nom: null, prenom: null) : parseBackLabels(backText);
  final r = IdResult();

  void put(String k, String? v) {
    if (v != null) r.fields[k] = v;
  }

  void dateField(String key, Dmy? a, Dmy? b) {
    if (a != null && b != null && a != b) {
      r.conflicts.add(key);
      put(key, a.text); // نُبقي قيمة الوجه ونعلّم التعارض
    } else {
      put(key, (a ?? b)?.text);
    }
  }

  dateField('date_naissance', f.dateNaissance, mz.birth);
  dateField('date_expiration', f.dateExpiration, mz.expiry);
  put('date_delivrance', f.dateDelivrance?.text);
  put('cni', f.cni);
  put('prenom_ar', f.prenomAr);
  put('nom_ar', f.nomAr);
  put('lieu_naissance', f.lieuNaissance);
  put('lieu_delivrance', f.lieuDelivrance);

  void nameField(String key, String? a, String? b) {
    if (a != null && b != null && a != b) {
      r.conflicts.add(key);
      put(key, b);
    } else {
      put(key, a ?? b);
    }
  }

  nameField('nom_fr', mz.nomFr, bl.nom);
  nameField('prenom_fr', mz.prenomFr, bl.prenom);
  put('doc_number', mz.docNumber);

  int? sk(String k) {
    final v = r.fields[k];
    if (v == null) return null;
    return int.parse(v.substring(6)) * 10000 +
        int.parse(v.substring(3, 5)) * 100 +
        int.parse(v.substring(0, 2));
  }

  final seq = ['date_naissance', 'date_delivrance', 'date_expiration']
      .map(sk)
      .whereType<int>()
      .toList();
  final sorted = [...seq]..sort();
  for (var i = 0; i < seq.length; i++) {
    if (seq[i] != sorted[i]) {
      r.conflicts.add('ordre_dates');
      break;
    }
  }
  r.review.addAll(['lieu_delivrance', 'lieu_naissance', 'nom_ar', 'prenom_ar']);
  for (final k in [
    'prenom_ar', 'nom_ar', 'date_naissance', 'lieu_naissance',
    'cni', 'date_delivrance', 'lieu_delivrance'
  ]) {
    if (!r.fields.containsKey(k)) r.missing.add(k);
  }
  return r;
}
