import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum OperationType {
  navigate,
  click,
  type,
  extractText,
}

class SavedPage {
  final String id;
  final String name;
  final String url;

  SavedPage({
    required this.id,
    required this.name,
    required this.url,
  });

  Map<String, String> toFields() => {
        'name': name,
        'url': url,
      };

  static SavedPage fromFields(String id, Map<String, String> fields) => SavedPage(
        id: id,
        name: fields['name'] ?? 'Page $id',
        url: fields['url'] ?? '',
      );
}

class OperationPreset {
  final String id;
  final String label;
  final OperationType type;
  final String selector;
  final String value;

  OperationPreset({
    required this.id,
    required this.label,
    required this.type,
    required this.selector,
    required this.value,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type.name,
        'selector': selector,
        'value': value,
      };

  static OperationPreset fromJson(Map<String, dynamic> json) => OperationPreset(
        id: json['id'] as String,
        label: json['label'] as String,
        type: OperationType.values.firstWhere((e) => e.name == json['type']),
        selector: (json['selector'] ?? '') as String,
        value: (json['value'] ?? '') as String,
      );
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Web Tasks Bot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const LandingScreen(),
    );
  }
}

class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  List<SavedPage> _pages = [];

  @override
  void initState() {
    super.initState();
    _loadPages();
  }

  Future<void> _loadPages() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('page_ids') ?? [];
    final List<SavedPage> result = [];
    for (final id in ids) {
      final name = prefs.getString('page_${id}_name') ?? 'Page $id';
      final url = prefs.getString('page_${id}_url') ?? '';
      result.add(SavedPage(id: id, name: name, url: url));
    }
    setState(() {
      _pages = result;
    });
  }

  Future<void> _savePages(List<SavedPage> pages) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = pages.map((p) => p.id).toList();
    await prefs.setStringList('page_ids', ids);
    for (final p in pages) {
      await prefs.setString('page_${p.id}_name', p.name);
      await prefs.setString('page_${p.id}_url', p.url);
    }
    setState(() {
      _pages = pages;
    });
  }

  Future<void> _promptAddPage() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add Page'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Page name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(labelText: 'Web link (URL)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                var name = nameController.text.trim();
                var url = urlController.text.trim();
                if (name.isEmpty || url.isEmpty) return;
                // Ensure scheme
                final parsed = Uri.tryParse(url);
                if (parsed == null || !parsed.hasScheme) {
                  url = 'https://$url';
                }
                final id = DateTime.now().millisecondsSinceEpoch.toString();
                final updated = List<SavedPage>.from(_pages)
                  ..add(SavedPage(id: id, name: name, url: url));
                await _savePages(updated);
                if (mounted) Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Pages'),
      ),
      body: _pages.isEmpty
          ? const Center(child: Text('No pages yet. Tap + to add one.'))
          : ListView.separated(
              itemCount: _pages.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final page = _pages[index];
                return ListTile(
                  title: Text(page.name),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => HomeScreen(initialUrl: page.url)),
                    );
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _promptAddPage,
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

class HomeScreen extends StatefulWidget {
  final String? initialUrl;
  const HomeScreen({super.key, this.initialUrl});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  InAppWebViewController? _webViewController;
  String? _savedUrl;
  bool _isLoading = true;
  List<OperationPreset> _presets = [];
  OperationPreset? _selectedPreset;
  bool _autoLoadedInitial = false;

  @override
  void initState() {
    super.initState();
    _restoreState();
  }

