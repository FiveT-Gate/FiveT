import SwiftUI

/// The lightning bolt of Smart Connect, in its row of the VPN tab's list and in its panel.
private struct SmartMark: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.27))
    }
}

/// Smart Connect's row at the top of the VPN tab's list.
struct SmartConnectRow: View {
    @ObservedObject var smart = SmartConnect.shared
    var body: some View {
        HStack(spacing: 8) {
            SmartMark(size: 16)
            Text("Smart Connect").lineLimit(1)
            Spacer(minLength: 0)
            if smart.running { ProgressView().controlSize(.mini) }
        }
        .padding(.vertical, 3)   // the same air as the other rows
        .help("Built in: tests the VPNs that are switched on and connects the one with the best score. It cannot be removed.")
    }
}

/// Smart Connect's panel in the VPN tab: Connect on top, then the VPNs it chooses from (My VPNs, then the built-in ones), each with a switch.
struct SmartConnectTab: View {
    @ObservedObject var smart = SmartConnect.shared
    @ObservedObject var store = ConnectionStore.shared

    var body: some View {
        let entries = smart.entries
        let saved = entries.filter { !$0.builtIn }
        Form {
            Section {
                SmartHeader()
                Toggle("Switch to Another VPN if One Stops Working", isOn: $store.autoFailover)
                Text("If the VPN you are using stays down after a few tries, FiveT connects the next of My VPNs that is switched on below, and keeps going round until one works.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !saved.isEmpty {
                Section("My VPNs") {
                    ForEach(saved) { SmartRow(entry: $0) }
                }
            }
            Section("Built in") {
                ForEach(entries.filter(\.builtIn)) { SmartRow(entry: $0) }
                Text("A VPN that is switched off here is skipped. The check does not touch your connection: V2Ray and Outline servers are tried on the side, Windscribe Max and Express Max use the best result of their last scan, and OpenVPN uses what was measured the last time it was up. Only then the best one is connected. Forti stays as it is.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The built-in services are asked once when the panel opens: "Signed out" and the dots are then true.
        .task { for m in WindscribeMax.all where !m.scanning && m.busy == nil { await m.refresh() } }
    }
}

private struct SmartHeader: View {
    @ObservedObject var smart = SmartConnect.shared
    // Watched so a "Connected to …" notice is redrawn when that VPN goes down.
    @ObservedObject var vpn = VPNManager.shared
    @ObservedObject var windscribe = WindscribeMax.windscribe
    @ObservedObject var express = WindscribeMax.express

    /// The last run's notice, unless it says a VPN is connected that is down by now.
    private var notice: String? {
        guard let id = smart.noticeConnection, !smart.isUp(id) else { return smart.notice }
        return smart.entries.first { $0.id == id }.map { "Disconnected from \($0.name)." }
    }

    var body: some View {
        HStack(spacing: 12) {
            SmartMark(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Smart Connect").font(.headline)
                if smart.running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(smart.step).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let n = notice {
                    Text(n).font(.subheadline).foregroundStyle(smart.noticeIsError ? Color.red : .secondary).lineLimit(2)
                } else {
                    Text("Checks every VPN that is switched on in the background, then connects the one with the best score.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                if smart.running { smart.stop() } else { smart.start() }
            } label: {
                Label(smart.running ? "Stop" : "Connect", systemImage: smart.running ? "stop.fill" : "bolt.fill")
                    .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }
}

private struct SmartRow: View {
    let entry: SmartConnect.Entry
    @ObservedObject var smart = SmartConnect.shared
    @ObservedObject var vpn = VPNManager.shared
    // The built-in services' own state (connected or not) is shown in the dot.
    @ObservedObject var windscribe = WindscribeMax.windscribe
    @ObservedObject var express = WindscribeMax.express

    private var connected: Bool {
        entry.builtIn ? WindscribeMax.service(for: entry.id)?.connected == true : vpn.status(for: entry.id)?.phase == .connected
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(entry.name, isOn: Binding(get: { smart.isOn(entry) }, set: { smart.setOn($0, entry) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(entry.unavailable != nil || smart.running)
            if entry.builtIn, let m = WindscribeMax.service(for: entry.id) {
                WindscribeMark(size: 16, resource: m.backend.logoResource)
            }
            Text(entry.name).lineLimit(1).foregroundStyle(entry.unavailable == nil ? .primary : .secondary)
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Spacer(minLength: 8)
            outcome
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var outcome: some View {
        if let why = entry.unavailable {
            Text(why).font(.subheadline).foregroundStyle(.secondary)
        } else if smart.testing == entry.id {
            ProgressView().controlSize(.small)
        } else if let m = smart.results[entry.id] {
            if let f = m.failure {
                Text(f).font(.subheadline).foregroundStyle(.red).lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    if let s = m.speed { Text(String(format: "%.0f Mbit/s", s)).foregroundStyle(.secondary) }
                    if m.score == nil || smart.winner != entry.id, let n = m.note { Text(n).foregroundStyle(.secondary) }
                    if let sc = m.score {
                        if smart.winner == entry.id {
                            Label("Best · \(sc)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Score \(sc)")
                        }
                    }
                }
                .font(.subheadline.monospacedDigit())
            }
        } else if smart.running && smart.isOn(entry) {
            Text("Waiting").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
