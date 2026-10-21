import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(ThirdWaveFormats)
import ThirdWaveFormats
#endif

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $state.section) {
                    ForEach(AppState.Section.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(s)
                    }
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            } detail: {
                switch state.section ?? .pack {
                case .pack: PackView()
                case .unpack: UnpackView()
                case .slots: SlotsView()
                }
            }
            Divider()
            LogBar(showLog: $showLog)
        }
        .frame(minWidth: 960, minHeight: 600)
        .alert("pgdata Packer", isPresented: Binding(
            get: { state.alertMessage != nil }, set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("OK") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }
}

// MARK: - Log

struct LogBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showLog: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { showLog.toggle() } label: {
                    Image(systemName: showLog ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(state.log.last ?? "Drop .pro, .wt, .bin or .pgdata files anywhere in the window.")
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if showLog {
                ScrollView {
                    Text(state.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
            }
        }
    }
}

// MARK: - Drop support

enum DropSupport {
    static func load(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var u: URL?
                if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) }
                else if let x = item as? URL { u = x }
                if let u { lock.lock(); urls.append(u); lock.unlock() }
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

struct EmptyHint: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Shared bits

struct StatusText: View {
    let status: PackPlan.Status
    var body: some View {
        switch status {
        case .ok(let s): Text(s).foregroundStyle(.secondary)
        case .warning(let s): Label(s, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .missing(let s): Label(s, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

struct VerdictBadge: View {
    let verdict: PackPlan.Verdict
    var body: some View {
        switch verdict {
        case .factoryOnly:
            Label("Factory content only — nothing to embed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .embedsContent:
            Label("Embeds wavetables or samples", systemImage: "shippingbox.fill").foregroundStyle(.blue)
        case .blocked(let refs):
            Label("Missing content for " + refs.map(\.label).joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

extension PackPlan.Verdict {
    var symbol: String {
        switch self {
        case .factoryOnly: return "checkmark.circle"
        case .embedsContent: return "shippingbox.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .factoryOnly: return .secondary
        case .embedsContent: return .blue
        case .blocked: return .red
        }
    }
}
