import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:telemedicine/home_widget/reports/report_controller/report_controller.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class UploadReportScreen extends ConsumerStatefulWidget {
  const UploadReportScreen({super.key});

  @override
  ConsumerState<UploadReportScreen> createState() =>
      _UploadReportScreenState();
}

class _UploadReportScreenState extends ConsumerState<UploadReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();

  String? _selectedReportType;
  DateTime? _reportDate;
  File? _selectedFile;
  bool _isUploading = false;
  String? _fileName;
  String? _fileType;

  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _reportDate = DateTime.now();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickImageFromCamera() async {
    final XFile? photo = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );
    if (photo != null) {
      setState(() {
        _selectedFile = File(photo.path);
        _fileName = photo.name;
        _fileType = 'image';
      });
    }
  }

  Future<void> _pickImageFromGallery() async {
    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (image != null) {
      setState(() {
        _selectedFile = File(image.path);
        _fileName = image.name;
        _fileType = 'image';
      });
    }
  }

  Future<void> _pickPDF() async {
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result != null) {
      setState(() {
        _selectedFile = File(result.files.single.path!);
        _fileName = result.files.single.name;
        _fileType = 'pdf';
      });
    }
  }

  void _showFilePickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E4F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF2F8),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      color: Color(0xFF062B72),
                    ),
                  ),
                  title: Text(
                    'Take Photo',
                    style: TextStyle(
                      color: const Color(0xFF1F2F44),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImageFromCamera();
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF2F8),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.photo_library,
                      color: Color(0xFF062B72),
                    ),
                  ),
                  title: Text(
                    'Choose from Gallery',
                    style: TextStyle(
                      color: const Color(0xFF1F2F44),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImageFromGallery();
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF2F8),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.picture_as_pdf,
                      color: Color(0xFF062B72),
                    ),
                  ),
                  title: Text(
                    'Choose PDF',
                    style: TextStyle(
                      color: const Color(0xFF1F2F44),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickPDF();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _reportDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF062B72),
              onPrimary: Colors.white,
              onSurface: Color(0xFF1F2F44),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _reportDate) {
      setState(() {
        _reportDate = picked;
      });
    }
  }

  Future<void> _uploadReport() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedFile == null) {
      ToastService.instance.showError('Please select a file to upload');
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      final reportController = ref.read(reportControllerProvider);

      final uploadedReport = await reportController.uploadReport(
        file: _selectedFile!,
        reportType: _selectedReportType!,
        description: _descriptionController.text.trim(),
        reportDate: _reportDate!,
      );

      if (uploadedReport != null && mounted) {
        _formKey.currentState!.reset();
        setState(() {
          _selectedFile = null;
          _fileName = null;
          _fileType = null;
          _selectedReportType = null;
          _descriptionController.clear();
          _reportDate = DateTime.now();
        });

        ToastService.instance.showSuccess('Report uploaded successfully!');

        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            Navigator.pop(context, true);
          }
        });
      }
    } catch (e) {
      ToastService.instance.showError('Upload failed: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // ECG Watermark - Top Right (matching Sign In)
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),

          // Main Content
          SafeArea(
            child: Column(
              children: [
                // Top Bar with Back Button
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(20),
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const CircularBackButton(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Upload Report',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Scrollable Content
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.symmetric(
                      horizontal: context.rsp(20),
                      vertical: 8,
                    ),
                    child: CenteredContent(
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Title
                            Text(
                              'Medical Report',
                              style: TextStyle(
                                fontSize: context.fs(20),
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF1F2F44),
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Upload your medical report by selecting the report type, date, and file.',
                              style: TextStyle(
                                fontSize: context.fs(13),
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF657991),
                                height: 1.4,
                              ),
                            ),
                            SizedBox(height: context.rsp(20)),

                            // Report Type Dropdown (Metallic styled)
                            _buildMetallicDropdown(
                              value: _selectedReportType,
                              hintText: 'Select Report Type',
                              icon: Icons.medical_information_rounded,
                              items: ReportType.allDisplayNames,
                              onChanged: (value) {
                                setState(() {
                                  _selectedReportType = value;
                                });
                              },
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Please select report type';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),

                            // Report Date (Metallic styled)
                            _buildMetallicDatePicker(),
                            const SizedBox(height: 16),

                            // Description
                            MetallicInput(
                              hintText: 'Description (optional)',
                              icon: Icons.description_rounded,
                              controller: _descriptionController,
                              validator: null,
                            ),
                            SizedBox(height: context.rsp(16)),

                            // File Upload Area (Metallic styled)
                            _buildMetallicFileUpload(),
                            SizedBox(height: context.rsp(16)),

                            // Upload Button
                            GradientButton(
                              text: 'Upload Report',
                              icon: Icons.arrow_forward_rounded,
                              isLoading: _isUploading,
                              onPressed: _uploadReport,
                            ),
                            SizedBox(height: context.rsp(16)),

                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetallicDropdown({
    required String? value,
    required String hintText,
    required IconData icon,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFFE3EAF2),
                Color(0xFFF5F8FC),
                Color(0xFFE2E9F2),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F233C).withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFF3F7FB),
                  Colors.white,
                  Color(0xFFF0F4F9),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(27),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                icon: const Icon(
                  Icons.arrow_drop_down,
                  color: Color(0xFF7E90A6),
                ),
                dropdownColor: Colors.white,
                style: TextStyle(
                  fontSize: context.fs(14),
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF1E2F44),
                ),
                hint: Row(
                  children: [
                    Icon(icon, color: const Color(0xFF0E274D), size: 18),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        hintText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFF7E90A6),
                          fontSize: context.fs(13),
                        ),
                      ),
                    ),
                  ],
                ),
                items: items.map((String item) {
                  return DropdownMenuItem<String>(
                    value: item,
                    child: Row(
                      children: [
                        Icon(
                          ReportType.fromString(item).icon,
                          size: 18,
                          color: const Color(0xFF0E274D),
                        ),
                        const SizedBox(width: 12),
                        Text(item),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        if (value == null && validator != null)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 6),
            child: Text(
              validator(value) ?? '',
              style: TextStyle(
                color: Colors.red,
                fontSize: context.fs(12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMetallicDatePicker() {
    final hasValue = _reportDate != null;
    final displayText = hasValue
        ? '${_reportDate!.day}/${_reportDate!.month}/${_reportDate!.year}'
        : 'Select Report Date';

    return GestureDetector(
      onTap: _selectDate,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFFE3EAF2),
              Color(0xFFF5F8FC),
              Color(0xFFE2E9F2),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F233C).withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFFF3F7FB),
                Colors.white,
                Color(0xFFF0F4F9),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(27),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.calendar_today_rounded,
                color: Color(0xFF0E274D),
                size: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w500,
                    color: hasValue
                        ? const Color(0xFF1E2F44)
                        : const Color(0xFF7E90A6),
                  ),
                ),
              ),
              const Icon(
                Icons.arrow_drop_down,
                color: Color(0xFF7E90A6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetallicFileUpload() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Report File',
            style: TextStyle(
              fontSize: context.fs(13),
              fontWeight: FontWeight.w600,
              color: const Color(0xFF1F2F44),
            ),
          ),
        ),
        GestureDetector(
          onTap: _showFilePickerOptions,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFE3EAF2),
                  Color(0xFFF5F8FC),
                  Color(0xFFE2E9F2),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F233C).withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Container(
              constraints: const BoxConstraints(minHeight: 120),
              width: double.infinity,
              padding: EdgeInsets.all(context.rsp(16)),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFFF3F7FB),
                    Colors.white,
                    Color(0xFFF0F4F9),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: _selectedFile != null
                  ? Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _fileType == 'pdf'
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.picture_as_pdf_rounded,
                                        size: 50,
                                        color: Color(0xFF062B72),
                                      ),
                                      const SizedBox(height: 8),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        child: Text(
                                          _fileName!,
                                          style: TextStyle(
                                            fontSize: context.fs(13),
                                            color: const Color(0xFF1E2F44),
                                          ),
                                          textAlign: TextAlign.center,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : Image.file(
                                  _selectedFile!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0F233C)
                                      .withValues(alpha: 0.1),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: Color(0xFF0E274D),
                              ),
                              onPressed: () {
                                setState(() {
                                  _selectedFile = null;
                                  _fileName = null;
                                  _fileType = null;
                                });
                              },
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.cloud_upload_rounded,
                          size: 48,
                          color: const Color(0xFF062B72).withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tap to upload file',
                          style: TextStyle(
                            fontSize: context.fs(13),
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF6B7B8D),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'JPG, PNG, PDF supported (Max 10MB)',
                          style: TextStyle(
                            fontSize: context.fs(11.5),
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF8FA4BD),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
