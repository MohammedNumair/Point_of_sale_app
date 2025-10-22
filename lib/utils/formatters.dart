// lib/utils/formatters.dart
import 'package:intl/intl.dart';

class Formatters {
  static final NumberFormat currency = NumberFormat.currency(symbol: '', decimalDigits: 2);

  static String money(double amount) {
    return currency.format(amount);
  }
}
