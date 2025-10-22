import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../providers/cart_model.dart';

class InvoiceResultScreen extends StatefulWidget {
  final String invoiceName;
  final List<CartItem> cartSnapshot;
  final String? customerName;
  final String? customerContact;

  const InvoiceResultScreen({
    super.key,
    required this.invoiceName,
    required this.cartSnapshot,
    this.customerName,
    this.customerContact,
  });

  @override
  State<InvoiceResultScreen> createState() => _InvoiceResultScreenState();
}

class _InvoiceResultScreenState extends State<InvoiceResultScreen> {
  bool _printing = false;

  String get _customerLabel {
    if (widget.customerName != null && widget.customerName!.trim().isNotEmpty) {
      return widget.customerName!;
    }
    return 'Customer';
  }


  String get _initials {
    final name = widget.customerName ?? '';
    if (name.trim().isEmpty) return 'C';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    final a = parts.first.substring(0, 1);
    final b = parts.last.substring(0, 1);
    return (a + b).toUpperCase();
  }

  /// Build a small receipt-like pdf using the cart snapshot
  Future<Uint8List> _buildPdfBytes() async {
    final pdf = pw.Document();
    double netTotal = 0.0;
    for (final c in widget.cartSnapshot) netTotal += c.rate * c.qty;
    final grand = netTotal;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80, // thermal-like size; adjust as needed
        margin: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        build: (pw.Context ctx) {
          String itemLine(String name, double qty, double amount) {
            final nm = name.length > 20 ? '${name.substring(0, 20)}…' : name;
            final q = (qty % 1 == 0) ? qty.toStringAsFixed(0) : qty.toStringAsFixed(2);
            final amt = amount.toStringAsFixed(2);
            final left = '$nm x$q';
            // ensure right alignment for amount
            final fill = 40 - left.length;
            return left + ' ' * (fill > 0 ? fill : 2) + amt;
          }

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(child: pw.Text('POS Invoice', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
              pw.SizedBox(height: 6),
              pw.Text('Invoice: ${widget.invoiceName}'),
              pw.Text('Customer: ${widget.customerName ?? '-'}'),
              pw.SizedBox(height: 6),
              pw.Divider(),
              ...widget.cartSnapshot.map((c) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Text(itemLine(c.item.itemName ?? c.item.name, c.qty, c.rate * c.qty), style: const pw.TextStyle(fontSize: 9)),
              )),
              pw.Divider(),
              pw.SizedBox(height: 4),
              pw.Text('Net Total: ${netTotal.toStringAsFixed(2)}'),
              pw.Text('Grand Total: ${grand.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Center(child: pw.Text('Thank you!', style: const pw.TextStyle(fontSize: 9))),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  Future<void> _handlePrint() async {
    setState(() => _printing = true);
    try {
      final bytes = await _buildPdfBytes();
      // Use Printing.layoutPdf directly (doesn't require the CheckoutScreen context)
      await Printing.layoutPdf(onLayout: (format) async => bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Print job requested')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print error: $e')));
    } finally {
      if (!mounted) return;
      setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    double netTotal = 0.0;
    for (final c in widget.cartSnapshot) {
      netTotal += c.rate * c.qty;
    }
    final grandTotal = netTotal;

    return Scaffold(
      appBar: AppBar(title: const Text('Invoice')),
      body: Center(
        child: SizedBox(
          width: 520,
          child: Card(
            margin: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      CircleAvatar(child: Text(_initials)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_customerLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                        ]),
                      ),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('₹ ${grandTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Text(widget.invoiceName, style: const TextStyle(color: Colors.grey)),
                        const SizedBox(height: 6),
                        Chip(label: Row(children: const [Icon(Icons.circle, size: 8, color: Colors.green), SizedBox(width: 6), Text('Paid')])),
                      ])
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text('Items', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.cartSnapshot.length,
                      itemBuilder: (ctx, i) {
                        final c = widget.cartSnapshot[i];
                        return ListTile(
                          dense: true,
                          leading: const SizedBox(width: 40, child: Icon(Icons.receipt)),
                          title: Text(c.item.itemName ?? c.item.name),
                          subtitle: Text('${c.qty.toStringAsFixed(c.qty % 1 == 0 ? 0 : 2)} ${c.item.uom ?? ''}'),
                          trailing: Text('₹ ${(c.rate * c.qty).toStringAsFixed(2)}'),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text('Totals', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Net Total:'), Text('₹ ${netTotal.toStringAsFixed(2)}')]),
                        const SizedBox(height: 8),
                        const Divider(),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: const [Text('Grand Total', style: TextStyle(fontWeight: FontWeight.bold))]),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const SizedBox(), Text('₹ ${ (netTotal).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold))]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('Payments', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('Cash'),
                      Text('₹ ${grandTotal.toStringAsFixed(2)}'),
                    ]),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: _printing ? null : _handlePrint,
                        child: _printing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Print Receipt'),
                      ),
                      const SizedBox(width: 8),
                      // OutlinedButton(
                      //     onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email not implemented'))),
                      //     child: const Text('Email Receipt')),
                      // const Spacer(),
                      ElevatedButton(
                        onPressed: () {
                          Provider.of<CartModel>(context, listen: false).clear();
                          // back to items and clear stack
                          Navigator.of(context).pushNamedAndRemoveUntil('/items', (route) => false);
                        },
                        child: const Text('New Order'),
                      )
                    ],
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
