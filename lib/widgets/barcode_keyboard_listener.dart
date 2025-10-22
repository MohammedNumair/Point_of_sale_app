import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef BarcodeCallback = Future<void> Function(String barcode);

class BarcodeKeyboardListener extends StatefulWidget {
  final Widget child;
  final BarcodeCallback onBarcode;
  final Duration interKeyTimeout; // resets buffer after this much idle time
  final LogicalKeyboardKey submitKey; // default Enter
  final String? prefix; // optional: scanner may send prefix bytes

  const BarcodeKeyboardListener({
    Key? key,
    required this.child,
    required this.onBarcode,
    this.interKeyTimeout = const Duration(milliseconds: 300),
    this.submitKey = LogicalKeyboardKey.enter,
    this.prefix,
  }) : super(key: key);

  @override
  _BarcodeKeyboardListenerState createState() => _BarcodeKeyboardListenerState();
}

class _BarcodeKeyboardListenerState extends State<BarcodeKeyboardListener> {
  String _buffer = '';
  Timer? _timer;
  final FocusNode _focusNode = FocusNode();

  void _resetBuffer() {
    _buffer = '';
    _timer?.cancel();
    _timer = null;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.interKeyTimeout, () {
      if (_buffer.isNotEmpty) {
        _fireBarcode(_buffer);
      }
      _resetBuffer();
    });
  }

  Future<void> _fireBarcode(String raw) async {
    String barcode = raw;
    if (widget.prefix != null && barcode.startsWith(widget.prefix!)) {
      barcode = barcode.substring(widget.prefix!.length);
    }
    try {
      await widget.onBarcode(barcode);
    } catch (e, st) {
      debugPrint('Error in onBarcode: $e\n$st');
    }
  }

  KeyEventResult _onKey(RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      final key = event.logicalKey;

      // If Enter/Submit
      if (key == widget.submitKey) {
        if (_buffer.isNotEmpty) {
          final captured = _buffer;
          _resetBuffer();
          _fireBarcode(captured);
        }
        return KeyEventResult.handled;
      }

      // Try to get character from the event
      String? char = event.character;
      if ((char == null || char.isEmpty) && key.keyLabel.isNotEmpty) {
        char = key.keyLabel;
      }

      if (char != null && char.isNotEmpty) {
        _buffer += char;
        _startTimer();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _onKey,
      autofocus: true,
      child: widget.child,
    );
  }
}
