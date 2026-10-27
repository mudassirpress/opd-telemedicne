// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'offline_call_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class OfflineCallRecordAdapter extends TypeAdapter<OfflineCallRecord> {
  @override
  final int typeId = 2;

  @override
  OfflineCallRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return OfflineCallRecord(
      callId: fields[0] as String,
      callerId: fields[1] as String,
      receiverId: fields[2] as String,
      callType: fields[3] as String,
      startTime: fields[4] as DateTime,
      endTime: fields[5] as DateTime?,
      duration: fields[6] as int?,
      callStatus: fields[7] as String,
      callerName: fields[8] as String?,
      receiverName: fields[9] as String?,
      callerImage: fields[10] as String?,
      receiverImage: fields[11] as String?,
      channelId: fields[12] as String,
      synced: fields[13] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, OfflineCallRecord obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.callId)
      ..writeByte(1)
      ..write(obj.callerId)
      ..writeByte(2)
      ..write(obj.receiverId)
      ..writeByte(3)
      ..write(obj.callType)
      ..writeByte(4)
      ..write(obj.startTime)
      ..writeByte(5)
      ..write(obj.endTime)
      ..writeByte(6)
      ..write(obj.duration)
      ..writeByte(7)
      ..write(obj.callStatus)
      ..writeByte(8)
      ..write(obj.callerName)
      ..writeByte(9)
      ..write(obj.receiverName)
      ..writeByte(10)
      ..write(obj.callerImage)
      ..writeByte(11)
      ..write(obj.receiverImage)
      ..writeByte(12)
      ..write(obj.channelId)
      ..writeByte(13)
      ..write(obj.synced);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflineCallRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
