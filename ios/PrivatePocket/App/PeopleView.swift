import SwiftUI

/// People: a map of who you talk to. Size is time spoken, distance is recency, a ring
/// is something owed either way. Tap one for the whole relationship.
struct PeopleView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var threads: ThreadStore
    @State private var selected: String?
    @State private var asList = false
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        let all = library.recordings
        let people = Digest.people(all, limit: 24)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("People").font(.largeTitle.weight(.bold)).tracking(-0.5)
                        Spacer()
                        Button(asList ? "Map" : "List") { withAnimation { asList.toggle() } }.font(.subheadline.weight(.bold))
                    }
                    .padding(.top, 8)
                    if people.isEmpty {
                        Text("People appear as the reader names them. Rename a speaker on a moment and they show here.")
                            .font(.subheadline).foregroundStyle(Brand.muted)
                    } else if asList {
                        ForEach(people) { p in
                            NavigationLink(value: p.name) { PersonRow(person: p) }.buttonStyle(.plain)
                                .contextMenu { PersonMenuItems(name: p.name, others: people.map(\.name), renaming: $renaming, newName: $newName) }
                        }
                    } else {
                        PeopleMap(people: people, selected: $selected)
                        Text("Bigger: more time talking. Closer: more recent. Amber ring: something owed.").font(.caption).foregroundStyle(Brand.dim)
                        if let s = selected ?? people.first?.name, let p = people.first(where: { $0.name == s }) {
                            PersonCard(person: p)
                                .contextMenu { PersonMenuItems(name: p.name, others: people.map(\.name), renaming: $renaming, newName: $newName) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(Brand.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { name in
                if let p = Digest.people(all, limit: 200).first(where: { $0.name == name }) { PersonView(person: p) } else { RecordingDetail(id: name) }
            }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
            .navigationDestination(for: ThreadLink.self) { ThreadView(id: $0.id) }
            .modifier(PersonRenaming(renaming: $renaming, newName: $newName))
        }
    }
}

/// Rename, the same person as another, not a person: on a person, anywhere.
struct PersonMenuItems: View {
    @EnvironmentObject var threads: ThreadStore
    let name: String
    let others: [String]
    @Binding var renaming: String?
    @Binding var newName: String
    var done: (() -> Void)? = nil

    var body: some View {
        Button { newName = name; renaming = name } label: { Label("Rename", systemImage: "pencil") }
        let rest = others.filter { $0 != name }.prefix(10)
        if !rest.isEmpty {
            Menu {
                ForEach(Array(rest), id: \.self) { o in
                    Button(o) { withAnimation { threads.samePerson(name, as: o) }; done?() }
                }
            } label: { Label("Same person as…", systemImage: "person.2") }
        }
        Button(role: .destructive) { withAnimation { threads.notAPerson(name) }; done?() } label: { Label("Not a person", systemImage: "xmark") }
    }
}

struct PersonRenaming: ViewModifier {
    @EnvironmentObject var threads: ThreadStore
    @Binding var renaming: String?
    @Binding var newName: String
    var done: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let n = renaming { threads.renamePerson(n, to: newName) }
                done?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every moment that names them shows the new name. Give the name of someone already here to make them one person.")
        }
    }
}

extension Digest.Person {
    var seconds: Int { moments.map { $0.meta.seconds ?? 0 }.reduce(0, +) }
    var isWork: Bool { moments.filter { $0.kind.isWork }.count >= moments.filter { $0.kind.isLife }.count }
    var owed: Bool { waitingOn.contains { !$0.isDone } || youOwe > 0 }
    var daysSince: Int { lastSeen.map { Int(Date().timeIntervalSince($0) / 86_400) } ?? 999 }
}

