// message_action_widget.dart - Create new file

import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class MessageActionWidget extends StatelessWidget {
  final bool isMe;
  final bool isDeleted;
  final VoidCallback onReply;
  final VoidCallback onEdit;
  final VoidCallback onDeleteForMe;
  final VoidCallback onDeleteForEveryone;
  final VoidCallback onCopy;
  final VoidCallback onForward;

  const MessageActionWidget({
    Key? key,
    required this.isMe,
    required this.isDeleted,
    required this.onReply,
    required this.onEdit,
    required this.onDeleteForMe,
    required this.onDeleteForEveryone,
    required this.onCopy,
    required this.onForward,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildActionItem(
            context: context,
            icon: Icons.reply,
            label: 'Reply',
            onTap: onReply,
          ),
          if (!isDeleted) ...[
            _buildDivider(),
            _buildActionItem(
              context: context,
              icon: Icons.copy,
              label: 'Copy',
              onTap: onCopy,
            ),
          ],
          if (isMe && !isDeleted) ...[
            _buildDivider(),
            _buildActionItem(
              context: context,
              icon: Icons.edit,
              label: 'Edit',
              onTap: onEdit,
            ),
          ],
          if (isMe && !isDeleted) ...[
            _buildDivider(),
            _buildActionItem(
              context: context,
              icon: Icons.delete_outline,
              label: 'Delete for me',
              onTap: onDeleteForMe,
              iconColor: Colors.orange,
            ),
          ],
          if (isMe && !isDeleted) ...[
            _buildDivider(),
            _buildActionItem(
              context: context,
              icon: Icons.delete_forever,
              label: 'Delete for everyone',
              onTap: onDeleteForEveryone,
              iconColor: Colors.red,
            ),
          ],
          if (!isMe && !isDeleted) ...[
            _buildDivider(),
            _buildActionItem(
              context: context,
              icon: Icons.forward,
              label: 'Forward',
              onTap: onForward,
              iconColor: Colors.blue,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rsp(16),
          vertical: 12,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor ?? Colors.grey[700]),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(14),
                  color: iconColor ?? Colors.grey[800],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(height: 1, thickness: 0.5, color: Colors.grey[200]);
  }
}
