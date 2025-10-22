// lib/screens/checkout_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'package:dio/dio.dart';

import '../providers/cart_model.dart';
import '../api/api_client.dart';
import '../utils/formatters.dart';
import '../constants/config.dart';
import 'invoice_result_screen.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _creatingInvoice = false;
  String? _createdInvoiceName;

  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _posProfiles = [];
  List<Map<String, dynamic>> _priceLists = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _paymentModes = [];

  String? _selectedCustomer;
  String? _selectedPosProfile;
  String? _selectedPriceList;
  String? _selectedCurrency;
  String? _selectedPaymentMode;
  DateTime _postingDate = DateTime.now();

  bool _loadingLookups = true;
  String? _lookupError;

  @override
  void initState() {
    super.initState();
    _loadLookups();
  }

  Future<void> _loadLookups() async {
    setState(() {
      _loadingLookups = true;
      _lookupError = null;
    });

    try {
      final apiProv = Provider.of<ApiProvider>(context, listen: false);
      final dio = apiProv.dio;

      final customers = await apiProv.getCustomerList();
      final posProfiles = await apiProv.getPOSProfileList();
      final priceLists = await apiProv.getSellingPriceList();
      final currencies = await apiProv.getCurrencyList();

      final resp = await dio.get('/api/resource/Mode of Payment',
          queryParameters: {'fields': '["name","mode_of_payment"]', 'limit_page_length': '200'},
          options: Options(validateStatus: (_) => true));

      List<Map<String, dynamic>> paymentModes = <Map<String, dynamic>>[];
      if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List) {
        paymentModes = List<Map<String, dynamic>>.from(
            (resp.data['data'] as List).map((e) => Map<String, dynamic>.from(e)));
      }

      setState(() {
        _customers = customers;
        _posProfiles = posProfiles;
        _price_listsSetter(priceLists);
        _priceLists = priceLists;
        _currencies = currencies;
        _paymentModes = paymentModes;

        if (_customers.isNotEmpty) _selectedCustomer = _customers.first['name'] ?? _customers.first['customer_name']?.toString();
        if (_posProfiles.isNotEmpty) _selectedPosProfile = _posProfiles.first['name'];
        if (_priceLists.isNotEmpty) _selectedPriceList = _priceLists.first['name'];
        if (_currencies.isNotEmpty) _selectedCurrency = _currencies.first['name'];
        if (_paymentModes.isNotEmpty) _selectedPaymentMode = _paymentModes.first['name'];
      });
    } on DioError catch (dioErr) {
      String msg = 'Error loading dropdowns: ${dioErr.message}';
      if (dioErr.response != null) msg += '\nServer: ${dioErr.response?.statusCode} ${dioErr.response?.data}';
      debugPrint('>>> loadLookups DioError: $msg');
      setState(() => _lookupError = msg);
    } catch (e, st) {
      debugPrint('>>> loadLookups unexpected error: $e\n$st');
      setState(() => _lookupError = 'Error loading dropdowns: $e');
    } finally {
      setState(() => _loadingLookups = false);
    }
  }

  // helper to avoid analyzer warnings in pasted code
  void _price_listsSetter(List<Map<String, dynamic>> v) {}

  String formatQty(double q) {
    if (q % 1 == 0) return q.toStringAsFixed(0);
    if ((q * 10) % 1 == 0) return q.toStringAsFixed(1);
    if ((q * 100) % 1 == 0) return q.toStringAsFixed(2);
    return q.toStringAsFixed(3).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  Future<void> _printInvoice(BuildContext context, CartModel cart) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(58 * PdfPageFormat.mm, double.infinity),
        margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        build: (pw.Context ctx) {
          String formatLine(String name, double qty, double total) {
            final cleanName = name.length > 18 ? name.substring(0, 18) : name;
            final qtyText = formatQty(qty);
            final itemText = '$cleanName x$qtyText';
            return itemText.padRight(22) + total.toStringAsFixed(2);
          }

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(child: pw.Text('POS Invoice', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
              pw.SizedBox(height: 6),
              pw.Divider(thickness: 0.5),
              ...cart.items.map((c) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Text(formatLine(c.item.itemName ?? c.item.name, c.qty, c.rate * c.qty),
                    style: const pw.TextStyle(fontSize: 9)),
              )),
              pw.Divider(thickness: 0.5),
              pw.SizedBox(height: 4),
              pw.Text('TOTAL:'.padRight(22) + cart.total.toStringAsFixed(2),
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Center(child: pw.Text('Thank you!', style: pw.TextStyle(fontSize: 9))),
            ],
          );
        },
      ),
    );

    try {
      await Printing.layoutPdf(onLayout: (PdfPageFormat fmt) async => pdf.save());
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Print job requested')));
    } catch (e, st) {
      debugPrint('>>> printInvoice error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print error: $e')));
    }
  }

  /// Create POS invoice on server. Returns a result map:
  /// { 'ok': bool, 'invoiceName': String?, 'message': String? }
  Future<Map<String, dynamic>> _createInvoiceOnServer(BuildContext context, CartModel cart) async {
    final companyName = AppConfig.companyName ?? '';
    if (companyName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Company not configured (AppConfig.companyName)')));
      return {'ok': false, 'message': 'Company not configured'};
    }

    if (_selectedCustomer == null || _selectedPosProfile == null || _selectedPriceList == null || _selectedCurrency == null || _selectedPaymentMode == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all dropdowns')));
      return {'ok': false, 'message': 'Please fill all dropdowns'};
    }

    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    final dio = apiProv.dio;

    final itemsPayload = cart.items.map((c) => {
      'item_code': c.item.name,
      'qty': c.qty,
      'rate': c.rate,
      'amount': c.rate * c.qty,
    }).toList();

    final salesInvoicePaymentRow = {'mode_of_payment': _selectedPaymentMode, 'amount': cart.total};

    final Map<String, dynamic> payload = {
      'customer': _selectedCustomer,
      'company': companyName,
      'pos_profile': _selectedPosProfile,
      'posting_date': DateFormat('yyyy-MM-dd').format(_postingDate),
      'currency': _selectedCurrency,
      'selling_price_list': _selectedPriceList,
      'items': itemsPayload,
      'sales_invoice_payment': [salesInvoicePaymentRow],
      'payments': [
        {'mode_of_payment': _selectedPaymentMode, 'amount': cart.total}
      ],
      'paid_amount': cart.total,
      'docstatus': 1,
    };

    debugPrint('>>> createPosInvoice payload: $payload');

    try {
      if (mounted) setState(() => _creatingInvoice = true);

      final Response createResp = await dio.post('/api/resource/POS Invoice', data: payload, options: Options(validateStatus: (_) => true));

      debugPrint('>>> createPosInvoice createResp status: ${createResp.statusCode}');
      debugPrint('>>> createPosInvoice createResp data: ${createResp.data}');

      if (!(createResp.statusCode == 200 || createResp.statusCode == 201)) {
        final err = createResp.data ?? 'Server returned ${createResp.statusCode}';
        return {'ok': false, 'message': 'Error creating invoice: $err'};
      }

      final createBody = createResp.data;
      Map<String, dynamic>? createdDoc;
      String? createdName;
      if (createBody is Map && createBody['data'] is Map) {
        createdDoc = Map<String, dynamic>.from(createBody['data'] as Map);
        createdName = createdDoc['name']?.toString();
      } else if (createBody is Map && createBody['name'] != null) {
        createdName = createBody['name'].toString();
      }

      if (createdDoc == null && createdName == null) {
        return {'ok': true, 'invoiceName': null, 'message': 'Invoice created but server did not return name/doc.'};
      }

      final Map<String, dynamic> docToSubmit = createdDoc ?? {'doctype': 'POS Invoice', 'name': createdName};

      // Try to submit using client.submit (some servers require this)
      final Response submitResp = await dio.post('/api/method/frappe.client.submit', data: {'doc': docToSubmit}, options: Options(validateStatus: (_) => true));

      debugPrint('>>> createPosInvoice submitResp status: ${submitResp.statusCode}');
      debugPrint('>>> createPosInvoice submitResp data: ${submitResp.data}');

      if (submitResp.statusCode == 200 || submitResp.statusCode == 201) {
        final invoiceName = createdName ?? (submitResp.data is Map ? (submitResp.data['message']?['name'] ?? submitResp.data['data']?['name']) : null);
        return {'ok': true, 'invoiceName': invoiceName, 'message': 'POS Invoice created and submitted'};
      } else {
        final err = submitResp.data ?? 'Submit returned ${submitResp.statusCode}';
        return {'ok': true, 'invoiceName': createdName, 'message': 'Invoice created but submit failed: $err'};
      }
    } on DioError catch (dioErr) {
      debugPrint('>>> createPosInvoice DioError: ${dioErr.message}');
      debugPrint('>>> createPosInvoice DioError response: ${dioErr.response?.data}');
      return {'ok': false, 'message': 'Network error: ${dioErr.message}'};
    } catch (e, st) {
      debugPrint('>>> createPosInvoice unexpected error: $e\n$st');
      return {'ok': false, 'message': 'Error: $e'};
    } finally {
      if (mounted) setState(() => _creatingInvoice = false);
    }
  }

  Future<void> _showCreateDialog(BuildContext screenContext, CartModel cart) async {
    // use the screenContext (outer context) for navigation so we don't try to navigate from inside the dialog
    showDialog(
      context: screenContext,
      builder: (_) {
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          return AlertDialog(
            title: const Text('Create POS Invoice'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loadingLookups) const LinearProgressIndicator(),
                  if (_lookupError != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8.0), child: Text(_lookupError!, style: const TextStyle(color: Colors.red))),
                  // Customer
                  GestureDetector(
                    onTap: () async {
                      final sel = await _openSearchablePicker(ctx: screenContext, title: 'Select Customer', items: _customers, valueKey: 'name', subLabelKey: 'customer_name');
                      if (sel != null) setStateDialog(() => _selectedCustomer = sel);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Customer', border: OutlineInputBorder()),
                      child: Row(children: [Expanded(child: Text(_selectedCustomer ?? 'Select')), const Icon(Icons.arrow_drop_down)]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // POS Profile
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'POS Profile', border: OutlineInputBorder()),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedPosProfile,
                        items: _posProfiles.map((m) {
                          final display = m['name'] ?? m.toString();
                          return DropdownMenuItem<String>(value: m['name']?.toString(), child: Text(display.toString()));
                        }).toList(),
                        onChanged: (v) => setStateDialog(() => _selectedPosProfile = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Price List
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Selling Price List', border: OutlineInputBorder()),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedPriceList,
                        items: _priceLists.map((m) {
                          return DropdownMenuItem<String>(value: m['name']?.toString(), child: Text(m['name']?.toString() ?? ''));
                        }).toList(),
                        onChanged: (v) => setStateDialog(() => _selectedPriceList = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Currency
                  GestureDetector(
                    onTap: () async {
                      final sel = await _openSearchablePicker(ctx: screenContext, title: 'Select Currency', items: _currencies, valueKey: 'name');
                      if (sel != null) setStateDialog(() => _selectedCurrency = sel);
                    },
                    child: InputDecorator(decoration: const InputDecoration(labelText: 'Currency', border: OutlineInputBorder()), child: Row(children: [Expanded(child: Text(_selectedCurrency ?? 'Select')), const Icon(Icons.arrow_drop_down)])),
                  ),
                  const SizedBox(height: 8),
                  // Payment Mode
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Mode of Payment', border: OutlineInputBorder()),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedPaymentMode,
                        items: _paymentModes.map((m) {
                          final label = (m['mode_of_payment'] ?? m['name'])?.toString() ?? '';
                          return DropdownMenuItem<String>(value: m['name']?.toString(), child: Text(label));
                        }).toList(),
                        onChanged: (v) => setStateDialog(() => _selectedPaymentMode = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Posting Date', border: OutlineInputBorder()),
                    child: Row(
                      children: [
                        Expanded(child: Text(DateFormat('yyyy-MM-dd').format(_postingDate))),
                        TextButton(onPressed: () async {
                          final d = await showDatePicker(context: screenContext, initialDate: _postingDate, firstDate: DateTime(2000), lastDate: DateTime(2100));
                          if (d != null) setStateDialog(() => _postingDate = d);
                        }, child: const Text('Select')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(screenContext).pop(), child: const Text('Cancel')),
              TextButton(
                onPressed: _creatingInvoice ? null : () async {
                  if (_selectedCustomer == null || _selectedPosProfile == null || _selectedPriceList == null || _selectedCurrency == null || _selectedPaymentMode == null) {
                    ScaffoldMessenger.of(screenContext).showSnackBar(const SnackBar(content: Text('Please fill all dropdowns')));
                    return;
                  }

                  // Call the create function using the screenContext and the cart from provider (screen-level)
                  final result = await _createInvoiceOnServer(screenContext, Provider.of<CartModel>(screenContext, listen: false));

                  // Always close the dialog first
                  Navigator.of(screenContext).pop();

                  // Show feedback
                  if (result['ok'] == true) {
                    final invoiceName = result['invoiceName'] as String?;
                    final msg = result['message']?.toString() ?? 'Invoice created';
                    ScaffoldMessenger.of(screenContext).showSnackBar(SnackBar(content: Text(msg)));

                    // Navigate to invoice result screen (replace current screen)
                    // Use pushReplacement so checkout screen is replaced by result, similar to your desired flow
                    Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => InvoiceResultScreen(
                        invoiceName: _createdInvoiceName ?? '',
                        cartSnapshot: List.from(cart.items), // snapshot copy
                        customerName: _selectedCustomer,      // pass selected customer from checkout screen
                      ),
                    ));

                  } else {
                    final err = result['message']?.toString() ?? 'Failed to create invoice';
                    ScaffoldMessenger.of(screenContext).showSnackBar(SnackBar(content: Text(err)));
                  }
                },
                child: _creatingInvoice ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Submit'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<String?> _openSearchablePicker({
    required BuildContext ctx,
    required String title,
    required List<Map<String, dynamic>> items,
    String valueKey = 'name',
    String? subLabelKey,
    String Function(Map<String, dynamic>)? labelFormatter,
  }) async {
    if (items.isEmpty) return null;
    return showDialog<String>(
      context: ctx,
      builder: (dialogCtx) {
        String query = '';
        List<Map<String, dynamic>> filtered = List.from(items);
        return StatefulBuilder(builder: (dCtx, setDState) {
          void doFilter(String q) {
            query = q.toLowerCase();
            filtered = items.where((m) {
              final a = (m[subLabelKey ?? valueKey] ?? m[valueKey] ?? '').toString().toLowerCase();
              final b = (m[valueKey] ?? '').toString().toLowerCase();
              return a.contains(query) || b.contains(query);
            }).toList();
            setDState(() {});
          }

          return AlertDialog(
            title: Text(title),
            content: Container(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search...'), onChanged: doFilter),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty ? const Center(child: Text('No results')) : ListView.separated(
                      shrinkWrap: true,
                      itemBuilder: (_, i) {
                        final m = filtered[i];
                        final primary = labelFormatter != null ? labelFormatter(m) : (m[subLabelKey ?? valueKey] ?? m[valueKey] ?? '').toString();
                        final subtitle = (m[valueKey] ?? '').toString();
                        return ListTile(
                          title: Text(primary),
                          subtitle: subtitle != primary ? Text(subtitle) : null,
                          onTap: () => Navigator.of(dCtx).pop(m[valueKey]?.toString()),
                        );
                      },
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemCount: filtered.length,
                    ),
                  ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.of(dialogCtx).pop(), child: const Text('Close'))],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = Provider.of<CartModel>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Point of Sale')),
      body: SafeArea(
        child: Row(
          children: [
            // Left: Cart / items (makes it look like screenshot when on checkout)
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(children: [
                  // Customer header & search for quick add (reusing some UI)
                  Row(children: [
                    Expanded(child: Text('Items', style: Theme.of(context).textTheme.titleLarge)),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.fullscreen), label: const Text('Full Screen')),
                  ]),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: cart.items.length,
                      itemBuilder: (ctx, i) {
                        final c = cart.items[i];
                        final lineTotal = (c.rate * c.qty);
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(c.item.itemName ?? c.item.name, style: const TextStyle(fontSize: 16)),
                              const SizedBox(height: 4),
                              Text('Unit: ${Formatters.money(c.rate)}', style: const TextStyle(color: Colors.grey)),
                            ])),
                            Row(children: [
                              IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () {
                                final newQty = c.qty - 1.0;
                                if (newQty <= 0.0) Provider.of<CartModel>(context, listen: false).remove(c.item);
                                else Provider.of<CartModel>(context, listen: false).setQty(c.item, newQty);
                              }),
                              SizedBox(width: 48, child: Center(child: Text(formatQty(c.qty), style: const TextStyle(fontSize: 16)))),
                              IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () {
                                Provider.of<CartModel>(context, listen: false).setQty(c.item, c.qty + 1.0);
                              }),
                              const SizedBox(width: 12),
                              SizedBox(width: 80, child: Text(Formatters.money(lineTotal), textAlign: TextAlign.right)),
                            ])
                          ]),
                        );
                      },
                    ),
                  )
                ]),
              ),
            ),

            // Right: Payment & summary panel
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('Payment Method', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      // Simple cash input + quick presets
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300)),
                        child: Column(children: [
                          TextField(decoration: const InputDecoration(border: InputBorder.none, hintText: 'Paid amount'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                          const SizedBox(height: 8),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            ElevatedButton(onPressed: () {}, child: const Text('₹ 100')),
                            ElevatedButton(onPressed: () {}, child: const Text('₹ 200')),
                            ElevatedButton(onPressed: () {}, child: const Text('₹ 500')),
                          ])
                        ]),
                      ),
                      const SizedBox(height: 12),
                      Expanded(child: Container()), // spacer to resemble layout
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Grand Total', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text('Paid Amount', style: TextStyle(color: Colors.grey.shade700)),
                          ])),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('₹ ${(cart.total).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text('₹ ${(cart.total).toStringAsFixed(2)}'),
                          ])
                        ]),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: cart.items.isEmpty || _loadingLookups ? null : () => _showCreateDialog(context, Provider.of<CartModel>(context, listen: false)), child: Padding(padding: const EdgeInsets.symmetric(vertical: 14.0), child: const Text('Complete Order'))),
                    ]),
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}