/// The map: the most talked-to at the centre, the rest around them by recency.
struct PeopleMap: View {
    let people: [Digest.Person]
    @Binding var selected: String?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h: CGFloat = 340
            let c = CGPoint(x: w / 2, y: h / 2)
            let maxSec = max(1, people.map(\.seconds).max() ?? 1)
            ZStack {
                ForEach(Array(people.enumerated()), id: \.element.id) { i, p in
                    let pos = position(i, p, centre: c, w: w, h: h)
                    if i > 0 {
                        Path { path in path.move(to: c); path.addLine(to: pos) }
                            .stroke(Brand.raised, lineWidth: 2)
                    }
                }
                ForEach(Array(people.enumerated()), id: \.element.id) { i, p in
                    let pos = position(i, p, centre: c, w: w, h: h)
                    let size = 40 + 50 * CGFloat(p.seconds) / CGFloat(maxSec)
                    Button { withAnimation(.spring(duration: 0.3)) { selected = p.name } } label: {
                        Text(p.name.split(separator: " ").first.map(String.init) ?? p.name)
                            .font(.system(size: size > 70 ? 17 : size > 50 ? 14 : 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: size, height: size)
                            .background(p.isWork ? Brand.work : Brand.life, in: Circle())
                            .foregroundStyle(p.isWork ? Brand.onWork : Brand.onLife)
                            .overlay(Circle().strokeBorder(Brand.ground, lineWidth: p.owed ? 4 : 0))
                            .overlay(Circle().strokeBorder(Brand.record, lineWidth: p.owed ? 3 : 0).padding(-4))
                            .overlay(Circle().strokeBorder(Brand.text, lineWidth: selected == p.name ? 2 : 0).padding(-9))
                    }
                    .buttonStyle(.plain)
                    .position(pos)
                    .accessibilityLabel("\(p.name), \(p.moments.count) moments")
                }
            }
        }
        .frame(height: 340)
    }

    private func position(_ i: Int, _ p: Digest.Person, centre c: CGPoint, w: CGFloat, h: CGFloat) -> CGPoint {
        guard i > 0 else { return c }
        let angle = Double(i) * 2.399963 + 0.6   // the golden angle spreads them evenly
        let radius = 80 + min(60, CGFloat(p.daysSince) * 2)
        let x = c.x + CGFloat(cos(angle)) * min(radius, w / 2 - 36)
        let y = c.y + CGFloat(sin(angle)) * min(radius, h / 2 - 36)
        return CGPoint(x: x, y: y)
    }
}

struct PersonRow: View {
    let person: Digest.Person

    var body: some View {
        HStack(spacing: 12) {
            Text(String(person.name.prefix(1)).uppercased()).font(.subheadline.weight(.bold))
                .frame(width: 40, height: 40)
                .background(person.isWork ? Brand.work : Brand.life, in: Circle())
                .foregroundStyle(person.isWork ? Brand.onWork : Brand.onLife)
                .overlay(Circle().strokeBorder(Brand.record, lineWidth: person.owed ? 3 : 0).padding(-3))
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.callout.weight(.bold))
                Text(PersonCard.standing(person)).font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Brand.dim)
        }
        .padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The selected person, under the map: what stands between you, and the ways in.
struct PersonCard: View {
    @EnvironmentObject var library: Library
    let person: Digest.Person

