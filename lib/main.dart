import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhotoNukeApp());
}

class PhotoNukeApp extends StatelessWidget {
  const PhotoNukeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhotoNuke',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0E15),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF2E63),
          secondary: Color(0xFF08D9D6),
          surface: Color(0xFF1A1C28),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121420),
          elevation: 0,
        ),
      ),
      home: const GalleryNukeScreen(),
    );
  }
}

class GalleryNukeScreen extends StatefulWidget {
  const GalleryNukeScreen({super.key});

  @override
  State<GalleryNukeScreen> createState() => _GalleryNukeScreenState();
}

class _GalleryNukeScreenState extends State<GalleryNukeScreen> {
  PermissionState _permissionState = PermissionState.notDetermined;
  bool _isLoading = true;
  List<AssetEntity> _assets = [];
  final Set<String> _nukingIds = {};
  int _nukedCount = 0;
  int _currentPage = 0;
  bool _hasMore = true;
  bool _isLoadingMore = false;
  AssetPathEntity? _currentPath;
  bool _canManageMedia = true;

  @override
  void initState() {
    super.initState();
    _requestPermissionAndLoad();
  }

  Future<void> _checkMediaManagement() async {
    try {
      final canManage = await PhotoManager.canManageMedia();
      if (mounted) {
        setState(() => _canManageMedia = canManage);
      }
    } catch (_) {
      // Non-Android platforms or errors fall back safely
    }
  }

  Future<void> _requestManageMedia() async {
    try {
      await PhotoManager.requestManageMedia();
      await _checkMediaManagement();
    } catch (_) {}
  }

