import Foundation
import Network
import RekoCore

/// Minimal HTTP server so any phone browser on the same Wi-Fi can act as a remote.
/// Every request must carry the secret token (`?t=…`), which is only shown in the QR code / URL.
/// Request parsing and routing live in `RemoteRouter` (RekoCore) and are unit-tested.
///
///   GET  /?t=TOKEN               remote page
///   GET  /api/state?t=TOKEN      JSON state
///   POST /api/cmd/<command>?t=   run a Command
///   POST /api/cue/<index>?t=     jump to a cue
@MainActor
final class RemoteServer: ObservableObject {
    static let basePort: UInt16 = 8765
    private static let maxConnections = 16
    private var port = RemoteServer.basePort

    /// Link for the QR code; nil unless the server is actually listening (and the Mac has a LAN address).
    @Published private(set) var url: String?

    private let token: String
    private let onCommand: (Command) -> Void
    private let onCue: (Int) -> Void
    private let state: () -> [String: Any]
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Wi-Fi switches change the Mac's address; keep the QR link current even while settings are open.
    private let pathMonitor = NWPathMonitor()

    init(token: String, onCommand: @escaping (Command) -> Void, onCue: @escaping (Int) -> Void,
         state: @escaping () -> [String: Any]) {
        self.token = token
        self.onCommand = onCommand
        self.onCue = onCue
        self.state = state
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshURL() } }
        }
        pathMonitor.start(queue: .main)
    }

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: Self.parameters, on: nwPort) else { return }
        listener.service = NWListener.Service(name: "Reko", type: "_http._tcp")
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.refreshURL()
                case .failed:
                    // Port taken or network gone: drop it, then try the next port (up to 10 tries).
                    listener?.cancel()
                    self.listener = nil
                    self.url = nil
                    if self.port < Self.basePort + 10 { self.port += 1; self.start() }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Allow re-binding the port right after a stop, so the phone's saved link keeps working.
    private static var parameters: NWParameters {
        let p = NWParameters.tcp
        p.allowLocalEndpointReuse = true
        return p
    }

    func stop() {
        listener?.cancel()
        listener = nil
        url = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        port = Self.basePort
    }

    /// The Mac's address changes when it switches networks; call when showing the link.
    func refreshURL() {
        guard listener?.state == .ready, let ip = Self.lanIPv4Address() else { url = nil; return }
        let new = "http://\(ip):\(port)/?t=\(token)"
        if new != url { url = new }
    }

    private func accept(_ conn: NWConnection) {
        guard connections.count < Self.maxConnections else { return conn.cancel() } // flood protection
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed: self?.connections[id] = nil
                default: break
                }
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { conn.cancel() } // drop idle/slow clients
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return conn.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(to: buffer, on: conn)
                } else if done || buffer.count > 64_000 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buffer)
                }
            }
        }
    }

    private func respond(to raw: Data, on conn: NWConnection) {
        switch RemoteRouter.route(raw, token: token) {
        case .page:
            send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8))
        case .state:
            sendState(conn)
        case .command(let name):
            guard let command = Command(rawValue: name) else { return send(conn, status: "404 Not Found") }
            onCommand(command)
            sendState(conn)
        case .cue(let index):
            onCue(index)
            sendState(conn)
        case .badRequest:
            send(conn, status: "400 Bad Request")
        case .forbidden:
            send(conn, status: "403 Forbidden", body: Data("Scan the QR code in Reko's settings to connect.".utf8))
        case .notFound:
            send(conn, status: "404 Not Found")
        }
    }

    private func sendState(_ conn: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: state())) ?? Data("{}".utf8)
        send(conn, status: "200 OK", type: "application/json", body: body)
    }

    private func send(_ conn: NWConnection, status: String, type: String = "text/plain", body: Data = Data()) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// First IPv4 address on an active non-loopback interface (Wi-Fi / Ethernet), preferring en0.
    static func lanIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue } // skip VPN/utun/bridge interfaces
            candidates.append((name, String(cString: host)))
        }
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.ip
    }
}

