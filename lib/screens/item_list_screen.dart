// lib/screens/item_list_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../providers/cart_model.dart';
import 'checkout_screen.dart';
import '../widgets/item_card.dart';
import '../logic/barcode_handlers.dart';
import '../widgets/barcode_keyboard_listener.dart';
import '../constants/config.dart';
import '../utils/formatters.dart'; // Formatters.money (keep if used elsewhere)

class ItemListScreen extends StatefulWidget {
  const ItemListScreen({super.key});
  @override
  State<ItemListScreen> createState() => _ItemListScreenState();
}

class _ItemListScreenState extends State<ItemListScreen> {
  List<Item> items = [];
  bool loading = true;
  String? error;

  // barcode -> Item mapping built from initial fetch
  final Map<String, Item> _barcodeMap = {};

  // map item.name -> selling price (standard_rate) from server raw row
  final Map<String, double> _sellingRateMap = {};

  // settings/persisted selections
  String? _selectedPosProfile;
  String? _selectedPriceList;
  List<Map<String, dynamic>> _posProfiles = [];
  List<Map<String, dynamic>> _priceLists = [];
  bool _settingsLoading = false;

  // customers
  List<Map<String, dynamic>> _customers = [];
  String? _selectedCustomer;

  static const _prefsPosOpeningDone = 'pos_opening_done';

  final _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _pauseBarcode = false; // true when search field has focus

  String _searchQuery = '';

  // Guard to prevent overlapping opening checks/dialogs
  bool _openingCheckInProgress = false;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _loadCustomers();

    // pause barcode while typing in search
    _searchFocus.addListener(() {
      setState(() {
        _pauseBarcode = _searchFocus.hasFocus;
      });
    });

    // On first frame: ensure opening entry exists (status == "Open") BEFORE loading items.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _ensureOpeningEntryExists();
      await fetchItems();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Re-check when this route becomes current. Using a post-frame callback ensures ModalRoute is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ModalRoute<dynamic>? route = ModalRoute.of(context);
      if (route != null && route.isCurrent) {
        if (!_openingCheckInProgress) {
          // fire-and-forget; internal guard prevents reentry
          _ensureOpeningEntryExists();
        }
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadCustomers() async {
    try {
      final apiProv = Provider.of<ApiProvider>(context, listen: false);
      final customers = await apiProv.getCustomerList();
      setState(() {
        _customers = customers;
        if (_customers.isNotEmpty) {
          // choose a sensible default (first)
          _selectedCustomer = _customers.first['name']?.toString();
        }
      });
    } catch (e) {
      debugPrint('loadCustomers error: $e');
    }
  }

  /// Ensure that there is an Open POS Opening Entry for today.
  /// If not found, show a mandatory dialog and require the user to create & submit one.
  Future<void> _ensureOpeningEntryExists() async {
    if (_openingCheckInProgress || !mounted) return;
    _openingCheckInProgress = true;

    final apiProv = Provider.of<ApiProvider>(context, listen: false);

    // Helper to ask server whether an Opening Entry exists for today with status == "Open"
    Future<bool> serverHasOpenOpening() async {
      try {
        final company = AppConfig.companyName ?? '';
        final today = DateTime.now();
        final todayStr =
            '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

        // Query for POS Opening Entry with matching company, period_start_date and status == "Open"
        final resp = await apiProv.dio.get('/api/resource/POS Opening Entry', queryParameters: {
          'fields': '["name","period_start_date","status","docstatus"]',
          'filters': jsonEncode([
            ['company', '=', company],
            ['period_start_date', '=', todayStr],
            ['status', '=', 'Open']
          ]),
          'limit_page_length': '1'
        }, options: Options(validateStatus: (_) => true));

        if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List && (resp.data['data'] as List).isNotEmpty) {
          return true;
        }
      } catch (e) {
        debugPrint('serverHasOpenOpening check failed: $e');
      }
      return false;
    }

    try {
      bool exists = await serverHasOpenOpening();

      while (!exists && mounted) {
        // show mandatory dialog which will remain until successful submit/open
        await _showOpeningEntryDialog(mandatory: true);

        // after dialog returns, re-check server for Open entry
        exists = await serverHasOpenOpening();

        if (!exists && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('POS Opening Entry with status "Open" not found on server. Please create and submit/open it.')));
          // small delay to avoid very fast loop
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    } finally {
      _openingCheckInProgress = false;
    }
  }

  Future<void> _loadSavedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPos = prefs.getString('selected_pos_profile');
      final savedPrice = prefs.getString('selected_price_list');
      final savedCompany = prefs.getString('company_name');

