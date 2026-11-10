import SwiftUI

struct CorePortRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    let port: Int
    @State private var newPort = ""
    @State private var listener: CorePortListener?
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("新端口", text: $newPort, prompt: Text("新端口"))
                    .liquidInput()
                    .frame(width: 110)
                    .onSubmit(changePort)
                Button("换端口并启动", action: changePort)
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    .disabled(newPort.isEmpty)
            }
            if let error = model.portError {
                Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
            } else {
                Text("更换后，其他设备需使用新端口连接。")
                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
            }
            HStack {
                Button("查看并清理占用者…") {
                    Task {
                        if let owner = await model.inspectConflictingPort(port) {
                            listener = owner
                            confirmStop = true
                        }
                    }
                }
                Button("重试端口 \(port)") { model.launch() }
            }
            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
        }
        .disabled(model.corePortRecoveryBusy)
        .alert("强制停止占用进程？", isPresented: $confirmStop, presenting: listener) { owner in
            Button("取消", role: .cancel) {}
            Button("强制停止并启动", role: .destructive) {
                Task { await model.clearConflictingPort(owner) }
            }
        } message: { owner in
            Text("\(owner.name)（PID \(owner.pid)）正在监听端口 \(owner.port)。强制停止可能中断它正在进行的工作。\n\(owner.executable)")
        }
    }

    private func changePort() {
        guard !newPort.isEmpty else { return }
        model.changeConflictingPort(newPort, from: port)
    }
}
