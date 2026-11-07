"""Reject compilation in the native test's executable action closure."""

import json
import sys


def native_actions(graph):
    actions = graph["actions"]
    producers = {output: index for index, action in enumerate(actions) for output in action.get("outputIds", [])}
    inputs = {entry["id"]: entry for entry in graph.get("depSetOfFiles", [])}
    pending = [index for index, action in enumerate(actions) if action["mnemonic"] == "TestRunner"]
    if not pending:
        raise ValueError("Action graph contains no native TestRunner")
    visited = set()
    seen_inputs = set()
    while pending:
        index = pending.pop()
        if index in visited:
            continue
        visited.add(index)
        action = actions[index]
        yield action
        input_sets = list(action.get("inputDepSetIds", []))
        while input_sets:
            key = input_sets.pop()
            if key in seen_inputs:
                continue
            seen_inputs.add(key)
            entry = inputs[key]
            input_sets.extend(entry.get("transitiveDepSetIds", []))
            pending.extend(producers[file] for file in entry.get("directArtifactIds", []) if file in producers)


def main():
    with open(sys.argv[1]) as stream:
        graph = json.load(stream)
    mnemonics = sorted({action["mnemonic"] for action in native_actions(graph)})
    print("Native execution action mnemonics:", ", ".join(mnemonics))
    if any("Compile" in name or name.endswith("Link") for name in mnemonics):
        raise SystemExit("Native execution unexpectedly compiles or links a helper")


if __name__ == "__main__":
    main()
