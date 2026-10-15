// agenda: Calendar and Reminders through EventKit (every account the Mac's Calendar app has: iCloud, Google, Exchange...).
//   agenda [days]                                  events for today + N-1 days (default 2) and open reminders
//   agenda calendars                               the calendars that can take events, with their account
//   agenda add "Title" "YYYY-MM-DD HH:MM" [minutes] [--calendar "Work [Non-Personal]"] [--location "..."] [--notes "..."] [--all-day] [--yes]
//                                                  add an event (default 60 minutes; "YYYY-MM-DD" alone means all day); prints its id
//   agenda delete <event id> [--yes]               remove an event this tool added (or any id from `agenda`)
//   agenda remind "text" "YYYY-MM-DD HH:MM"|+20m   add a Reminder with an alarm
// add/delete refuse without --yes and print what they would do.
import EventKit
import Foundation

let store = EKEventStore()
var args = Array(CommandLine.arguments.dropFirst())
let sem = DispatchSemaphore(value: 0)
let yes = args.contains("--yes")
args.removeAll { $0 == "--yes" }

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }

func access(_ kind: EKEntityType, _ done: @escaping (Bool) -> Void) {
    if kind == .event { store.requestFullAccessToEvents { ok, _ in done(ok) } }
    else { store.requestFullAccessToReminders { ok, _ in done(ok) } }
}

let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.dateFormat = "EEE MMM d"
let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US"); tf.dateFormat = "h:mm a"
func parseDateTime(_ s: String) -> (Date, Bool)? {   // (date, allDay)
    let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX")
    p.dateFormat = "yyyy-MM-dd HH:mm"; if let d = p.date(from: s) { return (d, false) }
    p.dateFormat = "yyyy-MM-dd'T'HH:mm"; if let d = p.date(from: s) { return (d, false) }
    p.dateFormat = "yyyy-MM-dd"; if let d = p.date(from: s) { return (d, true) }
    return nil
}
func calendarLabel(_ c: EKCalendar) -> String { "\(c.title) [\(c.source.title)]" }
func findCalendar(_ spec: String, account: String? = nil) -> (EKCalendar?, String?) {
    // "Work", "Work [Non-Personal]", or "Work" with --account "Non-Personal".
    var name = spec, acct = account
    if acct == nil, let open = spec.lastIndex(of: "["), spec.hasSuffix("]") {
        name = String(spec[..<open]).trimmingCharacters(in: .whitespaces)
        acct = String(spec[spec.index(after: open)..<spec.index(before: spec.endIndex)]).trimmingCharacters(in: .whitespaces)
    }
    var cals = store.calendars(for: .event).filter { $0.allowsContentModifications }
    if let acct {
        let a = acct.lowercased()
        let exactAcct = cals.filter { $0.source.title.lowercased() == a }     // "Personal" must not also mean "Non-Personal"
        cals = exactAcct.isEmpty ? cals.filter { $0.source.title.lowercased().contains(a) } : exactAcct
    }
    let n = name.lowercased()
    let exact = cals.filter { $0.title.lowercased() == n }
    if exact.count == 1 { return (exact[0], nil) }
    let hits = cals.filter { $0.title.lowercased().contains(n) || $0.source.title.lowercased().contains(n) }
    if hits.count == 1 { return (hits[0], nil) }
    if hits.isEmpty { return (nil, "No calendar matching '\(name)'. `agenda calendars` lists them.") }
    return (nil, "'\(name)' matches several calendars: " + hits.map(calendarLabel).joined(separator: ", ") + ". Ask which.")
}

