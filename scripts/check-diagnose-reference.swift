#!/usr/bin/env swift
import Foundation

func refusal(_ data: Data) -> String? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["schema"] as? Int == 2,
        object["models"] is [String: Any]
    else { return "diagnose reference must be schema 2" }
    if object["provisional"] as? Bool == true { return "provisional diagnose reference is for local installs only" }
    guard let conditions = object["conditions"] as? [String: Any], !conditions.isEmpty,
        conditions.values.contains(where: { !($0 is NSNull) && String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) != "" })
    else { return "diagnose reference has no recorded conditions" }
    return nil
}

if CommandLine.arguments.dropFirst().first == "--selftest" {
    let fixtures: [(String, Bool)] = [
        (#"{"schema":2,"models":{},"provisional":true,"conditions":{"lock":"measure"}}"#, false),
        (#"{"schema":2,"models":{},"provisional":false}"#, false),
        (#"{"schema":2,"models":{},"conditions":{}}"#, false),
        (#"{"schema":2,"models":{},"conditions":{"lock":null}}"#, false),
        (#"{"schema":2,"models":{},"provisional":false,"conditions":{"lock":"quiet measure window"}}"#, true)
    ]
    for (text, accepted) in fixtures where (refusal(Data(text.utf8)) == nil) != accepted {
        fputs("diagnose-reference guard fixture failed\n", stderr); exit(1)
    }
    print("diagnose-reference guard: provisional/missing conditions refused; qualified fixture accepted")
} else {
    let path = CommandLine.arguments.dropFirst().first ?? "Resources/diagnose-reference.json"
    do {
        if let reason = refusal(try Data(contentsOf: URL(fileURLWithPath: path))) {
            fputs("REFUSED: \(reason)\n", stderr); exit(1)
        }
        print("diagnose reference: qualified schema 2 with recorded conditions")
    } catch { fputs("REFUSED: cannot read diagnose reference\n", stderr); exit(1) }
}
