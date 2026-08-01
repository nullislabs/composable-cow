#!/usr/bin/env python3
"""Derive handler descriptor documents from build artifacts and author overlays.

Descriptors are derived, not hand-written (docs/discovery.md 1.4). This reads
the solc AST emitted by `forge build --ast`, joins it with the author overlay in
descriptors/overlays/, and writes the canonical document to descriptors/.

Two facts come from the AST rather than the ABI:

  - `staticInput.components`, because the struct never crosses an external ABI
    boundary and so appears in no contract's ABI.
  - `errors`, because every reason error in this codebase is declared at file
    scope, where solc omits it from the contract ABI. Only the framework
    wrapper errors (OrderNotValid, PollTry*) reach the ABI, and those are not
    reason codes.

The document carries no handler address or chain id. The digest is a constructor
argument, so it is part of the initcode that fixes a CREATE2 address; a document
naming its own address could not be committed to. Binding comes from resolution
instead. See descriptors/README.md.

Usage:
    dev/gen-descriptors.py            # write documents
    dev/gen-descriptors.py --check    # exit 1 if committed bytes differ

Standard library only, plus `cast` for selector hashing.
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
DESCRIPTORS = ROOT / "descriptors"
OVERLAYS = DESCRIPTORS / "overlays"

# Elementary types the descriptor may carry. Anything else is a generator bug
# rather than something to silently pass through to consumers.
TYPE_MAP = {"address payable": "address"}


def load_asts():
    """Map absolutePath -> AST for every source unit forge emitted."""
    asts = {}
    for f in OUT.rglob("*.json"):
        try:
            d = json.loads(f.read_text())
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        a = d.get("ast") if isinstance(d, dict) else None
        if a and a.get("absolutePath"):
            asts[a["absolutePath"]] = a
    if not asts:
        sys.exit("no ASTs in out/: run `forge build --ast` first")
    return asts


def walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def import_closure(asts, root):
    """Source units reachable from `root` via imports, restricted to src/."""
    seen, stack = set(), [root]
    while stack:
        p = stack.pop()
        if p in seen or p not in asts:
            continue
        seen.add(p)
        for n in asts[p]["nodes"]:
            if n.get("nodeType") == "ImportDirective":
                t = n.get("absolutePath")
                if t and t.startswith("src/"):
                    stack.append(t)
    return seen


def solidity_type(type_string, context):
    """Canonical ABI type for a struct member."""
    if type_string in TYPE_MAP:
        return TYPE_MAP[type_string]
    if type_string.startswith("contract "):
        return "address"
    if type_string.startswith("enum "):
        return "uint8"
    if type_string.startswith(("struct ", "mapping", "function ")):
        sys.exit(f"{context}: unsupported member type {type_string!r}; descriptor components are flat")
    return type_string


def find_struct(asts, files, qualified, handler):
    """Resolve `Scope.Name` (e.g. TWAPOrder.Data) to its member list."""
    scope, _, name = qualified.partition(".")
    if not name:
        sys.exit(f"{handler}: staticInputStruct must be 'Scope.Name', got {qualified!r}")
    for path in sorted(files):
        for n in walk(asts[path]):
            if n.get("nodeType") != "StructDefinition" or n.get("name") != name:
                continue
            # canonicalName is e.g. "TWAPOrder.Data"
            if n.get("canonicalName") != qualified:
                continue
            return [
                {"name": m["name"], "type": solidity_type(m["typeDescriptions"]["typeString"], handler)}
                for m in n["members"]
            ]
    sys.exit(f"{handler}: struct {qualified} not found in the import closure")


def reason_errors(asts, files):
    """Error names used as reason codes, i.e. referenced as `X.selector`."""
    names = set()
    for path in files:
        for n in walk(asts[path]):
            if n.get("nodeType") == "MemberAccess" and n.get("memberName") == "selector":
                e = n.get("expression", {})
                if e.get("nodeType") == "Identifier":
                    names.add(e["name"])
    # Keep only names that are actually error declarations; `.selector` is also
    # valid on functions and would otherwise leak in.
    declared = {}
    for path in files:
        for n in walk(asts[path]):
            if n.get("nodeType") == "ErrorDefinition":
                declared[n["name"]] = [p["typeDescriptions"]["typeString"] for p in n["parameters"]["parameters"]]
    return {n: declared[n] for n in sorted(names) if n in declared}


def selector(name, param_types):
    sig = f"{name}({','.join(param_types)})"
    r = subprocess.run(["cast", "sig", sig], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"cast sig failed for {sig}: {r.stderr.strip()}")
    return r.stdout.strip()


def canonical(obj):
    """RFC 8785 for the subset used here: ASCII, no floats, sorted keys."""
    for n in walk(obj):
        if isinstance(n, float):
            sys.exit("floats are not canonicalizable under this subset")
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"


def offchain_input_required(ast, handler):
    """True iff the handler's `generateOrder` actually reads `offchainInput`.

    Deriving this from `PollNeedsOffchainInput` would be unsound: a handler can
    consume `offchainInput` without ever declaring that error. The parameter is
    the last one on `generateOrder`; unused parameters are left unnamed here, so
    the reliable test is whether the body references the declaration.
    """
    for n in walk(ast):
        if n.get("nodeType") != "FunctionDefinition" or n.get("name") != "generateOrder":
            continue
        params = n["parameters"]["parameters"]
        if not params:
            sys.exit(f"{handler}: generateOrder has no parameters")
        last = params[-1]
        if last["typeDescriptions"]["typeString"] != "bytes":
            sys.exit(f"{handler}: last generateOrder parameter is not bytes, cannot identify offchainInput")
        if not last.get("name"):
            return False
        pid = last["id"]
        return any(
            b.get("nodeType") == "Identifier" and b.get("referencedDeclaration") == pid
            for b in walk(n.get("body") or {})
        )
    sys.exit(f"{handler}: no generateOrder definition found")


def build(handler, overlay, asts):
    src = overlay["source"]
    if src not in asts:
        sys.exit(f"{handler}: no AST for {src}")
    files = import_closure(asts, src)

    errors = {}
    for name, params in reason_errors(asts, files).items():
        entry = {"name": name}
        label = overlay.get("labels", {}).get(name)
        if label:
            entry["label"] = label
        errors[selector(name, params)] = entry

    required = offchain_input_required(asts[src], handler)

    doc = {
        "version": "1",
        "name": overlay["name"],
        "description": overlay["description"],
        "staticInput": {"components": find_struct(asts, files, overlay["staticInputStruct"], handler)},
        "offchainInput": {"required": required},
        "display": overlay["display"],
        "errors": errors,
        "links": overlay.get("links", {}),
        "extensions": overlay.get("extensions", {}),
    }
    return canonical(doc)


def main():
    check = "--check" in sys.argv[1:]
    asts = load_asts()
    overlays = sorted(OVERLAYS.glob("*.json"))
    if not overlays:
        sys.exit(f"no overlays in {OVERLAYS}")

    stale = []
    for o in overlays:
        handler = o.stem
        doc = build(handler, json.loads(o.read_text()), asts)
        target = DESCRIPTORS / f"{handler}.json"
        if check:
            if not target.exists() or target.read_text() != doc:
                stale.append(target.relative_to(ROOT))
        else:
            target.write_text(doc)
            print(f"  wrote {target.relative_to(ROOT)}")

    if check:
        if stale:
            print("descriptors are stale, run dev/gen-descriptors.py:", file=sys.stderr)
            for s in stale:
                print(f"  {s}", file=sys.stderr)
            return 1
        print(f"  {len(overlays)} descriptors up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
