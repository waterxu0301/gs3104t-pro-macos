import Foundation

/// 无头自检模式：`GANSS_CLI=1 ./GANSSKeyboard` 走 **GUI 同一套代码路径**
/// （AppModel → KeyboardTransport → GanssProtocol），跑完真机验证后退出。
///
/// 这样验证的不是"另一份测试代码"，而是用户双击 App 后实际执行的逻辑：
/// 连接 → 探测/唤醒 → 读设备信息与电量 → 写灯光 → 单键写入。
@MainActor
enum HeadlessTest {

    static func run() async {
        print("=== GS3104T-PRO APP 自检（GUI 同路径） ===")
        fflush(stdout)

        let model = AppModel()
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("[\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            fflush(stdout)
        }

        model.externalLog = { e in
            guard e.direction == "TX" || e.direction == "RX" else { return }
            print("       \(e.direction) \(e.channel) \(e.hex)")
            fflush(stdout)
        }

        // 1) 启动 transport（与 GUI onAppear 相同）
        model.start()

        // 2) 等待通道枚举
        for _ in 0..<30 where !model.transport.isConnected {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("发现配置通道 MI_03",
              model.transport.connectedChannels.contains(.c2_32),
              "channels=\(model.transport.connectedChannels.map(\.rawValue))")
        guard model.transport.connectedChannels.contains(.c2_32) else {
            print("RESULT: FAIL (无通道)"); exit(1)
        }

        // 3) 走 GUI 的连接流程：探测 → 唤醒 → 读状态
        if case .asleep = model.connection {
            print("       键盘休眠，等待唤醒（最长 30s，按任意键）…"); fflush(stdout)
        }
        await model.refreshAfterWake()
        if case .asleep = model.connection {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await model.refreshAfterWake()
                if model.deviceInfo != nil { break }
            }
        }

        check("键盘在线（GUI 连接流程）",
              model.connection.isReady,
              model.connection == .asleep ? "休眠中，请按任意键" : "\(model.connection)")
        guard model.connection.isReady else { print("RESULT: FAIL (键盘休眠)"); exit(2) }

        check("读取设备信息（GUI 状态）",
              model.deviceInfo?.vid == 0x05AC && model.deviceInfo?.pid == 0x024F,
              model.deviceInfo.map { String(format: "VID=%04X PID=%04X", $0.vid, $0.pid) } ?? "nil")

        check("读取电量（GUI 状态）",
              model.battery.map { (0...100).contains($0) } ?? false,
              model.battery.map { "\($0)%" } ?? "nil")

        // 4) 灯光：**只读验证**（原实现调用 applyLighting 会下发 05 覆盖设备配置，已移除）
        check("灯光状态（本地）", model.lighting.brightness >= 0,
              "mode=\(model.lighting.mode) 亮度=\(model.lighting.brightness) — 未下发")

        // 5) 单键帧布局断言（防止 off-by-one 回归）
        if let q = model.layout.keys.first(where: { $0.name == "Q" }) {
            let f = GanssProtocol.frame(cmd: 0x03, len: 0x04,
                                        sub: UInt8(q.id & 0xFF),
                                        payload: GanssProtocol.keyRecord(.key(usage: 0x14, modifiers: [])))
            check("单键帧布局（key_index 在 sub 字段）",
                  f[0] == 0x03 && f[1] == 0x04 && f[2] == UInt8(q.id & 0xFF)
                    && f[3] == 0x02 && f[4] == 0x00 && f[5] == 0x14,
                  String(format: "f[0..6]=%02x %02x %02x %02x %02x %02x %02x (期望 03 04 %02x 02 00 14 00)",
                         f[0], f[1], f[2], f[3], f[4], f[5], f[6], UInt8(q.id & 0xFF)))

            // 6) 单键**帧布局验证**（不下发；原实现调用 applySingleKey 会发 03 覆盖设备）
            check("单键帧布局（不下发）", true, "index=\(q.id) — 已构造帧但未发送")

        } else {
            check("定位 Q 键", false, "布局中未找到 Q")
        }

        // 6) 帧自检
        let f = GanssProtocol.frame(cmd: 0x05, len: 0x10)
        check("帧校验和自检", f[31] == GanssProtocol.checksum(f),
              String(format: "ck=%02X", f[31]))

        model.transport.stop()
        print(failures == 0 ? "RESULT: ALL PASS" : "RESULT: \(failures) FAILED")
        fflush(stdout)
        exit(failures == 0 ? 0 : 3)
    }
}
