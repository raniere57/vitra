import Foundation

/// The JavaScript the browser tools run inside the page.
///
/// Kept in one place, and written to be readable: this is the part of Vitra an
/// agent depends on most, and a bug here is a wrong click on someone's page.
enum BrowserScripts {
    /// Sets up the ref registry. Runs in the isolated world, so the page's own
    /// scripts can neither see nor tamper with it.
    static let registry = """
    if (!window.__vitra) {
      window.__vitra = {
        next: 1,
        toRef: new WeakMap(),
        byRef: new Map(),
        ref(element) {
          let id = this.toRef.get(element);
          if (!id) {
            id = 'e' + this.next++;
            this.toRef.set(element, id);
            this.byRef.set(id, new WeakRef(element));
          }
          return id;
        },
        element(id) {
          const found = this.byRef.get(id);
          return found ? found.deref() : null;
        },
        visible(element) {
          if (element.hasAttribute('aria-hidden')) return false;
          const style = getComputedStyle(element);
          if (style.visibility === 'hidden' || style.display === 'none') return false;
          if (parseFloat(style.opacity) === 0) return false;
          const box = element.getBoundingClientRect();
          return box.width > 0 && box.height > 0;
        },
        label(element) {
          const aria = element.getAttribute('aria-label');
          if (aria) return aria.trim();
          if (element.tagName === 'INPUT' && element.labels && element.labels[0]) {
            return element.labels[0].textContent.trim();
          }
          const text = (element.innerText || element.textContent || '').trim();
          if (text) return text.replace(/\\s+/g, ' ').slice(0, 120);
          return (element.getAttribute('placeholder') || element.getAttribute('title') || '').trim();
        },
        role(element) {
          const explicit = element.getAttribute('role');
          if (explicit) return explicit;
          const tag = element.tagName.toLowerCase();
          if (tag === 'a') return 'link';
          if (tag === 'input') return (element.type || 'text') + '-input';
          if (tag === 'select') return 'select';
          if (tag === 'textarea') return 'textarea';
          if (tag === 'button') return 'button';
          if (/^h[1-6]$/.test(tag)) return 'heading';
          return tag;
        },
      };
    }
    """

    /// A compact listing of what a person could see and use on the page.
    static func snapshot(limit: Int) -> String {
        """
        \(registry)
        const vitra = window.__vitra;
        const interactive = 'a[href], button, input, select, textarea, summary, [role], [onclick], [contenteditable="true"]';
        const structural = 'h1, h2, h3, h4, h5, h6, label, legend, figcaption';
        const seen = new Set();
        const lines = [];
        let truncated = false;

        for (const element of document.querySelectorAll(interactive + ', ' + structural)) {
          if (seen.has(element) || !vitra.visible(element)) continue;
          seen.add(element);
          if (lines.length >= \(limit)) { truncated = true; break; }

          const parts = [vitra.ref(element), vitra.role(element)];
          const label = vitra.label(element);
          if (label) parts.push(JSON.stringify(label));
          if ('value' in element && element.value && element.type !== 'password') {
            parts.push('value=' + JSON.stringify(String(element.value).slice(0, 80)));
          }
          if (element.disabled) parts.push('disabled');
          if (element.checked) parts.push('checked');
          lines.push('- ' + parts.join(' '));
        }

        return JSON.stringify({
          url: location.href,
          title: document.title,
          truncated: truncated,
          elements: lines,
        });
        """
    }

    static func click(ref: String) -> String {
        """
        \(registry)
        const element = window.__vitra.element(\(quote(ref)));
        if (!element || !element.isConnected) {
          return JSON.stringify({ ok: false, reason: 'gone' });
        }
        element.scrollIntoView({ block: 'center', inline: 'center' });
        element.focus({ preventScroll: true });
        element.click();
        return JSON.stringify({ ok: true, role: window.__vitra.role(element), label: window.__vitra.label(element) });
        """
    }

    static func type(ref: String, text: String, submit: Bool) -> String {
        """
        \(registry)
        const element = window.__vitra.element(\(quote(ref)));
        if (!element || !element.isConnected) {
          return JSON.stringify({ ok: false, reason: 'gone' });
        }
        const editable = element.isContentEditable
          || element instanceof HTMLInputElement
          || element instanceof HTMLTextAreaElement;
        if (!editable) {
          return JSON.stringify({ ok: false, reason: 'not-editable', role: window.__vitra.role(element) });
        }

        element.scrollIntoView({ block: 'center' });
        element.focus({ preventScroll: true });

        const text = \(quote(text));
        if (element.isContentEditable) {
          element.textContent = text;
        } else {
          // React and friends listen for the native setter, not for assignment.
          const prototype = element instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
          setter.call(element, text);
        }
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));

        if (\(submit ? "true" : "false")) {
          const enter = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true };
          element.dispatchEvent(new KeyboardEvent('keydown', enter));
          element.dispatchEvent(new KeyboardEvent('keyup', enter));
          if (element.form && typeof element.form.requestSubmit === 'function') {
            element.form.requestSubmit();
          }
        }
        return JSON.stringify({ ok: true });
        """
    }

    /// Forwards the page's own console to the app.
    ///
    /// This one runs in the page's world on purpose: an override installed in
    /// the isolated world would only capture the isolated world's own logging,
    /// which is nothing. It wraps `console` and forwards; it reads no page state
    /// and exposes nothing back to the page.
    static let consoleForwarder = """
    (function () {
      const post = (level, args) => {
        try {
          const text = Array.from(args).map((value) => {
            if (typeof value === 'string') return value;
            try { return JSON.stringify(value); } catch (error) { return String(value); }
          }).join(' ');
          window.webkit.messageHandlers.vitraConsole.postMessage({ level: level, text: text });
        } catch (error) { /* the handler is gone; nothing to do */ }
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level].bind(console);
        console[level] = function () { post(level, arguments); original.apply(console, arguments); };
      }
      window.addEventListener('error', (event) => post('error', [event.message]));
      window.addEventListener('unhandledrejection', (event) => post('error', ['unhandled rejection: ' + event.reason]));
    })();
    """

    /// JSON-quotes a Swift string for embedding in a script.
    private static func quote(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        guard let data, let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        // ["..."] -> "..."
        return String(array.dropFirst().dropLast())
    }
}
