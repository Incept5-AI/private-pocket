import SwiftUI

/// What the week added up to: time by work and life, open actions, what others
/// promised, what is coming up, and who you talked to. Counted from the sidecars on
/// this iPhone; a model only ever reads one conversation at a time.
struct InsightsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var model: AppModel
    @State private var span = 0   // this week, this month

    private var window: DateInterval {
        Calendar.current.dateInterval(of: span == 0 ? .weekOfYear : .month, for: Date())
            ?? DateInterval(start: .distantPast, end: .distantFuture)
    }
    private var moments: [Recording] { library.recordings.filter { $0.startedAt.map(window.contains) == true } }
    private var unread: [Recording] { moments.filter { $0.meta.transcript != nil && $0.meta.insight?.readByModel != true } }

    private var seconds: (work: Int, life: Int, other: Int) {
        var w = 0, l = 0, o = 0
        for r in moments {
            let s = r.meta.seconds ?? 0
            if r.kind.isWork { w += s } else if r.kind.isLife { l += s } else { o += s }
        }
        return (w, l, o)
    }
    private var actions: [(Recording, String)] {
        moments.flatMap { r in (r.meta.insight?.actions ?? []).filter { !(r.meta.insight?.isAdded($0) ?? false) }.map { (r, $0) } }
    }
    private var promises: [(Recording, String)] {
        moments.flatMap { r in (r.meta.insight?.promises ?? []).map { (r, $0) } }
    }
    private var upcoming: [(Recording, String, Date?)] {
        moments.flatMap { r in (r.meta.insight?.upcoming ?? []).map { (r, $0, Planner.date(in: $0)) } }
            .filter { $0.2.map { $0 > Date() } ?? true }
            .sorted { ($0.2 ?? .distantFuture) < ($1.2 ?? .distantFuture) }
    }
    private var people: [(String, Int)] {
        var counts: [String: Int] = [:]
        for r in moments {
            for p in Set(r.meta.insight?.people ?? Array((r.meta.speakerNames ?? [:]).values)) { counts[p, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(12).map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Span", selection: $span) {
                        Text("This week").tag(0)
                        Text("This month").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if moments.isEmpty {
                        card {
                            Label("Nothing recorded \(span == 0 ? "this week" : "this month") yet.", systemImage: "waveform")
                                .foregroundStyle(Brand.muted)
                        }
                    } else {
                        timeCard
                        if !unread.isEmpty { readCard }
                        listCard("Open actions", symbol: "checkmark.circle", items: actions, empty: "No open actions.") { r, a in
                            Button("Add") { Task { await model.addToReminders(r, action: a) } }
                                .font(.subheadline.weight(.semibold))
                        }
                        listCard("Promised to you", symbol: "hand.raised", items: promises, empty: "Nothing promised yet.") { _, _ in
                            EmptyView()
                        }
                        upcomingCard
                        peopleCard
                    }
                }
                .padding(16)
            }
            .background(Brand.ground)
            .navigationTitle("Insights")
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
        }
    }

    // MARK: Cards

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func heading(_ title: String, symbol: String, count: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.subheadline.weight(.bold)) }
        }
    }

    private static func hours(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60)" : "\(max(1, s / 60)) min"
    }

    private var timeCard: some View {
        let s = seconds
        let total = max(1, s.work + s.life + s.other)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.hours(s.work + s.life + s.other)).font(.system(size: 34, weight: .bold, design: .rounded))
                Text("\(moments.count) \(moments.count == 1 ? "moment" : "moments")").font(.subheadline).foregroundStyle(Brand.muted)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        Rectangle().fill(Brand.work).frame(width: g.size.width * CGFloat(s.work) / CGFloat(total))
                        Rectangle().fill(Brand.life).frame(width: g.size.width * CGFloat(s.life) / CGFloat(total))
                        Rectangle().fill(Brand.hairline)
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                HStack(spacing: 14) {
                    legend(Brand.work, "Work \(Self.hours(s.work))")
                    legend(Brand.life, "Life \(Self.hours(s.life))")
                    if s.other > 0 { legend(Brand.hairline, "Unsorted \(Self.hours(s.other))") }
                }
                .font(.caption).foregroundStyle(Brand.muted)
            }
        }
    }

    private func legend(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var readCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(unread.count) \(unread.count == 1 ? "conversation hasn't" : "conversations haven't") been read yet, so their kind, actions and dates are missing here.")
                    .font(.subheadline).foregroundStyle(Brand.muted)
                if let why = Summariser.availability {
                    Text(why).font(.caption).foregroundStyle(Brand.dim)
                } else {
                    let busy = unread.contains { model.working.contains($0.id) }
                    Button { Task { await model.analyseMissing(unread) } } label: {
                        if busy { HStack { ProgressView(); Text("Reading…") } } else { Text("Read them") }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(busy)
                }
            }
        }
    }

    private func listCard<Trailing: View>(_ title: String, symbol: String, items: [(Recording, String)], empty: String,
                                          @ViewBuilder trailing: @escaping (Recording, String) -> Trailing) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                heading(title, symbol: symbol, count: items.count)
                if items.isEmpty {
                    Text(empty).font(.subheadline).foregroundStyle(Brand.dim)
                } else {
                    ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            NavigationLink(value: item.0.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.1).font(.body)
                                    Text(item.0.quote).font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            trailing(item.0, item.1)
                        }
                    }
                    if items.count > 8 { Text("and \(items.count - 8) more").font(.caption).foregroundStyle(Brand.dim) }
                }
            }
        }
    }

    private var upcomingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                heading("Coming up", symbol: "calendar", count: upcoming.count)
                if upcoming.isEmpty {
                    Text("Nothing coming up was mentioned.").font(.subheadline).foregroundStyle(Brand.dim)
                } else {
                    ForEach(Array(upcoming.prefix(8).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            NavigationLink(value: item.0.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.1).font(.body)
                                    Text(item.2.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? item.0.quote)
                                        .font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            if item.0.meta.insight?.isAdded(item.1) == true {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.good)
                            } else if item.2 != nil {
                                Button("Add") { Task { await model.addToCalendar(item.0, item: item.1) } }
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                }
            }
        }
    }

    private var peopleCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                heading("People", symbol: "person.2")
                if people.isEmpty {
                    Text("Name the speakers on a moment, or let a model read it, and they show up here.")
                        .font(.subheadline).foregroundStyle(Brand.dim)
                } else {
                    FlowChips(items: people.map { "\($0.0) · \($0.1)" })
                }
            }
        }
    }
}

/// Chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.self) { item in
                    chip(item)
                        .alignmentGuide(.leading) { d in
                            if x + d.width > geo.size.width { x = 0; y += rowHeight + 6; rowHeight = 0 }
                            let result = x
                            x += d.width + 6
                            rowHeight = max(rowHeight, d.height)
                            if item == items.last { x = 0 }
                            return -result
                        }
                        .alignmentGuide(.top) { _ in
                            let result = y
                            if item == items.last { y = 0; rowHeight = 0 }
                            return -result
                        }
                }
            }
        }
        .frame(height: CGFloat((items.count + 2) / 3) * 34)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Brand.raised, in: Capsule())
    }
}
