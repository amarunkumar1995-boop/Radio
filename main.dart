import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

const defaultShop = 'நியூ செல்வம் ரேடியோஸ், முத்தனேந்தல்';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'வாடகை கணக்கு',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

// ---------- helpers ----------
String fmt(num n) {
  final d = n.toDouble();
  if (d == d.roundToDouble()) return d.toInt().toString();
  return d.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

String pad2(double n) => fmt(n).padLeft(2, '0');
String two(int n) => n.toString().padLeft(2, '0');
String ddmmyyyy(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
String dateKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// ---------- models ----------
class RItem {
  String name;
  double given;
  double? ret;
  double rate;
  RItem(this.name, this.given, this.ret, this.rate);
  Map<String, dynamic> toJson() => {'n': name, 'g': given, 'r': ret, 'p': rate};
  factory RItem.fromJson(Map<String, dynamic> j) => RItem(
      j['n'], (j['g'] as num).toDouble(), (j['r'] as num?)?.toDouble(), (j['p'] as num).toDouble());
}

class Entry {
  String id, customer, phone;
  bool hasReturn, hasAmount;
  DateTime given;
  DateTime? returnDate;
  int days;
  List<RItem> items;
  double advance;
  Entry({
    required this.id,
    required this.customer,
    required this.phone,
    required this.hasReturn,
    required this.hasAmount,
    required this.given,
    required this.returnDate,
    required this.days,
    required this.items,
    required this.advance,
  });

  int get mult => hasReturn ? days : 1;
  double sub(RItem i) => hasAmount ? i.given * i.rate * mult : 0;
  double get total => items.fold(0.0, (s, i) => s + sub(i));
  double get balance => math.max(0, total - advance);

  Map<String, dynamic> toJson() => {
        'id': id,
        'c': customer,
        'ph': phone,
        'hr': hasReturn,
        'ha': hasAmount,
        'gd': given.toIso8601String(),
        'rd': returnDate?.toIso8601String(),
        'd': days,
        'it': items.map((e) => e.toJson()).toList(),
        'ad': advance,
      };
  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'],
        customer: j['c'],
        phone: j['ph'] ?? '',
        hasReturn: j['hr'] ?? false,
        hasAmount: j['ha'] ?? false,
        given: DateTime.parse(j['gd']),
        returnDate: j['rd'] == null ? null : DateTime.parse(j['rd']),
        days: j['d'] ?? 1,
        items: (j['it'] as List).map((e) => RItem.fromJson(e)).toList(),
        advance: (j['ad'] as num?)?.toDouble() ?? 0,
      );
}

// ---------- WhatsApp text ----------
String blockText(Entry e) {
  final l = <String>[];
  final name = e.customer.isEmpty ? '[வாடிக்கையாளர் பெயர்]' : e.customer;
  final ph = e.phone.isEmpty ? '' : ' (${e.phone})';
  l.add('*வாடிக்கையாளர் பெயர்: $name$ph*');
  if (e.hasReturn && e.returnDate != null) {
    l.add('🔄 _திரும்பப் பெறும் நாள்: ${ddmmyyyy(e.returnDate!)} (${e.days} நாட்கள்)_');
  }
  for (final it in e.items) {
    final parts = <String>['📤 கொடுத்தது: ${pad2(it.given)}'];
    if (e.hasReturn && it.ret != null) parts.add('📥 வந்தது: ${pad2(it.ret!)}');
    if (e.hasAmount) {
      final f = e.hasReturn
          ? '${fmt(it.given)} × ₹${fmt(it.rate)} × ${e.days} நாள்'
          : '${fmt(it.given)} × ₹${fmt(it.rate)}';
      parts.add('$f = *₹${fmt(e.sub(it))}*');
    }
    l.add('* ${it.name} : ${parts.join(' | ')}');
  }
  if (e.hasAmount) {
    l.add('*💰 மொத்த தொகை: ₹${fmt(e.total)}*');
    if (e.advance > 0) {
      l.add('*💵 முன்பணம்:* ₹${fmt(e.advance)} | *❗ மீதி:* ₹${fmt(e.balance)}');
    }
  }
  return l.join('\n');
}

String groupedText(List<Entry> list) {
  final groups = <String, List<Entry>>{};
  for (final e in list) {
    groups.putIfAbsent(dateKey(e.given), () => []).add(e);
  }
  final blocks = <String>[];
  groups.forEach((k, recs) {
    final header = '*📌கொடுக்கப்பட்ட நாள் - ${ddmmyyyy(recs.first.given)}*';
    blocks.add('$header\n\n${recs.map(blockText).join('\n\n')}');
  });
  return blocks.join('\n______________________________\n\n');
}

// ---------- row controllers ----------
class RowCtl {
  final name = TextEditingController();
  final given = TextEditingController();
  final ret = TextEditingController();
  final rate = TextEditingController();
  RowCtl([String n = '', String g = '', String r = '', String p = '']) {
    name.text = n;
    given.text = g;
    ret.text = r;
    rate.text = p;
  }
  void dispose() {
    name.dispose();
    given.dispose();
    ret.dispose();
    rate.dispose();
  }
}

// ---------- page ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SharedPreferences? prefs;
  final scroll = ScrollController();

  String shop = defaultShop;
  List<Entry> entries = [];
  String? editingId;

  final customer = TextEditingController();
  final phone = TextEditingController();
  final daysCtl = TextEditingController(text: '1');
  final advance = TextEditingController();
  bool hasReturn = false;
  bool hasAmount = false;
  bool inclusive = false;
  DateTime given = dateOnly(DateTime.now());
  DateTime returnDate = dateOnly(DateTime.now());
  List<RowCtl> rows = [RowCtl()];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    final s = prefs!.getString('shop');
    final e = prefs!.getString('entries');
    setState(() {
      if (s != null && s.trim().isNotEmpty) shop = s;
      if (e != null) {
        entries = (jsonDecode(e) as List).map((x) => Entry.fromJson(x)).toList();
      }
    });
  }

  void _saveEntries() =>
      prefs?.setString('entries', jsonEncode(entries.map((e) => e.toJson()).toList()));

  void toast(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // ----- days -----
  void _calcDays() {
    if (returnDate.isBefore(given)) returnDate = given;
    final diff = returnDate.difference(given).inDays;
    var d = diff == 0 ? 1 : diff;
    if (inclusive && diff > 0) d += 1;
    daysCtl.text = '$d';
  }

  int get days => hasReturn ? math.max(1, int.tryParse(daysCtl.text) ?? 1) : 1;

  Entry _draft() {
    final items = <RItem>[];
    for (final r in rows) {
      final n = r.name.text.trim();
      final g = double.tryParse(r.given.text) ?? 0;
      final rt = hasAmount ? (double.tryParse(r.rate.text) ?? 0) : 0.0;
      final rq = (hasReturn && r.ret.text.isNotEmpty) ? double.tryParse(r.ret.text) : null;
      if (n.isNotEmpty || g > 0 || rt > 0) {
        items.add(RItem(n.isEmpty ? 'பொருள்' : n, g, rq, rt));
      }
    }
    return Entry(
      id: editingId ?? DateTime.now().microsecondsSinceEpoch.toString(),
      customer: customer.text.trim(),
      phone: phone.text.trim(),
      hasReturn: hasReturn,
      hasAmount: hasAmount,
      given: given,
      returnDate: hasReturn ? returnDate : null,
      days: days,
      items: items,
      advance: hasAmount ? (double.tryParse(advance.text) ?? 0) : 0,
    );
  }

  String get previewText {
    final header = '*$shop*\n──────────────────────\n';
    final d = _draft();
    final hasDraft = d.customer.isNotEmpty || d.phone.isNotEmpty || d.items.isNotEmpty;
    if (hasDraft) return header + groupedText([d]);
    if (entries.isNotEmpty && editingId == null) return header + groupedText(entries);
    return '$header(விவரங்களை உள்ளிடவும்)';
  }

  // ----- actions -----
  void _submit() {
    final d = _draft();
    if (d.customer.isEmpty) {
      toast('வாடிக்கையாளர் பெயரை உள்ளிடவும்!');
      return;
    }
    d.items.removeWhere((i) => i.given <= 0);
    if (d.items.isEmpty) {
      toast('குறைந்தது ஒரு பொருளும் எண்ணிக்கையும் உள்ளிடவும்!');
      return;
    }
    setState(() {
      if (editingId != null) {
        final idx = entries.indexWhere((e) => e.id == editingId);
        if (idx != -1) entries[idx] = d;
        toast('அப்டேட் செய்யப்பட்டது!');
      } else {
        entries.add(d);
        toast('பட்டியலில் சேர்க்கப்பட்டது!');
      }
      _resetForm();
    });
    _saveEntries();
  }

  void _resetForm() {
    editingId = null;
    customer.clear();
    phone.clear();
    advance.clear();
    for (final r in rows) {
      r.dispose();
    }
    rows = [RowCtl()];
  }

  void _edit(Entry e) {
    setState(() {
      editingId = e.id;
      customer.text = e.customer;
      phone.text = e.phone;
      hasReturn = e.hasReturn;
      hasAmount = e.hasAmount;
      given = e.given;
      returnDate = e.returnDate ?? e.given;
      daysCtl.text = '${e.days}';
      advance.text = e.advance > 0 ? fmt(e.advance) : '';
      for (final r in rows) {
        r.dispose();
      }
      rows = e.items
          .map((i) => RowCtl(i.name, fmt(i.given), i.ret == null ? '' : fmt(i.ret!),
              i.rate == 0 ? '' : fmt(i.rate)))
          .toList();
    });
    scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  void _delete(Entry e) {
    setState(() {
      entries.removeWhere((x) => x.id == e.id);
      if (editingId == e.id) _resetForm();
    });
    _saveEntries();
    toast('பதிவு நீக்கப்பட்டது');
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('அனைத்தையும் அழிக்கவா?'),
        content: const Text('நிச்சயமாக அனைத்துப் பதிவுகளையும் அழிக்க வேண்டுமா?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('வேண்டாம்')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('ஆம், அழி')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        entries.clear();
        _resetForm();
      });
      _saveEntries();
    }
  }

  Future<void> _editShop() async {
    final c = TextEditingController(text: shop);
    final r = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('கடை பெயர்'),
        content: TextField(controller: c, maxLines: 2),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, defaultShop), child: const Text('இயல்புநிலை')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('சேமி')),
        ],
      ),
    );
    if (r != null) {
      setState(() => shop = r.isEmpty ? defaultShop : r);
      prefs?.setString('shop', shop);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: previewText));
    toast('WhatsApp ஃபார்மட் காப்பி ஆச்சு! பேஸ்ட் பண்ணுங்க');
  }

  Future<void> _pickDate(bool isGiven) async {
    final p = await showDatePicker(
      context: context,
      initialDate: isGiven ? given : returnDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (p == null) return;
    setState(() {
      if (isGiven) {
        given = p;
      } else {
        returnDate = p;
      }
      if (hasReturn) _calcDays();
    });
  }

  // ----- UI pieces -----
  Widget _num(TextEditingController c, String label, {bool decimal = true}) => TextField(
        controller: c,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        textAlign: TextAlign.center,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        onChanged: (_) => setState(() {}),
      );

  Widget _itemRow(int idx) {
    final r = rows[idx];
    final g = double.tryParse(r.given.text) ?? 0;
    final rt = double.tryParse(r.rate.text) ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: r.name,
                decoration: const InputDecoration(
                    labelText: 'பொருள் (எ.கா: சேர்)', border: OutlineInputBorder(), isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => setState(() {
                if (rows.length > 1) {
                  rows.removeAt(idx).dispose();
                } else {
                  r.name.clear();
                  r.given.clear();
                  r.ret.clear();
                  r.rate.clear();
                }
              }),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _num(r.given, '📤 கொடுத்தது')),
            if (hasReturn) ...[
              const SizedBox(width: 8),
              Expanded(child: _num(r.ret, '📥 வந்தது')),
            ],
            if (hasAmount) ...[
              const SizedBox(width: 8),
              Expanded(child: _num(r.rate, 'ரேட் ₹')),
            ],
          ]),
          if (hasAmount)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(hasReturn
                    ? '${fmt(g)} × ₹${fmt(rt)} × $days நாள்'
                    : '${fmt(g)} × ₹${fmt(rt)}'),
                Text('= ₹${fmt(g * rt * (hasReturn ? days : 1))}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _formCard() {
    final d = _draft();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(editingId == null ? '📝 புதிய வாடகை விவரம்' : '✏️ திருத்துக (Editing)',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            if (editingId != null)
              TextButton(onPressed: () => setState(_resetForm), child: const Text('ரத்து')),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: customer,
            decoration: const InputDecoration(
                labelText: '👤 வாடிக்கையாளர் பெயர் *', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
                labelText: '📞 போன் நம்பர் (விருப்பம்)', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: hasReturn,
            title: const Text('🔄 திரும்பப் பெறும் நாள் & பொருட்கள் சேர்க்க'),
            onChanged: (v) => setState(() {
              hasReturn = v ?? false;
              if (hasReturn) _calcDays();
            }),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: hasAmount,
            title: const Text('💰 வாடகைத் தொகை சேர்க்க'),
            onChanged: (v) => setState(() => hasAmount = v ?? false),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text('📌 கொடுக்கப்பட்ட நாள்: ${ddmmyyyy(given)}'),
            onTap: () => _pickDate(true),
          ),
          if (hasReturn) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_repeat),
              title: Text('🔄 திரும்பப் பெறும் நாள்: ${ddmmyyyy(returnDate)}'),
              onTap: () => _pickDate(false),
            ),
            Row(children: [
              SizedBox(width: 110, child: _num(daysCtl, 'நாட்கள்', decimal: false)),
              const SizedBox(width: 8),
              Expanded(
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: inclusive,
                  title: const Text('கொடுத்த நாளையும் சேர்த்து (+1)', style: TextStyle(fontSize: 13)),
                  onChanged: (v) => setState(() {
                    inclusive = v ?? false;
                    _calcDays();
                  }),
                ),
              ),
            ]),
          ],
          const Divider(),
          Text(hasAmount ? '📦 பொருட்கள் & வாடகை விவரம் *' : '📦 பொருட்கள் & எண்ணிக்கை *',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (int i = 0; i < rows.length; i++) _itemRow(i),
          OutlinedButton.icon(
            onPressed: () => setState(() => rows.add(RowCtl())),
            icon: const Icon(Icons.add),
            label: const Text('பொருள் சேர்'),
          ),
          if (hasAmount) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.green.shade50, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('💰 மொத்த வாடகை:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('₹${fmt(d.total)}',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.green.shade800)),
                ]),
                const SizedBox(height: 8),
                _num(advance, '💵 முன்பணம் ₹'),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('❗ மீதித் தொகை:'),
                  Text('₹${fmt(d.balance)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ]),
              ]),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.check),
              label: Text(editingId == null ? 'பட்டியலில் சேர்' : 'மாற்றங்களைச் சேமி'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _previewCard() => Card(
        color: const Color(0xFFEFEAE2),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('💬 WhatsApp Preview', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFFD9FDD3), borderRadius: BorderRadius.circular(12)),
              child: SelectableText(previewText, style: const TextStyle(fontSize: 14, height: 1.4)),
            ),
          ]),
        ),
      );

  Widget _savedList() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('🗂️ சேமித்த பட்டியல் (${entries.length})',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            if (entries.isNotEmpty)
              TextButton(
                onPressed: _clearAll,
                child: const Text('அனைத்தையும் அழி', style: TextStyle(color: Colors.red)),
              ),
          ]),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('இதுவரை எந்தப் பதிவும் இல்லை.'),
            ),
          for (final e in entries.reversed)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(e.customer + (e.phone.isEmpty ? '' : '  📞${e.phone}'),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                      icon: const Icon(Icons.edit, color: Colors.indigo, size: 20),
                      onPressed: () => _edit(e)),
                  IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                      onPressed: () => _delete(e)),
                ]),
                Text(
                  e.hasReturn && e.returnDate != null
                      ? '📌 ${ddmmyyyy(e.given)} ➔ 🔄 ${ddmmyyyy(e.returnDate!)} (${e.days} நாட்கள்)'
                      : '📌 ${ddmmyyyy(e.given)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 4),
                for (final i in e.items)
                  Text('• ${i.name}: 📤${fmt(i.given)}'
                      '${e.hasReturn && i.ret != null ? ' 📥${fmt(i.ret!)}' : ''}'
                      '${e.hasAmount ? '  = ₹${fmt(e.sub(i))}' : ''}'),
                if (e.hasAmount)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'மொத்தம்: ₹${fmt(e.total)}'
                      '${e.advance > 0 ? '  | முன்பணம் ₹${fmt(e.advance)} | மீதி ₹${fmt(e.balance)}' : ''}',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green.shade800),
                    ),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.indigo.shade700,
        foregroundColor: Colors.white,
        title: Text(shop, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [IconButton(icon: const Icon(Icons.edit), onPressed: _editShop)],
      ),
      body: ListView(
        controller: scroll,
        padding: const EdgeInsets.all(12),
        children: [
          _formCard(),
          const SizedBox(height: 12),
          _previewCard(),
          const SizedBox(height: 12),
          _savedList(),
          const SizedBox(height: 12),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade700, padding: const EdgeInsets.all(14)),
                onPressed: _copy,
                icon: const Icon(Icons.copy),
                label: const Text('Copy for WhatsApp'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(14)),
                onPressed: () => Share.share(previewText),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
