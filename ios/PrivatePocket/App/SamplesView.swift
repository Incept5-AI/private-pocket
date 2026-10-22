import SwiftUI

/// Settings → Try it → Sample moments: add the bundled samples, watch each one get
/// transcribed and read, and see whether it was read as the kind it was meant to be.
struct SamplesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @State private var running = false

    private var samples: [SampleMoment] { SampleMoments.all() }
    private var added: [(SampleMoment, Recording)] { samples.compactMap { s in model.sampleRecording(s).map { (s, $0) } } }
    private var read: [(SampleMoment, Recording)] { added.filter { $0.1.meta.insight?.readByModel == true } }
    private var right: Int { read.filter { $0.0.kind == $0.1.meta.insight?.kind }.count }

    private var readingLabel: String {
        let c = LLM.config
        return c.remote ? "\(c.model) on \(c.host)" : "On this iPhone"
    }

    var body: some View {
        List {
            Section {
                if added.isEmpty {
                    Text("Eight short conversations, one of each kind, spoken by synthetic voices and stored the way the Pocket stores them. Add them and they go through everything a real recording does.")
                        .font(.subheadline).foregroundStyle(Brand.muted)
                } else {
                    LabeledContent("Read as expected", value: read.isEmpty ? "–" : "\(right) of \(read.count)")
                    LabeledContent("Speech to text", value: Prefs.sttRemoteNow ? "\(Prefs.sttModel) on the server" : "On this iPhone")
                    LabeledContent("Reading", value: readingLabel)
                }
                Button {
                    running = true
                    Task { await model.addSamples(); running = false }
                } label: {
                    if running {
                        HStack { ProgressView(); Text("Working…") }
                    } else {
                        Label(added.isEmpty ? "Add sample moments" : "Add the missing ones", systemImage: "plus")
                    }
                }
                .disabled(running || added.count == samples.count)
            } footer: {
                Text("They are dated over the last few hours, so they show on today, in Moments and in this week's Insights. Each is transcribed and read in turn; a tick means it was read as the kind it was meant to be.")
            }
            Section("Samples") {
                ForEach(samples) { s in
                    if let r = model.sampleRecording(s) {
                        NavigationLink(value: r.id) { row(s, r) }
                    } else {
                        row(s, nil)
                    }
                }
            }
            if !added.isEmpty {
                Section {
                    Button {
                        running = true
                        Task { await model.rerunSamples(); running = false }
                    } label: { Label("Transcribe and read again", systemImage: "arrow.clockwise") }
                        .disabled(running)
                    Button("Remove sample moments", role: .destructive) { model.removeSamples() }
                        .disabled(running)
                } footer: {
                    Text("Again runs with the current settings, so this iPhone and your server can be compared on the same eight.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .navigationTitle("Sample moments")
        .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
    }

    private func row(_ s: SampleMoment, _ r: Recording?) -> some View {
        let expected = MomentKind(rawValue: s.kind) ?? .other
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title)
                HStack(spacing: 6) {
                    KindChip(kind: expected)
                    if let i = r?.meta.insight, i.readByModel {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Brand.dim)
                        KindChip(kind: i.momentKind)
                    }
                }
            }
            Spacer()
            status(r)
        }
    }

    @ViewBuilder private func status(_ r: Recording?) -> some View {
        if let r {
            if model.working.contains(r.id) {
                ProgressView().controlSize(.small)
            } else if r.meta.transcript == nil {
                Text("Not transcribed").font(.caption).foregroundStyle(Brand.muted)
            } else if let i = r.meta.insight, i.readByModel {
                let ok = i.kind == r.meta.expectedKind
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? Brand.good : Brand.bad)
            } else {
                Text("Not read").font(.caption).foregroundStyle(Brand.muted)
            }
        } else {
            Text("Not added").font(.caption).foregroundStyle(Brand.dim)
        }
    }
}
