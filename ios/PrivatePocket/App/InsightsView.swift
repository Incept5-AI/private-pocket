import SwiftUI

// MARK: - A finding

struct FindingCard: View {
    let finding: Finding
    let perform: (Finding.Action) -> Void
    /// A wrong guess goes away for this span, before it costs trust.
    let notRight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(finding.tag.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.7)
                .foregroundStyle(finding.tint)
            if let v = finding.visual { FindingVisual(visual: v).accessibilityHidden(true) }
            Text(finding.text)
                .font(.body.weight(.medium)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(finding.choices) { c in
                    Button(c.label) { perform(c.action) }
                        .buttonStyle(.glass)
                        .font(.footnote.weight(.semibold))
                }
                Spacer(minLength: 0)
                Button("Not right", action: notRight)
                    .font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The picture a finding rests on, one small chart each, all in the brand's colours.
struct FindingVisual: View {
    let visual: Finding.Visual

    var body: some View {
        switch visual {
        case .balance(let before, let after, let bl, let al): BalanceBars(before: before, after: after, beforeLabel: bl, afterLabel: al)
        case .ring(let done, let total, let previous): RingView(done: done, total: total, previous: previous)
        case .growth(let open, let labels): GrowthView(open: open, labels: labels)
        case .spike(let intake, let labels, let peak): SpikeView(intake: intake, labels: labels, peak: peak)
        case .timeline(let dates, let window, let settledAt): TimelineStrip(dates: dates, window: window, settledAt: settledAt, labelled: true)
        case .waiting(let rows): WaitingRows(rows: rows)
        case .lapse(let said, let due, let now): LapseView(said: said, due: due, now: now)
        case .pair(let a, let b, let al, let bl): PairBars(a: a, b: b, aLabel: al, bLabel: bl)
        case .step(let fv, let fl, let tv, let tl, let up): StepView(fromValue: fv, fromLabel: fl, toValue: tv, toLabel: tl, up: up)
        case .presence(let present, let labels): PresenceDots(present: present, labels: labels)
        case .hours(let seconds, let decisions): HoursBar(seconds: seconds, decisions: decisions)
        }
    }
}

struct BalanceBars: View {
    let before: Double?
    let after: Double
    let beforeLabel: String
    let afterLabel: String

    var body: some View {
        VStack(spacing: 8) {
            if let before { row(beforeLabel, before, dim: true) }
            row(afterLabel, after, dim: false)
        }
    }

    private func row(_ label: String, _ work: Double, dim: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(Brand.muted).frame(width: 76, alignment: .leading)
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(dim ? Brand.work.opacity(0.4) : Brand.work).frame(width: max(0, g.size.width * work))
                    Rectangle().fill(dim ? Brand.life.opacity(0.4) : Brand.life)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            Text(Findings.pct(work)).font(.caption.monospacedDigit()).foregroundStyle(dim ? Brand.dim : Brand.text).frame(width: 38, alignment: .trailing)
        }
    }
}

struct RingView: View {
    let done: Int
    let total: Int
    let previous: (done: Int, total: Int)?

    private var frac: Double { total > 0 ? Double(done) / Double(total) : 0 }
    private var prevFrac: Double? { previous.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil } }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Brand.hairline, lineWidth: 7)
                Circle().trim(from: 0, to: frac)
                    .stroke(Brand.good, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let prevFrac {
                    Circle().inset(by: 9).stroke(Brand.hairline, lineWidth: 3)
                    Circle().inset(by: 9).trim(from: 0, to: prevFrac)
                        .stroke(Brand.dim, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(done)/\(total)").font(.system(.footnote, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) { Circle().fill(Brand.good).frame(width: 8, height: 8); Text("done, \(Findings.pct(frac))") }
                if let prevFrac { HStack(spacing: 6) { Circle().fill(Brand.dim).frame(width: 8, height: 8); Text("last time, \(Findings.pct(prevFrac))") } }
            }
            .font(.caption).foregroundStyle(Brand.muted)
            Spacer(minLength: 0)
        }
    }
}