  Future<void> _restoreState() async {
    final prefs = await SharedPreferences.getInstance();
    _savedUrl = prefs.getString('target_url');
    // Load presets stored field-by-field to avoid bringing a JSON codec.
    _presets = await _loadPresetsCompat(prefs);
    // If navigated from landing with an explicit URL, prefer that.
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _savedUrl = widget.initialUrl;
    }
    if (_savedUrl != null) {
      _urlController.text = _savedUrl!;
    }
    setState(() {});
    await _maybeAutoLoadInitialUrl();
  }

  Future<void> _maybeAutoLoadInitialUrl() async {
    if (_autoLoadedInitial) return;
    if (_webViewController == null) return;
    final hasInitial = widget.initialUrl != null && widget.initialUrl!.isNotEmpty;
    if (!hasInitial) return;
    final url = _savedUrl ?? widget.initialUrl!;
    if (url.isEmpty) return;
    _autoLoadedInitial = true;
    try {
      await _webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (_) {}
  }

  Future<List<OperationPreset>> _loadPresetsCompat(SharedPreferences prefs) async {
    final ids = prefs.getStringList('preset_ids') ?? [];
    final List<OperationPreset> result = [];
    for (final id in ids) {
      final label = prefs.getString('preset_${id}_label') ?? '';
      final typeName = prefs.getString('preset_${id}_type') ?? OperationType.navigate.name;
      final selector = prefs.getString('preset_${id}_selector') ?? '';
      final value = prefs.getString('preset_${id}_value') ?? '';
      result.add(OperationPreset(
        id: id,
        label: label.isEmpty ? 'Preset $id' : label,
        type: OperationType.values.firstWhere((e) => e.name == typeName, orElse: () => OperationType.navigate),
        selector: selector,
        value: value,
      ));
    }
    if (result.isEmpty) {
      // Seed a couple of examples
      final example = [
        OperationPreset(id: '1', label: 'Click #login', type: OperationType.click, selector: '#login', value: ''),
        OperationPreset(id: '2', label: 'Type into #q', type: OperationType.type, selector: '#q', value: 'hello'),
        OperationPreset(id: '3', label: 'Extract .price', type: OperationType.extractText, selector: '.price', value: ''),
      ];
      await _savePresets(example);
      return example;
    }
    return result;
  }

  Future<void> _saveTargetUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('target_url', url);
    setState(() {
      _savedUrl = url;
    });
  }

  Future<void> _savePresets(List<OperationPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = presets.map((p) => p.id).toList();
    await prefs.setStringList('preset_ids', ids);
    for (final p in presets) {
      await prefs.setString('preset_${p.id}_label', p.label);
      await prefs.setString('preset_${p.id}_type', p.type.name);
      await prefs.setString('preset_${p.id}_selector', p.selector);
      await prefs.setString('preset_${p.id}_value', p.value);
    }
    setState(() {
      _presets = presets;
    });
  }

  Future<void> _promptAddOrEditPreset({OperationPreset? preset}) async {
    final labelController = TextEditingController(text: preset?.label ?? '');
    final selectorController = TextEditingController(text: preset?.selector ?? '');
    final valueController = TextEditingController(text: preset?.value ?? '');
    OperationType type = preset?.type ?? OperationType.click;
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(preset == null ? 'Add Operation' : 'Edit Operation'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(labelText: 'Label'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<OperationType>(
                  value: type,
                  onChanged: (v) => type = v ?? type,
                  items: OperationType.values
                      .map((t) => DropdownMenuItem(value: t, child: Text(t.name)))
                      .toList(),
                  decoration: const InputDecoration(labelText: 'Type'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: selectorController,
                  decoration: const InputDecoration(labelText: 'CSS Selector (if applicable)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: valueController,
                  decoration: const InputDecoration(labelText: 'Value (for type/navigate)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final id = preset?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
                final updated = List<OperationPreset>.from(_presets);
                final newPreset = OperationPreset(
                  id: id,
                  label: labelController.text.trim().isEmpty ? 'Preset $id' : labelController.text.trim(),
                  type: type,
                  selector: selectorController.text.trim(),
                  value: valueController.text.trim(),
                );
                final idx = updated.indexWhere((p) => p.id == id);
                if (idx >= 0) {
                  updated[idx] = newPreset;
                } else {
                  updated.add(newPreset);
                }
                await _savePresets(updated);
                if (mounted) Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _runPreset(OperationPreset preset) async {
    if (_webViewController == null) return;
    // Placeholder for AI planner. For now, execute simple JS based on selected preset.
    final js = _buildJsForPreset(preset);
    try {
      final result = await _webViewController!.evaluateJavascript(source: js);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Operation result: ${result ?? 'done'}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Operation failed: $e')),
      );
    }
  }

  String _buildJsForPreset(OperationPreset preset) {
    switch (preset.type) {
      case OperationType.navigate:
        final url = preset.value.replaceAll("'", "%27");
        return "window.location.href='" + url + "'";
      case OperationType.click:
        return "(function(){var el=document.querySelector('" + preset.selector.replaceAll("'", "\\'") + "'); if(el){el.click(); return 'clicked';} return 'not found';})()";
      case OperationType.type:
        return "(function(){var el=document.querySelector('" + preset.selector.replaceAll("'", "\\'") + "'); if(el){el.focus(); el.value='" + preset.value.replaceAll("'", "\\'") + "'; el.dispatchEvent(new Event('input',{bubbles:true})); return 'typed';} return 'not found';})()";
      case OperationType.extractText:
        return "(function(){var el=document.querySelector('" + preset.selector.replaceAll("'", "\\'") + "'); return el? (el.innerText||el.textContent||''): ''})()";
    }
  }

  Future<void> _attemptAutoLogin() async {
    if (_webViewController == null) return;
    // Heuristic: focus first password field to trigger OS/browser autofill; if credentials saved, the popup should appear.
    const js = "(function(){var pw=document.querySelector('input[type=password]'); if(pw){pw.focus(); return true;} return false;})()";
    await _webViewController!.evaluateJavascript(source: js);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Web Tasks Bot'),
        actions: [
          IconButton(
            tooltip: 'Login helper (one-time fill)',
            onPressed: _openLoginHelper,
            icon: const Icon(Icons.vpn_key_outlined),
          ),
          IconButton(
            tooltip: 'Add operation',
            onPressed: () => _promptAddOrEditPreset(),
            icon: const Icon(Icons.add_task_outlined),
          )
        ],
      ),
      body: Column(
        children: [
          if (widget.initialUrl == null || widget.initialUrl!.isNotEmpty == false)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Target website URL',
                        hintText: 'https://example.com',
                      ),
                      onSubmitted: (v) async {
                        final url = v.trim();
                        if (url.isEmpty) return;
                        await _saveTargetUrl(url);
                        if (_webViewController != null) {
                          await _webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final url = _urlController.text.trim();
                      if (url.isEmpty) return;
                      await _saveTargetUrl(url);
                      if (_webViewController != null) {
                        await _webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
                      }
                    },
                    child: const Text('Open'),
                  )
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<OperationPreset>(
                    isExpanded: true,
                    value: _selectedPreset,
                    hint: const Text('Choose operation preset'),
                    items: _presets
                        .map((p) => DropdownMenuItem(value: p, child: Text(p.label)))
                        .toList(),
                    onChanged: (p) => setState(() => _selectedPreset = p),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _selectedPreset == null ? null : () => _runPreset(_selectedPreset!),
                  child: const Text('Run'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: _savedUrl != null ? URLRequest(url: WebUri(_savedUrl!)) : null,
              initialOptions: InAppWebViewGroupOptions(
                android: AndroidInAppWebViewOptions(
                  useHybridComposition: false,
                ),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                incognito: false,
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: true,
                allowsBackForwardNavigationGestures: true,
                supportMultipleWindows: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                saveFormData: true,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                userAgent: 'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                _maybeAutoLoadInitialUrl();
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url;
                if (uri == null) return NavigationActionPolicy.ALLOW;
                final scheme = uri.scheme.toLowerCase();
                switch (scheme) {
                  case 'http':
                  case 'https':
                  case 'about':
                  case 'data':
                  case 'javascript':
                  case 'blob':
                    return NavigationActionPolicy.ALLOW;
                  default:
                    // Allow non-http(s) as well so flows that rely on intents/custom schemes don't get blocked.
                    return NavigationActionPolicy.ALLOW;
                }
              },
              onCreateWindow: (controller, createWindowRequest) async {
                final req = createWindowRequest.request;
                if (req.url != null) {
                  await controller.loadUrl(urlRequest: req);
                }
                // Return false to prevent creating a separate WebView; we loaded it in the same one.
                return false;
              },
              onLoadStop: (controller, url) async {
                setState(() => _isLoading = false);
                await _attemptAutoLogin();
              },
              onLoadStart: (controller, url) {
                setState(() => _isLoading = true);
              },
            ),
          ),
          if (_isLoading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }

  Future<void> _openLoginHelper() async {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final userSelController = TextEditingController();
    final passSelController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('One-time login fill'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: usernameController,
                  decoration: const InputDecoration(labelText: 'Username / Email'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                ExpansionTile(
                  title: const Text('Advanced selectors (optional)'),
                  children: [
                    TextField(
                      controller: userSelController,
                      decoration: const InputDecoration(labelText: 'Username CSS selector'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: passSelController,
                      decoration: const InputDecoration(labelText: 'Password CSS selector'),
                    ),
                  ],
                )
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final username = usernameController.text;
                final password = passwordController.text;
                final userSel = userSelController.text.trim();
                final passSel = passSelController.text.trim();
                if (_webViewController != null && username.isNotEmpty && password.isNotEmpty) {
                  final js = _buildOneTimeLoginJs(username: username, password: password, userSelector: userSel.isEmpty ? null : userSel, passSelector: passSel.isEmpty ? null : passSel);
                  try {
                    await _webViewController!.evaluateJavascript(source: js);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Filled login fields. Submit attempted if button found.')));
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login helper failed: $e')));
                    }
                  }
                }
                if (mounted) Navigator.pop(context);
              },
              child: const Text('Fill now'),
            ),
          ],
        );
      },
    );
  }

  String _buildOneTimeLoginJs({required String username, required String password, String? userSelector, String? passSelector}) {
    String esc(String s) => s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
    final uSel = userSelector != null ? "document.querySelector('" + esc(userSelector) + "')" :
        "(document.querySelector('input[type=email],input[type=text][name*=email i],input[type=text][name*=user i],input[name*=email i],input[name*=user i]') || document.querySelector('input[type=text],input:not([type])'))";
    final pSel = passSelector != null ? "document.querySelector('" + esc(passSelector) + "')" :
        "document.querySelector('input[type=password]')";
    final js = "(function(){var uEl=" + uSel + "; var pEl=" + pSel + "; if(uEl){uEl.focus(); uEl.value='" + esc(username) + "'; uEl.dispatchEvent(new Event('input',{bubbles:true}));} if(pEl){pEl.focus(); pEl.value='" + esc(password) + "'; pEl.dispatchEvent(new Event('input',{bubbles:true}));} var btn=null; var cs=Array.from(document.querySelectorAll('button, input[type=submit]')); for(var i=0;i<cs.length;i++){var b=cs[i]; var t=(b.innerText||b.textContent||''); if((b.type||'').toLowerCase()=='submit' || /log\\s*in|sign\\s*in/i.test(t) || /login|signin/i.test(b.id||'') || /login|signin/i.test(b.name||'')){btn=b; break;}} if(btn){btn.click(); return 'filled+submitted';} return 'filled';})()";
    return js;
  }
}
