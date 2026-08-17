import Foundation

struct BrowserProfile {
    let userAgent: String
    let acceptLanguage: String
    let platform: String
    let windowWidth: Int
    let windowHeight: Int

    var centerX: Double { Double(windowWidth) / 2 }
    var centerY: Double { Double(windowHeight) / 2 }

    var stealthScript: String {
        """
        (() => {
          const patch = (target, key, value) => {
            try {
              Object.defineProperty(target, key, {
                get: () => value,
                configurable: true
              });
            } catch(e) {}
          };
          patch(navigator, 'webdriver', false);
          patch(navigator, 'hardwareConcurrency', 8);
          patch(navigator, 'deviceMemory', 8);
          patch(navigator, 'platform', '\(platform)');
          patch(navigator, 'languages', ['en-US', 'en']);

          window.chrome = window.chrome || {
            app: { isInstalled: false },
            runtime: {
              OnInstalledReason: { INSTALL: "install", UPDATE: "update" },
              OnRestartRequiredReason: { APP_UPDATE: "app_update" },
              PlatformArch: { ARM64: "arm64", X86_64: "x86-64" },
              PlatformOs: { MAC: "mac", WIN: "win" }
            },
            csi: function() {},
            loadTimes: function() {}
          };

          try {
            const getParameter = WebGLRenderingContext.prototype.getParameter;
            WebGLRenderingContext.prototype.getParameter = function(parameter) {
              if (parameter === 37445) return 'Apple';
              if (parameter === 37446) return 'ANGLE (Apple, Apple M1, OpenGL 4.1)';
              return getParameter.apply(this, arguments);
            };
          } catch(e) {}

          const originalQuery = navigator.permissions && navigator.permissions.query;
          if (originalQuery) {
            navigator.permissions.query = (parameters) => {
              if (parameters && parameters.name === 'notifications') {
                return Promise.resolve({ state: Notification.permission });
              }
              return originalQuery.call(navigator.permissions, parameters);
            };
          }
        })();
        """
    }

    /// A stronger stealth bundle used only on the quiet-CDP path. Beyond the baseline patches it fixes
    /// the headless fingerprints anti-bot scripts key on: empty `navigator.plugins`/`mimeTypes`, zeroed
    /// `outerWidth`/`outerHeight`, missing `navigator.connection`, WebGL2, and — importantly — makes the
    /// patched functions report native `toString()` so the overrides themselves can't be detected.
    var hardenedStealthScript: String {
        """
        (() => {
          const nativeToString = Function.prototype.toString;
          const faux = new WeakSet();
          const asNative = (fn) => { try { faux.add(fn); } catch (e) {} return fn; };
          const toStringProxy = function toString() {
            if (faux.has(this)) return 'function ' + (this.name || '') + '() { [native code] }';
            return nativeToString.call(this);
          };
          faux.add(toStringProxy);
          try { Function.prototype.toString = toStringProxy; } catch (e) {}

          const patch = (target, key, getter) => {
            try {
              Object.defineProperty(target, key, { get: asNative(getter), configurable: true });
            } catch (e) {}
          };

          patch(navigator, 'webdriver', () => false);
          patch(navigator, 'hardwareConcurrency', () => 8);
          patch(navigator, 'deviceMemory', () => 8);
          patch(navigator, 'platform', () => '\(platform)');
          patch(navigator, 'languages', () => ['en-US', 'en']);
          patch(navigator, 'maxTouchPoints', () => 0);

          // Real desktop Chrome exposes these; headless zeroes/omits them.
          try {
            patch(window, 'outerWidth', () => \(windowWidth));
            patch(window, 'outerHeight', () => \(windowHeight));
          } catch (e) {}
          try {
            patch(navigator, 'connection', () => ({
              effectiveType: '4g', rtt: 50, downlink: 10, saveData: false
            }));
          } catch (e) {}

          // A non-empty PluginArray/MimeTypeArray — the single most common headless tell.
          try {
            const makePlugin = (name, filename, desc) => {
              const p = Object.create(Plugin.prototype);
              Object.defineProperties(p, {
                name: { value: name }, filename: { value: filename },
                description: { value: desc }, length: { value: 1 }
              });
              return p;
            };
            const plugins = [
              makePlugin('PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
              makePlugin('Chrome PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
              makePlugin('Chromium PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
            ];
            const arr = Object.create(PluginArray.prototype);
            plugins.forEach((p, i) => { arr[i] = p; });
            Object.defineProperty(arr, 'length', { value: plugins.length });
            patch(navigator, 'plugins', () => arr);
            const mimeArr = Object.create(MimeTypeArray.prototype);
            Object.defineProperty(mimeArr, 'length', { value: 1 });
            patch(navigator, 'mimeTypes', () => mimeArr);
          } catch (e) {}

          window.chrome = window.chrome || {
            app: { isInstalled: false },
            runtime: {
              OnInstalledReason: { INSTALL: "install", UPDATE: "update" },
              OnRestartRequiredReason: { APP_UPDATE: "app_update" },
              PlatformArch: { ARM64: "arm64", X86_64: "x86-64" },
              PlatformOs: { MAC: "mac", WIN: "win" }
            },
            csi: asNative(function () {}),
            loadTimes: asNative(function () {})
          };

          const spoofWebGL = (proto) => {
            try {
              const getParameter = proto.prototype.getParameter;
              proto.prototype.getParameter = asNative(function (parameter) {
                if (parameter === 37445) return 'Apple';
                if (parameter === 37446) return 'ANGLE (Apple, Apple M1, OpenGL 4.1)';
                return getParameter.apply(this, arguments);
              });
            } catch (e) {}
          };
          spoofWebGL(WebGLRenderingContext);
          if (typeof WebGL2RenderingContext !== 'undefined') spoofWebGL(WebGL2RenderingContext);

          const originalQuery = navigator.permissions && navigator.permissions.query;
          if (originalQuery) {
            navigator.permissions.query = asNative((parameters) => {
              if (parameters && parameters.name === 'notifications') {
                return Promise.resolve({ state: Notification.permission });
              }
              return originalQuery.call(navigator.permissions, parameters);
            });
          }
        })();
        """
    }

    static func random() -> BrowserProfile {
        let presets: [BrowserProfile] = [
            BrowserProfile(
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
                acceptLanguage: "en-US,en;q=0.9",
                platform: "MacIntel",
                windowWidth: 1920,
                windowHeight: 1080
            ),
            BrowserProfile(
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36",
                acceptLanguage: "en-US,en;q=0.9",
                platform: "Win32",
                windowWidth: 1536,
                windowHeight: 864
            ),
            BrowserProfile(
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                acceptLanguage: "en-US,en;q=0.9",
                platform: "Win32",
                windowWidth: 2560,
                windowHeight: 1440
            ),
        ]

        return presets.randomElement() ?? presets[0]
    }
}