enum RemotePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
    <meta name="theme-color" content="#000">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <title>Reko Remote</title>
    <style>
      :root { color-scheme: dark; --bg:#000; --card:#16161a; --line:#2a2a30; --text:#f4f4f5; --dim:#8b8b93; --accent:#ffd60a; --go:#30d158; }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      body { margin:0; background:var(--bg); color:var(--text); font:16px/1.4 -apple-system, system-ui, sans-serif;
             padding: max(16px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom)); }
      header { display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; }
      h1 { font-size:17px; margin:0; letter-spacing:.02em; }
      #status { color:var(--dim); font-size:13px; text-align:right; }
      .bar { height:4px; background:var(--line); border-radius:2px; overflow:hidden; margin-bottom:18px; }
      .bar > div { height:100%; width:0; background:var(--accent); transition:width .4s; }
      button { font:inherit; color:var(--text); background:var(--card); border:1px solid var(--line); border-radius:16px;
               padding:18px 0; width:100%; touch-action:manipulation; }
      button:active { transform:scale(.97); background:#222228; }
      #play { font-size:22px; font-weight:600; padding:30px 0; margin-bottom:12px; }
      #play.on { background:var(--go); color:#000; border-color:var(--go); }
      .grid { display:grid; grid-template-columns:1fr 1fr 1fr; gap:10px; margin-bottom:10px; }
      h2 { font-size:12px; color:var(--dim); text-transform:uppercase; letter-spacing:.08em; margin:22px 0 8px; }
      #cues button { text-align:left; padding:14px 16px; margin-bottom:8px; border-radius:12px; }
      #cues button.cur { border-color:var(--accent); color:var(--accent); }
      #err { color:#ff453a; font-size:13px; min-height:1em; }
    </style>
    </head>
    <body>
      <header><h1>Reko</h1><div id="status">connecting…</div></header>
      <div class="bar"><div id="progress"></div></div>
      <button id="play" data-cmd="togglePlay">Play</button>
      <div class="grid">
        <button data-cmd="previousCue">⏮ Cue</button>
        <button data-cmd="restart">⤒ Top</button>
        <button data-cmd="nextCue">Cue ⏭</button>
        <button data-cmd="slower">Slower</button>
        <button data-cmd="toggleVisible">Show/Hide</button>
        <button data-cmd="faster">Faster</button>
        <button data-cmd="scrollUp">▲ Back</button>
        <span></span>
        <button data-cmd="scrollDown">▼ Ahead</button>
      </div>
      <div id="err"></div>
      <h2>Cues</h2>
      <div id="cues"></div>
    <script>
      const t = new URLSearchParams(location.search).get('t');
      const $ = id => document.getElementById(id);
      let cueKey = '';
      async function call(method, path) {
        try {
          const r = await fetch(path + '?t=' + encodeURIComponent(t), { method });
          if (!r.ok) throw new Error(r.status);
          render(await r.json()); $('err').textContent = '';
        } catch (e) { $('err').textContent = 'Not connected — is Reko running on the same Wi-Fi?'; }
      }
      function render(s) {
        const counting = s.countdown > 0;
        $('play').textContent = counting ? 'Starting in ' + s.countdown + '…' : (s.playing ? 'Pause' : 'Play');
        $('play').classList.toggle('on', s.playing || counting);
        $('status').textContent = (s.visible ? '' : 'hidden · ') + s.modeTitle + (s.mode === 'speech' ? '' : ' · ' + s.speed + '×');
        $('progress').style.width = Math.round(s.progress * 100) + '%';
        const key = s.sections.join('\n');
        if (key !== cueKey) {
          cueKey = key;
          $('cues').replaceChildren(...s.sections.map((title, i) => {
            const b = document.createElement('button');
            b.textContent = title; b.onclick = () => call('POST', '/api/cue/' + i);
            return b;
          }));
          if (!s.sections.length) $('cues').textContent = 'Start a line with # in your script to add cues.';
        }
        [...$('cues').children].forEach((b, i) => b.classList && b.classList.toggle('cur', i === s.section));
      }
      document.querySelectorAll('[data-cmd]').forEach(b => b.onclick = () => call('POST', '/api/cmd/' + b.dataset.cmd));
      call('GET', '/api/state');
      setInterval(() => { if (!document.hidden) call('GET', '/api/state'); }, 1000);
    </script>
    </body>
    </html>
    """#
}