      if (savedPos != null && savedPos.trim().isNotEmpty) _selectedPosProfile = savedPos.trim();
      if (savedPrice != null && savedPrice.trim().isNotEmpty) _selectedPriceList = savedPrice.trim();
      if (savedCompany != null && savedCompany.isNotEmpty) AppConfig.companyName = savedCompany;
      setState(() {});
    } catch (_) {}
  }

  Future<void> fetchItems() async {
    setState(() {
      loading = true;
      error = null;
    });

    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    try {
      final resp = await apiProv.client.getItems({
        // ensure server returns standard_rate in listing (selling price)
        'fields': '["name","item_name","image","stock_uom","valuation_rate","barcodes","standard_rate"]',
        'limit_page_length': '200'
      });

      final data = resp.data;
      if (data == null || data['data'] == null) {
        setState(() => error = 'Invalid response from server (no data)');
        return;
      }

      final rawList = (data['data'] as List).cast<dynamic>();
      items = [];
      _barcodeMap.clear();
      _sellingRateMap.clear();

      for (var raw in rawList) {
        final Map<String, dynamic> row = Map<String, dynamic>.from(raw as Map);
        final item = Item.fromJson(row);
        items.add(item);

        // store any standard_rate present in the raw JSON
        try {
          if (row.containsKey('standard_rate') && row['standard_rate'] != null) {
            final sr = row['standard_rate'];
            double val = 0.0;
            if (sr is num) val = sr.toDouble();
            else if (sr is String) val = double.tryParse(sr) ?? 0.0;
            if (val > 0) _sellingRateMap[item.name] = val;
          }
        } catch (_) {
          // ignore
        }

        // collect barcodes from child tables and top-level fields
        for (final entry in row.entries) {
          final val = entry.value;
          if (val is List && val.isNotEmpty && val.first is Map) {
            try {
              final first = Map<String, dynamic>.from(val.first as Map);
              if (first.containsKey('barcode') || first.containsKey('item_barcode') || first.containsKey('barcode_value')) {
                for (final el in (val as List)) {
                  if (el is Map) {
                    final bcCandidates = <dynamic>[el['barcode'], el['item_barcode'], el['barcode_value'], el['barcode_id']];
                    for (final candidate in bcCandidates) {
                      if (candidate == null) continue;
                      final bc = candidate.toString().trim();
                      if (bc.isEmpty) continue;
                      for (final v in _barcodeVariants(bc)) _barcodeMap[v] = item;
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }

        final topCandidates = <String>['default_code', 'ean', 'upc', 'barcode'];
        for (final k in topCandidates) {
          if (row.containsKey(k) && row[k] != null) {
            final bc = row[k].toString().trim();
            if (bc.isNotEmpty) for (final v in _barcodeVariants(bc)) _barcodeMap[v] = item;
          }
        }
      }

      debugPrint('Loaded ${items.length} items, found ${_barcodeMap.length} barcode entries locally.');
      setState(() {});
    } catch (e) {
      setState(() => error = 'Error loading items: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  String imageUrlFor(String? imagePath) {
    if (imagePath == null) return '';
    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    if (imagePath.startsWith('/')) return '${apiProv.baseUrl}$imagePath';
    if (imagePath.startsWith('http')) return imagePath;
    return '${apiProv.baseUrl}/$imagePath';
  }

  List<String> _barcodeVariants(String bc) {
    final out = <String>[];
    final trimmed = bc.trim();
    out.add(trimmed);
    final noLeading = trimmed.replaceFirst(RegExp(r'^0+'), '');
    if (noLeading.isNotEmpty && noLeading != trimmed) out.add(noLeading);
    for (final len in [8, 12, 13]) if (trimmed.length < len) out.add(trimmed.padLeft(len, '0'));
    final digitsOnly = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.isNotEmpty && digitsOnly != trimmed) out.add(digitsOnly);
    return out.toSet().toList();
  }

  Future<void> _onBarcodeScanned(String rawBarcode) async {
    // If paused (search input focused), ignore barcode events
    if (_pauseBarcode) return;

    final barcode = rawBarcode.trim();
    if (barcode.isEmpty) return;
    final variants = _barcodeVariants(barcode);
    Item? local;
    for (final v in variants) {
      if (_barcodeMap.containsKey(v)) {
        local = _barcodeMap[v];
        break;
      }
    }
    if (local != null) {
      // prefer selling price (if we stored it) otherwise fallback to valuation_rate (Item.rate)
      final useRate = _sellingRateMap[local.name] ?? local.rate ?? 0.0;
      Provider.of<CartModel>(context, listen: false).add(local, rate: useRate);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${local.itemName ?? local.name} added — ${(useRate).toStringAsFixed(2)}')));
      return;
    }
    try {
      await handleBarcodeScan(context, barcode);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Barcode lookup failed: ${e.toString()}'), backgroundColor: Colors.red));
    }
  }

  // ----------------- open settings / logout -----------------
  Future<void> _openSettingsDialog() async {
    setState(() => _settingsLoading = true);
    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    try {
      final rawPos = await apiProv.getPOSProfileList();
      _posProfiles = rawPos.map((m) => {'name': (m['name']?.toString() ?? '').trim(), ...m}).toList();
      final rawPrices = await apiProv.getSellingPriceList();
      _priceLists = rawPrices.map((m) => {'name': (m['name']?.toString() ?? '').trim(), ...m}).toList();
    } catch (e) {
      debugPrint('settings: fetch lists error: $e');
    } finally {
      setState(() => _settingsLoading = false);
    }

    String? selPos = _selectedPosProfile;
    String? selPrice = _selectedPriceList;

    await showDialog(
      context: context,
      builder: (dctx) {
        return StatefulBuilder(builder: (dctxInner, setD) {
          final trimmedPosList = _posProfiles.map((m) => (m['name']?.toString() ?? '').trim()).toList();
          final trimmedPriceList = _priceLists.map((m) => (m['name']?.toString() ?? '').trim()).toList();

          final bool selPosExists = selPos != null && selPos!.isNotEmpty && trimmedPosList.contains(selPos);
          final bool selPriceExists = selPrice != null && selPrice!.isNotEmpty && trimmedPriceList.contains(selPrice);

          return AlertDialog(
            title: const Text('Settings'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_settingsLoading) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'POS Profile', border: OutlineInputBorder()),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: selPosExists ? selPos : null,
                        items: trimmedPosList.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
                        onChanged: (v) => setD(() => selPos = v?.trim()),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Selling Price List', border: OutlineInputBorder()),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: selPriceExists ? selPrice : null,
                        items: trimmedPriceList.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
                        onChanged: (v) => setD(() => selPrice = v?.trim()),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Company: ', style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(child: Text(AppConfig.companyName)),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
              TextButton(
                onPressed: () async {
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    if (selPos != null && selPos!.isNotEmpty) {
                      final trimmedPos = selPos!.trim();
                      await prefs.setString('selected_pos_profile', trimmedPos);
                      _selectedPosProfile = trimmedPos;

                      // try to fetch POS Profile doc to read company field
                      try {
                        final resp = await apiProv.dio.get('/api/resource/POS Profile/$trimmedPos', queryParameters: {'fields': '["name","company"]'}, options: Options(validateStatus: (_) => true));
                        if (resp.statusCode == 200 && resp.data != null) {
                          final d = resp.data;
                          String? company;
                          if (d is Map && d['data'] is Map && d['data']['company'] != null) {
                            company = d['data']['company']?.toString();
                          } else if (d is Map && d['company'] != null) {
                            company = d['company']?.toString();
                          }
                          if (company != null && company.isNotEmpty) {
                            AppConfig.companyName = company;
                            await prefs.setString('company_name', company);
                          }
                        }
                      } catch (e) {
                        debugPrint('settings: error fetching POS Profile doc: $e');
                      }
                    }

                    if (selPrice != null && selPrice!.isNotEmpty) {
                      final trimmedPrice = selPrice!.trim();
                      await prefs.setString('selected_price_list', trimmedPrice);
                      _selectedPriceList = trimmedPrice;
                    }

                    setState(() {});
                  } catch (e) {
                    debugPrint('settings: save failed: $e');
                  } finally {
                    Navigator.of(dctx).pop();
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _logout() async {
    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    try {
      if (apiProv.cookieJar != null) await apiProv.cookieJar!.deleteAll();
    } catch (e) {
      debugPrint('logout: cookie clear failed: $e');
    }
    try {
      apiProv.dio.close(force: true);
    } catch (_) {}
    Provider.of<CartModel>(context, listen: false).clear();
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  // ----------------- POS Opening Entry creation & submit -----------------
  /// If mandatory is true dialog is non-dismissable and the user must successfully submit an opening entry.
  Future<void> _showOpeningEntryDialog({bool mandatory = false}) async {
    setState(() => _settingsLoading = true);
    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    List<Map<String, dynamic>> posProfiles = [];
    List<Map<String, dynamic>> paymentModes = [];

    try {
      posProfiles = await apiProv.getPOSProfileList();
      final resp = await apiProv.dio.get('/api/resource/Mode of Payment', queryParameters: {'fields': '["name","mode_of_payment"]', 'limit_page_length': '200'}, options: Options(validateStatus: (_) => true));
      if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List) paymentModes = List<Map<String, dynamic>>.from((resp.data['data'] as List).map((e) => Map<String, dynamic>.from(e)));
    } catch (e) {
      debugPrint('opening entry: fetch lists error: $e');
    } finally {
      setState(() => _settingsLoading = false);
    }

    String? loggedUser;
    try {
      final uresp = await apiProv.dio.get('/api/method/frappe.auth.get_logged_user', options: Options(validateStatus: (_) => true));
      if (uresp.statusCode == 200 && uresp.data is Map && uresp.data['message'] != null) loggedUser = uresp.data['message'].toString();
    } catch (e) {
      debugPrint('Could not fetch logged user: $e');
      loggedUser = null;
    }

    // Build dialog
    await showDialog(
      barrierDismissible: !mandatory, // if mandatory true -> non-dismissable
      context: context,
      builder: (dctx) {
        final rows = <Map<String, dynamic>>[{'mode_of_payment': null, 'opening_amount': 0.0}];
        String? selectedPosLocal = (posProfiles.isNotEmpty ? (posProfiles.first['name']?.toString()) : _selectedPosProfile) ?? _selectedPosProfile;
        DateTime periodStart = DateTime.now();

        return WillPopScope(
          // prevent back button when mandatory
          onWillPop: () async => !mandatory,
          child: StatefulBuilder(builder: (ctx, setSt) {
            Widget rowWidget(int index) {
              final row = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: DropdownButtonFormField<String>(
                        value: row['mode_of_payment']?.toString(),
                        items: paymentModes.map((m) => DropdownMenuItem<String>(value: m['name']?.toString(), child: Text((m['mode_of_payment'] ?? m['name'])?.toString() ?? ''))).toList(),
                        onChanged: (v) => setSt(() => row['mode_of_payment'] = v),
                        decoration: const InputDecoration(labelText: 'Mode of Payment', border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: TextFormField(
                        initialValue: (row['opening_amount'] ?? 0.0).toString(),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Opening Amount', border: OutlineInputBorder()),
                        onChanged: (s) {
                          final val = double.tryParse(s.replaceAll(',', '')) ?? 0.0;
                          setSt(() => row['opening_amount'] = val);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () {
                        setSt(() => rows.removeAt(index));
                      },
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              );
            }

            return AlertDialog(
              title: const Text('Create POS Opening Entry'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_settingsLoading) const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    TextFormField(initialValue: AppConfig.companyName, readOnly: true, decoration: const InputDecoration(labelText: 'Company', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'POS Profile', border: OutlineInputBorder()),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: selectedPosLocal,
                          items: posProfiles.map((m) => DropdownMenuItem<String>(value: m['name']?.toString(), child: Text(m['name']?.toString() ?? ''))).toList(),
                          onChanged: (v) => setSt(() => selectedPosLocal = v),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(initialValue: loggedUser ?? '', readOnly: true, decoration: const InputDecoration(labelText: 'Cashier (logged user)', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'Period Start Date', border: OutlineInputBorder()),
                      child: Row(
                        children: [
                          Expanded(child: Text('${periodStart.year.toString().padLeft(4, '0')}-${periodStart.month.toString().padLeft(2, '0')}-${periodStart.day.toString().padLeft(2, '0')}')),
                          TextButton(onPressed: () async {
                            final d = await showDatePicker(context: context, initialDate: periodStart, firstDate: DateTime(2000), lastDate: DateTime(2100));
                            if (d != null) setSt(() => periodStart = d);
                          }, child: const Text('Select')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Align(alignment: Alignment.centerLeft, child: Text('Opening Balance Details', style: TextStyle(fontWeight: FontWeight.bold))),
                    const SizedBox(height: 8),
                    ...List.generate(rows.length, (i) => rowWidget(i)),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ElevatedButton.icon(onPressed: () => setSt(() => rows.add({'mode_of_payment': null, 'opening_amount': 0.0})), icon: const Icon(Icons.add), label: const Text('Add Row')),
                    )
                  ],
                ),
              ),
              actions: [
                if (!mandatory) TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: () async {
                    if (selectedPosLocal == null || selectedPosLocal!.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select POS Profile')));
                      return;
                    }
                    if (loggedUser == null || loggedUser.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logged user not found.')));
                      return;
                    }
                    final obRows = <Map<String, dynamic>>[];
                    for (final r in rows) {
                      if (r['mode_of_payment'] == null) continue;
                      final amt = (r['opening_amount'] ?? 0.0) is double ? r['opening_amount'] : double.tryParse((r['opening_amount'] ?? '0').toString()) ?? 0.0;
                      obRows.add({'mode_of_payment': r['mode_of_payment'], 'opening_amount': amt});
                    }
                    if (obRows.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please add at least one opening balance row')));
                      return;
                    }
                    final periodStartStr = '${periodStart.year.toString().padLeft(4, '0')}-${periodStart.month.toString().padLeft(2, '0')}-${periodStart.day.toString().padLeft(2, '0')}';
                    final payload = {
                      'company': AppConfig.companyName,
                      'pos_profile': selectedPosLocal,
                      'user': loggedUser,
                      'balance_details': obRows,
                      'opening_balance_details': obRows,
                      'period_start_date': periodStartStr,
                    };

                    try {
                      // create entry
                      final createResp = await apiProv.dio.post('/api/resource/POS Opening Entry', data: payload, options: Options(validateStatus: (_) => true));
                      if (!(createResp.statusCode == 200 || createResp.statusCode == 201)) {
                        final err = createResp.data ?? 'Server returned ${createResp.statusCode}';
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error creating opening entry: $err')));
                        return;
                      }

                      // extract name or doc
                      String? createdName;
                      Map<String, dynamic>? createdDoc;
                      final createBody = createResp.data;
                      if (createBody is Map && createBody['data'] is Map) {
                        createdDoc = Map<String, dynamic>.from(createBody['data'] as Map);
                        createdName = createdDoc['name']?.toString();
                      } else if (createBody is Map && createBody['name'] != null) {
                        createdName = createBody['name'].toString();
                      }

                      final docToSubmit = createdDoc ?? {'doctype': 'POS Opening Entry', 'name': createdName};

                      // submit
                      final submitResp = await apiProv.dio.post('/api/method/frappe.client.submit', data: {'doc': docToSubmit}, options: Options(validateStatus: (_) => true));
                      if (submitResp.statusCode == 200 || submitResp.statusCode == 201) {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(_prefsPosOpeningDone, true);
                        Navigator.of(ctx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('POS Opening Entry created and submitted')));
                      } else {
                        final err = submitResp.data ?? 'Submit returned ${submitResp.statusCode}';
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Created but submit failed: $err')));
                        // remain on dialog so user can retry or correct
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                      // remain on dialog so user can retry
                    }
                  },
                  child: const Text('Submit'),
                )
              ],
            );
          }),
        );
      },
    );
  }

  // ----------------- end opening entry -----------------

  // ----------------- POS Closing Entry creation & sales invoice trigger -----------------
  Future<void> _showClosingEntryDialog() async {
    setState(() => _settingsLoading = true);
    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    List<Map<String, dynamic>> posProfiles = [];
    List<Map<String, dynamic>> paymentModes = [];

    try {
      posProfiles = await apiProv.getPOSProfileList();
      final resp = await apiProv.dio.get('/api/resource/Mode of Payment', queryParameters: {'fields': '["name","mode_of_payment"]', 'limit_page_length': '200'}, options: Options(validateStatus: (_) => true));
      if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List) paymentModes = List<Map<String, dynamic>>.from((resp.data['data'] as List).map((e) => Map<String, dynamic>.from(e)));
    } catch (e) {
      debugPrint('closing entry: fetch lists error: $e');
    } finally {
      setState(() => _settingsLoading = false);
    }

    String? loggedUser;
    try {
      final uresp = await apiProv.dio.get('/api/method/frappe.auth.get_logged_user', options: Options(validateStatus: (_) => true));
      if (uresp.statusCode == 200 && uresp.data is Map && uresp.data['message'] != null) loggedUser = uresp.data['message'].toString();
    } catch (e) {
      debugPrint('Could not fetch logged user: $e');
      loggedUser = null;
    }

    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (dctx) {
        final rows = <Map<String, dynamic>>[{'mode_of_payment': null, 'closing_amount': 0.0}];
        String? selectedPosLocal = (posProfiles.isNotEmpty ? (posProfiles.first['name']?.toString()) : _selectedPosProfile) ?? _selectedPosProfile;
        DateTime periodEnd = DateTime.now();

        return StatefulBuilder(builder: (ctx, setSt) {
          Widget rowWidget(int index) {
            final row = rows[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 6,
                    child: DropdownButtonFormField<String>(
                      value: row['mode_of_payment']?.toString(),
                      items: paymentModes.map((m) => DropdownMenuItem<String>(value: m['name']?.toString(), child: Text((m['mode_of_payment'] ?? m['name'])?.toString() ?? ''))).toList(),
                      onChanged: (v) => setSt(() => row['mode_of_payment'] = v),
                      decoration: const InputDecoration(labelText: 'Mode of Payment', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: TextFormField(
                      initialValue: (row['closing_amount'] ?? 0.0).toString(),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Closing Amount', border: OutlineInputBorder()),
                      onChanged: (s) {
                        final val = double.tryParse(s.replaceAll(',', '')) ?? 0.0;
                        setSt(() => row['closing_amount'] = val);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () {
                      setSt(() => rows.removeAt(index));
                    },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            title: const Text('Create POS Closing Entry'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_settingsLoading) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  TextFormField(initialValue: AppConfig.companyName, readOnly: true, decoration: const InputDecoration(labelText: 'Company', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'POS Profile', border: OutlineInputBorder()),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: selectedPosLocal,
                        items: posProfiles.map((m) => DropdownMenuItem<String>(value: m['name']?.toString(), child: Text(m['name']?.toString() ?? ''))).toList(),
                        onChanged: (v) => setSt(() => selectedPosLocal = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(initialValue: loggedUser ?? '', readOnly: true, decoration: const InputDecoration(labelText: 'Cashier (logged user)', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Period End Date', border: OutlineInputBorder()),
                    child: Row(
                      children: [
                        Expanded(child: Text('${periodEnd.year.toString().padLeft(4, '0')}-${periodEnd.month.toString().padLeft(2, '0')}-${periodEnd.day.toString().padLeft(2, '0')}')),
                        TextButton(onPressed: () async {
                          final d = await showDatePicker(context: context, initialDate: periodEnd, firstDate: DateTime(2000), lastDate: DateTime(2100));
                          if (d != null) setSt(() => periodEnd = d);
                        }, child: const Text('Select')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Align(alignment: Alignment.centerLeft, child: Text('Closing Balance Details', style: TextStyle(fontWeight: FontWeight.bold))),
                  const SizedBox(height: 8),
                  ...List.generate(rows.length, (i) => rowWidget(i)),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton.icon(onPressed: () => setSt(() => rows.add({'mode_of_payment': null, 'closing_amount': 0.0})), icon: const Icon(Icons.add), label: const Text('Add Row')),
                  )
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  if (selectedPosLocal == null || selectedPosLocal!.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select POS Profile')));
                    return;
                  }
                  if (loggedUser == null || loggedUser!.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logged user not found.')));
                    return;
                  }
                  final cbRows = <Map<String, dynamic>>[];
                  for (final r in rows) {
                    if (r['mode_of_payment'] == null) continue;
                    final amt = (r['closing_amount'] ?? 0.0) is double ? r['closing_amount'] : double.tryParse((r['closing_amount'] ?? '0').toString()) ?? 0.0;
                    cbRows.add({'mode_of_payment': r['mode_of_payment'], 'closing_amount': amt});
                  }
                  if (cbRows.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please add at least one closing balance row')));
                    return;
                  }
                  final periodEndStr = '${periodEnd.year.toString().padLeft(4, '0')}-${periodEnd.month.toString().padLeft(2, '0')}-${periodEnd.day.toString().padLeft(2, '0')}';
                  final payload = {
                    'company': AppConfig.companyName,
                    'pos_profile': selectedPosLocal,
                    'user': loggedUser,
                    'balance_details': cbRows,
                    'closing_balance_details': cbRows,
                    'period_end_date': periodEndStr,
                  };

                  try {
                    final createResp = await apiProv.dio.post('/api/resource/POS Closing Entry', data: payload, options: Options(validateStatus: (_) => true));
                    if (!(createResp.statusCode == 200 || createResp.statusCode == 201)) {
                      final err = createResp.data ?? 'Server returned ${createResp.statusCode}';
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error creating closing entry: $err')));
                      return;
                    }

                    // extract name or doc
                    String? createdName;
                    Map<String, dynamic>? createdDoc;
                    final createBody = createResp.data;
                    if (createBody is Map && createBody['data'] is Map) {
                      createdDoc = Map<String, dynamic>.from(createBody['data'] as Map);
                      createdName = createdDoc['name']?.toString();
                    } else if (createBody is Map && createBody['name'] != null) {
                      createdName = createBody['name'].toString();
                    }

                    final docToSubmit = createdDoc ?? {'doctype': 'POS Closing Entry', 'name': createdName};
                    final submitResp = await apiProv.dio.post('/api/method/frappe.client.submit', data: {'doc': docToSubmit}, options: Options(validateStatus: (_) => true));
                    if (submitResp.statusCode == 200 || submitResp.statusCode == 201) {
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('POS Closing Entry created and submitted')));

                      // Now attempt to create sales invoices from this closing entry using custom server API.
                      if (createdName != null) {
                        await _postClosingAndCreateInvoices(createdName);
                      }
                    } else {
                      final err = submitResp.data ?? 'Submit returned ${submitResp.statusCode}';
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Created but submit failed: $err')));
                    }
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                  }
                },
                child: const Text('Submit'),
              )
            ],
          );
        });
      },
    );
  }

  /// Best-effort call to server custom method to create sales invoices from the created POS Closing Entry.
  Future<void> _postClosingAndCreateInvoices(String posClosingName) async {
    final apiProv = Provider.of<ApiProvider>(context, listen: false);
    try {
      final resp = await apiProv.dio.post('/api/method/pos_custom.api.create_sales_invoice_from_pos_closing',
          data: {'pos_closing_entry': posClosingName}, options: Options(validateStatus: (_) => true));

      if (resp.statusCode == 200) {
        final msg = (resp.data is Map && resp.data['message'] != null) ? resp.data['message'].toString() : 'Sales invoices created';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      } else {
        final err = resp.data ?? 'Status ${resp.statusCode}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invoice generation failed: $err')));
      }
    } catch (e) {
      debugPrint('error posting closing->invoices: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invoice generation error: $e')));
    }
  }

  // ----------------- end closing entry -----------------

  // Filter items per _searchQuery
  List<Item> get _filteredItems {
    if (_searchQuery.isEmpty) return items;
    final q = _searchQuery.toLowerCase();
    return items.where((it) {
      final name = (it.itemName ?? it.name).toLowerCase();
      final code = it.name.toLowerCase();
      return name.contains(q) || code.contains(q);
    }).toList();
  }

  // Reusable searchable picker used for selecting customers
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
              height: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search...'), onChanged: doFilter),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('No results'))
                        : ListView.separated(
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

    // NOTE: per request make grid 5 columns
    const int columns = 5;

    return BarcodeKeyboardListener(
      onBarcode: (code) async => await _onBarcodeScanned(code),
      child: Scaffold(
        appBar: AppBar(
          title: Row(children: [
            const Text('Point of Sale'),
            const SizedBox(width: 12),
            if (_selectedPosProfile != null) Chip(label: Text(_selectedPosProfile!)),
          ]),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: fetchItems),
            // POS Closing Entry button
            IconButton(
              icon: const Icon(Icons.power_settings_new),
              tooltip: 'POS Closing Entry',
              onPressed: () async {
                await _showClosingEntryDialog();
              },
            ),
            IconButton(icon: const Icon(Icons.settings), onPressed: _openSettingsDialog),
            Stack(
              children: [
                IconButton(icon: const Icon(Icons.shopping_cart), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckoutScreen()))),
                if (cart.count > 0)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: CircleAvatar(radius: 8, child: Text('${cart.count}', style: const TextStyle(fontSize: 10))),
                  ),
              ],
            )
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DrawerHeader(
                  decoration: const BoxDecoration(color: Colors.blue),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('ERPNext POS', style: Theme.of(context).primaryTextTheme.titleLarge?.copyWith(color: Colors.white)),
                    const SizedBox(height: 8),
                    Text('Company: ${AppConfig.companyName}', style: const TextStyle(color: Colors.white70)),
                    if (_selectedPosProfile != null) Text('POS: $_selectedPosProfile', style: const TextStyle(color: Colors.white70)),
                    if (_selectedPriceList != null) Text('Price: $_selectedPriceList', style: const TextStyle(color: Colors.white70)),
                  ]),
                ),
                ListTile(leading: const Icon(Icons.settings), title: const Text('Settings'), onTap: () {
                  Navigator.of(context).pop();
                  _openSettingsDialog();
                }),
                ListTile(leading: const Icon(Icons.logout), title: const Text('Logout'), onTap: () {
                  Navigator.of(context).pop();
                  _logout();
                }),
                const Spacer(),
                Padding(padding: const EdgeInsets.all(12.0), child: Text('Base: ${Provider.of<ApiProvider>(context, listen: false).baseUrl}', style: const TextStyle(fontSize: 12, color: Colors.black54))),
              ],
            ),
          ),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
            ? Center(child: Text(error!))
            : Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              // Left: Items area (search + grid)
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          focusNode: _searchFocus,
                          controller: _searchCtrl,
                          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by item code, name or barcode'),
                          onChanged: (s) => setState(() {
                            _searchQuery = s;
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 220,
                        child: InputDecorator(
                          decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                          child: Row(
                            children: [
                              Expanded(child: Text(_selectedPriceList ?? 'Select price list')),
                              IconButton(
                                icon: const Icon(Icons.arrow_drop_down),
                                onPressed: () => _openSettingsDialog(),
                              )
                            ],
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Expanded(
                      child: GridView.builder(
                        itemCount: _filteredItems.length,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          childAspectRatio: 0.75,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemBuilder: (ctx, i) {
                          final it = _filteredItems[i];

                          // prefer server-returned standard_rate if available
                          final displayRate = _sellingRateMap[it.name] ?? it.rate ?? 0.0;

                          final uom = (it.uom ?? '').trim();
                          final uomText = uom.isEmpty ? '' : uom;
                          final priceLabel = displayRate > 0 ? '₹ ${displayRate.toStringAsFixed(0)} / ${uomText.isNotEmpty ? uomText : ''}'.trim() : '';

                          // Wrap the card with InkWell so tapping the whole card adds the item
                          return InkWell(
                            onTap: () {
                              Provider.of<CartModel>(context, listen: false).add(it, rate: displayRate);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${it.itemName ?? it.name} added — ${displayRate.toStringAsFixed(2)}')));
                            },
                            child: ItemCard(
                              itemName: it.itemName ?? it.name,
                              uom: uomText,
                              imageUrl: imageUrlFor(it.image),
                              priceLabel: priceLabel,
                              // NOTE: intentionally not passing an "onAdd" callback so the card's add button isn't shown (if ItemCard
                              // is implemented to show button only when onAdd is provided). Tapping the card adds the item instead.
                            ),
                          );
                        },
                      ),
                    )
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // Right: Cart & customer panel (scrollable to avoid overflow)
              Expanded(
                flex: 1,
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: () async {
                        // open customer picker
                        final sel = await _openSearchablePicker(ctx: context, title: 'Select Customer', items: _customers, valueKey: 'name', subLabelKey: 'customer_name');
                        if (sel != null) setState(() => _selectedCustomer = sel);
                      },
                      child: Card(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Row(
                            children: [
                              CircleAvatar(child: Text((_selectedCustomer != null && _selectedCustomer!.isNotEmpty) ? (_selectedCustomer![0].toUpperCase()) : 'C')),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(
                                    _selectedCustomerDisplay(),
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Text('Tap to change customer', style: TextStyle(color: Colors.grey.shade600)),
                                ]),
                              ),
                              IconButton(onPressed: () async {
                                final sel = await _openSearchablePicker(ctx: context, title: 'Select Customer', items: _customers, valueKey: 'name', subLabelKey: 'customer_name');
                                if (sel != null) setState(() => _selectedCustomer = sel);
                              }, icon: const Icon(Icons.edit)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Card(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Text('Item Cart', style: Theme.of(context).textTheme.titleMedium),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: cart.items.isEmpty
                                  ? const Center(child: Text('Cart is empty'))
                                  : ListView.builder(
                                itemCount: cart.items.length,
                                itemBuilder: (ctx, i) {
                                  final it = cart.items[i];
                                  return ListTile(
                                    leading: SizedBox(
                                      width: 40,
                                      height: 40,
                                      child: it.item.image != null && it.item.image!.isNotEmpty
                                          ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.network(imageUrlFor(it.item.image), fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: Colors.grey.shade200)),
                                      )
                                          : const Icon(Icons.inventory),
                                    ),
                                    title: Text(it.item.itemName ?? it.item.name),
                                    subtitle: Text('${it.qty % 1 == 0 ? it.qty.toStringAsFixed(0) : it.qty.toString()} ${it.item.uom ?? ''}'),
                                    trailing: ConstrainedBox(
                                      constraints: const BoxConstraints(minWidth: 90, maxWidth: 140),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Text('₹ ${(it.rate * it.qty).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                                icon: const Icon(Icons.remove_circle_outline),
                                                onPressed: () {
                                                  final newQty = it.qty - 1.0;
                                                  if (newQty <= 0.0) Provider.of<CartModel>(context, listen: false).remove(it.item);
                                                  else Provider.of<CartModel>(context, listen: false).setQty(it.item, newQty);
                                                },
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 6.0),
                                                child: Text('${(it.qty % 1 == 0) ? it.qty.toStringAsFixed(0) : it.qty.toStringAsFixed(2)}'),
                                              ),
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                                icon: const Icon(Icons.add_circle_outline),
                                                onPressed: () {
                                                  Provider.of<CartModel>(context, listen: false).setQty(it.item, it.qty + 1.0);
                                                },
                                              ),
                                            ],
                                          )
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Total Quantity'), Text('${cart.items.fold<double>(0, (p, e) => p + e.qty)}')]),
                                  const SizedBox(height: 6),
                                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Net Total'), Text('₹ ${cart.total.toStringAsFixed(2)}')]),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Grand Total', style: TextStyle(fontWeight: FontWeight.bold)),
                                      Text('₹ ${(cart.total).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton(
                                    onPressed: cart.items.isEmpty ? null : () {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckoutScreen()));
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 14.0),
                                      child: Text('Checkout'),
                                    ),
                                  )
                                ],
                              ),
                            )
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  String _selectedCustomerDisplay() {
    if (_selectedCustomer == null) return 'Select Customer';
    // show nicer label if we have mapping
    final found = _customers.firstWhere((c) => c['name'] == _selectedCustomer, orElse: () => {});
    if (found.isNotEmpty) {
      final primary = (found['customer_name'] ?? found['name'] ?? '').toString();
      final secondary = (found['name'] ?? '').toString();
      return primary.isNotEmpty ? '$primary' : secondary;
    }
    return _selectedCustomer!;
  }
}









// // lib/screens/item_list_screen.dart
// import 'dart:async';
// import 'dart:convert';
//
// import 'package:dio/dio.dart';
// import 'package:flutter/material.dart';
// import 'package:provider/provider.dart';
// import 'package:shared_preferences/shared_preferences.dart';
//
// import '../api/api_client.dart';
// import '../api/models.dart';
// import '../providers/cart_model.dart';
// import 'checkout_screen.dart';
// import '../widgets/item_card.dart';
// import '../logic/barcode_handlers.dart';
// import '../widgets/barcode_keyboard_listener.dart';
// import '../constants/config.dart';
// import '../utils/formatters.dart'; // Formatters.money
//
// class ItemListScreen extends StatefulWidget {
//   const ItemListScreen({super.key});
//   @override
//   State<ItemListScreen> createState() => _ItemListScreenState();
// }
//
// class _ItemListScreenState extends State<ItemListScreen> {
//   List<Item> items = [];
//   bool loading = true;
//   String? error;
//
//   // barcode -> Item mapping built from initial fetch
//   final Map<String, Item> _barcodeMap = {};
//
//   // map item.name -> selling price (standard_rate) from server raw row
//   final Map<String, double> _sellingRateMap = {};
//
//   // settings/persisted selections
//   String? _selectedPosProfile;
//   String? _selectedPriceList;
//   List<Map<String, dynamic>> _posProfiles = [];
//   List<Map<String, dynamic>> _priceLists = [];
//   bool _settingsLoading = false;
//
//   // customers
//   List<Map<String, dynamic>> _customers = [];
//   String? _selectedCustomer;
//
//   static const _prefsPosOpeningDone = 'pos_opening_done';
//
//   final _searchCtrl = TextEditingController();
//   final FocusNode _searchFocus = FocusNode();
//   bool _pauseBarcode = false; // true when search field has focus
//
//   String _searchQuery = '';
//
//   @override
//   void initState() {
//     super.initState();
//     fetchItems();
//     _loadSavedSettings();
//     _loadCustomers();
//     // pause barcode while typing in search
//     _searchFocus.addListener(() {
//       setState(() {
//         _pauseBarcode = _searchFocus.hasFocus;
//       });
//     });
//
//     // Show opening dialog after first frame with robust server-check
//     WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowOpeningEntry());
//   }
//
//   @override
//   void dispose() {
//     _searchCtrl.dispose();
//     _searchFocus.dispose();
//     super.dispose();
//   }
//
//   Future<void> _loadCustomers() async {
//     try {
//       final apiProv = Provider.of<ApiProvider>(context, listen: false);
//       final customers = await apiProv.getCustomerList();
//       setState(() {
//         _customers = customers;
//         if (_customers.isNotEmpty) {
//           // choose a sensible default (first)
//           _selectedCustomer = _customers.first['name']?.toString();
//         }
//       });
//     } catch (e) {
//       debugPrint('loadCustomers error: $e');
//     }
//   }
//
//   Future<void> _maybeShowOpeningEntry() async {
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       final donePref = prefs.getBool(_prefsPosOpeningDone) ?? false;
//
//       // If preference indicates done, still check server for today's entry (robust)
//       final apiProv = Provider.of<ApiProvider>(context, listen: false);
//       final company = AppConfig.companyName ?? '';
//       final today = DateTime.now();
//       final todayStr =
//           '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
//
//       bool serverHasEntry = false;
//       try {
//         final resp = await apiProv.dio.get('/api/resource/POS Opening Entry', queryParameters: {
//           'fields': '["name","period_start_date","docstatus"]',
//           'filters': jsonEncode([
//             ['company', '=', company],
//             ['period_start_date', '=', todayStr]
//           ]),
//           'limit_page_length': '1'
//         }, options: Options(validateStatus: (_) => true));
//
//         if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List && (resp.data['data'] as List).isNotEmpty) {
//           serverHasEntry = true;
//         }
//       } catch (e) {
//         debugPrint('maybeShowOpeningEntry: server check failed: $e');
//         // ignore — we will fall back to pref behavior
//       }
//
//       // If prefs say not done OR server does not have entry -> show dialog
//       if (!donePref || !serverHasEntry) {
//         // small delay to let UI settle
//         await Future.delayed(const Duration(milliseconds: 150));
//         if (mounted) _showOpeningEntryDialog();
//       }
//     } catch (e) {
//       debugPrint('maybeShowOpeningEntry error: $e');
//     }
//   }
//
//   Future<void> _loadSavedSettings() async {
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       final savedPos = prefs.getString('selected_pos_profile');
//       final savedPrice = prefs.getString('selected_price_list');
//       final savedCompany = prefs.getString('company_name');
//
//       if (savedPos != null && savedPos.trim().isNotEmpty) _selectedPosProfile = savedPos.trim();
//       if (savedPrice != null && savedPrice.trim().isNotEmpty) _selectedPriceList = savedPrice.trim();
//       if (savedCompany != null && savedCompany.isNotEmpty) AppConfig.companyName = savedCompany;
//       setState(() {});
//     } catch (_) {}
//   }
//
//   Future<void> fetchItems() async {
//     setState(() {
//       loading = true;
//       error = null;
//     });
//
//     final apiProv = Provider.of<ApiProvider>(context, listen: false);
//     try {
//       final resp = await apiProv.client.getItems({
//         // ensure server returns standard_rate in listing (selling price)
//         'fields': '["name","item_name","image","stock_uom","valuation_rate","barcodes","standard_rate"]',
//         'limit_page_length': '200'
//       });
//
//       final data = resp.data;
//       if (data == null || data['data'] == null) {
//         setState(() => error = 'Invalid response from server (no data)');
//         return;
//       }
//
//       final rawList = (data['data'] as List).cast<dynamic>();
//       items = [];
//       _barcodeMap.clear();
//       _sellingRateMap.clear();
//
//       for (var raw in rawList) {
//         final Map<String, dynamic> row = Map<String, dynamic>.from(raw as Map);
//         final item = Item.fromJson(row);
//         items.add(item);
//
//         // store any standard_rate present in the raw JSON
//         try {
//           if (row.containsKey('standard_rate') && row['standard_rate'] != null) {
//             final sr = row['standard_rate'];
//             double val = 0.0;
//             if (sr is num) val = sr.toDouble();
//             else if (sr is String) val = double.tryParse(sr) ?? 0.0;
//             if (val > 0) _sellingRateMap[item.name] = val;
//           }
//         } catch (_) {
//           // ignore
//         }
//
//         // collect barcodes from child tables and top-level fields
//         for (final entry in row.entries) {
//           final val = entry.value;
//           if (val is List && val.isNotEmpty && val.first is Map) {
//             try {
//               final first = Map<String, dynamic>.from(val.first as Map);
//               if (first.containsKey('barcode') || first.containsKey('item_barcode') || first.containsKey('barcode_value')) {
//                 for (final el in (val as List)) {
//                   if (el is Map) {
//                     final bcCandidates = <dynamic>[el['barcode'], el['item_barcode'], el['barcode_value'], el['barcode_id']];
//                     for (final candidate in bcCandidates) {
//                       if (candidate == null) continue;
//                       final bc = candidate.toString().trim();
//                       if (bc.isEmpty) continue;
//                       for (final v in _barcodeVariants(bc)) _barcodeMap[v] = item;
//                     }
//                   }
//                 }
//               }
//             } catch (_) {}
//           }
//         }
//
//         final topCandidates = <String>['default_code', 'ean', 'upc', 'barcode'];
//         for (final k in topCandidates) {
//           if (row.containsKey(k) && row[k] != null) {
//             final bc = row[k].toString().trim();
//             if (bc.isNotEmpty) for (final v in _barcodeVariants(bc)) _barcodeMap[v] = item;
//           }
//         }
//       }
//
//       debugPrint('Loaded ${items.length} items, found ${_barcodeMap.length} barcode entries locally.');
//       setState(() {});
//     } catch (e) {
//       setState(() => error = 'Error loading items: $e');
//     } finally {
//       setState(() => loading = false);
//     }
//   }
//
//   String imageUrlFor(String? imagePath) {
//     if (imagePath == null) return '';
//     final apiProv = Provider.of<ApiProvider>(context, listen: false);
//     if (imagePath.startsWith('/')) return '${apiProv.baseUrl}$imagePath';
//     if (imagePath.startsWith('http')) return imagePath;
//     return '${apiProv.baseUrl}/$imagePath';
//   }
//
//   List<String> _barcodeVariants(String bc) {
//     final out = <String>[];
//     final trimmed = bc.trim();
//     out.add(trimmed);
//     final noLeading = trimmed.replaceFirst(RegExp(r'^0+'), '');
//     if (noLeading.isNotEmpty && noLeading != trimmed) out.add(noLeading);
//     for (final len in [8, 12, 13]) if (trimmed.length < len) out.add(trimmed.padLeft(len, '0'));
//     final digitsOnly = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
//     if (digitsOnly.isNotEmpty && digitsOnly != trimmed) out.add(digitsOnly);
//     return out.toSet().toList();
//   }
//
//   Future<void> _onBarcodeScanned(String rawBarcode) async {
//     // If paused (search input focused), ignore barcode events
//     if (_pauseBarcode) return;
//
//     final barcode = rawBarcode.trim();
//     if (barcode.isEmpty) return;
//     final variants = _barcodeVariants(barcode);
//     Item? local;
//     for (final v in variants) {
//       if (_barcodeMap.containsKey(v)) {
//         local = _barcodeMap[v];
//         break;
//       }
//     }
//     if (local != null) {
//       // prefer selling price (if we stored it) otherwise fallback to valuation_rate (Item.rate)
//       final useRate = _sellingRateMap[local.name] ?? local.rate ?? 0.0;
//       Provider.of<CartModel>(context, listen: false).add(local, rate: useRate);
//       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${local.itemName ?? local.name} added — ${(useRate).toStringAsFixed(2)}')));
//       return;
//     }
//     try {
//       await handleBarcodeScan(context, barcode);
//     } catch (e) {
//       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Barcode lookup failed: ${e.toString()}'), backgroundColor: Colors.red));
//     }
//   }
//
//   // ----------------- open settings / logout -----------------
//   Future<void> _openSettingsDialog() async {
//     setState(() => _settingsLoading = true);
//     final apiProv = Provider.of<ApiProvider>(context, listen: false);
//     try {
//       final rawPos = await apiProv.getPOSProfileList();
//       _posProfiles = rawPos.map((m) => {'name': (m['name']?.toString() ?? '').trim(), ...m}).toList();
//       final rawPrices = await apiProv.getSellingPriceList();
//       _priceLists = rawPrices.map((m) => {'name': (m['name']?.toString() ?? '').trim(), ...m}).toList();
//     } catch (e) {
//       debugPrint('settings: fetch lists error: $e');
//     } finally {
//       setState(() => _settingsLoading = false);
//     }
//
//     String? selPos = _selectedPosProfile;
//     String? selPrice = _selectedPriceList;
//
//     await showDialog(
//       context: context,
//       builder: (ctx) {
//         return StatefulBuilder(builder: (dctx, setD) {
//           final trimmedPosList = _posProfiles.map((m) => (m['name']?.toString() ?? '').trim()).toList();
//           final trimmedPriceList = _priceLists.map((m) => (m['name']?.toString() ?? '').trim()).toList();
//
//           final bool selPosExists = selPos != null && selPos!.isNotEmpty && trimmedPosList.contains(selPos);
//           final bool selPriceExists = selPrice != null && selPrice!.isNotEmpty && trimmedPriceList.contains(selPrice);
//
//           return AlertDialog(
//             title: const Text('Settings'),
//             content: SizedBox(
//               width: double.maxFinite,
//               child: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   if (_settingsLoading) const LinearProgressIndicator(),
//                   const SizedBox(height: 8),
//                   InputDecorator(
//                     decoration: const InputDecoration(labelText: 'POS Profile', border: OutlineInputBorder()),
//                     child: DropdownButtonHideUnderline(
//                       child: DropdownButton<String>(
//                         isExpanded: true,
//                         value: selPosExists ? selPos : null,
//                         items: trimmedPosList.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
//                         onChanged: (v) => setD(() => selPos = v?.trim()),
//                       ),
//                     ),
//                   ),
//                   const SizedBox(height: 12),
//                   InputDecorator(
//                     decoration: const InputDecoration(labelText: 'Selling Price List', border: OutlineInputBorder()),
//                     child: DropdownButtonHideUnderline(
//                       child: DropdownButton<String>(
//                         isExpanded: true,
//                         value: selPriceExists ? selPrice : null,
//                         items: trimmedPriceList.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
//                         onChanged: (v) => setD(() => selPrice = v?.trim()),
//                       ),
//                     ),
//                   ),
//                   const SizedBox(height: 12),
//                   Row(
//                     children: [
//                       const Text('Company: ', style: TextStyle(fontWeight: FontWeight.bold)),
//                       Expanded(child: Text(AppConfig.companyName)),
//                     ],
//                   ),
//                 ],
//               ),
//             ),
//             actions: [
//               TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
//               TextButton(
//                   onPressed: () async {
//                     try {
//                       final prefs = await SharedPreferences.getInstance();
//                       if (selPos != null && selPos!.isNotEmpty) {
//                         final trimmedPos = selPos!.trim();
//                         await prefs.setString('selected_pos_profile', trimmedPos);
//                         _selectedPosProfile = trimmedPos;
//
//                         // try to fetch POS Profile doc to read company field
//                         try {
//                           final resp = await apiProv.dio.get('/api/resource/POS Profile/$trimmedPos', queryParameters: {'fields': '["name","company"]'}, options: Options(validateStatus: (_) => true));
//                           if (resp.statusCode == 200 && resp.data != null) {
//                             final d = resp.data;
//                             String? company;
//                             if (d is Map && d['data'] is Map && d['data']['company'] != null) {
//                               company = d['data']['company']?.toString();
//                             } else if (d is Map && d['company'] != null) {
//                               company = d['company']?.toString();
//                             }
//                             if (company != null && company.isNotEmpty) {
//                               AppConfig.companyName = company;
//                               await prefs.setString('company_name', company);
//                             }
//                           }
//                         } catch (e) {
//                           debugPrint('settings: error fetching POS Profile doc: $e');
//                         }
//                       }
//
//                       if (selPrice != null && selPrice!.isNotEmpty) {
//                         final trimmedPrice = selPrice!.trim();
//                         await prefs.setString('selected_price_list', trimmedPrice);
//                         _selectedPriceList = trimmedPrice;
//                       }
//
//                       setState(() {});
//                     } catch (e) {
//                       debugPrint('settings: save failed: $e');
//                     } finally {
//                       Navigator.of(dctx).pop();
//                     }
//                   },
//                   child: const Text('Save')),
//             ],
//           );
//         });
//       },
//     );
//   }
//
//   Future<void> _logout() async {
//     final apiProv = Provider.of<ApiProvider>(context, listen: false);
//     try {
//       if (apiProv.cookieJar != null) await apiProv.cookieJar!.deleteAll();
//     } catch (e) {
//       debugPrint('logout: cookie clear failed: $e');
//     }
//     try {
//       apiProv.dio.close(force: true);
//     } catch (_) {}
//     Provider.of<CartModel>(context, listen: false).clear();
//     Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
//   }
//
//   // ----------------- POS Opening Entry creation & submit -----------------
//   Future<void> _showOpeningEntryDialog() async {
//     setState(() => _settingsLoading = true);
//     final apiProv = Provider.of<ApiProvider>(context, listen: false);
//     List<Map<String, dynamic>> posProfiles = [];
//     List<Map<String, dynamic>> paymentModes = [];
//
//     try {
//       posProfiles = await apiProv.getPOSProfileList();
//       final resp = await apiProv.dio.get('/api/resource/Mode of Payment', queryParameters: {'fields': '["name","mode_of_payment"]', 'limit_page_length': '200'}, options: Options(validateStatus: (_) => true));
//       if (resp.statusCode == 200 && resp.data is Map && resp.data['data'] is List) paymentModes = List<Map<String, dynamic>>.from((resp.data['data'] as List).map((e) => Map<String, dynamic>.from(e)));
//     } catch (e) {
//       debugPrint('opening entry: fetch lists error: $e');
//     } finally {
//       setState(() => _settingsLoading = false);
//     }
//
//     String? loggedUser;
//     try {
//       final uresp = await apiProv.dio.get('/api/method/frappe.auth.get_logged_user', options: Options(validateStatus: (_) => true));
//       if (uresp.statusCode == 200 && uresp.data is Map && uresp.data['message'] != null) loggedUser = uresp.data['message'].toString();
//     } catch (e) {
//       debugPrint('Could not fetch logged user: $e');
//       loggedUser = null;
//     }
//
//     await showDialog(
//       barrierDismissible: false,
//       context: context,
//       builder: (dctx) {
//         final rows = <Map<String, dynamic>>[{'mode_of_payment': null, 'opening_amount': 0.0}];
//         String? selectedPosLocal = (posProfiles.isNotEmpty ? (posProfiles.first['name']?.toString()) : _selectedPosProfile) ?? _selectedPosProfile;
//         DateTime periodStart = DateTime.now();
//
//         return StatefulBuilder(builder: (ctx, setSt) {
//           Widget rowWidget(int index) {
//             final row = rows[index];
//             return Padding(
//               padding: const EdgeInsets.symmetric(vertical: 6),
//               child: Row(
//                 children: [
//                   Expanded(
//                     flex: 6,
//                     child: DropdownButtonFormField<String>(
//                       value: row['mode_of_payment']?.toString(),
//                       items: paymentModes.map((m) => DropdownMenuItem<String>(value: m['name']?.toString(), child: Text((m['mode_of_payment'] ?? m['name'])?.toString() ?? ''))).toList(),
//                       onChanged: (v) => setSt(() => row['mode_of_payment'] = v),
//                       decoration: const InputDecoration(labelText: 'Mode of Payment', border: OutlineInputBorder()),
//                     ),
//                   ),
//                   const SizedBox(width: 8),
//                   Expanded(
//                     flex: 4,
//                     child: TextFormField(
//                       initialValue: (row['opening_amount'] ?? 0.0).toString(),
//                       keyboardType: const TextInputType.numberWithOptions(decimal: true),
//                       decoration: const InputDecoration(labelText: 'Opening Amount', border: OutlineInputBorder()),
//                       onChanged: (s) {
//                         final val = double.tryParse(s.replaceAll(',', '')) ?? 0.0;
//                         setSt(() => row['opening_amount'] = val);
//                       },
//                     ),
//                   ),
//                   const SizedBox(width: 8),
//                   IconButton(
//                     onPressed: () {
//                       setSt(() => rows.removeAt(index));
//                     },
//                     icon: const Icon(Icons.delete_outline),
//                   ),
//                 ],
//               ),
//             );
//           }
//
//           return AlertDialog(
//             title: const Text('Create POS Opening Entry'),
//             content: SingleChildScrollView(
//               child: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   if (_settingsLoading) const LinearProgressIndicator(),
//                   const SizedBox(height: 8),
//                   TextFormField(initialValue: AppConfig.companyName, readOnly: true, decoration: const InputDecoration(labelText: 'Company', border: OutlineInputBorder())),
//                   const SizedBox(height: 12),
//                   InputDecorator(
//                     decoration: const InputDecoration(labelText: 'POS Profile', border: OutlineInputBorder()),
//                     child: DropdownButtonHideUnderline(
//                       child: DropdownButton<String>(
//                         isExpanded: true,
//                         value: selectedPosLocal,
//                         items: posProfiles.map((m) => DropdownMenuItem<String>(value: m['name']?.toString(), child: Text(m['name']?.toString() ?? ''))).toList(),
//                         onChanged: (v) => setSt(() => selectedPosLocal = v),
//                       ),
//                     ),
//                   ),
//                   const SizedBox(height: 12),
//                   TextFormField(initialValue: loggedUser ?? '', readOnly: true, decoration: const InputDecoration(labelText: 'Cashier (logged user)', border: OutlineInputBorder())),
//                   const SizedBox(height: 12),
//                   InputDecorator(
//                     decoration: const InputDecoration(labelText: 'Period Start Date', border: OutlineInputBorder()),
//                     child: Row(
//                       children: [
//                         Expanded(child: Text('${periodStart.year.toString().padLeft(4, '0')}-${periodStart.month.toString().padLeft(2, '0')}-${periodStart.day.toString().padLeft(2, '0')}')),
//                         TextButton(onPressed: () async {
//                           final d = await showDatePicker(context: context, initialDate: periodStart, firstDate: DateTime(2000), lastDate: DateTime(2100));
//                           if (d != null) setSt(() => periodStart = d);
//                         }, child: const Text('Select')),
//                       ],
//                     ),
//                   ),
//                   const SizedBox(height: 12),
//                   const Align(alignment: Alignment.centerLeft, child: Text('Opening Balance Details', style: TextStyle(fontWeight: FontWeight.bold))),
//                   const SizedBox(height: 8),
//                   ...List.generate(rows.length, (i) => rowWidget(i)),
//                   const SizedBox(height: 6),
//                   Align(
//                     alignment: Alignment.centerLeft,
//                     child: ElevatedButton.icon(onPressed: () => setSt(() => rows.add({'mode_of_payment': null, 'opening_amount': 0.0})), icon: const Icon(Icons.add), label: const Text('Add Row')),
//                   )
//                 ],
//               ),
//             ),
//             actions: [
//               TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
//               ElevatedButton(
//                 onPressed: () async {
//                   if (selectedPosLocal == null || selectedPosLocal!.isEmpty) {
//                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select POS Profile')));
//                     return;
//                   }
//                   if (loggedUser == null || loggedUser!.isEmpty) {
//                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logged user not found.')));
//                     return;
//                   }
//                   final obRows = <Map<String, dynamic>>[];
//                   for (final r in rows) {
//                     if (r['mode_of_payment'] == null) continue;
//                     final amt = (r['opening_amount'] ?? 0.0) is double ? r['opening_amount'] : double.tryParse((r['opening_amount'] ?? '0').toString()) ?? 0.0;
//                     obRows.add({'mode_of_payment': r['mode_of_payment'], 'opening_amount': amt});
//                   }
//                   if (obRows.isEmpty) {
//                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please add at least one opening balance row')));
//                     return;
//                   }
//                   final periodStartStr = '${periodStart.year.toString().padLeft(4, '0')}-${periodStart.month.toString().padLeft(2, '0')}-${periodStart.day.toString().padLeft(2, '0')}';
//                   final payload = {
//                     'company': AppConfig.companyName,
//                     'pos_profile': selectedPosLocal,
//                     'user': loggedUser,
//                     'balance_details': obRows,
//                     'opening_balance_details': obRows,
//                     'period_start_date': periodStartStr,
//                   };
//
//                   try {
//                     final createResp = await apiProv.dio.post('/api/resource/POS Opening Entry', data: payload, options: Options(validateStatus: (_) => true));
//                     if (!(createResp.statusCode == 200 || createResp.statusCode == 201)) {
//                       final err = createResp.data ?? 'Server returned ${createResp.statusCode}';
//                       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error creating opening entry: $err')));
//                       return;
//                     }
//
//                     // extract name or doc
//                     String? createdName;
//                     Map<String, dynamic>? createdDoc;
//                     final createBody = createResp.data;
//                     if (createBody is Map && createBody['data'] is Map) {
//                       createdDoc = Map<String, dynamic>.from(createBody['data'] as Map);
//                       createdName = createdDoc['name']?.toString();
//                     } else if (createBody is Map && createBody['name'] != null) {
//                       createdName = createBody['name'].toString();
//                     }
//
//                     if (createdDoc == null && createdName == null) {
//                       // can't submit, but doc likely created in draft. mark done.
//                       final prefs = await SharedPreferences.getInstance();
//                       await prefs.setBool(_prefsPosOpeningDone, true);
//                       Navigator.of(ctx).pop();
//                       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('POS Opening Entry created (no name returned)')));
//                       return;
//                     }
//
//                     final docToSubmit = createdDoc ?? {'doctype': 'POS Opening Entry', 'name': createdName};
//                     final submitResp = await apiProv.dio.post('/api/method/frappe.client.submit', data: {'doc': docToSubmit}, options: Options(validateStatus: (_) => true));
//                     if (submitResp.statusCode == 200 || submitResp.statusCode == 201) {
//                       final prefs = await SharedPreferences.getInstance();
//                       await prefs.setBool(_prefsPosOpeningDone, true);
//                       Navigator.of(ctx).pop();
//                       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('POS Opening Entry created and submitted')));
//                     } else {
//                       final err = submitResp.data ?? 'Submit returned ${submitResp.statusCode}';
//                       // still mark prefs so user won't be prompted again
//                       final prefs = await SharedPreferences.getInstance();
//                       await prefs.setBool(_prefsPosOpeningDone, true);
//                       Navigator.of(ctx).pop();
//                       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Created but submit failed: $err')));
//                     }
//                   } catch (e) {
//                     ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
//                   }
//                 },
//                 child: const Text('Submit'),
//               )
//             ],
//           );
//         });
//       },
//     );
//   }
//
//   // ----------------- end opening entry -----------------
//
//   // Filter items per _searchQuery
//   List<Item> get _filteredItems {
//     if (_searchQuery.isEmpty) return items;
//     final q = _searchQuery.toLowerCase();
//     return items.where((it) {
//       final name = (it.itemName ?? it.name).toLowerCase();
//       final code = it.name.toLowerCase();
//       return name.contains(q) || code.contains(q);
//     }).toList();
//   }
//
//   // Reusable searchable picker used for selecting customers
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
//               height: 400,
//               child: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search...'), onChanged: doFilter),
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
//             actions: [TextButton(onPressed: () => Navigator.of(dialogCtx).pop(), child: const Text('Close'))],
//           );
//         });
//       },
//     );
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     final cart = Provider.of<CartModel>(context);
//
//     // responsive columns
//     final width = MediaQuery.of(context).size.width;
//     int columns = 3;
//     if (width < 900) {
//       columns = 2;
//     } else if (width >= 1400) {
//       columns = 4;
//     }
//
//     return BarcodeKeyboardListener(
//       onBarcode: (code) async => await _onBarcodeScanned(code),
//       child: Scaffold(
//         appBar: AppBar(
//           title: Row(children: [
//             const Text('Point of Sale'),
//             const SizedBox(width: 12),
//             if (_selectedPosProfile != null) Chip(label: Text(_selectedPosProfile!)),
//           ]),
//           actions: [
//             IconButton(icon: const Icon(Icons.refresh), onPressed: fetchItems),
//             IconButton(icon: const Icon(Icons.settings), onPressed: _openSettingsDialog),
//             Stack(
//               children: [
//                 IconButton(icon: const Icon(Icons.shopping_cart), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckoutScreen()))),
//                 if (cart.count > 0)
//                   Positioned(
//                     right: 6,
//                     top: 6,
//                     child: CircleAvatar(radius: 8, child: Text('${cart.count}', style: const TextStyle(fontSize: 10))),
//                   ),
//               ],
//             )
//           ],
//         ),
//         drawer: Drawer(
//           child: SafeArea(
//             child: Column(
//               crossAxisAlignment: CrossAxisAlignment.stretch,
//               children: [
//                 DrawerHeader(
//                   decoration: const BoxDecoration(color: Colors.blue),
//                   child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
//                     Text('ERPNext POS', style: Theme.of(context).primaryTextTheme.titleLarge?.copyWith(color: Colors.white)),
//                     const SizedBox(height: 8),
//                     Text('Company: ${AppConfig.companyName}', style: const TextStyle(color: Colors.white70)),
//                     if (_selectedPosProfile != null) Text('POS: $_selectedPosProfile', style: const TextStyle(color: Colors.white70)),
//                     if (_selectedPriceList != null) Text('Price: $_selectedPriceList', style: const TextStyle(color: Colors.white70)),
//                   ]),
//                 ),
//                 ListTile(leading: const Icon(Icons.settings), title: const Text('Settings'), onTap: () {
//                   Navigator.of(context).pop();
//                   _openSettingsDialog();
//                 }),
//                 ListTile(leading: const Icon(Icons.logout), title: const Text('Logout'), onTap: () {
//                   Navigator.of(context).pop();
//                   _logout();
//                 }),
//                 const Spacer(),
//                 Padding(padding: const EdgeInsets.all(12.0), child: Text('Base: ${Provider.of<ApiProvider>(context, listen: false).baseUrl}', style: const TextStyle(fontSize: 12, color: Colors.black54))),
//               ],
//             ),
//           ),
//         ),
//         body: loading
//             ? const Center(child: CircularProgressIndicator())
//             : error != null
//             ? Center(child: Text(error!))
//             : Padding(
//           padding: const EdgeInsets.all(12.0),
//           child: Row(
//             children: [
//               // Left: Items area (search + grid)
//               Expanded(
//                 flex: 3,
//                 child: Column(
//                   children: [
//                     Row(children: [
//                       Expanded(
//                         child: TextField(
//                           focusNode: _searchFocus,
//                           controller: _searchCtrl,
//                           decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by item code, name or barcode'),
//                           onChanged: (s) => setState(() {
//                             _searchQuery = s;
//                           }),
//                         ),
//                       ),
//                       const SizedBox(width: 8),
//                       SizedBox(
//                         width: 220,
//                         child: InputDecorator(
//                           decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
//                           child: Row(
//                             children: [
//                               Expanded(child: Text(_selectedPriceList ?? 'Select price list')),
//                               IconButton(
//                                 icon: const Icon(Icons.arrow_drop_down),
//                                 onPressed: () => _openSettingsDialog(),
//                               )
//                             ],
//                           ),
//                         ),
//                       ),
//                     ]),
//                     const SizedBox(height: 8),
//                     Expanded(
//                       child: GridView.builder(
//                         itemCount: _filteredItems.length,
//                         gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
//                           crossAxisCount: columns,
//                           childAspectRatio: 0.75,
//                           crossAxisSpacing: 12,
//                           mainAxisSpacing: 12,
//                         ),
//                         itemBuilder: (ctx, i) {
//                           final it = _filteredItems[i];
//
//                           // prefer server-returned standard_rate if available
//                           final displayRate = _sellingRateMap[it.name] ?? it.rate ?? 0.0;
//
//                           final uom = (it.uom ?? '').trim();
//                           final uomText = uom.isEmpty ? '' : uom;
//                           final priceLabel = displayRate > 0 ? '₹ ${displayRate.toStringAsFixed(0)} / ${uomText.isNotEmpty ? uomText : ''}'.trim() : '';
//
//                           return ItemCard(
//                             itemName: it.itemName ?? it.name,
//                             uom: uomText,
//                             imageUrl: imageUrlFor(it.image),
//                             priceLabel: priceLabel,
//                             // pass displayRate so add uses same price
//                             onAdd: () {
//                               Provider.of<CartModel>(context, listen: false).add(it, rate: displayRate);
//                               ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${it.itemName ?? it.name} added — ${displayRate.toStringAsFixed(2)}')));
//                             },
//                           );
//                         },
//                       ),
//                     )
//                   ],
//                 ),
//               ),
//
//               const SizedBox(width: 12),
//
//               // Right: Cart & customer panel (scrollable to avoid overflow)
//               Expanded(
//                 flex: 1,
//                 child: Column(
//                   children: [
//                     GestureDetector(
//                       onTap: () async {
//                         // open customer picker
//                         final sel = await _openSearchablePicker(ctx: context, title: 'Select Customer', items: _customers, valueKey: 'name', subLabelKey: 'customer_name');
//                         if (sel != null) setState(() => _selectedCustomer = sel);
//                       },
//                       child: Card(
//                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
//                         child: Padding(
//                           padding: const EdgeInsets.all(12.0),
//                           child: Row(
//                             children: [
//                               CircleAvatar(child: Text((_selectedCustomer != null && _selectedCustomer!.isNotEmpty) ? (_selectedCustomer![0].toUpperCase()) : 'C')),
//                               const SizedBox(width: 12),
//                               Expanded(
//                                 child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
//                                   Text(
//                                     _selectedCustomerDisplay(),
//                                     style: const TextStyle(fontWeight: FontWeight.bold),
//                                     overflow: TextOverflow.ellipsis,
//                                   ),
//                                   const SizedBox(height: 6),
//                                   Text('Tap to change customer', style: TextStyle(color: Colors.grey.shade600)),
//                                 ]),
//                               ),
//                               IconButton(onPressed: () async {
//                                 final sel = await _openSearchablePicker(ctx: context, title: 'Select Customer', items: _customers, valueKey: 'name', subLabelKey: 'customer_name');
//                                 if (sel != null) setState(() => _selectedCustomer = sel);
//                               }, icon: const Icon(Icons.edit)),
//                             ],
//                           ),
//                         ),
//                       ),
//                     ),
//                     const SizedBox(height: 12),
//                     Expanded(
//                       child: Card(
//                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
//                         child: Column(
//                           crossAxisAlignment: CrossAxisAlignment.stretch,
//                           children: [
//                             Padding(
//                               padding: const EdgeInsets.all(12.0),
//                               child: Text('Item Cart', style: Theme.of(context).textTheme.titleMedium),
//                             ),
//                             const Divider(height: 1),
//                             Expanded(
//                               child: cart.items.isEmpty
//                                   ? const Center(child: Text('Cart is empty'))
//                                   : ListView.builder(
//                                 itemCount: cart.items.length,
//                                 itemBuilder: (ctx, i) {
//                                   final it = cart.items[i];
//                                   return ListTile(
//                                     leading: SizedBox(
//                                       width: 40,
//                                       height: 40,
//                                       child: it.item.image != null && it.item.image!.isNotEmpty
//                                           ? ClipRRect(
//                                         borderRadius: BorderRadius.circular(4),
//                                         child: Image.network(imageUrlFor(it.item.image), fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: Colors.grey.shade200)),
//                                       )
//                                           : const Icon(Icons.inventory),
//                                     ),
//                                     title: Text(it.item.itemName ?? it.item.name),
//                                     subtitle: Text('${it.qty % 1 == 0 ? it.qty.toStringAsFixed(0) : it.qty.toString()} ${it.item.uom ?? ''}'),
//                                     trailing: ConstrainedBox(
//                                       constraints: const BoxConstraints(minWidth: 90, maxWidth: 140),
//                                       child: Column(
//                                         mainAxisSize: MainAxisSize.min,
//                                         crossAxisAlignment: CrossAxisAlignment.end,
//                                         children: [
//                                           Text('₹ ${(it.rate * it.qty).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
//                                           const SizedBox(height: 4),
//                                           Row(
//                                             mainAxisSize: MainAxisSize.min,
//                                             children: [
//                                               IconButton(
//                                                 padding: EdgeInsets.zero,
//                                                 constraints: const BoxConstraints(),
//                                                 icon: const Icon(Icons.remove_circle_outline),
//                                                 onPressed: () {
//                                                   final newQty = it.qty - 1.0;
//                                                   if (newQty <= 0.0) Provider.of<CartModel>(context, listen: false).remove(it.item);
//                                                   else Provider.of<CartModel>(context, listen: false).setQty(it.item, newQty);
//                                                 },
//                                               ),
//                                               Padding(
//                                                 padding: const EdgeInsets.symmetric(horizontal: 6.0),
//                                                 child: Text('${(it.qty % 1 == 0) ? it.qty.toStringAsFixed(0) : it.qty.toStringAsFixed(2)}'),
//                                               ),
//                                               IconButton(
//                                                 padding: EdgeInsets.zero,
//                                                 constraints: const BoxConstraints(),
//                                                 icon: const Icon(Icons.add_circle_outline),
//                                                 onPressed: () {
//                                                   Provider.of<CartModel>(context, listen: false).setQty(it.item, it.qty + 1.0);
//                                                 },
//                                               ),
//                                             ],
//                                           )
//                                         ],
//                                       ),
//                                     ),
//                                   );
//                                 },
//                               ),
//                             ),
//                             const Divider(height: 1),
//                             Padding(
//                               padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
//                               child: Column(
//                                 crossAxisAlignment: CrossAxisAlignment.stretch,
//                                 children: [
//                                   Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Total Quantity'), Text('${cart.items.fold<double>(0, (p, e) => p + e.qty)}')]),
//                                   const SizedBox(height: 6),
//                                   Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Net Total'), Text('₹ ${cart.total.toStringAsFixed(2)}')]),
//                                   const SizedBox(height: 10),
//                                   Row(
//                                     mainAxisAlignment: MainAxisAlignment.spaceBetween,
//                                     children: [
//                                       const Text('Grand Total', style: TextStyle(fontWeight: FontWeight.bold)),
//                                       Text('₹ ${(cart.total).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
//                                     ],
//                                   ),
//                                   const SizedBox(height: 12),
//                                   ElevatedButton(
//                                     onPressed: cart.items.isEmpty ? null : () {
//                                       Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckoutScreen()));
//                                     },
//                                     child: const Padding(
//                                       padding: EdgeInsets.symmetric(vertical: 14.0),
//                                       child: Text('Checkout'),
//                                     ),
//                                   )
//                                 ],
//                               ),
//                             )
//                           ],
//                         ),
//                       ),
//                     ),
//                   ],
//                 ),
//               )
//             ],
//           ),
//         ),
//       ),
//     );
//   }
//
//   String _selectedCustomerDisplay() {
//     if (_selectedCustomer == null) return 'Select Customer';
//     // show nicer label if we have mapping
//     final found = _customers.firstWhere((c) => c['name'] == _selectedCustomer, orElse: () => {});
//     if (found.isNotEmpty) {
//       final primary = (found['customer_name'] ?? found['name'] ?? '').toString();
//       final secondary = (found['name'] ?? '').toString();
//       return primary.isNotEmpty ? '$primary' : secondary;
//     }
//     return _selectedCustomer!;
//   }
// }
//
//
//
//
//
//
