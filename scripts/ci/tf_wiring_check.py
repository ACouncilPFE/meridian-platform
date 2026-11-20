"""Offline Terraform wiring check (no provider downloads needed).

For every environment under terraform/envs and terraform/bootstrap, verifies that:
  * each module call passes only inputs the module declares,
  * every required module input (no default) is set,
  * every `module.X.Y` reference points at a declared module with output Y,
  * every `var.X` used in a module or environment is declared there.

Complements `terraform validate`, which needs registry access.

    pip install python-hcl2 && python3 scripts/ci/tf_wiring_check.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import hcl2

ROOT = Path(__file__).resolve().parents[2] / "terraform"
META_KEYS = {"source", "providers", "count", "for_each", "depends_on"}


def _key(k: str) -> str:
    return k.strip('"')


def _parse_dir(d: Path) -> list[dict]:
    docs = []
    for f in sorted(d.glob("*.tf")):
        try:
            docs.append(hcl2.loads(f.read_text()))
        except Exception as exc:  # noqa: BLE001 (report any parser failure as a finding)
            sys.exit(f"PARSE ERROR {f}: {exc}")
    return docs


def _text(d: Path) -> str:
    return "\n".join(f.read_text() for f in d.glob("*.tf"))


def _variables(docs: list[dict]) -> dict[str, bool]:
    """name -> has_default"""
    return {_key(k): "default" in body for doc in docs for v in doc.get("variable", []) for k, body in v.items()}


def _outputs(docs: list[dict]) -> set[str]:
    return {_key(k) for doc in docs for o in doc.get("output", []) for k in o}


def _undeclared_vars(d: Path, declared: set[str]) -> set[str]:
    return set(re.findall(r"\bvar\.([a-z_0-9]+)", _text(d))) - declared


def check() -> list[str]:
    problems: list[str] = []
    modules: dict[str, tuple[dict[str, bool], set[str]]] = {}

    for mdir in sorted(p for p in (ROOT / "modules").iterdir() if p.is_dir()):
        docs = _parse_dir(mdir)
        variables = _variables(docs)
        modules[mdir.name] = (variables, _outputs(docs))
        problems += [f"module {mdir.name}: undeclared var.{v}" for v in sorted(_undeclared_vars(mdir, set(variables)))]

    for edir in sorted([*(ROOT / "envs").iterdir(), *(ROOT / "bootstrap").iterdir()]):
        docs = _parse_dir(edir)
        where = f"{edir.parent.name}/{edir.name}"
        calls: dict[str, str] = {}
        for doc in docs:
            for block in doc.get("module", []):
                for raw_name, body in block.items():
                    name = _key(raw_name)
                    src = _key(body["source"]).rstrip("/").split("/")[-1]
                    if src not in modules:
                        problems.append(f"{where}: module.{name} has unknown source {src}")
                        continue
                    calls[name] = src
                    declared, _ = modules[src]
                    passed = {_key(k) for k in body if not k.startswith("__") and _key(k) not in META_KEYS}
                    problems += [f"{where}: module.{name} passes unknown input '{k}'" for k in sorted(passed - set(declared))]
                    problems += [
                        f"{where}: module.{name} missing required input '{k}'"
                        for k, has_default in sorted(declared.items())
                        if not has_default and k not in passed
                    ]

        for name, out in sorted(set(re.findall(r"\bmodule\.([a-z_0-9]+)\.([a-z_0-9]+)", _text(edir)))):
            if name not in calls:
                problems.append(f"{where}: reference to undeclared module.{name}")
            elif out not in modules[calls[name]][1]:
                problems.append(f"{where}: module.{name} has no output '{out}'")

        problems += [f"{where}: undeclared var.{v}" for v in sorted(_undeclared_vars(edir, set(_variables(docs))))]

    return problems


def main() -> int:
    problems = check()
    for p in problems:
        print(p)
    print(f"terraform wiring: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