  Future<void> _requestPermissionAndLoad() async {
    setState(() => _isLoading = true);

    try {
      final state = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;

      setState(() => _permissionState = state);

      if (state.isAuth || state.hasAccess) {
        await _checkMediaManagement();
        await _loadInitialAssets();
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error requesting permission: $e');
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadInitialAssets() async {
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(
              type: OrderOptionType.createDate,
              asc: false,
            ),
          ],
        ),
      );

      if (paths.isEmpty) {
        if (mounted) {
          setState(() {
            _assets = [];
            _isLoading = false;
          });
        }
        return;
      }

      _currentPath = paths.first;
      _currentPage = 0;
      final assets = await _currentPath!.getAssetListPaged(
        page: _currentPage,
        size: 80,
      );

      if (mounted) {
        setState(() {
          _assets = assets;
          _hasMore = assets.length >= 80;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading assets: $e');
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadMoreAssets() async {
    if (_isLoadingMore || !_hasMore || _currentPath == null) return;
    _isLoadingMore = true;

    try {
      final nextPage = _currentPage + 1;
      final newAssets = await _currentPath!.getAssetListPaged(
        page: nextPage,
        size: 80,
      );

      if (mounted) {
        setState(() {
          _currentPage = nextPage;
          _assets.addAll(newAssets);
          _hasMore = newAssets.length >= 80;
        });
      }
    } finally {
      _isLoadingMore = false;
    }
  }

  Future<void> _nukeAsset(AssetEntity asset) async {
    if (_nukingIds.contains(asset.id)) return;

    // Trigger instant haptic burst
    HapticFeedback.heavyImpact();

    setState(() {
      _nukingIds.add(asset.id);
    });

    try {
      // Delete/Trash the asset from the gallery
      final List<String> result = await PhotoManager.editor.deleteWithIds([asset.id]);

      // If deletion completed (or on platforms where dialog resolves), remove from UI
      if (result.contains(asset.id) || result.isNotEmpty) {
        if (mounted) {
          setState(() {
            _assets.removeWhere((a) => a.id == asset.id);
            _nukedCount++;
          });
        }
      } else {
        // User cancelled deletion or platform didn't return id
        if (mounted) {
          setState(() {
            _nukingIds.remove(asset.id);
          });
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error nuking asset: $e');
      }
      if (mounted) {
        setState(() {
          _nukingIds.remove(asset.id);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text(
              'PHOTONUKE',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 2.0,
                color: Color(0xFFFF2E63),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFF2E63).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF2E63), width: 1),
              ),
              child: const Text(
                'TAP TO NUKE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: Color(0xFFFF2E63),
                ),
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2132),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF08D9D6), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_fire_department, color: Color(0xFF08D9D6), size: 18),
                const SizedBox(width: 4),
                Text(
                  '$_nukedCount NUKED',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: Color(0xFF08D9D6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFF2E63),
        ),
      );
    }

    if (!_permissionState.isAuth && !_permissionState.hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                size: 72,
                color: Color(0xFFFF2E63),
              ),
              const SizedBox(height: 16),
              const Text(
                'GALLERY ACCESS REQUIRED',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'PhotoNuke needs permission to display your photos and purge targets on tap.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2E63),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed: () async {
                  await PhotoManager.openSetting();
                },
                icon: const Icon(Icons.settings),
                label: const Text('OPEN SETTINGS'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _requestPermissionAndLoad,
                child: const Text('RETRY PERMISSION CHECK'),
              ),
            ],
          ),
        ),
      );
    }

    if (_assets.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: Color(0xFF08D9D6)),
            SizedBox(height: 16),
            Text(
              'ALL TARGETS NEUTRALIZED',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'No photos found in gallery. Your device is clean!',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (!_canManageMedia)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF2E63).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF2E63), width: 1),
            ),
            child: Row(
              children: [
                const Icon(Icons.flash_on, color: Color(0xFFFF2E63), size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Instant delete requires Media Management access to bypass confirmation dialogs.',
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFFFF2E63),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _requestManageMedia,
                  child: const Text(
                    'ENABLE',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (scrollInfo) {
              if (scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) {
                _loadMoreAssets();
              }
              return false;
            },
            child: GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: _assets.length,
              itemBuilder: (context, index) {
                final asset = _assets[index];
                final isNuking = _nukingIds.contains(asset.id);
                return PhotoThumbnailTile(
                  key: ValueKey(asset.id),
                  asset: asset,
                  isNuking: isNuking,
                  onTap: () => _nukeAsset(asset),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class PhotoThumbnailTile extends StatefulWidget {
  final AssetEntity asset;
  final bool isNuking;
  final VoidCallback onTap;

  const PhotoThumbnailTile({
    super.key,
    required this.asset,
    required this.isNuking,
    required this.onTap,
  });

  @override
  State<PhotoThumbnailTile> createState() => _PhotoThumbnailTileState();
}

class _PhotoThumbnailTileState extends State<PhotoThumbnailTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shatterController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;
  Uint8List? _thumbData;
  bool _thumbLoaded = false;

  @override
  void initState() {
    super.initState();
    _shatterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(
        parent: _shatterController,
        curve: Curves.easeOutBack,
      ),
    );

    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _shatterController,
        curve: const Interval(0.2, 1.0, curve: Curves.easeIn),
      ),
    );

    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    try {
      final data = await widget.asset.thumbnailDataWithSize(
        const ThumbnailSize(240, 240),
        quality: 85,
      );
      if (mounted) {
        setState(() {
          _thumbData = data;
          _thumbLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _thumbLoaded = true);
      }
    }
  }

  @override
  void didUpdateWidget(covariant PhotoThumbnailTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isNuking && !oldWidget.isNuking) {
      _shatterController.forward();
    }
  }

  @override
  void dispose() {
    _shatterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isNuking ? null : widget.onTap,
      child: AnimatedBuilder(
        animation: _shatterController,
        builder: (context, child) {
          final isAnimating = _shatterController.value > 0;
          return Transform.scale(
            scale: isAnimating ? _scaleAnimation.value : 1.0,
            child: Opacity(
              opacity: isAnimating ? _opacityAnimation.value : 1.0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1E2B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _thumbData != null
                        ? Image.memory(
                            _thumbData!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : (_thumbLoaded
                            ? const Center(
                                child: Icon(Icons.broken_image,
                                    color: Colors.white24),
                              )
                            : const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFFFF2E63),
                                  ),
                                ),
                              )),
                  ),
                  if (isAnimating)
                    CustomPaint(
                      painter: ShatterPopPainter(
                        progress: _shatterController.value,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class ShatterPopPainter extends CustomPainter {
  final double progress;
  static final List<double> _randomAngles =
      List.generate(12, (i) => (i * 2 * pi / 12) + (i % 2 == 0 ? 0.1 : -0.1));

  ShatterPopPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxDist = size.width * 0.7;

    // Flash glow ring
    final glowPaint = Paint()
      ..color = const Color(0xFFFF2E63).withValues(alpha: (1.0 - progress).clamp(0.0, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * (1.0 - progress);

    canvas.drawCircle(center, (size.width / 2) * progress, glowPaint);

    // Radiating shatter fragments
    for (int i = 0; i < _randomAngles.length; i++) {
      final angle = _randomAngles[i];
      final dist = progress * maxDist * (0.8 + (i % 3) * 0.2);
      final particleCenter = Offset(
        center.dx + cos(angle) * dist,
        center.dy + sin(angle) * dist,
      );

      final particleRadius = (6.0 - progress * 4.0).clamp(1.0, 6.0);
      final particlePaint = Paint()
        ..color = (i % 2 == 0 ? const Color(0xFFFF2E63) : const Color(0xFF08D9D6))
            .withValues(alpha: (1.0 - progress).clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;

      canvas.drawCircle(particleCenter, particleRadius, particlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ShatterPopPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