struct GrowthView: View {
    let open: [Int]
    let labels: [String]

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let n = open.count
                guard n > 1 else { return }
                let top = max(1, open.max() ?? 1)
                let w = size.width - 16, h = size.height - 16
                func pt(_ i: Int) -> CGPoint { CGPoint(x: w * CGFloat(i) / CGFloat(n - 1), y: 12 + h - h * CGFloat(open[i]) / CGFloat(top)) }
                var line = Path()
                line.move(to: pt(0))
                for i in 1..<n { line.addLine(to: pt(i)) }
                var area = line
                area.addLine(to: CGPoint(x: pt(n - 1).x, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(Brand.act.opacity(0.16)))
                ctx.stroke(line, with: .color(Brand.act), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let last = pt(n - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(Brand.act))
                ctx.draw(Text("\(open[n - 1])").font(.caption.weight(.bold)).foregroundStyle(Brand.text), at: CGPoint(x: last.x + 4, y: last.y - 10), anchor: .bottom)
                if let f = open.firstIndex(where: { $0 > 0 }) {
                    let p = pt(f)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Brand.act))
                    ctx.draw(Text("\(open[f])").font(.caption2).foregroundStyle(Brand.muted), at: CGPoint(x: p.x, y: p.y - 8), anchor: .bottom)
                }
            }
            .frame(height: 64)
            HStack {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i]).font(.caption2).foregroundStyle(Brand.muted)
                    if i < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.trailing, 16)
        }
    }
}

struct SpikeView: View {
    let intake: [Int]
    let labels: [String]
    let peak: Int

    var body: some View {
        let top = max(1, intake.max() ?? 1)
        HStack(alignment: .bottom, spacing: intake.count > 10 ? 3 : 8) {
            ForEach(intake.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    if i == peak { Text("\(intake[i])").font(.caption.weight(.bold)).foregroundStyle(Brand.record) }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i == peak ? Brand.record : Brand.raised)
                        .frame(height: max(3, 48 * CGFloat(intake[i]) / CGFloat(top)))
                    if i < labels.count { Text(labels[i]).font(.caption2).foregroundStyle(i == peak ? Brand.text : Brand.muted) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The moments of a thread as dots along the span; a settled one gets a green dot.
struct TimelineStrip: View {
    let dates: [Date]
    let window: DateInterval
    let settledAt: Date?
    let labelled: Bool

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.hairline).frame(height: 2)
                    ForEach(Array(dates.enumerated()), id: \.offset) { _, d in
                        let f = max(0, min(1, d.timeIntervalSince(window.start) / max(1, window.duration)))
                        let settled = settledAt.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false
                        Circle()
                            .fill(settled ? Brand.good : (settledAt == nil && labelled ? Brand.record : Brand.act))
                            .frame(width: settled ? 11 : 8, height: settled ? 11 : 8)
                            .offset(x: g.size.width * CGFloat(f) - (settled ? 5.5 : 4))
                    }
                }
                .frame(height: 11)
            }
            .frame(height: 11)
            if labelled {
                HStack {
                    Text(window.start.formatted(.dateTime.day().month(.abbreviated)))
                    Spacer()
                    Text(settledAt == nil ? "no decision yet" : "settled")
                        .foregroundStyle(settledAt == nil ? Brand.record : Brand.good)
                    Spacer()
                    Text(window.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated)))
                }
                .font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .padding(.vertical, 3)
    }
}

struct WaitingRows: View {
    let rows: [(name: String, days: Int)]

