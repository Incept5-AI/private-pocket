import SwiftUI

/// One way of handling things, everywhere: a tap opens a thing or does its one obvious job;
/// a swipe right does the good thing (Done, a block's action), a full swipe at once; a swipe
/// left puts it away (Not mine, Not a thread, Put away), Delete outermost and red; anything
/// else is a visible button or the page's ••• menu. Nothing waits behind a hold.
struct SwipeAction: Identifiable {
    let title: String
    let symbol: String
    let tint: Color
    let ink: Color
    let run: () -> Void
    var id: String { title }

    static func done(_ isDone: Bool, _ run: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: isDone ? "Not done" : "Done", symbol: isDone ? "arrow.uturn.backward" : "checkmark", tint: Brand.good, ink: Brand.ground, run: run)
    }
    /// Not the user's, or not what it seemed: kept, and never shown again.
    static func away(_ title: String, _ run: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: title, symbol: "xmark", tint: Brand.raised, ink: Brand.text, run: run)
    }
    static func delete(_ run: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: "Delete", symbol: "trash", tint: Brand.bad, ink: Brand.onLife, run: run)
    }
    static func act(_ title: String, _ run: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: title, symbol: "arrow.up.right", tint: Brand.act, ink: Brand.onAct, run: run)
    }
    /// Into Reminders or Calendar, in blue beside Done's green.
    static func place(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> SwipeAction {
        SwipeAction(title: title, symbol: symbol, tint: Brand.work, ink: Brand.onWork, run: run)
    }
}

extension AppModel {
    /// An item's swipes wherever it shows: to the right Done and Remind me for a to-do, Remind
    /// me (to chase) for a promise, Calendar for a date; to the left Not mine and Delete. The
    /// row itself only says where it stands; it holds no buttons of its own.
    func itemSwipes(_ r: Recording, _ item: NextItem) -> (leading: [SwipeAction], trailing: [SwipeAction]) {
        var leading: [SwipeAction] = []
        if item.isAction {
            leading.append(.done(item.isDone) { self.setDone(r, item: item, done: !item.isDone) })
            if !item.isDone, item.reminderID == nil { leading.append(.place("Remind me", "bell") { Task { _ = await self.place(r, item) } }) }
        } else if item.isDate {
            if item.eventID == nil, item.date != nil { leading.append(.place("Calendar", "calendar.badge.plus") { Task { _ = await self.place(r, item) } }) }
        } else if item.reminderID == nil {
            leading.append(.place("Remind me", "bell") { Task { await self.remindMe(r, item: item) } })
        }
        return (leading, [.away("Not mine") { self.dismiss(r, item: item) }, .delete { self.deleteItem(r, item: item) }])
    }
}

/// A row that swipes as a List row does, on a page that is not a List. Opened, it stays open
/// until an action, a tap on it, or a swipe back; a full swipe right runs the first leading
/// action. The trailing actions are listed inside out, so Delete goes last.
struct SwipeRow<Content: View>: View {
    var leading: [SwipeAction] = []
    var trailing: [SwipeAction] = []
    @ViewBuilder var content: () -> Content
    @State private var settled: CGFloat = 0
    @GestureState private var drag: CGFloat = 0
    private let width: CGFloat = 76

    var body: some View {
        let lead = width * CGFloat(leading.count), trail = width * CGFloat(trailing.count)
        let x = min(leading.isEmpty ? 0 : lead + 64, max(trailing.isEmpty ? 0 : -(trail + 24), settled + drag))
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { if settled != 0 { Color.clear.contentShape(Rectangle()).onTapGesture { close() } } }
            .offset(x: x)
            .background(alignment: .leading) { buttons(leading).opacity(x > 0 ? 1 : 0) }
            .background(alignment: .trailing) { buttons(trailing).opacity(x < 0 ? 1 : 0) }
            .clipShape(Rectangle())
            .animation(.snappy(duration: 0.25), value: settled)
            .animation(.interactiveSpring, value: drag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .updating($drag) { v, state, _ in
                        if abs(v.translation.width) > abs(v.translation.height) * 1.2 { state = v.translation.width }
                    }
                    .onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
                        if let first = leading.first, settled + v.translation.width > lead + 48 { settled = 0; first.run(); return }
                        let end = settled + v.predictedEndTranslation.width
                        settled = end > lead / 2 && !leading.isEmpty ? lead : end < -trail / 2 && !trailing.isEmpty ? -trail : 0
                    }
            )
            .sensoryFeedback(.selection, trigger: settled) { _, now in now != 0 }
            .accessibilityActions { ForEach(leading + trailing) { a in Button(a.title, action: a.run) } }
            .sideScrollZone()
    }

    private func buttons(_ actions: [SwipeAction]) -> some View {
        HStack(spacing: 0) {
            ForEach(actions) { a in
                Button { close(); a.run() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: a.symbol).font(.body.weight(.semibold))
                        Text(a.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: width).frame(maxHeight: .infinity)
                    .foregroundStyle(a.ink).background(a.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func close() { settled = 0 }
}

extension View {
    /// The same actions as `SwipeRow`, on a row of a List, through the system's own swipes.
    func listSwipes(leading: [SwipeAction] = [], trailing: [SwipeAction] = []) -> some View {
        swipeActions(edge: .leading, allowsFullSwipe: true) {
            ForEach(leading) { a in Button(action: a.run) { Label(a.title, systemImage: a.symbol) }.tint(a.tint) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            ForEach(trailing.reversed()) { a in Button(action: a.run) { Label(a.title, systemImage: a.symbol) }.tint(a.tint) }
        }
    }
}