// // lib/screens/checkout_screen.dart
// import 'package:flutter/material.dart';
// import 'package:provider/provider.dart';
// import 'package:pdf/pdf.dart';
// import 'package:pdf/widgets.dart' as pw;
// import 'package:printing/printing.dart';
// import 'package:intl/intl.dart';
// import 'package:dio/dio.dart';
//
// import '../providers/cart_model.dart';
// import '../api/api_client.dart';
// import '../utils/formatters.dart';
// import '../constants/config.dart';
//
// class CheckoutScreen extends StatefulWidget {
//   const CheckoutScreen({super.key});
//
//   @override
//   State<CheckoutScreen> createState() => _CheckoutScreenState();
// }
//
// class _CheckoutScreenState extends State<CheckoutScreen> {
//   bool _creatingInvoice = false;
//   String? _createdInvoiceName;
//
//   // lookup lists populated from ERPNext
//   List<Map<String, dynamic>> _customers = [];
//   List<Map<String, dynamic>> _posProfiles = [];
//   List<Map<String, dynamic>> _priceLists = [];
//   List<Map<String, dynamic>> _currencies = [];
//   List<Map<String, dynamic>> _paymentModes = [];
//
//   // selected values
//   String? _selectedCustomer;
//   String? _selectedPosProfile;
//   String? _selectedPriceList;
//   String? _selectedCurrency;
//   String? _selectedPaymentMode;
//   DateTime _postingDate = DateTime.now();
//
//   bool _loadingLookups = true;
//   String? _lookupError;
//
//   @override
//   void initState() {
//     super.initState();
//     _loadLookups();
//   }
//
//   Future<void> _loadLookups() async {
//     setState(() {
//       _loadingLookups = true;
//       _lookupError = null;
//     });
//
//     try {
//       final apiProv = Provider.of<ApiProvider>(context, listen: false);
//       final dio = apiProv.dio;
//
//       debugPrint('>>> loadLookups: fetching customers, pos profiles, price lists, currencies, payment modes');
//
//       final customers = await apiProv.getCustomerList();
//       final posProfiles = await apiProv.getPOSProfileList();
//       final priceLists = await apiProv.getSellingPriceList();
//       final currencies = await apiProv.getCurrencyList();
//
//       // Mode of Payment - fetch from resource "Mode of Payment"
//       final resp = await dio.get(
//         '/api/resource/Mode of Payment',
//         queryParameters: {'fields': '["name","mode_of_payment"]', 'limit_page_length': '200'},
//         options: Options(validateStatus: (_) => true),
//       );
//
//       List<Map<String, dynamic>> paymentModes = <Map<String, dynamic>>[];
//       if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List) {
//         paymentModes = List<Map<String, dynamic>>.from((resp.data['data'] as List).map((e) => Map<String, dynamic>.from(e)));
//       } else {
//         debugPrint('>>> loadLookups: payment modes fetch returned ${resp.statusCode} ${resp.data}');
//       }
//
//       setState(() {
//         _customers = customers;
//         _posProfiles = posProfiles;
//         _priceLists = priceLists; // keep USAGE consistent below
//         _priceLists = priceLists;
//         _currencies = currencies;
//         _paymentModes = paymentModes;
//
//         if (_customers.isNotEmpty) _selectedCustomer = _customers.first['name'] ?? _customers.first['customer_name']?.toString();
//         if (_posProfiles.isNotEmpty) _selectedPosProfile = _posProfiles.first['name'];
//         if (_priceLists.isNotEmpty) _selectedPriceList = _priceLists.first['name'];
//         if (_currencies.isNotEmpty) _selectedCurrency = _currencies.first['name'];
//         if (_paymentModes.isNotEmpty) _selectedPaymentMode = _paymentModes.first['name'];
//       });
//     } on DioError catch (dioErr) {
//       String msg = 'Error loading dropdowns: ${dioErr.message}';
//       if (dioErr.response != null) msg += '\nServer: ${dioErr.response?.statusCode} ${dioErr.response?.data}';
//       debugPrint('>>> loadLookups DioError: $msg');
//       setState(() => _lookupError = msg);
//     } catch (e, st) {
//       debugPrint('>>> loadLookups unexpected error: $e\n$st');
//       setState(() => _lookupError = 'Error loading dropdowns: $e');
//     } finally {
//       setState(() => _loadingLookups = false);
//     }
//   }
//
//   // ---------- Helpers ----------
//   /// Format quantity for display:
//   /// - integer quantities show without decimals
//   /// - else up to 3 decimals, trimmed of trailing zeros
//   String formatQty(double q) {
//     if (q % 1 == 0) return q.toStringAsFixed(0);
//     if ((q * 10) % 1 == 0) return q.toStringAsFixed(1);
//     if ((q * 100) % 1 == 0) return q.toStringAsFixed(2);
//     return q.toStringAsFixed(3).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
//   }
//
//   // Print small 2" invoice
//   Future<void> _printInvoice(BuildContext context, CartModel cart) async {
//     final pdf = pw.Document();
//
//     pdf.addPage(
//       pw.Page(
//         pageFormat: PdfPageFormat(58 * PdfPageFormat.mm, double.infinity),
//         margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
//         build: (pw.Context ctx) {
//           String formatLine(String name, double qty, double total) {
//             final cleanName = name.length > 18 ? name.substring(0, 18) : name;
//             final qtyText = formatQty(qty);
//             final itemText = '$cleanName x$qtyText';
//             return itemText.padRight(22) + total.toStringAsFixed(2);
//           }
//
//           return pw.Column(
//             crossAxisAlignment: pw.CrossAxisAlignment.start,
//             children: [
//               pw.Center(child: pw.Text('POS Invoice', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
//               pw.SizedBox(height: 6),
//               pw.Divider(thickness: 0.5),
//               ...cart.items.map((c) => pw.Padding(
//                 padding: const pw.EdgeInsets.symmetric(vertical: 2),
//                 child: pw.Text(formatLine(c.item.itemName ?? c.item.name, c.qty, c.rate * c.qty), style: const pw.TextStyle(fontSize: 9)),
//               )),
//               pw.Divider(thickness: 0.5),
//               pw.SizedBox(height: 4),
//               pw.Text('TOTAL:'.padRight(22) + cart.total.toStringAsFixed(2), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
//               pw.SizedBox(height: 10),
//               pw.Center(child: pw.Text('Thank you!', style: pw.TextStyle(fontSize: 9))),
//             ],
//           );
//         },
//       ),
//     );
//
//     try {
//       await Printing.layoutPdf(onLayout: (PdfPageFormat fmt) async => pdf.save());
//       debugPrint('>>> printInvoice: layoutPdf completed');
//     } catch (e, st) {
//       debugPrint('>>> printInvoice error: $e\n$st');
//       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print error: $e')));
//     }
//   }
//
//   /// Create POS Invoice on ERPNext and ensure it's submitted (docstatus = 1).
//   Future<bool> _createInvoiceOnServer(BuildContext context, CartModel cart) async {
//     final companyName = AppConfig.companyName ?? '';
//     if (companyName.isEmpty) {
//       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Company not configured (AppConfig.companyName)')));
//       return false;
//     }
//
//     if (_selectedCustomer == null || _selectedPosProfile == null || _selectedPriceList == null || _selectedCurrency == null || _selectedPaymentMode == null) {
//       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all dropdowns')));
//       return false;
//     }
//
//     final apiProv = Provider.of<ApiProvider>(context, listen: false);
//     final dio = apiProv.dio;
//
//     final itemsPayload = cart.items.map((c) => {
//       'item_code': c.item.name,
//       'qty': c.qty,
//       'rate': c.rate,
//       'amount': c.rate * c.qty,
//     }).toList();
//
//     final salesInvoicePaymentRow = {
//       'mode_of_payment': _selectedPaymentMode,
//       'amount': cart.total,
//     };
//
//     final Map<String, dynamic> payload = {
//       'customer': _selectedCustomer,
//       'company': companyName,
//       'pos_profile': _selectedPosProfile,
//       'posting_date': DateFormat('yyyy-MM-dd').format(_postingDate),
//       'currency': _selectedCurrency,
//       'selling_price_list': _selectedPriceList,
//       'items': itemsPayload,
//       'sales_invoice_payment': [salesInvoicePaymentRow],
//       'payments': [{'mode_of_payment': _selectedPaymentMode, 'amount': cart.total}],
//       'paid_amount': cart.total,
//       'docstatus': 1,
//     };
//
//     debugPrint('>>> createPosInvoice payload: $payload');
//
//     try {
//       setState(() => _creatingInvoice = true);
//
//       // Create the POS Invoice
//       final Response createResp = await dio.post(
//         '/api/resource/POS Invoice',
//         data: payload,
//         options: Options(validateStatus: (_) => true),
//       );
//
//       debugPrint('>>> createPosInvoice createResp status: ${createResp.statusCode}');
//       debugPrint('>>> createPosInvoice createResp data: ${createResp.data}');
//
//       if (!(createResp.statusCode == 200 || createResp.statusCode == 201)) {
//         final err = createResp.data ?? 'Server returned ${createResp.statusCode}';
//         debugPrint('>>> createPosInvoice server error (create): $err');
//         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error creating invoice: $err')));
//         return false;
//       }
//
//       // Extract created doc (if returned)
//       final createBody = createResp.data;
//       Map<String, dynamic>? createdDoc;
//       String? createdName;
//       if (createBody is Map && createBody['data'] is Map) {
//         createdDoc = Map<String, dynamic>.from(createBody['data'] as Map);
//         createdName = createdDoc['name']?.toString();
//       } else if (createBody is Map && createBody['name'] != null) {
//         createdName = createBody['name'].toString();
//       }
//
//       if (createdDoc == null && createdName == null) {
//         debugPrint('>>> createPosInvoice: created but no doc or name returned.');
//         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invoice created but server did not return name/doc.')));
//         return true;
//       }
//
//       // Prepare doc for explicit submit call
//       final Map<String, dynamic> docToSubmit = createdDoc ?? {
//         'doctype': 'POS Invoice',
//         'name': createdName,
//       };
//
//       debugPrint('>>> createPosInvoice attempting submit with doc: ${docToSubmit.keys}');
//
//       final Response submitResp = await dio.post(
//         '/api/method/frappe.client.submit',
//         data: {'doc': docToSubmit},
//         options: Options(validateStatus: (_) => true),
//       );
//
//       debugPrint('>>> createPosInvoice submitResp status: ${submitResp.statusCode}');
//       debugPrint('>>> createPosInvoice submitResp data: ${submitResp.data}');
//
//       if (submitResp.statusCode == 200 || submitResp.statusCode == 201) {
//         setState(() => _createdInvoiceName = createdName ?? (submitResp.data is Map ? (submitResp.data['message']?['name'] ?? submitResp.data['data']?['name']) : null));
//         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('POS Invoice created and submitted')));
//         return true;
//       } else {
//         final err = submitResp.data ?? 'Submit returned ${submitResp.statusCode}';
//         debugPrint('>>> createPosInvoice submit error: $err');
//         setState(() => _createdInvoiceName = createdName);
//         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invoice created but submit failed: $err')));
//         return true;
//       }
//     } on DioError catch (dioErr) {
//       debugPrint('>>> createPosInvoice DioError: ${dioErr.message}');
//       debugPrint('>>> createPosInvoice DioError response: ${dioErr.response?.data}');
//       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error: ${dioErr.message}')));
//       return false;
//     } catch (e, st) {
//       debugPrint('>>> createPosInvoice unexpected error: $e\n$st');
//       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
//       return false;
//     } finally {
//       setState(() => _creatingInvoice = false);
//     }
//   }
//
//   // ------------ SEARCHABLE SELECTOR IMPLEMENTATION ------------
//   Future<String?> _openSearchablePicker({
//     required BuildContext ctx,
//     required String title,
//     required List<Map<String, dynamic>> items,
//     String valueKey = 'name',
//     String? subLabelKey,
//     String Function(Map<String, dynamic>)? labelFormatter,
//   }) async {
//     if (items.isEmpty) return null;
//
//     return showDialog<String>(
//       context: ctx,
//       builder: (dialogCtx) {
//         String query = '';
//         List<Map<String, dynamic>> filtered = List.from(items);
//
//         return StatefulBuilder(builder: (dCtx, setDState) {
//           void doFilter(String q) {
//             query = q.toLowerCase();
//             filtered = items.where((m) {
//               final a = (m[subLabelKey ?? valueKey] ?? m[valueKey] ?? '').toString().toLowerCase();
//               final b = (m[valueKey] ?? '').toString().toLowerCase();
//               return a.contains(query) || b.contains(query);
//             }).toList();
//             setDState(() {});
//           }
//
//           return AlertDialog(
//             title: Text(title),
//             content: Container(
//               width: double.maxFinite,
//               child: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   TextField(
//                     decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search...'),
//                     onChanged: doFilter,
//                   ),
//                   const SizedBox(height: 8),
//                   Expanded(
//                     child: filtered.isEmpty
//                         ? const Center(child: Text('No results'))
//                         : ListView.separated(
//                       shrinkWrap: true,
//                       itemBuilder: (_, i) {
//                         final m = filtered[i];
//                         final primary = labelFormatter != null ? labelFormatter(m) : (m[subLabelKey ?? valueKey] ?? m[valueKey] ?? '').toString();
//                         final subtitle = (m[valueKey] ?? '').toString();
//                         return ListTile(
//                           title: Text(primary),
//                           subtitle: subtitle != primary ? Text(subtitle) : null,
//                           onTap: () => Navigator.of(dCtx).pop(m[valueKey]?.toString()),
//                         );
//                       },
//                       separatorBuilder: (_, __) => const Divider(height: 1),
//                       itemCount: filtered.length,
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//             actions: [
//               TextButton(onPressed: () => Navigator.of(dialogCtx).pop(), child: const Text('Close')),
//             ],
//           );
//         });
//       },
//     );
//   }
//
//   // ------------ UI building helpers ------------
//   Widget _buildDropdown({
//     required String label,
//     required List<Map<String, dynamic>> items,
//     required String? value,
//     required ValueChanged<String?> onChanged,
//     String valueKey = 'name',
//     String? subLabelKey,
//   }) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(vertical: 6),
//       child: InputDecorator(
//         decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
//         child: DropdownButtonHideUnderline(
//           child: DropdownButton<String>(
//             isExpanded: true,
//             value: value,
//             items: items.map((m) {
//               final display = m[subLabelKey ?? valueKey] ?? m[valueKey] ?? m.toString();
//               return DropdownMenuItem<String>(value: m[valueKey]?.toString(), child: Text(display.toString()));
//             }).toList(),
//             onChanged: onChanged,
//           ),
//         ),
//       ),
//     );
//   }
//
//   Widget _buildSearchableField({
//     required String label,
//     required List<Map<String, dynamic>> items,
//     required String? value,
//     required ValueChanged<String?> onSelected,
//     String valueKey = 'name',
//     String? subLabelKey,
//   }) {
//     final display = items.firstWhere(
//           (m) => (m[valueKey]?.toString() ?? '') == (value ?? ''),
//       orElse: () => <String, dynamic>{},
//     );
//     final displayText = (display.isNotEmpty ? (display[subLabelKey ?? valueKey] ?? display[valueKey] ?? '') : (value ?? 'Select')).toString();
//
//     return Padding(
//       padding: const EdgeInsets.symmetric(vertical: 6),
//       child: GestureDetector(
//         onTap: () async {
//           final sel = await _openSearchablePicker(
//             ctx: context,
//             title: 'Select $label',
//             items: items,
//             valueKey: valueKey,
//             subLabelKey: subLabelKey,
//             labelFormatter: (m) => (m[subLabelKey ?? valueKey] ?? m[valueKey] ?? '').toString(),
//           );
//           if (sel != null) onSelected(sel);
//         },
//         child: InputDecorator(
//           decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
//           child: Row(
//             children: [
//               Expanded(child: Text(displayText.isNotEmpty ? displayText : 'Select')),
//               const Icon(Icons.arrow_drop_down),
//             ],
//           ),
//         ),
//       ),
//     );
//   }
//
//   // ------------ Dialogs & submit UI ------------
//   void _showCreateDialog(BuildContext context, CartModel cart) {
//     showDialog(
//       context: context,
//       builder: (_) {
//         return StatefulBuilder(builder: (ctx, setStateDialog) {
//           return AlertDialog(
//             title: const Text('Create POS Invoice'),
//             content: SingleChildScrollView(
//               child: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   if (_loadingLookups) const LinearProgressIndicator(),
//                   if (_lookupError != null) Padding(
//                     padding: const EdgeInsets.symmetric(vertical: 8.0),
//                     child: Text(_lookupError!, style: const TextStyle(color: Colors.red)),
//                   ),
//
//                   // SEARCHABLE: Customer
//                   _buildSearchableField(
//                     label: 'Customer',
//                     items: _customers,
//                     value: _selectedCustomer,
//                     onSelected: (v) => setStateDialog(() => _selectedCustomer = v),
//                     valueKey: 'name',
//                     subLabelKey: 'customer_name',
//                   ),
//
//                   // POS Profile (normal dropdown)
//                   _buildDropdown(
//                     label: 'POS Profile',
//                     items: _posProfiles,
//                     value: _selectedPosProfile,
//                     onChanged: (v) => setStateDialog(() => _selectedPosProfile = v),
//                     valueKey: 'name',
//                     subLabelKey: 'pos_profile_name',
//                   ),
//
//                   // Selling Price List (normal dropdown)
//                   _buildDropdown(
//                     label: 'Selling Price List',
//                     items: _priceLists,
//                     value: _selectedPriceList,
//                     onChanged: (v) => setStateDialog(() => _selectedPriceList = v),
//                     valueKey: 'name',
//                   ),
//
//                   // SEARCHABLE: Currency
//                   _buildSearchableField(
//                     label: 'Currency',
//                     items: _currencies,
//                     value: _selectedCurrency,
//                     onSelected: (v) => setStateDialog(() => _selectedCurrency = v),
//                     valueKey: 'name',
//                   ),
//
//                   // Mode of Payment (normal dropdown)
//                   _buildDropdown(
//                     label: 'Mode of Payment',
//                     items: _paymentModes,
//                     value: _selectedPaymentMode,
//                     onChanged: (v) => setStateDialog(() => _selectedPaymentMode = v),
//                     valueKey: 'name',
//                     subLabelKey: 'mode_of_payment',
//                   ),
//
//                   const SizedBox(height: 8),
//
//                   InputDecorator(
//                     decoration: const InputDecoration(labelText: 'Posting Date', border: OutlineInputBorder()),
//                     child: Row(
//                       children: [
//                         Expanded(child: Text(DateFormat('yyyy-MM-dd').format(_postingDate))),
//                         TextButton(
//                           onPressed: () async {
//                             final d = await showDatePicker(
//                               context: context,
//                               initialDate: _postingDate,
//                               firstDate: DateTime(2000),
//                               lastDate: DateTime(2100),
//                             );
//                             if (d != null) setStateDialog(() => _postingDate = d);
//                           },
//                           child: const Text('Select'),
//                         ),
//                       ],
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//             actions: [
//               TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
//               TextButton(
//                 onPressed: _creatingInvoice
//                     ? null
//                     : () async {
//                   if (_selectedCustomer == null ||
//                       _selectedPosProfile == null ||
//                       _selectedPriceList == null ||
//                       _selectedCurrency == null ||
//                       _selectedPaymentMode == null) {
//                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all dropdowns')));
//                     return;
//                   }
//
//                   final ok = await _createInvoiceOnServer(context, Provider.of<CartModel>(context, listen: false));
//                   if (ok) {
//                     Navigator.of(context).pop();
//                     _showInvoiceCreatedDialog(context, Provider.of<CartModel>(context, listen: false));
//                   }
//                 },
//                 child: _creatingInvoice ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Submit'),
//               ),
//             ],
//           );
//         });
//       },
//     );
//   }
//
//   void _showInvoiceCreatedDialog(BuildContext context, CartModel cart) {
//     showDialog(
//       context: context,
//       builder: (_) {
//         return AlertDialog(
//           title: const Text('Invoice Created'),
//           content: SingleChildScrollView(
//             child: Column(
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 if (_createdInvoiceName != null) ...[
//                   Text('Invoice: $_createdInvoiceName', style: const TextStyle(fontWeight: FontWeight.bold)),
//                   const SizedBox(height: 8),
//                 ],
//                 const Text('Items:'),
//                 const SizedBox(height: 8),
//                 ...cart.items.map((c) => Row(
//                   mainAxisAlignment: MainAxisAlignment.spaceBetween,
//                   children: [
//                     Expanded(child: Text('${c.item.itemName ?? c.item.name} x${formatQty(c.qty)}')),
//                     Text((c.rate * c.qty).toStringAsFixed(2)),
//                   ],
//                 )),
//                 const Divider(),
//                 Row(
//                   mainAxisAlignment: MainAxisAlignment.spaceBetween,
//                   children: [
//                     const Text('Net Total:', style: TextStyle(fontWeight: FontWeight.bold)),
//                     Text(cart.total.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold)),
//                   ],
//                 ),
//               ],
//             ),
//           ),
//           actions: [
//             TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
//             TextButton(
//               onPressed: () async {
//                 Navigator.of(context).pop();
//                 await _printInvoice(context, cart);
//               },
//               child: const Text('Print'),
//             ),
//             TextButton(
//               onPressed: () {
//                 Provider.of<CartModel>(context, listen: false).clear();
//                 Navigator.of(context).popUntil((route) => route.isFirst);
//               },
//               child: const Text('Done'),
//             ),
//           ],
//         );
//       },
//     );
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     final cart = Provider.of<CartModel>(context);
//
//     return Scaffold(
//       appBar: AppBar(title: const Text('POS Invoice')),
//       body: SafeArea(
//         child: cart.items.isEmpty
//             ? const Center(child: Text('Cart is empty'))
//             : Column(
//           children: [
//             Expanded(
//               child: ListView.separated(
//                 separatorBuilder: (_, __) => const Divider(),
//                 itemCount: cart.items.length,
//                 itemBuilder: (ctx, i) {
//                   final c = cart.items[i];
//                   final lineTotal = (c.rate * c.qty);
//
//                   return Padding(
//                     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
//                     child: Row(
//                       children: [
//                         Expanded(
//                           child: Column(
//                             crossAxisAlignment: CrossAxisAlignment.start,
//                             children: [
//                               Text(c.item.itemName ?? c.item.name, style: const TextStyle(fontSize: 16)),
//                               const SizedBox(height: 4),
//                               Text('Unit: ${Formatters.money(c.rate)}', style: const TextStyle(color: Colors.grey)),
//                             ],
//                           ),
//                         ),
//                         Row(
//                           children: [
//                             IconButton(
//                               icon: const Icon(Icons.remove_circle_outline),
//                               onPressed: () {
//                                 final newQty = c.qty - 1.0;
//                                 if (newQty <= 0.0) {
//                                   Provider.of<CartModel>(context, listen: false).remove(c.item);
//                                 } else {
//                                   Provider.of<CartModel>(context, listen: false).setQty(c.item, newQty);
//                                 }
//                               },
//                             ),
//                             SizedBox(width: 48, child: Center(child: Text(formatQty(c.qty), style: const TextStyle(fontSize: 16)))),
//                             IconButton(
//                               icon: const Icon(Icons.add_circle_outline),
//                               onPressed: () {
//                                 Provider.of<CartModel>(context, listen: false).setQty(c.item, c.qty + 1.0);
//                               },
//                             ),
//                             const SizedBox(width: 12),
//                             SizedBox(width: 80, child: Text(Formatters.money(lineTotal), textAlign: TextAlign.right)),
//                           ],
//                         ),
//                       ],
//                     ),
//                   );
//                 },
//               ),
//             ),
//             const Divider(),
//             Padding(
//               padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
//               child: Row(
//                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
//                 children: [
//                   const Text('Total:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
//                   Text(Formatters.money(cart.total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
//                 ],
//               ),
//             ),
//             Padding(
//               padding: const EdgeInsets.only(bottom: 12),
//               child: Row(
//                 mainAxisAlignment: MainAxisAlignment.spaceEvenly,
//                 children: [
//                   ElevatedButton(
//                     onPressed: cart.items.isEmpty || _loadingLookups ? null : () => _showCreateDialog(context, cart),
//                     child: const Text('Create POS Invoice'),
//                   ),
//                   ElevatedButton(
//                     onPressed: cart.items.isEmpty ? null : () async => await _printInvoice(context, cart),
//                     child: const Text('Print'),
//                   ),
//                 ],
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
