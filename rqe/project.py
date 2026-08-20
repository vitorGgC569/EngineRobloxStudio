from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ProjectError(RuntimeError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ProjectError(f"arquivo obrigatório não encontrado: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ProjectError(f"JSON inválido em {path}: {exc}") from exc


@dataclass
class Project:
    root: Path
    config: dict[str, Any]
    contract: dict[str, Any]
    fixture: dict[str, Any] | None

    @classmethod
    def load(cls, root: str | Path, *, include_fixture: bool = True) -> "Project":
        root_path = Path(root).resolve()
        config = read_json(root_path / "rqe.project.json")
        contract_relative = config.get("contract")
        if not isinstance(contract_relative, str) or not contract_relative.strip():
            raise ProjectError("rqe.project.json must name a project-relative contract")
        contract_path = root_path / contract_relative
        fixture = None
        fixture_relative = config.get("fixture")
        if include_fixture and isinstance(fixture_relative, str) and fixture_relative.strip():
            fixture_path = root_path / fixture_relative
            fixture = read_json(fixture_path)
        return cls(root_path, config, read_json(contract_path), fixture)

    @property
    def contract_path(self) -> Path:
        return self.root / self.config.get("contract", "contracts/game-contract.json")

    @property
    def scripts_dir(self) -> Path:
        return self.root / self.config.get("scripts", "src")

    @property
    def reports_dir(self) -> Path:
        return self.root / self.config.get("reports", "reports")

    def expected_paths(self) -> list[str]:
        return list(self.config.get("expectedPaths", []))
