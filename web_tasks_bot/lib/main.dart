import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:web_tasks_bot/services/tts_service.dart';
import 'package:web_tasks_bot/services/voice_text_service.dart';

// Cloud Function endpoint and constant prompt for the AI agent
const String kAICloudFunctionUrl =
    'https://us-central1-studious-apex-468917-c2.cloudfunctions.net/web_task_AI';
const String kAIFixedPrompt = 'Answer the question on the attached HTML page. If there is request to click on the page, return the HTML filed name to click surounded by <>';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await VoiceTextService.instance.loadFromAssets(); } catch (e) { print('VoiceTextService preload failed: '+e.toString()); }
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
    _loadAndApplyLanguage();
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

  Future<void> _loadAndApplyLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString('app_language') ?? 'En';
      await TtsService.instance.setLanguageByMenu(lang);
    } catch (_) {}
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
                if (context.mounted) Navigator.pop(context);
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
        actions: [
          PopupMenuButton<MainMenuAction>(
            onSelected: (action) async {
              switch (action) {
                case MainMenuAction.language:
                  await _pickAndApplyLanguage(context);
                  break;
                case MainMenuAction.about:
                  await showAboutDialog(context);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: MainMenuAction.language,
                child: Text('Language'),
              ),
              const PopupMenuItem(
                value: MainMenuAction.about,
                child: Text('About'),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          _pages.isEmpty
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
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.play_circle_fill, size: 40),
              label: const Text('Actions', style: TextStyle(fontSize: 24)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                minimumSize: const Size(280, 120),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () async {
                try {
                  final prefs = await SharedPreferences.getInstance();
                  final lang = prefs.getString('app_language') ?? 'En';
                  await TtsService.instance.speakMessageById('1', languageName: lang);
                } catch (_) {}
              },
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'ai-landing-fab',
              tooltip: 'AI agent',
              onPressed: () async {
                if (_pages.isNotEmpty) {
                  final url = _pages.first.url;
                  if (!mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => HomeScreen(
                        initialUrl: url,
                        autoOpenAIAgent: true,
                      ),
                    ),
                  );
                } else {
                  await _promptAddPage();
                }
              },
              child: const Icon(Icons.smart_toy_outlined),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add-landing-fab',
        onPressed: _promptAddPage,
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

class HomeScreen extends StatefulWidget {
  final String? initialUrl;
  final bool autoOpenAIAgent;
  const HomeScreen({super.key, this.initialUrl, this.autoOpenAIAgent = false});

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
  bool _autoOpenedAgent = false;

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

  

  Future<String> _capturePageSnapshotJson() async {
    try {
      if (_webViewController == null) return jsonEncode({});
      // Give the page a brief moment to finish dynamic rendering
      await Future.delayed(const Duration(milliseconds: 1200));
      final script = r'''(function(){
  try {
    function collectResources(){
      const out=[];
      const list=[['img','src'],['script','src'],['link','href'],['a','href'],['source','src'],['video','src'],['audio','src'],['iframe','src']];
      for (const [sel,attr] of list){
        document.querySelectorAll(sel+'['+attr+']').forEach(el=>{
          const raw=el.getAttribute(attr);
          if(!raw) return;
          let absolute=raw;
          try{ absolute=new URL(raw, document.baseURI).href; }catch(e){}
          out.push({tag:(el.tagName||'').toLowerCase(), attr, value: raw, absolute});
        });
      }
      return out;
    }

    function includeShadowRootsInClone(root, cloneRoot){
      const origEls = root.querySelectorAll('*');
      const cloneEls = cloneRoot.querySelectorAll('*');
      const len = Math.min(origEls.length, cloneEls.length);
      for(let i=0;i<len;i++){
        const o=origEls[i];
        const c=cloneEls[i];
        if(o && c && o.shadowRoot){
          const t = document.createElement('template');
          try { t.setAttribute('shadowrootmode', o.shadowRoot.mode || 'open'); } catch(e) {}
          t.innerHTML = o.shadowRoot.innerHTML;
          c.prepend(t);
        }
      }
    }

    const url=location.href;
    const origin=location.origin;
    const path=location.pathname;
    const pathSegments=path.split('/').filter(Boolean);
    const baseHref=document.baseURI;
    const title=document.title||'';

    // Clone the document and augment it
    const clone=document.documentElement.cloneNode(true);
    includeShadowRootsInClone(document, clone);
    let head=clone.querySelector('head');
    if(!head){ head=clone.firstElementChild; }
    if(head && !clone.querySelector('head base')){
      const base=document.createElement('base');
      base.setAttribute('href', baseHref);
      head.prepend(base);
    }
    const html='<!DOCTYPE html>\n'+clone.outerHTML;

    // Capture same-origin iframe HTML where possible
    const iframes = Array.from(document.querySelectorAll('iframe')).map(ifr=>{
      const src=ifr.getAttribute('src')||'';
      let absolute=src; try{ absolute=new URL(src||'', document.baseURI).href; }catch(e){}
      let frameHtml=''; let sameOrigin=false;
      try{
        const doc=ifr.contentDocument;
        if(doc && doc.documentElement){
          sameOrigin=true;
          frameHtml='<!DOCTYPE html>\n'+doc.documentElement.outerHTML;
        }
      }catch(e){}
      return {src, absolute, sameOrigin, html: frameHtml};
    });

    const resources=collectResources();
    return JSON.stringify({
      url, origin, path, pathSegments, baseHref, title,
      html, resources, iframes
    });
  } catch(e) {
    return JSON.stringify({error: String(e)});
  }
})()''';

      final result = await _webViewController!.evaluateJavascript(source: script);
      final snapshotJson = result?.toString() ?? jsonEncode({});

      // Persist the HTML part for debugging / sharing
      try {
        final Map<String, dynamic> data = jsonDecode(snapshotJson) as Map<String, dynamic>;
        final html = (data['html'] ?? '').toString();
        if (html.isNotEmpty) {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/webview_snapshot_${DateTime.now().millisecondsSinceEpoch}.html');
          await file.writeAsString(html, encoding: utf8);
        }
      } catch (_) {}

      return snapshotJson;
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
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
                if (context.mounted) Navigator.pop(context);
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
        return "window.location.href='$url'";
      case OperationType.click:
        return "(function(){var el=document.querySelector('${preset.selector.replaceAll("'", "\\'")}'); if(el){el.click(); return 'clicked';} return 'not found';})()";
      case OperationType.type:
        return "(function(){var el=document.querySelector('${preset.selector.replaceAll("'", "\\'")}'); if(el){el.focus(); el.value='${preset.value.replaceAll("'", "\\'")}'; el.dispatchEvent(new Event('input',{bubbles:true})); return 'typed';} return 'not found';})()";
      case OperationType.extractText:
        return "(function(){var el=document.querySelector('${preset.selector.replaceAll("'", "\\'")}'); return el? (el.innerText||el.textContent||''): ''})()";
    }
  }

  Future<void> _pressButtonByToken(String token) async {
    if (_webViewController == null) return;
    final js = _buildClickByTokenJs(token);
    try {
      final result = await _webViewController!.evaluateJavascript(source: js);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI action: ${result ?? 'done'}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI click failed: $e')),
      );
    }
  }

  String _buildClickByTokenJs(String token) {
    String esc(String s) => s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
    final t = esc(token);
    return """(function(){
  try{
    var tok='${t}';
    var tokTrim=tok.trim();
    var tokLower=tokTrim.toLowerCase();
    function norm(s){return (s||'').replace(/\s+/g,' ').trim().toLowerCase();}
    function isVisible(el){try{var r=el.getBoundingClientRect(); return r.width>0 && r.height>0;}catch(e){return true;}}
    function tryClick(el){if(!el) return false; try{el.scrollIntoView({block:'center'});}catch(e){}; try{el.focus&&el.focus();}catch(e){}; try{el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));}catch(e){}; try{el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));}catch(e){}; try{el.click();}catch(e){}; try{el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));}catch(e){}; return true;}

    // 1) If token looks like a selector, try it directly
    var el=null;
    var looksLikeSelector=/[.#\[\]> :]/.test(tokTrim);
    if(looksLikeSelector){
      try{ el=document.querySelector(tokTrim); }catch(e){}
      if(el){ tryClick(el); return 'clicked:selector'; }
    }

    // 2) ID
    el=document.getElementById(tokTrim);
    if(el){ tryClick(el); return 'clicked:id'; }

    // 3) Elements with matching name/id attributes among typical clickable elements
    var candidates=Array.from(document.querySelectorAll('button, [role="button"], input[type=button], input[type=submit], a[role="button"], a.button'));
    var match=candidates.find(function(e){var id=(e.id||''); var name=(e.getAttribute('name')||''); return id===tokTrim || name===tokTrim;});
    if(!match){
      // 4) aria-label or value equals
      match=candidates.find(function(e){return norm(e.getAttribute('aria-label'))===tokLower || norm(e.value)===tokLower;});
    }
    if(!match){
      // 5) Exact text match
      match=candidates.find(function(e){return norm(e.innerText||e.textContent)===tokLower;});
    }
    if(!match){
      // 6) Partial text match
      match=candidates.find(function(e){return norm(e.innerText||e.textContent).includes(tokLower);});
    }
    if(!match){
      // 7) Label[for] association
      var lbl=Array.from(document.querySelectorAll('label')).find(function(l){return norm(l.innerText||l.textContent)===tokLower || norm(l.innerText||l.textContent).includes(tokLower);});
      if(lbl){
        var forId=lbl.getAttribute('for');
        if(forId){ match=document.getElementById(forId); }
      }
    }
    if(match){ if(isVisible(match)){ tryClick(match); return 'clicked:match'; } else { tryClick(match); return 'clicked:hidden'; } }
    return 'not found';
  }catch(e){ return 'error:'+String(e); }
})()""";
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
          ),
          PopupMenuButton<MainMenuAction>(
            onSelected: (action) async {
              switch (action) {
                case MainMenuAction.language:
                  await _pickAndApplyLanguage(context);
                  break;
                case MainMenuAction.about:
                  await showAboutDialog(context);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: MainMenuAction.language,
                child: Text('Language'),
              ),
              const PopupMenuItem(
                value: MainMenuAction.about,
                child: Text('About'),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
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
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    javaScriptCanOpenWindowsAutomatically: true,
                    useHybridComposition: false,
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
                    if (widget.autoOpenAIAgent && !_autoOpenedAgent) {
                      _autoOpenedAgent = true;
                      if (!mounted) return;
                      await _openAIAgentDialog(
                        context,
                        htmlProvider: _capturePageSnapshotJson,
                        onAngleBracketCommand: (token) async {
                          await _pressButtonByToken(token);
                        },
                      );
                    }
                  },
                  onLoadStart: (controller, url) {
                    setState(() => _isLoading = true);
                  },
                ),
              ),
              if (_isLoading) const LinearProgressIndicator(minHeight: 2),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'ai-home-fab',
              tooltip: 'AI agent',
              onPressed: () => _openAIAgentDialog(
                context,
                htmlProvider: _capturePageSnapshotJson,
                onAngleBracketCommand: (token) async { await _pressButtonByToken(token); },
              ),
              child: const Icon(Icons.smart_toy_outlined),
            ),
          ),
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
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Filled login fields. Submit attempted if button found.')));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login helper failed: $e')));
                    }
                  }
                }
                if (context.mounted) Navigator.pop(context);
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
    final uSel = userSelector != null ? "document.querySelector('${esc(userSelector)}')" :
        "(document.querySelector('input[type=email],input[type=text][name*=email i],input[type=text][name*=user i],input[name*=email i],input[name*=user i]') || document.querySelector('input[type=text],input:not([type])'))";
    final pSel = passSelector != null ? "document.querySelector('${esc(passSelector)}')" :
        "document.querySelector('input[type=password]')";
    final js = "(function(){var uEl=$uSel; var pEl=$pSel; if(uEl){uEl.focus(); uEl.value='${esc(username)}'; uEl.dispatchEvent(new Event('input',{bubbles:true}));} if(pEl){pEl.focus(); pEl.value='${esc(password)}'; pEl.dispatchEvent(new Event('input',{bubbles:true}));} var btn=null; var cs=Array.from(document.querySelectorAll('button, input[type=submit]')); for(var i=0;i<cs.length;i++){var b=cs[i]; var t=(b.innerText||b.textContent||''); if((b.type||'').toLowerCase()=='submit' || /log\\s*in|sign\\s*in/i.test(t) || /login|signin/i.test(b.id||'') || /login|signin/i.test(b.name||'')){btn=b; break;}} if(btn){btn.click(); return 'filled+submitted';} return 'filled';})()";
    return js;
  }
}

