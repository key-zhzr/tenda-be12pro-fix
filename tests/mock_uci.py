#!/usr/bin/env python3
"""Small persistent UCI command model for host-side configuration regression tests."""
import json
import os
import shlex
import sys
from pathlib import Path

path = Path(os.environ["MOCK_UCI_STATE"])
state = json.loads(path.read_text())


def execute(args):
    args = [arg for arg in args if arg != "-q"]
    if " ".join(args) == os.environ.get("MOCK_UCI_FAIL"):
        return 1
    cmd = args[0]
    if cmd == "batch":
        result = 0
        for line in sys.stdin:
            if line.strip():
                result = max(result, execute(shlex.split(line)))
        return result
    if cmd in ("commit", "revert"):
        return 0
    if cmd == "import":
        state[args[1]] = json.load(sys.stdin)
        return 0
    if cmd == "export":
        print(json.dumps(state[args[1]]))
        return 0
    key, _, value = args[1].partition("=")
    parts = key.split(".")
    package = state.get(parts[0], {})
    if cmd == "show":
        for section, data in package.items():
            print(f"{parts[0]}.{section}={data['__type']}")
            for option, v in data.items():
                if option == "__type":
                    continue
                values = v if isinstance(v, list) else [v]
                # uci quotes values even when shlex considers them shell-safe.
                rendered = " ".join("'" + str(item) + "'" for item in values)
                print(f"{parts[0]}.{section}.{option}={rendered}")
        return 0
    section = package.get(parts[1], {})
    option = parts[2] if len(parts) > 2 else "__type"
    if cmd == "get":
        if option not in section:
            return 1
        v = section[option]
        print(" ".join(v) if isinstance(v, list) else v)
    elif cmd == "set":
        package = state.setdefault(parts[0], {})
        section = package.setdefault(parts[1], {})
        section[option] = value
    elif cmd == "add_list":
        previous = section.get(option, [])
        if not isinstance(previous, list):
            previous = [previous]
        section[option] = previous + [value]
    elif cmd == "delete":
        if option not in section:
            return 1
        if option == "__type":
            del package[parts[1]]
        else:
            del section[option]
    else:
        raise ValueError(args)
    return 0


rc = execute(sys.argv[1:])
path.write_text(json.dumps(state, sort_keys=True))
sys.exit(rc)
