import 'package:flutter/material.dart';
import 'package:flutter/services.h';
import 'package:photo_manager/photo_manager.dart';
import 'dart:typed_data';

void main() {
  runApp(const PhotoNukeApp());
}

class PhotoNukeApp extends StatelessWidget {
  const PhotoNukeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhotoNuke',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.redAccent,
          secondary: Colors.amber,
        ),
      ),
      home: const GalleryScreen(),
    );
  }
}

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool _hasPermission = false;
  List<AssetEntity> _mediaList = [];
  bool _isLoading = true;
  int _nukedCount = 0;

  @override
  void initState() {
    super.initState();
    _initGallery();
  }

  Future<void> _initGallery() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth || ps == PermissionState.limited) {
      setState(() {
        _hasPermission = true;
      });
      await _fetchMedia();
    } else {
      setState(() {
        _isLoading = false;
        _hasPermission = false;
      });
    }
  }

  Future<void> _fetchMedia() async {
    setState(() {
      _isLoading = true;
    });
    
    // Fetch recent images
    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderBy.createDate, asc: false)],
      ),
    );

    if (albums.isNotEmpty) {
      final List<AssetEntity> media = await albums.first.getAssetListRange(
        start: 0,
        end: 500,
      );
      setState(() {
        _mediaList = media;
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _nukeAsset(AssetEntity asset) async {
    // Haptic feedback & sound trigger
    HapticFeedback.heavyImpact();

    // Delete asset (moves to system trash / deletes)
    final List<String> result = await PhotoManager.editor.deleteWithIds([asset.id]);
    
    if (result.isNotEmpty) {
      setState(() {
        _mediaList.removeWhere((e) => e.id == asset.id);
        _nukedCount++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('💥 PhotoNuke  |  Nuked: $_nukedCount'),
        backgroundColor: const Color(0xFF1F1F1F),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_hasPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, size: 64, color: Colors.redAccent),
              const SizedBox(height: 16),
              const Text(
                'Gallery Permission Required',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'PhotoNuke needs local gallery access to let you purge unwanted photos instantly.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _initGallery,
                child: const Text('Grant Permission'),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_mediaList.isEmpty) {
      return const Center(
        child: Text(
          'Gallery is spotless! 🎉',
          style: TextStyle(fontSize: 18, color: Colors.grey),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: _mediaList.length,
      itemBuilder: (context, index) {
        final AssetEntity asset = _mediaList[index];
        return GestureDetector(
          onTap: () => _nukeAsset(asset),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done &&
                      snapshot.hasData) {
                    return Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                    );
                  }
                  return Container(color: Colors.grey[900]);
                },
              ),
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.local_fire_department,
                    size: 16,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
