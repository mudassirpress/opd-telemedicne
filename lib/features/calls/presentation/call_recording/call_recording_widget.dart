// call_recording_widget.dart - Create this new file

import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class CallRecordingWidget extends StatefulWidget {
  final String recordingUrl;
  final int duration;
  final bool isMe;

  const CallRecordingWidget({
    Key? key,
    required this.recordingUrl,
    required this.duration,
    required this.isMe,
  }) : super(key: key);

  @override
  State<CallRecordingWidget> createState() => _CallRecordingWidgetState();
}

class _CallRecordingWidgetState extends State<CallRecordingWidget> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      _audioPlayer.onDurationChanged.listen((duration) {
        if (mounted) {
          setState(() {
            _totalDuration = duration;
            _isLoading = false;
          });
        }
      });

      _audioPlayer.onPositionChanged.listen((position) {
        if (mounted) {
          setState(() {
            _currentPosition = position;
          });
        }
      });

      _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _currentPosition = Duration.zero;
          });
        }
      });

      await _audioPlayer.setSourceUrl(widget.recordingUrl);

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load recording';
          _isLoading = false;
        });
      }
      debugPrint('Error loading audio: $e');
    }
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    } else {
      await _audioPlayer.resume();
      if (mounted) {
        setState(() {
          _isPlaying = true;
        });
      }
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxBubbleWidth = math.min(260.0, context.sw - 80);
    if (_isLoading) {
      return Container(
        width: math.min(200.0, maxBubbleWidth),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: widget.isMe
              ? const Color.fromARGB(225, 139, 0, 0).withOpacity(0.2)
              : Colors.grey[200],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Loading recording...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: context.fs(12)),
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Container(
        width: math.min(200.0, maxBubbleWidth),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
          ],
        ),
      );
    }

    final displayDuration = _totalDuration.inSeconds > 0
        ? _totalDuration
        : Duration(seconds: widget.duration);

    return Container(
      width: maxBubbleWidth,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: widget.isMe
            ? const Color.fromARGB(225, 139, 0, 0).withOpacity(0.15)
            : Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: widget.isMe
              ? const Color.fromARGB(225, 139, 0, 0).withOpacity(0.3)
              : Colors.grey[300]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _togglePlayback,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: widget.isMe
                        ? const Color.fromARGB(225, 139, 0, 0)
                        : Colors.grey[700],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.call, size: 14, color: Colors.grey),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Call Recording',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(12),
                              fontWeight: FontWeight.w600,
                              color: widget.isMe
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          _isPlaying
                              ? _formatDuration(_currentPosition)
                              : _formatDuration(displayDuration),
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.isMe
                                ? Colors.white70
                                : Colors.grey[600],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: _totalDuration.inSeconds > 0
                                  ? _currentPosition.inSeconds /
                                        _totalDuration.inSeconds
                                  : 0,
                              backgroundColor: widget.isMe
                                  ? Colors.white.withOpacity(0.2)
                                  : Colors.grey[300],
                              color: widget.isMe
                                  ? Colors.white
                                  : const Color.fromARGB(225, 139, 0, 0),
                              minHeight: 3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
