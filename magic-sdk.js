/* ============================================================================
 * magic-sdk.js — Magic Ecosystem Web SDK (v0.3)
 *
 * ДВА ТРАНСПОРТА, ОДИН API:
 *   1) Native  — приложение открыто внутри Magic Hub (нативное iOS-приложение).
 *                Связь с пультом идёт через CoreBluetooth в Swift. Браузера не видно.
 *   2) WebBLE  — приложение открыто в браузере с Web Bluetooth (Bluefy на iOS,
 *                Chrome на Android/ПК). Резервный путь для разработки.
 *
 * Код приложения НЕ меняется — SDK сам выбирает транспорт.
 * Приложение обязано работать и вообще без пульта.
 * ========================================================================== */

const MAGIC_SVC = '7a4d2b10-9c3e-4f18-a6d2-5b1e8c7f0a01';
const MAGIC_CMD = '7a4d2b11-9c3e-4f18-a6d2-5b1e8c7f0a01';
const MAGIC_EVT = '7a4d2b12-9c3e-4f18-a6d2-5b1e8c7f0a01';

const Magic = {
  transport: 'none',          // 'native' | 'webble' | 'none'
  connected: false,
  device: null, server: null, chCmd: null, chEvt: null,

  info: { dev: null, fw: null, pv: null, btn: 0, gestures: [], battery: null, beacon: 0 },
  devices: [],                // Magic Devices, доступные через Hub

  _handlers: { command: [], state: [], status: [], device: [] },
  _queue: Promise.resolve(),
  _lastTap: { btn: null, time: 0 },
  DOUBLE_MS: 350,

  /* ---------- определение среды ---------- */
  _hasNative() {
    return typeof window !== 'undefined' &&
           !!(window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.magichub);
  },
  _hasWebBLE() {
    return typeof navigator !== 'undefined' && !!navigator.bluetooth;
  },
  isSupported() { return this._hasNative() || this._hasWebBLE(); },
  inHub()       { return this._hasNative(); },

  on(event, fn) { if (this._handlers[event]) this._handlers[event].push(fn); return this; },
  _emit(event, data) {
    (this._handlers[event] || []).forEach(fn => {
      try { fn(data); } catch (e) { console.error('[Magic] handler error', e); }
    });
  },

  /* ---------- подключение ---------- */
  async connect() {
    if (this._hasNative()) return this._connectNative();
    if (this._hasWebBLE()) return this._connectWebBLE();
    throw new Error('Нет доступного транспорта. Откройте приложение в Magic Hub.');
  },

  _connectNative() {
    this.transport = 'native';
    this._native({ op: 'connect' });
    return true;      // фактический статус придёт событием
  },

  async _connectWebBLE() {
    this.transport = 'webble';
    this._emit('status', { state: 'connecting' });
    this.device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [MAGIC_SVC] }, { namePrefix: 'Hidra' }],
      optionalServices: [MAGIC_SVC]
    });
    this.device.addEventListener('gattserverdisconnected', () => {
      this.connected = false;
      this._emit('status', { state: 'disconnected' });
    });
    this.server = await this.device.gatt.connect();
    const svc = await this.server.getPrimaryService(MAGIC_SVC);
    this.chCmd = await svc.getCharacteristic(MAGIC_CMD);
    this.chEvt = await svc.getCharacteristic(MAGIC_EVT);
    await this.chEvt.startNotifications();
    this.chEvt.addEventListener('characteristicvaluechanged', e => {
      this._onMessage(new TextDecoder().decode(e.target.value));
    });
    this.connected = true;
    this._emit('status', { state: 'connected', name: this.device.name });
    return true;
  },

  async disconnect() {
    try { await this.setContext('', ''); } catch (e) {}
    if (this.transport === 'native') { this._native({ op: 'disconnect' }); return; }
    if (this.device && this.device.gatt.connected) this.device.gatt.disconnect();
    this.connected = false;
  },

  /* ---------- мост в нативный Hub ---------- */
  _native(payload) {
    try { window.webkit.messageHandlers.magichub.postMessage(payload); }
    catch (e) { console.warn('[Magic] native bridge error', e); }
  },

  /* Вызывается нативным кодом Hub. Не трогать из приложения. */
  _receive(obj) {
    if (typeof obj === 'string') { this._onMessage(obj); return; }
    switch (obj.ev) {
      case 'status':
        this.connected = !!obj.connected;
        if (obj.info) Object.assign(this.info, obj.info);
        this._emit('status', { state: obj.state, info: this.info, battery: obj.battery });
        break;
      case 'message':   this._onMessage(obj.raw); break;
      case 'devices':   this.devices = obj.list || []; this._emit('device', { type: 'list', devices: this.devices }); break;
      case 'device':    this._emit('device', obj); break;
      default: console.log('[Magic] native event', obj);
    }
  },

  /* ---------- разбор сообщений Magic Protocol ---------- */
  _onMessage(raw) {
    let m;
    try { m = JSON.parse(raw); } catch (e) { console.warn('[Magic] bad JSON:', raw); return; }

    switch (m.t) {
      case 'HI':
        this.info.dev = m.dev; this.info.fw = m.fw; this.info.pv = m.pv; this.info.btn = m.btn;
        this._emit('status', { state: 'hello', info: this.info });
        break;
      case 'CAPS':
        this.info.btn = m.btn; this.info.gestures = m.gest || []; this.info.caps = m;
        this._emit('status', { state: 'caps', info: this.info });
        break;
      case 'HB':
        this.info.battery = m.bat; this.info.beacon = m.bc;
        this._emit('status', { state: 'heartbeat', battery: m.bat, beacon: m.bc });
        break;
      case 'EV': {
        if (m.g === 'c') { this._emit('command', { type: 'combo', combo: m.cb }); break; }
        const btn = m.b;
        if (m.g === 'l') { this._emit('command', { type: 'long', button: btn }); break; }
        const now = Date.now();
        if (this._lastTap.btn === btn && (now - this._lastTap.time) < this.DOUBLE_MS) {
          this._lastTap = { btn: null, time: 0 };
          this._emit('command', { type: 'double', button: btn });
        } else {
          this._lastTap = { btn, time: now };
          this._emit('command', { type: 'short', button: btn });
        }
        break;
      }
      case 'ACK': break;
      case 'ERR': console.warn('[Magic] ERROR от пульта:', m); break;
      case 'PONG': break;
      default: console.log('[Magic] неизвестный тип:', m);
    }
  },

  /* ---------- отправка ---------- */
  _send(obj) {
    if (this.transport === 'native') { this._native({ op: 'send', msg: obj }); return Promise.resolve(true); }
    if (!this.connected || !this.chCmd) return Promise.resolve(false);
    const data = new TextEncoder().encode(JSON.stringify(obj));
    this._queue = this._queue
      .then(() => this.chCmd.writeValue(data))
      .then(() => true)
      .catch(err => { console.warn('[Magic] write failed', err); return false; });
    return this._queue;
  },

  /* ---------- публичный API ---------- */
  setContext(app, mode) { return this._send({ t: 'CTX', app: app, mode: mode || '' }); },
  display(l1, l2)       { return this._send({ t: 'DISP', l1: String(l1 || ''), l2: String(l2 || '') }); },
  ping()                { return this._send({ t: 'PING' }); },
  requestStatus()       { return this._send({ t: 'STAT' }); },
  requestCaps()         { return this._send({ t: 'CAPS' }); },
  onCommand(fn)         { return this.on('command', fn); },
  onStatus(fn)          { return this.on('status', fn); },

  /* ---------- Magic Devices (только через Hub) ---------- */
  onDevice(fn)          { return this.on('device', fn); },
  listDevices()         { this._native({ op: 'devices.list' }); return this.devices; },
  deviceCommand(id, command, value) {
    if (!this.inHub()) { console.warn('[Magic] устройства доступны только внутри Magic Hub'); return false; }
    this._native({ op: 'device.cmd', id: id, command: command, value: value === undefined ? null : value });
    return true;
  },
  deviceSetting(id, key, value) {
    if (!this.inHub()) return false;
    this._native({ op: 'device.set', id: id, key: key, value: value });
    return true;
  },
  deviceMode(id, mode) {
    if (!this.inHub()) return false;
    this._native({ op: 'device.mode', id: id, mode: mode });
    return true;
  }
};

if (typeof window !== 'undefined') {
  window.Magic = Magic;
  // Точка входа для нативного Hub
  window.__magicReceive = obj => Magic._receive(obj);
}
