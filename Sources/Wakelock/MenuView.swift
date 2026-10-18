import SwiftUI
import WakelockCore

struct MenuBarLabel: View {
    @ObservedObject var controller: WakeController

    var body: some View {
        Image(systemName: controller.isDegraded ? "exclamationmark.triangle.fill"
              : controller.wantAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
    }
}

struct MenuView: View {
    @ObservedObject var controller: WakeController

    var body: some View {
        let c = controller
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wakelock").font(.headline)
                    Text(c.statusText).font(.caption).foregroundStyle(c.isDegraded ? .orange : .secondary)
                }
                Spacer()
                Toggle("Manual", isOn: Binding(get: { c.session.isOn }, set: { c.setManual($0) }))
                    .toggleStyle(.switch)
                    .disabled(c.blockReason != nil)
            }
            if let reason = c.session.autoOffReason {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Picker("Duration", selection: $controller.duration) {
                ForEach(WakeDuration.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 2) {
                Text("Turn off below \(c.batteryFloor)% battery (when unplugged)").font(.caption)
                Slider(value: Binding(get: { Double(c.batteryFloor) }, set: { c.batteryFloor = Int($0) }),
                       in: 5...80, step: 5)
            }
            Toggle("Stay awake with lid closed", isOn: $controller.closedLidEnabled)
            Toggle("Launch at login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))

            if !c.leases.isEmpty {
                Divider()
                Text("Script leases").font(.subheadline.bold())
                ForEach(c.leases.sorted, id: \.id) { lease in
                    HStack {
                        Text(lease.id).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(WakePolicy.format(lease.expiry.timeIntervalSince(c.now)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { c.release(lease: lease.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).help("Release this lease")
                    }
                }
            }

            Divider()
            Text("Actual system state").font(.subheadline.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Sleep disabled (pmset)", yesNo(c.readback.sleepDisabled),
                    ok: c.readback.sleepDisabled == c.wantDisableSleep)
                row("Idle-sleep assertion", c.assertionHeld ? "held" : "not held", ok: c.assertionHeld == c.wantAwake)
                row("Lid", c.lidClosed.map { $0 ? "closed" : "open" } ?? "n/a")
                row("Battery", c.battery.percent.map { "\($0)% · \(c.battery.onBatteryPower ? "unplugged" : "plugged in")" }
                    ?? "none")
            }
            .font(.caption)

            if c.needsSetup {
                HStack {
                    Label("Lid-closed mode needs a one-time admin approval", systemImage: "lock.fill")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(c.setupInProgress ? "Waiting…" : "Set Up…") { c.runSetup() }
                        .disabled(c.setupInProgress)
                }
            }

            // While setup is pending, the "not set up" pmset error just repeats the row above.
            ForEach([c.needsSetup ? nil : c.pmsetError, c.loginItemError, c.socketError].compactMap { $0 },
                    id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit Wakelock") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 310)
    }

    private func yesNo(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "unknown" }

    private func row(_ label: String, _ value: String, ok: Bool = true) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                if !ok { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
            }
        }
    }
}