    static func standing(_ p: Digest.Person) -> String {
        var parts = ["\(p.moments.count) \(p.moments.count == 1 ? "moment" : "moments")"]
        if let l = p.lastSeen { parts.append("last " + (Calendar.current.isDateInToday(l) ? "today" : l.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))) }
        let open = p.waitingOn.filter { !$0.isDone }
        if !open.isEmpty { parts.append("owes you \(open.count)") }
        if p.youOwe > 0 { parts.append("you owe \(p.youOwe)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let p = person
        let tint = p.isWork ? Brand.work : Brand.life, ink = p.isWork ? Brand.onWork : Brand.onLife
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.name).font(.title.weight(.bold)).tracking(-0.4)
                Spacer()
                Text(Self.standing(p)).font(.caption.weight(.semibold)).opacity(0.85).lineLimit(1)
            }
            Text(PersonView.between(p)).font(.callout.weight(.semibold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NavigationLink(value: p.name) {
                    Text("The whole relationship").font(.footnote.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 8).background(ink, in: Capsule()).foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                if let last = p.moments.max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
                    NavigationLink(value: last.id) {
                        Text("Hear the last").font(.footnote.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 8).background(ink.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(ink)
    }
}

/// The whole relationship: last spoken, the promises both ways, the threads between
/// you, and everything said with them.
struct PersonView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var threads: ThreadStore
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let person: Digest.Person
    @State private var renaming: String?
    @State private var newName = ""

    static func between(_ p: Digest.Person) -> String {
        var s: [String] = []
        let theirs = p.waitingOn.filter { !$0.isDone }
        if let t = theirs.first { s.append("\(p.name) owes you \(t.text.lowercased())" + (theirs.count > 1 ? ", and \(theirs.count - 1) more." : ".")) }
        let yours = p.moments.flatMap { ($0.meta.insight?.items ?? []).filter { $0.isAction && !$0.isDone && !$0.isDismissed && $0.text.localizedCaseInsensitiveContains(p.name) } }
        if let y = yours.first { s.append("You owe \(y.text.lowercased())" + (yours.count > 1 ? ", and \(yours.count - 1) more." : ".")) }
        if s.isEmpty {
            if let l = p.lastSeen { s.append("Nothing open between you. Last spoke \(Findings.dayName(l)).") } else { s.append("Nothing open between you.") }
        }
        return s.joined(separator: " ")
    }

    var body: some View {
        let p = person
        let all = library.recordings
        let tint = p.isWork ? Brand.work : Brand.life, ink = p.isWork ? Brand.onWork : Brand.onLife
        let theirs = p.waitingOn.filter { !$0.isDone }
        let yours: [(Recording, NextItem)] = p.moments.flatMap { r in
            (r.meta.insight?.items ?? []).filter { $0.isAction && !$0.isDone && !$0.isDismissed && $0.text.localizedCaseInsensitiveContains(p.name) }.map { (r, $0) }
        }
        let mine = Set(p.moments.map(\.id))
        let between = threads.live(all).filter { t in t.moments.contains { mine.contains($0.id) } }.sorted { $0.weight > $1.weight }.prefix(6)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(PersonCard.standing(p).uppercased()).font(.caption2.weight(.bold)).tracking(0.7).opacity(0.75)
                    Text(p.name).font(.largeTitle.weight(.bold)).tracking(-0.6)
                    Text(Self.between(p)).font(.callout.weight(.semibold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint).foregroundStyle(ink)
                VStack(alignment: .leading, spacing: 20) {
                    if !theirs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("\(p.name) owes you")
                            ForEach(theirs) { item in
                                HStack(spacing: 10) {
                                    Text(item.text).font(.callout.weight(.semibold))
                                    Spacer()
                                    if let w = item.when { Text(w).font(.caption).foregroundStyle(Brand.muted) }
                                }
                            }
                        }
                    }
                    if !yours.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("You owe \(p.name)")
                            ForEach(Array(yours.enumerated()), id: \.offset) { _, pair in
                                NavigationLink(value: pair.0.id) {
                                    HStack(spacing: 10) {
                                        Text(pair.1.text).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                        if let w = pair.1.when { Text(w).font(.caption).foregroundStyle(Brand.muted) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !between.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("Between you")
                            ForEach(Array(between)) { t in
                                NavigationLink(value: ThreadLink(id: t.id)) {
                                    HStack { Text(t.name).font(.callout.weight(.semibold)); Spacer(); ThreadPill(thread: t) }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Said with \(p.name)")
                        ForEach(p.moments.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }) { r in
                            NavigationLink(value: r.id) { TapeBand(recording: r) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
            }
        }
        .background(Brand.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { RecordButton(size: 30) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    PersonMenuItems(name: p.name, others: Digest.people(all, limit: 40).map(\.name), renaming: $renaming, newName: $newName) { dismiss() }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Mend this person")
            }
        }
        .modifier(PersonRenaming(renaming: $renaming, newName: $newName) { dismiss() })
        .onAppear { model.pageContext = RecordContext(person: p.name) }
        .onDisappear { if model.pageContext?.person == p.name { model.pageContext = nil } }
    }
}
