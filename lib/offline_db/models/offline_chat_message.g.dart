// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'offline_chat_message.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class OfflineChatMessageAdapter extends TypeAdapter<OfflineChatMessage> {
  @override
  final int typeId = 1;

  @override
  OfflineChatMessage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return OfflineChatMessage(
      messageId: fields[0] as String,
      senderId: fields[1] as String,
      receiverId: fields[2] as String,
      message: fields[3] as String,
      timestamp: fields[4] as DateTime,
      messageType: fields[5] as String,
      deliveryStatus: fields[6] as String,
      readStatus: fields[7] as String,
      mediaUrl: fields[8] as String?,
      duration: fields[9] as int?,
      callData: (fields[10] as Map?)?.cast<String, dynamic>(),
      isDeleted: fields[11] as bool,
      isEdited: fields[12] as bool,
      editedAt: fields[13] as DateTime?,
      deletedBy: fields[14] as String?,
      fileName: fields[15] as String?,
      isAdminMessage: fields[16] as bool,
      adminName: fields[17] as String?,
      adminId: fields[18] as String?,
      originalSenderId: fields[19] as String?,
      replyTo: fields[20] as String?,
      chatId: fields[21] as String,
      prescriptionId: fields[22] as String?,
      prescriptionNotePreview: fields[23] as String?,
      // Tolerant: rows written before these fields existed carry no entry, so
      // a strict `as bool` cast would throw on the first older row read back.
      isForwarded: fields[24] as bool? ?? false,
      deletedAt: fields[25] as DateTime?,
      isListened: fields[26] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, OfflineChatMessage obj) {
    writer
      ..writeByte(27)
      ..writeByte(0)
      ..write(obj.messageId)
      ..writeByte(1)
      ..write(obj.senderId)
      ..writeByte(2)
      ..write(obj.receiverId)
      ..writeByte(3)
      ..write(obj.message)
      ..writeByte(4)
      ..write(obj.timestamp)
      ..writeByte(5)
      ..write(obj.messageType)
      ..writeByte(6)
      ..write(obj.deliveryStatus)
      ..writeByte(7)
      ..write(obj.readStatus)
      ..writeByte(8)
      ..write(obj.mediaUrl)
      ..writeByte(9)
      ..write(obj.duration)
      ..writeByte(10)
      ..write(obj.callData)
      ..writeByte(11)
      ..write(obj.isDeleted)
      ..writeByte(12)
      ..write(obj.isEdited)
      ..writeByte(13)
      ..write(obj.editedAt)
      ..writeByte(14)
      ..write(obj.deletedBy)
      ..writeByte(15)
      ..write(obj.fileName)
      ..writeByte(16)
      ..write(obj.isAdminMessage)
      ..writeByte(17)
      ..write(obj.adminName)
      ..writeByte(18)
      ..write(obj.adminId)
      ..writeByte(19)
      ..write(obj.originalSenderId)
      ..writeByte(20)
      ..write(obj.replyTo)
      ..writeByte(21)
      ..write(obj.chatId)
      ..writeByte(22)
      ..write(obj.prescriptionId)
      ..writeByte(23)
      ..write(obj.prescriptionNotePreview)
      ..writeByte(24)
      ..write(obj.isForwarded)
      ..writeByte(25)
      ..write(obj.deletedAt)
      ..writeByte(26)
      ..write(obj.isListened);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflineChatMessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
