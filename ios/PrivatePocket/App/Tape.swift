import SwiftUI

/// The tape: the record of what was said, laid out in time. A day is bands, one per
/// moment, in the colour of its kind; a week is seven columns on an hour scale; a
/// month is a grid of days; a year is every day as a cell. Each zooms into the next.
enum TapeScale: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
}

enum TapeDays {
    /// "Today", "Yesterday", then the weekday and date.
    static func label(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        return sameYear ? day.formatted(.dateTime.weekday(.wide).day().month(.wide))
                        : day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func id(_ day: Date) -> String { "day-" + day.formatted(.iso8601.year().month().day()) }

    /// Seconds said each day, work and life apart, keyed by the start of the day: built once
    /// for a whole grid, rather than every cell walking every moment.
    struct Totals { var work = 0, life = 0, all = 0 }

    static func totals(_ moments: [Recording]) -> [Date: Totals] {
        let cal = Calendar.current
        var out: [Date: Totals] = [:]
        for r in moments {
            guard let s = r.startedAt else { continue }
            let day = cal.startOfDay(for: s), secs = r.meta.seconds ?? 0, kind = r.kind
            var t = out[day] ?? Totals()
            t.all += secs
            if kind.isWork { t.work += secs }
            if kind.isLife { t.life += secs }
            out[day] = t
        }
        return out
    }

    static func byDay(_ moments: [Recording]) -> [Date: [Recording]] {
        let cal = Calendar.current
        var out: [Date: [Recording]] = [:]
        for r in moments { if let s = r.startedAt { out[cal.startOfDay(for: s), default: []].append(r) } }
        return out
    }

    /// Moments grouped by calendar day, newest day first, newest moment first within it.
    static func grouped(_ all: [Recording]) -> [(day: Date, moments: [Recording])] {
        let cal = Calendar.current
        var byDay: [Date: [Recording]] = [:]
        for r in all {
            guard let s = r.startedAt else { continue }
            byDay[cal.startOfDay(for: s), default: []].append(r)
        }
        var out: [(day: Date, moments: [Recording])] = []
        for day in byDay.keys.sorted(by: >) {
            let moments = byDay[day]!.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            out.append((day: day, moments: moments))
        }
        return out
    }
}

/// The scale control: a visible way to do what the pinch does.
struct TapeScaleControl: View {
    @Binding var scale: TapeScale

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TapeScale.allCases) { s in
                Button { withAnimation(.easeInOut(duration: 0.2)) { scale = s } } label: {
                    Text(s.rawValue)
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(scale == s ? Brand.act : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(scale == s ? Brand.onAct : Brand.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One moment on the tape: the time beside it, the band in its kind's colour, the first
/// thing said, and what it left behind as pins.
struct TapeBand: View {
    let recording: Recording

    private var fill: Color {
        let k = recording.kind
        return k.isWork ? Brand.work : k.isLife ? Brand.life : Brand.raised
    }
    private var ink: Color {
        let k = recording.kind
        return k.isWork ? Brand.onWork : k.isLife ? Brand.onLife : Brand.text
    }
    private var pinFill: Color { recording.kind.isLife ? Brand.onLife : Color.white }
    private var pinInk: Color { recording.kind.isLife ? Brand.life : fill }

    var body: some View {
        let r = recording
        let items = (r.meta.insight?.items ?? []).filter { !$0.isDismissed }
        let todo = items.filter { $0.isAction && !$0.isDone }.count
        let promised = items.filter(\.isPromise).count
        let decided = r.meta.insight?.decisions?.count ?? 0
        let figure = r.meta.insight?.figures?.first
        let meta = [r.people.prefix(2).joined(separator: " · "), r.meta.seconds.map { PocketFacts.length($0) }, r.kind.label.lowercased()]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(alignment: .top, spacing: 10) {
            Text(r.startedAt?.formatted(date: .omitted, time: .shortened) ?? "–")
                .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Brand.muted)
                .frame(width: 48, alignment: .leading).padding(.top, 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(meta.uppercased()).font(.caption2.weight(.bold)).tracking(0.4).foregroundStyle(ink.opacity(0.75)).lineLimit(1)
                Text(r.quote).font(.callout.weight(.bold)).foregroundStyle(ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if todo + promised + decided > 0 || figure != nil {
                    HStack(spacing: 6) {
                        if todo > 0 { pin("\(todo) to do", fill: pinFill, ink: pinInk) }
                        if decided > 0 { pin("\(decided) decided", fill: Brand.act, ink: Brand.onAct) }
                        if promised > 0 { pin("\(promised) promise\(promised == 1 ? "" : "s")", fill: ink.opacity(0.18), ink: ink) }
                        if let f = figure, todo + decided < 3 { pin(f, fill: ink.opacity(0.18), ink: ink) }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func pin(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(fill, in: Capsule()).foregroundStyle(ink)
    }
}

/// Seven columns on an hour scale, for the week that holds `focus`.
struct TapeWeek: View {
    let all: [Recording]
    let focus: Date
    let land: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let week = cal.dateInterval(of: .weekOfYear, for: focus) ?? DateInterval(start: focus, duration: 7 * 86_400)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }
        let byDay = TapeDays.byDay(all)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 0) {
                    ForEach([8, 12, 16, 20], id: \.self) { h in
                        Text(String(format: "%02d", h)).font(.caption2.weight(.bold)).foregroundStyle(Brand.dim)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(width: 22, height: 300)
                ForEach(days, id: \.self) { day in
                    let moments = byDay[cal.startOfDay(for: day)] ?? []
                    let total = moments.map { $0.meta.seconds ?? 0 }.reduce(0, +)
                    Button { land(day) } label: {
                        VStack(spacing: 6) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.bold))
                                .foregroundStyle(cal.isDateInToday(day) ? Brand.record : Brand.muted)
                            ZStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(cal.isDateInToday(day) ? Brand.surface : Brand.surface.opacity(0.6))
                                if cal.isDateInToday(day) { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.record, lineWidth: 2) }
                                ForEach(moments) { r in
                                    if let s = r.startedAt {
                                        let hour = Double(cal.component(.hour, from: s)) + Double(cal.component(.minute, from: s)) / 60
                                        let y = max(0, min(1, (hour - 8) / 12)) * 300
                                        let h = max(4, Double(r.meta.seconds ?? 60) / 3600 / 12 * 300)
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(r.kind.isWork ? Brand.work : r.kind.isLife ? Brand.life : Brand.hairline)
                                            .frame(height: min(h, 300 - y))
                                            .padding(.horizontal, 4)
                                            .offset(y: y)
                                    }
                                }
                            }
                            .frame(height: 300)
                            Text(total > 0 ? PocketFacts.length(total) : "–").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(Brand.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            Text("\(week.start.formatted(.dateTime.day().month(.abbreviated))) to \(week.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated))). Tap a day to land on it.")
                .font(.caption).foregroundStyle(Brand.dim)
        }
    }
}

/// A grid of the month's days, each lit by how much was said and whether it was work or life.
struct TapeMonth: View {
    let all: [Recording]
    let focus: Date
    let land: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: focus) ?? DateInterval(start: focus, duration: 30 * 86_400)
        let first = month.start
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let cells = (0..<(leading + count)).map { i -> Date? in i < leading ? nil : cal.date(byAdding: .day, value: i - leading, to: first) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        let totals = TapeDays.totals(all)
        VStack(alignment: .leading, spacing: 10) {
            Text(first.formatted(.dateTime.month(.wide).year())).font(.headline)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(cal.shortWeekdaySymbols.indices, id: \.self) { i in
                    Text(cal.shortWeekdaySymbols[(i + cal.firstWeekday - 1) % 7].prefix(1)).font(.caption2.weight(.bold)).foregroundStyle(Brand.dim)
                }
                ForEach(cells.indices, id: \.self) { i in
                    if let day = cells[i] {
                        let t = totals[cal.startOfDay(for: day)] ?? TapeDays.Totals()
                        let work = t.work, life = t.life, total = t.all
                        let tint: Color = total == 0 ? Brand.surface : (work >= life ? Brand.work : Brand.life).opacity(min(1, 0.35 + Double(total) / 7200))
                        Button { land(day) } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint).aspectRatio(1, contentMode: .fit)
                                if cal.isDateInToday(day) { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.record, lineWidth: 2) }
                                Text(day.formatted(.dateTime.day())).font(.caption2.weight(.bold))
                                    .foregroundStyle(total == 0 ? Brand.dim : (work >= life ? Brand.onWork : Brand.onLife))
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            Text("Brighter is more said. Tap a day to land on it.").font(.caption).foregroundStyle(Brand.dim)
        }
    }
}

/// Every day of the year as a cell, a row per month, with on this day a year ago.
struct TapeYear: View {
    let all: [Recording]
    let focus: Date
    let land: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let year = cal.component(.year, from: focus)
        let total = all.filter { $0.startedAt.map { cal.component(.year, from: $0) == year } == true }
        let seconds = total.map { $0.meta.seconds ?? 0 }.reduce(0, +)
        let totals = TapeDays.totals(total)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(year)).font(.headline)
                Spacer()
                Text("\(Digest.hours(seconds)) of talk · \(total.count) moments").font(.caption).foregroundStyle(Brand.muted)
            }
            ForEach(1...12, id: \.self) { m in
                let monthStart = cal.date(from: DateComponents(year: year, month: m, day: 1)) ?? focus
                let days = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
                HStack(spacing: 6) {
                    Text(monthStart.formatted(.dateTime.month(.abbreviated))).font(.caption2.weight(.bold)).foregroundStyle(Brand.muted).frame(width: 28, alignment: .leading)
                    HStack(spacing: 2) {
                        ForEach(1...days, id: \.self) { d in
                            let day = cal.date(from: DateComponents(year: year, month: m, day: d)) ?? focus
                            let t = totals[cal.startOfDay(for: day)] ?? TapeDays.Totals()
                            let work = t.work, life = t.life, secs = t.all
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cal.isDateInToday(day) ? Brand.record : secs == 0 ? Brand.surface : (work >= life ? Brand.work : Brand.life).opacity(min(1, 0.35 + Double(secs) / 5400)))
                                .frame(maxWidth: .infinity)
                                .frame(height: 18)
                                .onTapGesture { land(day) }
                                .accessibilityElement()
                                .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (secs > 0 ? ", \(PocketFacts.length(secs))" : ", nothing recorded"))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { land(day) }
                        }
                        if days < 31 { ForEach(days..<31, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity).frame(height: 18) } }
                    }
                }
            }
            if let ago = cal.date(byAdding: .year, value: -1, to: Date()),
               let then = all.first(where: { $0.startedAt.map { cal.isDate($0, inSameDayAs: ago) } == true }) {
                NavigationLink(value: then.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ON THIS DAY, LAST YEAR").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Brand.onNotice.opacity(0.7))
                        Text(then.quote).font(.callout.weight(.bold)).foregroundStyle(Brand.onNotice)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.notice, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            Text("Tap a day to land on it.").font(.caption).foregroundStyle(Brand.dim)
        }
    }
}