enum MainMenuAction { language, about }

Future<void> showLanguageSelectionDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: const Text('Language'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('En'),
            child: const Text('En'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('He'),
            child: const Text('He'),
          ),
        ],
      );
    },
  );
}

Future<String?> _pickAndApplyLanguage(BuildContext context) async {
  String? selected;
  await showDialog(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: const Text('Language'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('En'),
            child: const Text('En'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('He'),
            child: const Text('He'),
          ),
        ],
      );
    },
  ).then((value) => selected = value as String?);
  if (selected != null) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_language', selected!);
      await TtsService.instance.setLanguageByMenu(selected!);
    } catch (_) {}
  } else {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_language', 'En');
      await TtsService.instance.setLanguageByMenu('En');
    } catch (_) {}
  }
  return selected;
}

Future<void> showAboutDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('About'),
        content: const Text('Web Tasks Bot. Version 0.1'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

Future<void> _openAIAgentDialog(BuildContext context, {required Future<String> Function() htmlProvider, Future<void> Function(String token)? onAngleBracketCommand}) async {
  // Use a navigator key lookup via contexts where this function is called.
  // The dialog maintains its own previousAnswer state until cancelled.
  final promptController = TextEditingController();
  String previousAnswer = '';
  String aiAnswer = '';
  String? error;
  bool sending = false;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> send() async {
            final userPrompt = promptController.text.trim();
            if (userPrompt.isEmpty) return;
            setState(() {
              sending = true;
              error = null;
            });
            try {
              final snapshotOrHtml = await htmlProvider();
              String pageHtml = '';
              Map<String, dynamic>? pageSnapshot;
              try {
                final decoded = jsonDecode(snapshotOrHtml);
                if (decoded is Map<String, dynamic> && decoded.containsKey('html')) {
                  pageSnapshot = decoded;
                  pageHtml = (decoded['html'] ?? '').toString();
                } else {
                  pageHtml = snapshotOrHtml;
                }
              } catch (_) {
                pageHtml = snapshotOrHtml;
              }
              final uri = Uri.parse(kAICloudFunctionUrl);
              final resp = await http.post(
                uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'userPrompt': userPrompt,
                  'previousAnswer': previousAnswer,
                  'pageHtml': pageHtml,
                  'pageSnapshot': pageSnapshot,
                  'constantPrompt': kAIFixedPrompt,
                }),
              );
              if (resp.statusCode == 200) {
                final data = jsonDecode(resp.body) as Map<String, dynamic>;
                final answer = (data['answer'] ?? '').toString();
                // If the answer contains a <...> token, execute and close dialog immediately
                try {
                  final regex = RegExp(r'<([^<>]+)>' );
                  final match = regex.firstMatch(answer);
                  if (match != null) {
                    final token = match.group(1)?.trim();
                    if (token != null && token.isNotEmpty && onAngleBracketCommand != null) {
                      try {
                        await onAngleBracketCommand(token);
                      } catch (_) {}
                      if (context.mounted) {
                        try { await TtsService.instance.stop(); } catch (_) {}
                        Navigator.of(context).pop();
                      }
                      return;
                    }
                  }
                } catch (_) {}

                // No angle-bracket token; show the AI response as usual
                Future<void>? speechDone;
                try {
                  if (answer.trim().isNotEmpty) {
                    // Start speaking immediately; this Future completes when speech ends
                    // because awaitSpeakCompletion(true) is enabled in TtsService.
                    speechDone = TtsService.instance.speak(answer);
                  }
                } catch (_) {}
                setState(() {
                  aiAnswer = answer;
                  previousAnswer = answer;
                });
                // Auto-clear only after BOTH: 20 seconds elapsed AND TTS finished speaking
                final scheduledAnswer = answer;
                final waiters = <Future<void>>[Future.delayed(const Duration(seconds: 2))];
                if (speechDone != null) {
                  waiters.add(speechDone);
                }
                // ignore: unawaited_futures
                Future.wait(waiters).then((_) async {
                  if (!context.mounted) return;
                  if (aiAnswer == scheduledAnswer && error == null && !sending) {
                    // TTS should have finished naturally; just close the dialog.
                    try { await Navigator.of(context).maybePop(); } catch (_) {}
                  }
                });
              } else {
                setState(() {
                  error = 'AI request failed (${resp.statusCode})';
                });
              }
            } catch (e) {
              setState(() {
                error = 'AI request error: $e';
              });
            } finally {
              setState(() {
                sending = false;
              });
            }
          }

          return AlertDialog(
            title: const Text('AI Agent'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: promptController,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(labelText: 'Describe what to do'),
                    ),
                    const SizedBox(height: 12),
                    if (aiAnswer.isNotEmpty)
                      Container(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.6,
                        ),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.black.withOpacity(0.02),
                        ),
                        child: SingleChildScrollView(child: Text(aiAnswer)),
                      ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error!, style: const TextStyle(color: Colors.red)),
                    ]
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: sending
                    ? null
                    : () {
                        try { TtsService.instance.stop(); } catch (_) {}
                        Navigator.of(context).pop();
                      },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: sending ? null : send,
                child: sending
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send'),
              ),
            ],
          );
        },
      );
    },
  );
}
