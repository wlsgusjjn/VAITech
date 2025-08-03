import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/pigeon.g.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as imgLib;
import 'package:stts/stts.dart';

final gemma = FlutterGemmaPlugin.instance;
final modelManager = gemma.modelManager;

InferenceModel? inferenceModel;
InferenceModelSession? session;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VAITech',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'VAITech'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  /// STT Params
  final _stt = Stt();
  bool? _hasPermission;
  String _text = '';
  String? _error;
  StreamSubscription<SttState>? _sttStateSubscription;
  StreamSubscription<SttRecognition>? _resultSubscription;
  bool _started = false;
  String _lang = 'en-US';

  /// TTS Params
  final _tts = Tts();
  StreamSubscription<TtsState>? _ttsStateSubscription;
  TtsState _ttsState = TtsState.stop;

  /// Camera & model Params
  late CameraController _controller;
  late Timer _timer;
  bool _isProcessing = false;
  bool modelLoad = false;
  bool streaming = false;
  Uint8List? imageBytes;
  Uint8List? lastImageBytes;

  /// Gemma text Params
  String answer = "";
  String question_prefix = "";
  bool loadComplete = false;

  @override
  void initState() {
    super.initState();
    getSystemLocaleIdentifier();
    initModels();
  }

  void getSystemLocaleIdentifier() {
    final Locale systemLocale = WidgetsBinding.instance.platformDispatcher.locale;
    _lang = systemLocale.toString();
  }

  Future<void> appClose() async {
    await  _tts.start(_text);
    await Future.delayed(Duration(seconds: 10));
    exit(0);
  }

  /// Get ready for loading the model
  Future<void> initModels() async {
    await initTts();
    await Permission.manageExternalStorage.request();
    final storagePermissionStatus = await Permission.manageExternalStorage.status;
    if (storagePermissionStatus.isDenied) {
      _text = "External file access permission not granted, so the model cannot be used. The app will now close.";
      await appClose();
    }
    await _stt.hasPermission();
    final microphonePermissionStatus = await Permission.microphone.status;
    if (microphonePermissionStatus.isDenied) {
      _text = "Microphone recording permission not granted, so the model cannot be used. The app will now close.";
      await appClose();
    }
    await loadModel();
    await initStt();
    if (inferenceModel == null) {
      _text = "An error occurred during model setup. The app will now close.";
      await appClose();
    }
    else {
      question_prefix = "Translate the following sentence into this $_lang language.";
      _text = "$question_prefix Model setup is complete. Please tap the screen once before asking Gemma a question.";
      question_prefix = "You are a compassionate guide model that serves as eyes for the visually impaired. Answer the following question in this $_lang language:";
    }
    streaming = true;
    await _runModel(true);
    setState(() {
      _text = "";
      answer = "";
      loadComplete = true;
    });
  }

  /// Gemma model load
  Future<void> loadModel() async {
    await modelManager.setModelPath('/storage/emulated/0/Download/gemma-3n-E2B-it-int4.task');
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text("Model loading complete."),
    ));

    inferenceModel = await FlutterGemmaPlugin.instance.createModel(
      modelType: ModelType.gemmaIt, // Required, model type to create
      preferredBackend: PreferredBackend.cpu, // Optional, backend type
      maxTokens: 512, // Recommended for multimodal models
      supportImage: true, // Enable image support
      maxNumImages: 1, // Optional, maximum number of images per message
    );

    if (inferenceModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Model not initialized."),
      ));
    }
    else{
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Model initialized."),
      ));
      setState(() {
        modelLoad = true;
      });
      _initCamera();
    }
  }

  /// Initialize STT
  Future<void> initStt() async {
    _stt.isSupported().then((supported) {
      debugPrint('Supported: $supported');
    });

    _stt.getLanguages().then((loc) {
      debugPrint('Supported languages: $loc');

      String _tempLang = _lang;
      _tempLang = _tempLang.replaceAll("_", "-");
      if (!loc.contains(_tempLang)) {
        _tempLang = "en-US";
      }
      _stt.setLanguage(_tempLang).then((_) {
        _stt.getLanguage().then((lang) {
          debugPrint('Current language: $lang');
        });
      });
    });
    _sttStateSubscription = _stt.onStateChanged.listen((sttState) {
        setState(() => _started = sttState == SttState.start);
      },
      onError: (err) {
        debugPrint(err.toString());
        setState(() => _error = err.toString());
      },
    );

    _resultSubscription = _stt.onResultChanged.listen((result) async {
      debugPrint('${result.text} (isFinal: ${result.isFinal})');
      setState(() => _text = result.text);
      if (result.isFinal && !streaming) {
        streaming = true;
        await _controller.startImageStream((CameraImage image) async {
          imageBytes = await convertCameraImageToJpeg(image);
          await _runModel(false);
        });
      }
    });
  }

  /// Initialize TTS
  Future<void> initTts() async {
    _tts.getLanguages().then((languages) {
      debugPrint('Supported languages: $languages');

      String _tempLang = _lang;
      _tempLang = _tempLang.replaceAll("_", "-");
      if (!languages.contains(_tempLang)) {
        _tempLang = "en-US";
      }
      _tts.setLanguage(_tempLang).then((_) {
        _tts.getLanguage().then((lang) {
          debugPrint('Current language: $lang');
        });
      });
    });

    _tts.getVoices().then((voices) {
      debugPrint('Available voices: $voices');
    });

    _tts.getVoicesByLanguage(_lang).then((voices) {
      debugPrint('Available voices for $_lang: $voices');
    });

    _ttsStateSubscription = _tts.onStateChanged.listen((ttsState) {
        setState(() => _ttsState = ttsState);
      },
      onError: (err) {
        debugPrint(err.toString());
      },
    );
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back);

    _controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _controller.initialize();

    setState(() {});
  }

  Future<void> _runModel(bool textOnly) async {
    if (inferenceModel == null || _text.isEmpty || (!textOnly && imageBytes == null)) {
      setState(() {
        _text = '';
        answer = '';
        imageBytes = null;
      });
      _isProcessing = false;
      streaming = false;
      return;
    }
    _isProcessing = true;

    String input_text = _text;

    if (!textOnly) {
      input_text = question_prefix + _text;
      await _controller.stopImageStream();
      setState(() {});
    }

    session = await inferenceModel!.createSession();
    final cameraPermissionStatus = await Permission.camera.status;
    if (cameraPermissionStatus.isDenied) {
      _text = "Camera permission not granted, so the model cannot be used. The app will now close.";
      await appClose();
    }

    if (textOnly) {
      await session!.addQueryChunk(Message.text(
        text: input_text,
      ));
    }
    else {
      await session!.addQueryChunk(Message.withImage(
        text: input_text,
        imageBytes: imageBytes!,
        isUser: true,
      ));
    }

    String response = await session!.getResponse();
    response = response.replaceAll("*", "");
    response = response.replaceAll("<end_of_turn>", "");
    print(response);

    session!.close();

    /// Gemma answer to speech
    await _tts.start(response);

    setState(() {
      _text = '';
      answer = response;
      lastImageBytes = imageBytes;
      imageBytes = null;
    });
    _isProcessing = false;
    streaming = false;
  }

  Future<Uint8List> convertCameraImageToJpeg(CameraImage image) async {
    final int width = image.width;
    final int height = image.height;

    final imgLib.Image rgbImage = imgLib.Image(width: width, height: height);

    final Plane planeY = image.planes[0];
    final Plane planeU = image.planes[1];
    final Plane planeV = image.planes[2];

    final int uvRowStride = planeU.bytesPerRow;
    final int uvPixelStride = planeU.bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
        final int index = y * width + x;

        final int yp = planeY.bytes[index];
        final int up = planeU.bytes[uvIndex];
        final int vp = planeV.bytes[uvIndex];

        int r = (yp + 1.370705 * (vp - 128)).round();
        int g = (yp - 0.337633 * (up - 128) - 0.698001 * (vp - 128)).round();
        int b = (yp + 1.732446 * (up - 128)).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        rgbImage.setPixel(x, y, imgLib.ColorRgb8(r, g, b));
      }
    }

    final imgLib.Image rotated = imgLib.copyRotate(rgbImage, angle: 90,);

    return Uint8List.fromList(imgLib.encodeJpg(rotated, quality: 95));
  }

  @override
  void dispose() {
    _sttStateSubscription?.cancel();
    _resultSubscription?.cancel();
    _stt.dispose();
    _ttsStateSubscription?.cancel();
    _tts.dispose();
    _controller.dispose();
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: GestureDetector(
        onTap: _started ? null : inferenceModel == null ? null : _isProcessing ? null : () {
          _stt.start();
        },
        child: Container(
          width: size.width,
          height: size.height,
          decoration: BoxDecoration(
            color: Colors.white,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  modelLoad? "Model is ready" : "Model not found",
                ),
                Container(
                  width: size.width * 0.7,
                  height: size.height * 0.5,
                  child: lastImageBytes != null ? Image.memory(
                    Uint8List.fromList(lastImageBytes!),
                    fit: BoxFit.cover,
                  ) : Container(),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(size.width * 0.08,0,size.width * 0.08,0),
                  child: Column(
                    children: [
                      Text(
                        loadComplete? _text : "",
                      ),
                      Text(
                        loadComplete? answer : "",
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}