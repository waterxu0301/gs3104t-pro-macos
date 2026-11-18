// ============================================================
// GANSS 官方网页驱动 WebHID Hook
// 用途：在 https://ganss.driveall.cn/#/ 页面的 Chrome DevTools
//       Console 中粘贴执行（或在 Tampermonkey 中 @run-at document-start）。
// 作用：
//   1. 放行 05AC:024F (DSM24 批次 GS3104T-PRO 2.4G) 的 HID 授权请求
//   2. 伪装 HIDDevice 属性，绕过页面按 productName/serial 的过滤
//   3. 全量打印 sendReport / sendFeatureReport / inputreport 收发报文
// ============================================================
(function () {
  'use strict';

  const TARGET_VID = 0x05AC, TARGET_PID = 0x024F;
  const SPOOF = {
    vendorId: 1452, productId: 591,          // 1452:591 = 官方白名单中的 GS3104T-PRO 2.4G
    productName: 'GS3104T-PRO 2.4G',
    serialNumber: 'DSMW00000000000000',       // DSMW 前缀伪造（保险起见）
  };

  const hex = (b) => Array.from(new Uint8Array(b.buffer || b))
    .map(v => v.toString(16).padStart(2, '0')).join(' ');
  const tag = ' %[GANS-Hook]%';

  // ---- 1. requestDevice：合并目标设备进 filters 结果 ----
  const origRequest = navigator.hid.requestDevice.bind(navigator.hid);
  navigator.hid.requestDevice = async (options = {}) => {
    const real = await origRequest(options);
    const extra = await origRequest({
      filters: [{ vendorId: TARGET_VID, productId: TARGET_PID }],
    });
    const merged = [...real, ...extra.filter(d => !real.includes(d))];
    console.log(tag + ' requestDevice: real=' + real.length + ' extra=' + extra.length);
    return merged;
  };

  // ---- 2. getDevices 同样补录 ----
  const origGet = navigator.hid.getDevices.bind(navigator.hid);
  navigator.hid.getDevices = async () => {
    const real = await origGet();
    const extra = await origGet();
    return [...real, ...extra.filter(d => !real.includes(d))];
  };

  // ---- 3. 伪装 HIDDevice 实例属性 + 报文打印 ----
  const origOpen = HIDDevice.prototype.open;
  HIDDevice.prototype.open = async function (...args) {
    const r = await origOpen.apply(this, args);
    if (this.vendorId === TARGET_VID && this.productId === TARGET_PID) {
      console.log(tag + ' opened target device; spoofing identity →', SPOOF);
      for (const [k, v] of Object.entries(SPOOF)) {
        Object.defineProperty(this, k, { get: () => v, configurable: true });
      }
      // collections 伪装为 GS3104T-PRO 的 vendor 页（若页面检查）
      Object.defineProperty(this, 'collections', {
        get: () => [{
          usagePage: 0xFF60, usage: 0x61,
          inputReports: [{ reportCount: 32 }],
          outputReports: [{ reportCount: 32 }],
          featureReports: [{ reportCount: 64 }],
        }],
        configurable: true,
      });
      // ---- 报文观测 ----
      const origSend = this.sendReport.bind(this);
      this.sendReport = async (id, data) => {
        console.log(tag + ` SEND rep=${id} [${hex(data)}]`);
        return origSend(id, data);
      };
      const origSendF = this.sendFeatureReport.bind(this);
      this.sendFeatureReport = async (id, data) => {
        console.log(tag + ` SEND-F rep=${id} [${hex(data)}]`);
        return origSendF(id, data);
      };
      this.addEventListener('inputreport', (e) => {
        console.log(tag + ` RECV rep=${e.reportId} [${hex(e.data)}]`);
      });
    }
    return r;
  };

  console.log(tag + ' installed. 请刷新页面后连接键盘。');
})();
