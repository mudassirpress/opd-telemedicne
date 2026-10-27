import 'package:flutter/material.dart';
import 'package:telemedicine/data/models/chat_model.dart';

/// The WhatsApp-style receipt shown next to a message the current user sent.
///
/// ```
/// pending   -> clock          (queued locally, not uploaded)
/// sent      -> one tick       (uploaded, receiver has not acknowledged)
/// delivered -> two grey ticks (receiver's device acknowledged it)
/// read      -> two blue ticks (receiver has seen it)
/// ```
///
/// Reads [ChatMessageModel.deliveryStatus] rather than inferring from the
/// `isDelivered` / `isRead` booleans. That distinction matters for `pending`:
/// a message that is queued and a message that was uploaded while the receiver
/// was offline are both `isDelivered == false`, but they need a clock and a
/// single tick respectively — which is exactly the case the old inline
/// `isRead ? blue : isDelivered ? grey-double : grey-single` chain could not
/// express.
///
/// Renders nothing for an incoming message; the caller decides that by passing
/// `show: false`, or by only calling this from the outgoing branch.
class MessageStatusIndicator extends StatelessWidget {
  final MessageDeliveryState state;
  final double size;

  /// Colour used on the sender's bubble. Pass a light colour (the bubbles are
  /// dark-filled) or a dark one for a light background.
  final Color color;

  /// Colour for the "read" state. Defaults to WhatsApp's light blue, which only
  /// reads correctly on the dark sender bubble.
  final Color? readColor;

  const MessageStatusIndicator({
    super.key,
    required this.state,
    required this.color,
    this.size = 14,
    this.readColor,
  });

  /// Convenience factory for the outgoing-message case.
  factory MessageStatusIndicator.forOutgoing(
    ChatMessageModel message, {
    required Color color,
    double size = 14,
    Color? readColor,
  }) {
    return MessageStatusIndicator(
      state: message.deliveryStatus,
      color: color,
      size: size,
      readColor: readColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (state) {
      // Clock: queued on this device, nothing has been uploaded.
      case MessageDeliveryState.pending:
        return Icon(Icons.schedule_rounded, size: size, color: color);

      // One tick: on the server, not yet acknowledged.
      case MessageDeliveryState.sent:
        return Icon(Icons.done, size: size, color: color);

      // Two grey ticks: the receiver's device has it.
      case MessageDeliveryState.delivered:
        return Icon(Icons.done_all, size: size, color: color);

      // Two blue ticks: seen.
      case MessageDeliveryState.read:
        return Icon(
          Icons.done_all,
          size: size,
          color: readColor ?? const Color(0xFF53BDEB),
        );
    }
  }
}
