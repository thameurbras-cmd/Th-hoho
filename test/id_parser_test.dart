import 'package:flutter_test/flutter_test.dart';
import 'package:th_hoho/id_parser.dart';

String makeMrz({
  String doc = '123456789',
  String dob = '900115',
  String exp = '300220',
  String nom = 'TESTNAME',
  String pre = 'TESTFIRST',
}) {
  final l1 = ('IDDZA$doc${mrzCheck(doc)}').padRight(30, '<');
  var l2 = '$dob${mrzCheck(dob)}M$exp${mrzCheck(exp)}DZA${'<' * 11}';
  final comp = l1.substring(5, 30) + l2.substring(0, 7) + l2.substring(8, 15) + l2.substring(18, 29);
  l2 += '${mrzCheck(comp)}';
  final l3 = ('$nom<<$pre').padRight(30, '<');
  return [l1, l2, l3].join('\n');
}

const front = '''الجمهورية الجزائرية الديمقراطية الشعبية
بطاقة التعريف الوطنية
123456789
سلطة الإصدار: بلدية المدينة-الولاية
تاريخ الإصدار: 2020.03.15
تاريخ الانتهاء: 2030.02.20
رقم التعريف الوطني: 100000000000000001
اللقب: بنمحمد
الإسم: أحمد
تاريخ الميلاد: 1990.01.15
مكان الميلاد: الجزائر''';

void main() {
  final today = DateTime(2026, 11, 6);

  test('dates', () {
    expect(parseDate('2021.11.09'), const Dmy(9, 11, 2021));
    expect(parseDate('09/11/2021'), const Dmy(9, 11, 2021));
    expect(parseDate('٠٩/١١/٢٠٢١'), const Dmy(9, 11, 2021));
    expect(parseDate('2021.13.40'), isNull);
    expect(parseDate('2021.02.30'), isNull);
  });

  test('mrz valid', () {
    final r = parseMrz(makeMrz(), now: today);
    expect(r.docNumber, '123456789');
    expect(r.birth, const Dmy(15, 1, 1990));
    expect(r.expiry, const Dmy(20, 2, 2030));
    expect(r.compositeOk, isTrue);
    expect(r.nomFr, 'TESTNAME');
  });

  test('mrz wrong check digit rejected', () {
    final l = makeMrz().split('\n');
    l[1] = l[1].substring(0, 6) + '0' + l[1].substring(7);
    final r = parseMrz(l.join('\n'), now: today);
    expect(r.birth, isNull);
    expect(r.expiry, isNotNull);
  });

  test('mrz century pivot', () {
    expect(parseMrz(makeMrz(dob: '071021'), now: today).birth, const Dmy(21, 10, 2007));
    expect(parseMrz(makeMrz(dob: '761231'), now: today).birth, const Dmy(31, 12, 1976));
  });

  test('front full', () {
    final r = parseFront(front);
    expect(r.cni, '100000000000000001');
    expect(r.prenomAr, 'أحمد');
    expect(r.nomAr, 'بنمحمد');
    expect(r.dateNaissance, const Dmy(15, 1, 1990));
  });

  test('front rejects bad NIN / glare / bad date', () {
    expect(parseFront('$front\n100000000000000002').cni, isNull);
    expect(parseFront(front.replaceAll('100000000000000001', '10000000000000001')).cni, isNull);
    final g = parseFront(front.replaceAll('اللقب: بنمحمد', 'اللقب:'));
    expect(g.nomAr, isNull);
    expect(g.prenomAr, 'أحمد');
    expect(parseFront(front.replaceAll('1990.01.15', '1990.13.45')).dateNaissance, isNull);
  });

  test('merge', () {
    final ok = mergeId(frontText: front, backText: makeMrz(), now: today);
    expect(ok.conflicts, isEmpty);
    expect(ok.fields['date_naissance'], '15/01/1990');
    final bad = mergeId(frontText: front.replaceAll('1990.01.15', '1991.01.15'), backText: makeMrz(), now: today);
    expect(bad.conflicts, contains('date_naissance'));
    expect(bad.fields['date_naissance'], '15/01/1991');
    final miss = mergeId(frontText: front.replaceAll('اللقب: بنمحمد', ''), now: today);
    expect(miss.missing, contains('nom_ar'));
    expect(miss.toFormData().containsKey('nom_ar'), isFalse);
  });
}
