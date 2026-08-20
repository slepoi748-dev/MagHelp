/* ============================================================================
 * magic-sdk.js — Magic Ecosystem Web SDK (v0.2)
 * Подключение Web App к пульту Hidra S3 по Magic Protocol через Web Bluetooth.
 *
 * ВАЖНО: Web Bluetooth НЕ работает в Safari на iOS.
 * На iPhone открывать в браузере Bluefy (App Store) — он поддерживает Web BLE.
 * На Android/Windows/Mac — обычный Chrome.
 * Требуется HTTPS (или localhost) и вызов connect() по клику пользователя.
 *
 * Приложение ДОЛЖНО работать и без пульта. SDK — необязательный слой.
 * ========================================================================== */

const MAGIC_SVC = '7a4d2b10-9c3e-4f18-a6d2-5b1e8c7f0a01';
const MAGIC_CMD = '7a4d2b11-9c3e-4f18-a6d2-5b1e8c7f0a01';
const MAGIC_EVT = '7a4d2b12-9c3e-4f18-a6d2-5b1e8c7f0a01';

const Magic = {
  device: null,
  server: null,
  chCmd: null,
  chEvt: null,
  connected: false,

  // информация об устройстве (из HELLO / CAPS)
  info: { dev: null, fw: null, pv: null, btn: 0, gestures: [], battery: null, beacon: 0 },

  // пользовательские колбэки
  _handlers: { command: [], state: [], status: [] },

  // очередь записи (BLE не любит параллельные writes)
  _queue: Promise.resolve(),

  // сборка double-tap на стороне Hub (в firmware намеренно не делается)
  _lastTap: { btn: null, time: 0 },
  DOUBLE_MS: 350,

  isSupported() {
    return typeof navigator !== 'undefined' && !!navigator.bluetooth;
  },

  on(event, fn) {
    if (this._handlers[event]) this._handlers[event].push(fn);
    return this;
  },
  _emit(event, data) {
    (this._handlers[event] || []).forEach(fn => {
      try { fn(data); } catch (e) { console.error('[Magic] handler error', e); }
    });
  },

  async connect() {
    if (!this.isSupported()) {
      throw new Error('Web Bluetooth недоступен. На iPhone откройте страницу в браузере Bluefy.');
    }
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
    if (this.device && this.device.gatt.connected) this.device.gatt.disconnect();
    this.connected = false;
  },

  _onMessage(raw) {
    let m;
    try { m = JSON.parse(raw); } catch (e) { console.warn('[Magic] bad JSON:', raw); return; }

    switch (m.t) {
      case 'HI':                                   // HELLO
        this.info.dev = m.dev; this.info.fw = m.fw; this.info.pv = m.pv;
        this.info.btn = m.btn;
        this._emit('status', { state: 'hello', info: this.info });
        break;

      case 'CAPS':                                 // CAPABILITIES
        this.info.btn = m.btn;
        this.info.gestures = m.gest || [];
        this.info.caps = m;
        this._emit('status', { state: 'caps', info: this.info });
        break;

      case 'HB':                                   // HEARTBEAT
        this.info.battery = m.bat;
        this.info.beacon = m.bc;
        this._emit('status', { state: 'heartbeat', battery: m.bat, beacon: m.bc });
        break;

      case 'EV': {                                 // EVENT — ввод с пульта
        if (m.g === 'c') {                         // комбинация двух кнопок
          this._emit('command', { type: 'combo', combo: m.cb });
          break;
        }
        const btn = m.b;
        if (m.g === 'l') {                         // длинное удержание
          this._emit('command', { type: 'long', button: btn });
          break;
        }
        // короткое нажатие: собираем double-tap здесь, на стороне Hub
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

  _write(obj) {
    if (!this.connected || !this.chCmd) return Promise.resolve(false);
    const data = new TextEncoder().encode(JSON.stringify(obj));
    // очередь: гарантирует последовательную отправку
    this._queue = this._queue
      .then(() => this.chCmd.writeValue(data))
      .then(() => true)
      .catch(err => { console.warn('[Magic] write failed', err); return false; });
    return this._queue;
  },

  /* --- публичный API (соответствует conceptual_api из ТЗ) --- */

  setContext(app, mode) { return this._write({ t: 'CTX', app: app, mode: mode || '' }); },
  display(l1, l2)       { return this._write({ t: 'DISP', l1: String(l1 || ''), l2: String(l2 || '') }); },
  ping()                { return this._write({ t: 'PING' }); },
  requestStatus()       { return this._write({ t: 'STAT' }); },
  requestCaps()         { return this._write({ t: 'CAPS' }); },
  onCommand(fn)         { return this.on('command', fn); },
  onStatus(fn)          { return this.on('status', fn); }
};

window.Magic = Magic;
