import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class PDFViewerScreen extends StatefulWidget {
  final String pdfUrl;
  final String fileName;

  const PDFViewerScreen({
    Key? key,
    required this.pdfUrl,
    required this.fileName,
  }) : super(key: key);

  @override
  State<PDFViewerScreen> createState() => _PDFViewerScreenState();
}

class _PDFViewerScreenState extends State<PDFViewerScreen> {
  bool _isLoading = true;
  int? _totalPages;
  int _currentPage = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: context.fs(15)),
        ),
        backgroundColor: AppColors.primaryRed,
        actions: [
          if (_totalPages != null)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rsp(16),
                vertical: 12,
              ),
              child: Text(
                'Page $_currentPage of $_totalPages',
                maxLines: 1,
                style: TextStyle(fontSize: context.fs(13)),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          PDFView(
            filePath: widget.pdfUrl,
            enableSwipe: true,
            swipeHorizontal: true,
            autoSpacing: false,
            pageFling: true,
            onRender: (pages) {
              setState(() {
                _totalPages = pages;
                _isLoading = false;
              });
            },
            onError: (error) {
              setState(() => _isLoading = false);
            },
            onPageChanged: (page, total) {
              setState(() {
                _currentPage = page!;
                _totalPages = total;
              });
            },
          ),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
