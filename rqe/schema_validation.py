"""Small, deterministic JSON Schema validator for RQE-owned schemas.

RQE cannot make release policy optional just because an editor dependency is
missing.  This module deliberately implements the draft-2020 keywords used by
our checked-in schemas and fails closed on unknown schema keywords.  It is not
intended to validate arbitrary third-party schemas.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any


class SchemaDefinitionError(ValueError):
    pass


ANNOTATION_KEYWORDS = {"$schema", "$id", "title", "description", "default", "examples"}
SUPPORTED_KEYWORDS = ANNOTATION_KEYWORDS | {
    "$ref", "$defs", "type", "const", "enum", "required", "properties",
    "additionalProperties", "minProperties", "maxProperties", "items",
    "minItems", "maxItems", "uniqueItems", "pattern", "minLength",
    "maxLength", "minimum", "maximum", "exclusiveMinimum",
    "exclusiveMaximum", "minProperties",
}


@dataclass(frozen=True)
class SchemaIssue:
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}: {self.message}"


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "null":
        return value is None
    raise SchemaDefinitionError(f"unsupported JSON Schema type {expected!r}")


def _resolve_local_ref(root: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise SchemaDefinitionError(f"only local JSON pointers are supported: {reference}")
    node: Any = root
    for encoded in reference[2:].split("/"):
        key = encoded.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or key not in node:
            raise SchemaDefinitionError(f"unresolved JSON Schema reference: {reference}")
        node = node[key]
    if not isinstance(node, dict):
        raise SchemaDefinitionError(f"JSON Schema reference is not an object: {reference}")
    return node


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def validate_schema_instance(instance: Any, schema: dict[str, Any]) -> list[SchemaIssue]:
    """Validate an instance against the supported, checked-in schema subset."""

    if not isinstance(schema, dict):
        raise SchemaDefinitionError("schema root must be an object")
    issues: list[SchemaIssue] = []

    def visit(value: Any, rule: dict[str, Any], path: str) -> None:
        unknown = set(rule) - SUPPORTED_KEYWORDS
        if unknown:
            raise SchemaDefinitionError(
                f"unsupported JSON Schema keyword(s) at {path}: {', '.join(sorted(unknown))}"
            )
        if "$ref" in rule:
            reference = rule["$ref"]
            if not isinstance(reference, str):
                raise SchemaDefinitionError(f"$ref at {path} must be a string")
            visit(value, _resolve_local_ref(schema, reference), path)
            return

        expected = rule.get("type")
        if expected is not None:
            choices = expected if isinstance(expected, list) else [expected]
            if not choices or any(not isinstance(item, str) for item in choices):
                raise SchemaDefinitionError(f"type at {path} must be a string or array of strings")
            if not any(_matches_type(value, item) for item in choices):
                issues.append(SchemaIssue(path, f"expected type {'|'.join(choices)}"))
                return

        if "const" in rule and value != rule["const"]:
            issues.append(SchemaIssue(path, f"must equal {rule['const']!r}"))
        if "enum" in rule:
            options = rule["enum"]
            if not isinstance(options, list):
                raise SchemaDefinitionError(f"enum at {path} must be an array")
            if value not in options:
                issues.append(SchemaIssue(path, f"must be one of {options!r}"))

        if isinstance(value, dict):
            required = rule.get("required", [])
            if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
                raise SchemaDefinitionError(f"required at {path} must be an array of strings")
            for key in required:
                if key not in value:
                    issues.append(SchemaIssue(f"{path}.{key}", "is required"))
            properties = rule.get("properties", {})
            if not isinstance(properties, dict):
                raise SchemaDefinitionError(f"properties at {path} must be an object")
            for key, child in properties.items():
                if key in value:
                    if not isinstance(child, dict):
                        raise SchemaDefinitionError(f"schema for {path}.{key} must be an object")
                    visit(value[key], child, f"{path}.{key}")
            extras = set(value) - set(properties)
            additional = rule.get("additionalProperties", True)
            if additional is False:
                for key in sorted(extras):
                    issues.append(SchemaIssue(f"{path}.{key}", "unknown property"))
            elif isinstance(additional, dict):
                for key in sorted(extras):
                    visit(value[key], additional, f"{path}.{key}")
            elif additional is not True:
                raise SchemaDefinitionError(f"additionalProperties at {path} must be boolean or object")
            if "minProperties" in rule and len(value) < rule["minProperties"]:
                issues.append(SchemaIssue(path, f"must contain at least {rule['minProperties']} properties"))
            if "maxProperties" in rule and len(value) > rule["maxProperties"]:
                issues.append(SchemaIssue(path, f"must contain at most {rule['maxProperties']} properties"))

        if isinstance(value, list):
            if "minItems" in rule and len(value) < rule["minItems"]:
                issues.append(SchemaIssue(path, f"must contain at least {rule['minItems']} items"))
            if "maxItems" in rule and len(value) > rule["maxItems"]:
                issues.append(SchemaIssue(path, f"must contain at most {rule['maxItems']} items"))
            if rule.get("uniqueItems"):
                encoded = [_canonical(item) for item in value]
                if len(encoded) != len(set(encoded)):
                    issues.append(SchemaIssue(path, "items must be unique"))
            item_rule = rule.get("items")
            if item_rule is not None:
                if not isinstance(item_rule, dict):
                    raise SchemaDefinitionError(f"items at {path} must be an object")
                for index, item in enumerate(value):
                    visit(item, item_rule, f"{path}[{index}]")

        if isinstance(value, str):
            if "minLength" in rule and len(value) < rule["minLength"]:
                issues.append(SchemaIssue(path, f"must have length >= {rule['minLength']}"))
            if "maxLength" in rule and len(value) > rule["maxLength"]:
                issues.append(SchemaIssue(path, f"must have length <= {rule['maxLength']}"))
            pattern = rule.get("pattern")
            if pattern is not None:
                if not isinstance(pattern, str):
                    raise SchemaDefinitionError(f"pattern at {path} must be a string")
                if re.search(pattern, value) is None:
                    issues.append(SchemaIssue(path, f"does not match pattern {pattern!r}"))

        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in rule and value < rule["minimum"]:
                issues.append(SchemaIssue(path, f"must be >= {rule['minimum']}"))
            if "maximum" in rule and value > rule["maximum"]:
                issues.append(SchemaIssue(path, f"must be <= {rule['maximum']}"))
            if "exclusiveMinimum" in rule and value <= rule["exclusiveMinimum"]:
                issues.append(SchemaIssue(path, f"must be > {rule['exclusiveMinimum']}"))
            if "exclusiveMaximum" in rule and value >= rule["exclusiveMaximum"]:
                issues.append(SchemaIssue(path, f"must be < {rule['exclusiveMaximum']}"))

    visit(instance, schema, "$")
    return issues

