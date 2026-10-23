import EventKit
import SwiftUI
import UserNotifications

/// The brief before: what is open with whoever is next on the calendar, ready a few
/// minutes ahead, on the Lock Screen and at the top of Now.
struct Brief: Identifiable {
    let event: EKEvent
    let person: Digest.Person
    /// What they said they would do, still open.
    let theirs: [NextItem]
    /// What you owe them, still open.
    let yours: [(Recording, NextItem)]
    /// The last time you spoke.
    let last: Recording?
    /// The last figure that came up with them.
    let figure: String?

    var id: String { event.eventIdentifier ?? event.title ?? UUID().uuidString }
    var count: Int { theirs.count + yours.count + (figure == nil ? 0 : 1) }
    var start: Date { event.startDate }
    var minutesAway: Int { max(0, Int(start.timeIntervalSinceNow / 60)) }
}

enum Briefs {
    static var calendarAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Events in the next `hours` that name someone the readings know, with what stands open.
    static func upcoming(_ all: [Recording], hours: Double = 3) -> [Brief] {
        guard calendarAllowed else { return [] }
        let people = Digest.people(all, limit: 80)
        guard !people.isEmpty else { return [] }
        let events = Planner.events(from: Date().addingTimeInterval(-10 * 60), to: Date().addingTimeInterval(hours * 3600))
        var out: [Brief] = []
        for e in events where !e.isAllDay {
            let hay = [e.title, e.notes, e.location].compactMap { $0 }.joined(separator: " ")
                + " " + (e.attendees ?? []).compactMap(\.name).joined(separator: " ")
            let named = people.filter { p in
                let first = p.name.split(separator: " ").first.map(String.init) ?? p.name
                return hay.range(of: "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
            }
            guard let p = named.max(by: { $0.moments.count < $1.moments.count }) else { continue }
            out.append(make(p, event: e))
        }
        return out.sorted { $0.start < $1.start }
    }

    static func make(_ p: Digest.Person, event: EKEvent) -> Brief {
        let theirs = p.waitingOn.filter { !$0.isDone && !$0.isDismissed }
        let yours: [(Recording, NextItem)] = p.moments.flatMap { r in
            (r.meta.insight?.items ?? []).filter { $0.isAction && !$0.isDone && !$0.isDismissed && $0.text.localizedCaseInsensitiveContains(p.name) }.map { (r, $0) }
        }
        let last = p.moments.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        return Brief(event: event, person: p, theirs: theirs, yours: yours, last: last, figure: last?.meta.insight?.figures?.first)
    }

    /// A notification ten minutes before each brief in the next day; one per event.
    static func schedule(_ all: [Recording]) {
        let briefs = upcoming(all, hours: 24)
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            centre.getPendingNotificationRequests { pending in
                let have = Set(pending.map(\.identifier))
                for b in briefs {
                    let fire = b.start.addingTimeInterval(-10 * 60)
                    guard fire > Date(), !have.contains("brief-" + b.id) else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "\(b.person.name), at \(b.start.formatted(date: .omitted, time: .shortened))"
                    content.body = line(b)
                    content.sound = nil
                    content.interruptionLevel = .timeSensitive
                    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    let req = UNNotificationRequest(identifier: "brief-" + b.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                    centre.add(req)
                }
            }
        }
    }

    static func allowNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
    }

    /// The brief in one line, for the Lock Screen and the block.
    static func line(_ b: Brief) -> String {
        var parts: [String] = []
        if let t = b.theirs.first { parts.append("\(b.person.name) said: \(t.text.lowercased())" + (b.theirs.count > 1 ? ", and \(b.theirs.count - 1) more" : "")) }
        if let y = b.yours.first { parts.append("you owe: \(y.1.text.lowercased())") }
        if let f = b.figure, parts.count < 2 { parts.append("last figure: \(f)") }
        if parts.isEmpty, let l = b.last, let s = l.startedAt { parts.append("last spoke \(Findings.dayName(s)): \(l.quote)") }
        return parts.joined(separator: ". ").capitalizedFirst + "."
    }
}

/// A notification now: an answer the card gave, for a phone that is in a bag.
enum Notify {
    static func now(title: String, body: String) {
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                centre.requestAuthorization(options: [.alert, .badge]) { ok, _ in if ok { send() } }
            } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                send()
            }
        }
        func send() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.interruptionLevel = .timeSensitive
            centre.add(UNNotificationRequest(identifier: "card-" + UUID().uuidString, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
    }
}

/// The brief, as its own screen: the name large on teal, the things open, and the last call.
struct BriefView: View {
    @Environment(\.dismiss) private var dismiss
    let brief: Brief

    var body: some View {
        let b = brief
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text((b.minutesAway == 0 ? "Now" : "In \(b.minutesAway) minutes") + " · " + (b.event.title ?? "a meeting"))
                        .font(.caption.weight(.bold)).tracking(1).textCase(.uppercase).opacity(0.7)
                    Text(b.person.name + ".").font(.system(size: 64, weight: .bold)).tracking(-2).lineLimit(2).minimumScaleFactor(0.6)
                    Text(b.count == 0 ? "Nothing open between you." : "\(b.count) thing\(b.count == 1 ? "" : "s") open." + (b.last?.startedAt.map { " You last spoke \(Findings.dayName($0))." } ?? ""))
                        .font(.title3.weight(.bold)).lineSpacing(2)
                    Rectangle().fill(Brand.onAct.opacity(0.25)).frame(height: 2)
                    VStack(alignment: .leading, spacing: 18) {
                        var n = 0
                        ForEach(b.theirs) { t in
                            let _ = { n += 1 }()
                            row(n, "\(b.person.name) said they'd \(t.text.lowercased()).", t.when.map { "Promise · \($0)" } ?? "Promise, still open")
                        }
                        ForEach(Array(b.yours.enumerated()), id: \.offset) { i, pair in
                            row(b.theirs.count + i + 1, "You owe: \(pair.1.text.lowercased()).", pair.0.startedAt.map { "Your to-do, from \(Findings.dayName($0))" } ?? "Your to-do")
                        }
                        if let f = b.figure {
                            row(b.theirs.count + b.yours.count + 1, "Last figure: \(f).", b.last?.startedAt.map { "Said \(Findings.dayName($0))" } ?? "")
                        }
                    }
                    if let last = b.last {
                        NavigationLink(value: last.id) {
                            HStack(spacing: 10) {
                                Image(systemName: "play.fill").foregroundStyle(Brand.record)
                                Text("Hear the last" + (last.meta.seconds.map { " · \(PocketFacts.length($0))" } ?? "")).font(.subheadline.weight(.bold))
                            }
                            .padding(.horizontal, 18).padding(.vertical, 13)
                            .background(Brand.onAct, in: Capsule()).foregroundStyle(Brand.act)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
                .padding(24).padding(.top, 8)
            }
            .background(Brand.act.ignoresSafeArea())
            .foregroundStyle(Brand.onAct)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.subheadline.weight(.bold)).tint(Brand.onAct)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: ThreadLink.self) { ThreadView(id: $0.id) }
        }
    }

    private func row(_ n: Int, _ text: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.callout.weight(.bold)).frame(width: 36, height: 36)
                .background(Brand.onAct, in: Circle()).foregroundStyle(Brand.act)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.body.weight(.semibold)).lineSpacing(1)
                if !sub.isEmpty { Text(sub).font(.footnote).opacity(0.75) }
            }
        }
    }
}
