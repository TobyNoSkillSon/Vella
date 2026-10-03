#!/usr/bin/env swift
import Foundation

func isRecorded(_ value: Any) -> Bool {
    if value is NSNull { return false }
    if let text = value as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if let list = value as? [Any] { return !list.isEmpty && list.allSatisfy(isRecorded) }
    if let map = value as? [String: Any] { return !map.isEmpty && map.values.allSatisfy(isRecorded) }
    return true
}

func refusal(_ data: Data) -> String? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["schema"] as? Int == 2,
        object["models"] is [String: Any]
    else { return "diagnose reference must be schema 2" }
    if object["provisional"] as? Bool == true { return "provisional diagnose reference is for local installs only" }
    guard let conditions = object["conditions"] as? [String: Any], !conditions.isEmpty else { return "diagnose reference has no recorded conditions" }
    if let empty = conditions.filter({ !isRecorded($0.value) }).keys.sorted().first { return "diagnose reference condition \"\(empty)\" is empty" }
    return nil
}

if CommandLine.arguments.dropFirst().first == "--selftest" {
    let fixtures: [(String, Bool)] = [
        (#"{"schema":2,"models":{},"provisional":true,"conditions":{"lock":"measure"}}"#, false),
        (#"{"schema":2,"models":{},"provisional":false}"#, false),
        (#"{"schema":2,"models":{},"conditions":{}}"#, false),
        (#"{"schema":2,"models":{},"conditions":{"lock":null}}"#, false),
        (#"{"schema":2,"models":{},"conditions":{"lock":"quiet measure window","sampled":""}}"#, false),
        (#"{"schema":2,"models":{},"conditions":{"lock":"quiet measure window","processes":[]}}"#, false),
        (#"{"schema":2,"models":{},"conditions":{"lock":"quiet measure window","cpu":{"median":null}}}"#, false),
        (#"{"schema":2,"models":{},"provisional":false,"conditions":{"lock":"quiet measure window","cpu":{"median":12},"processes":["a"]}}"#, true)
    ]
    for (text, accepted) in fixtures where (refusal(Data(text.utf8)) == nil) != accepted {
        fputs("diagnose-reference guard fixture failed\n", stderr); exit(1)
    }
    print("diagnose-reference guard: provisional/missing/incomplete conditions refused; qualified fixture accepted")
} else {
    let path = CommandLine.arguments.dropFirst().first ?? "Resources/diagnose-reference.json"
    do {
        if let reason = refusal(try Data(contentsOf: URL(fileURLWithPath: path))) {
            fputs("REFUSED: \(reason)\n", stderr); exit(1)
        }
        print("diagnose reference: qualified schema 2 with every condition recorded")
    } catch { fputs("REFUSED: cannot read diagnose reference\n", stderr); exit(1) }
}
