// lib/widgets/item_card.dart
import 'package:flutter/material.dart';

class ItemCard extends StatelessWidget {
  final String itemName;
  final String uom;
  final String imageUrl;
  final String priceLabel;

  const ItemCard({
    super.key,
    required this.itemName,
    required this.uom,
    required this.imageUrl,
    required this.priceLabel,
  });

  @override
  Widget build(BuildContext context) {
    // Compact sizing so cards fit well in a 5-column grid.
    const double imageHeight = 240;
    const double cardHeight = 150;

    final Widget imageWidget = (imageUrl.isNotEmpty)
        ? ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        imageUrl,
        width: double.infinity,
        height: imageHeight,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: double.infinity,
          height: imageHeight,
          color: Colors.grey.shade200,
          child: const Icon(Icons.image, size: 28, color: Colors.grey),
        ),
      ),
    )
        : Container(
      width: double.infinity,
      height: imageHeight,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.inventory, size: 28, color: Colors.grey),
    );

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 0.6,
      child: SizedBox(
        height: cardHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // image
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: imageWidget,
            ),

            // name + uom
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4),
              child: Text(
                itemName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                uom,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
              ),
            ),

            const Spacer(),

            // price (no Add button)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                priceLabel,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}












// // lib/widgets/item_card.dart
// import 'package:flutter/material.dart';
//
// class ItemCard extends StatelessWidget {
//   final String itemName;
//   final String uom;
//   final String imageUrl;
//   final VoidCallback onAdd;
//
//   const ItemCard({super.key, required this.itemName, required this.uom, required this.imageUrl, required this.onAdd});
//
//   @override
//   Widget build(BuildContext context) {
//     final lead = (imageUrl.isNotEmpty)
//         ? Image.network(imageUrl, width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_,__,___) => const Icon(Icons.image))
//         : const Icon(Icons.inventory, size: 48);
//
//     return Card(
//       child: ListTile(
//         leading: lead,
//         title: Text(itemName),
//         subtitle: Text(uom),
//         trailing: ElevatedButton(onPressed: onAdd, child: const Text('Add')),
//       ),
//     );
//   }
// }