    var body: some View {
        let top = max(1, rows.map(\.days).max() ?? 1)
        VStack(spacing: 7) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text(rows[i].name).font(.caption).foregroundStyle(Brand.textSecondary).frame(width: 76, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(rows[i].days >= 5 ? Brand.record : Brand.act)
                            .frame(width: max(6, g.size.width * CGFloat(rows[i].days) / CGFloat(top)))
                    }
                    .frame(height: 8)
                    Text("\(rows[i].days) d").font(.caption.monospacedDigit()).foregroundStyle(Brand.muted).frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

/// From the day it was said, past the day it was due, to now.
struct LapseView: View {
    let said: Date
    let due: Date?
    let now: Date

    var body: some View {
        let total = max(1, now.timeIntervalSince(said))
        VStack(spacing: 5) {
            GeometryReader { g in
                let dueX = due.map { g.size.width * CGFloat(max(0, min(1, $0.timeIntervalSince(said) / total))) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.hairline).frame(height: 3)
                    if let dueX {
                        Rectangle().fill(Brand.bad).frame(width: max(0, g.size.width - dueX), height: 3).offset(x: dueX)
                        Rectangle().fill(Brand.record).frame(width: 2, height: 14).offset(x: dueX - 1)
                    }
                    Circle().fill(Brand.dim).frame(width: 8, height: 8)
                    Circle().fill(due == nil ? Brand.record : Brand.bad).frame(width: 8, height: 8).offset(x: g.size.width - 8)
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            HStack {
                Text("said \(Findings.dayName(said))")
                Spacer()
                if let due { Text("due \(Findings.dayName(due))").foregroundStyle(Brand.record); Spacer() }
                Text("now")
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
    }
}

struct PairBars: View {
    let a: Int
    let b: Int
    let aLabel: String
    let bLabel: String

    var body: some View {
        let top = max(1, a, b)
        VStack(spacing: 7) {
            bar(aLabel, a, Brand.record, top)
            bar(bLabel, b, Brand.good, top)
        }
    }

    private func bar(_ label: String, _ v: Int, _ colour: Color, _ top: Int) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(Brand.muted).frame(width: 56, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(colour).frame(width: max(6, g.size.width * CGFloat(v) / CGFloat(top)))
            }
            .frame(height: 10)
            Text("\(v)").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 28, alignment: .trailing)
        }
    }
}

struct StepView: View {
    let fromValue: String
    let fromLabel: String
    let toValue: String
    let toLabel: String
    let up: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fromValue).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(Brand.textSecondary)
                Text(fromLabel).font(.caption).foregroundStyle(Brand.muted)
            }
            StepShape(up: up).stroke(Brand.act, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 44, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(toValue).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(Brand.act)
                Text(toLabel).font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

struct StepShape: Shape {
    let up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = up ? r.maxY - 1 : r.minY + 1, y1 = up ? r.minY + 1 : r.maxY - 1
        p.move(to: CGPoint(x: r.minX, y: y0))
        p.addLine(to: CGPoint(x: r.midX, y: y0))
        p.addLine(to: CGPoint(x: r.midX, y: y1))
        p.addLine(to: CGPoint(x: r.maxX, y: y1))
        return p
    }
}

struct PresenceDots: View {
    let present: [Bool]
    let labels: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(present.indices, id: \.self) { i in
                VStack(spacing: 5) {
                    Circle()
                        .fill(present[i] ? Brand.act : Color.clear)
                        .overlay(Circle().stroke(present[i] ? Brand.act : Brand.dim, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                    if i < labels.count { Text(labels[i]).font(.caption2).foregroundStyle(Brand.muted) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct HoursBar: View {
    let seconds: Int
    let decisions: Int

    var body: some View {
        let scale = max(seconds, 4 * 3600)
        VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.hairline).frame(height: 10)
                    Capsule().fill(Brand.work.opacity(0.75)).frame(width: max(8, g.size.width * CGFloat(seconds) / CGFloat(scale)), height: 10)
                    ForEach(1..<max(2, scale / 3600 + 1), id: \.self) { h in
                        Rectangle().fill(Brand.ground).frame(width: 1, height: 10).offset(x: g.size.width * CGFloat(h * 3600) / CGFloat(scale))
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(Digest.hours(seconds)) in meetings")
                Spacer()
                Text(decisions == 0 ? "no decision" : "\(decisions) decision\(decisions == 1 ? "" : "s")").foregroundStyle(decisions == 0 ? Brand.bad : Brand.good)
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
    }
}

/// Digests kept until the moments they were made from change, so a render costs a
/// hash of the readings rather than a pass over every moment.
final class DigestCache {
    private var entries: [String: (stamp: Int, digest: Digest)] = [:]

    func digest(_ all: [Recording], window: DateInterval) -> Digest {
        let key = "\(window.start.timeIntervalSince1970)/\(window.end.timeIntervalSince1970)"
        let stamp = Self.stamp(all)
        if let e = entries[key], e.stamp == stamp { return e.digest }
        let d = Digest.make(all, window: window)
        entries[key] = (stamp, d)
        return d
    }

    /// Everything a digest depends on, as one hash; the clock in ten-minute steps, since
    /// what needs you depends on it.
    static func stamp(_ all: [Recording]) -> Int {
        var h = Hasher()
        h.combine(all.count)
        h.combine(Int(Date().timeIntervalSince1970 / 600))
        for r in all {
            h.combine(r.id)
            h.combine(r.meta.analysedAt?.timeIntervalSince1970 ?? 0)
            h.combine(r.meta.transcribedAt?.timeIntervalSince1970 ?? 0)
            h.combine(r.meta.labelKind ?? "")
            for i in r.meta.insight?.items ?? [] {
                h.combine(i.done == true); h.combine(i.dismissed == true); h.combine(i.reminderID != nil); h.combine(i.eventID != nil)
            }
        }
        return h.finalize()
    }
}

/// A set of moments opened from a finding, a thread or a person.
struct MomentsFilter: Hashable {
    let title: String
    let ids: [String]
}

struct FilteredMoments: View {
    @EnvironmentObject var library: Library
    let filter: MomentsFilter

    var body: some View {
        let moments = library.recordings.filter { filter.ids.contains($0.id) }
        ScrollView {
            VStack(spacing: 10) {
                ForEach(moments) { r in
                    NavigationLink(value: r.id) { MomentCard(recording: r) }.buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Brand.ground)
        .navigationTitle(filter.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