switch args.first {
case "calendars":
    access(.event) { ok in
        guard ok else { fail("no access to Calendar (System Settings > Privacy & Security > Calendars)") }
        let def = store.defaultCalendarForNewEvents
        for c in store.calendars(for: .event).sorted(by: { ($0.source.title, $0.title) < ($1.source.title, $1.title) }) {
            let ro = c.allowsContentModifications ? "" : " (read only)"
            let d = (c.calendarIdentifier == def?.calendarIdentifier) ? " (default)" : ""
            print("- \(calendarLabel(c))\(ro)\(d)")
        }
        sem.signal()
    }
    sem.wait(); exit(0)

case "add":
    args.removeFirst()
    let calName = opt("--calendar"); let account = opt("--account"); let location = opt("--location"); let notes = opt("--notes"); let allDayFlag = flag("--all-day")
    guard args.count >= 2 else { fail("usage: agenda add \"Title\" \"YYYY-MM-DD HH:MM\" [minutes] [--calendar \"Work\"] [--yes]") }
    let title = args[0]
    guard let (start, parsedAllDay) = parseDateTime(args[1]) else { fail("time must be YYYY-MM-DD HH:MM, or YYYY-MM-DD for all day") }
    let allDay = allDayFlag || parsedAllDay
    let minutes = args.count > 2 ? (Int(args[2]) ?? 60) : 60
    access(.event) { ok in
        guard ok else { fail("no access to Calendar (System Settings > Privacy & Security > Calendars)") }
        var cal = store.defaultCalendarForNewEvents
        if let calName {
            let (c, why) = findCalendar(calName, account: account)
            if let why { fail(why) }
            cal = c
        }
        guard let cal else { fail("no writable calendar") }
        let end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))! : start.addingTimeInterval(Double(minutes) * 60)
        let when = allDay ? "\(df.string(from: start)), all day" : "\(df.string(from: start)) \(tf.string(from: start))–\(tf.string(from: end))"
        let describe = "add \"\(title)\" on \(when) to \(calendarLabel(cal))" + (location.map { " at \($0)" } ?? "")
        if !yes {
            print("WOULD DO: \(describe)")
            print("Not done. Ask your human to confirm, then run the same command with --yes.")
            exit(3)
        }
        let e = EKEvent(eventStore: store)
        e.title = title; e.calendar = cal; e.isAllDay = allDay
        e.startDate = allDay ? Calendar.current.startOfDay(for: start) : start
        e.endDate = end
        e.location = location; e.notes = notes
        do { try store.save(e, span: .thisEvent, commit: true); print("Done: \(describe)"); print("event id: \(e.eventIdentifier ?? "")") }
        catch { fail("could not save: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait(); exit(0)

case "delete":
    guard args.count >= 2 else { fail("usage: agenda delete <event id> [--yes]") }
    let id = args[1]
    access(.event) { ok in
        guard ok else { fail("no access to Calendar") }
        guard let e = store.event(withIdentifier: id) else { fail("no event with that id") }
        let describe = "delete \"\(e.title ?? "")\" on \(df.string(from: e.startDate)) from \(calendarLabel(e.calendar))"
        if !yes { print("WOULD DO: \(describe)"); print("Not done. Ask your human to confirm, then run the same command with --yes."); exit(3) }
        do { try store.remove(e, span: .thisEvent, commit: true); print("Done: \(describe)") }
        catch { fail("could not delete: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait(); exit(0)

case "remind":
    guard args.count >= 3 else { fail("usage: agenda remind \"text\" \"YYYY-MM-DD HH:MM\" | +20m | +2h | +1d") }
    let text = args[1], when = args[2]
    var date: Date
    if when.hasPrefix("+"), let n = Double(when.dropFirst().dropLast()) {
        let unit = when.last!
        let secs: Double = unit == "m" ? 60 : unit == "h" ? 3600 : unit == "d" ? 86400 : 0
        if secs == 0 { fail("relative time must end in m, h or d") }
        date = Date().addingTimeInterval(n * secs)
    } else {
        guard let (d, _) = parseDateTime(when) else { fail("time must be YYYY-MM-DD HH:MM or +20m / +2h / +1d") }
        date = d
    }
    access(.reminder) { ok in
        guard ok else { fail("no access to Reminders (System Settings > Privacy & Security > Reminders)") }
        let r = EKReminder(eventStore: store)
        r.title = text
        r.calendar = store.defaultCalendarForNewReminders()
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        r.addAlarm(EKAlarm(absoluteDate: date))
        do { try store.save(r, commit: true); print("reminder set: \"\(text)\" at \(df.string(from: date)) \(tf.string(from: date))") }
        catch { fail("could not save reminder: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait(); exit(0)

default:
    let days = max(1, Int(args.first ?? "2") ?? 2)
    access(.event) { ok in
        guard ok else { fail("no access to Calendar (System Settings > Privacy & Security > Calendars)") }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: days, to: start)!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        var day = ""
        if events.isEmpty { print("No events in the next \(days) day(s).") }
        for e in events {
            let d = df.string(from: e.startDate)
            if d != day { day = d; print("\(d):") }
            let time = e.isAllDay ? "all day" : "\(tf.string(from: e.startDate))–\(tf.string(from: e.endDate))"
            let loc = (e.location ?? "").isEmpty ? "" : " @ \(e.location!)"
            print("  \(time)  \(e.title ?? "(untitled)")\(loc)  [\(e.calendar.title)]  id:\(e.eventIdentifier ?? "")")
        }
        access(.reminder) { ok2 in
            if ok2 {
                let p = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
                store.fetchReminders(matching: p) { rs in
                    let list = (rs ?? []).sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    if !list.isEmpty {
                        print("Reminders due:")
                        for r in list {
                            let due = r.dueDateComponents?.date.map { "\(df.string(from: $0)) \(tf.string(from: $0))" } ?? "no date"
                            print("  \(due)  \(r.title ?? "")")
                        }
                    }
                    sem.signal()
                }
            } else { sem.signal() }
        }
    }
    sem.wait()
}
