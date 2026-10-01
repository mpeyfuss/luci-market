#!/usr/bin/env python3
"""Pack a Luci Market trait CSV into the uint32 values setTraits expects."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


CSV_HEADER = ["token_id", "trait_0", "trait_1", "trait_2", "trait_3"]
MAX_TRAIT_VALUE = 63


class TraitInputError(ValueError):
    """Raised when a trait CSV cannot be packed."""


def _parse_integer(value: str, field: str, line_number: int) -> int:
    text = value.strip()
    if not text:
        raise TraitInputError(f"line {line_number}: {field} cannot be blank")
    try:
        return int(text, 0) if text.lower().startswith("0x") else int(text, 10)
    except ValueError as exc:
        raise TraitInputError(f"line {line_number}: {field} must be an integer") from exc


def _parse_optional_trait(value: str, field: str, line_number: int) -> int | None:
    text = value.strip()
    if not text:
        return None
    trait = _parse_integer(text, field, line_number)
    if not 0 <= trait <= MAX_TRAIT_VALUE:
        raise TraitInputError(
            f"line {line_number}: {field} must be between 0 and {MAX_TRAIT_VALUE}, got {trait}"
        )
    return trait


def convert_csv(input_path: Path, batch_size: int = 250) -> dict:
    """Read a trait CSV and return packed trait words plus the collection config."""
    if batch_size <= 0:
        raise TraitInputError("batch size must be positive")

    token_ids: list[int] = []
    seen_token_ids: set[int] = set()
    traits: list[int] = []
    slot_population = [0, 0, 0, 0]

    with input_path.open("r", newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != CSV_HEADER:
            raise TraitInputError(
                f"CSV header must be exactly {','.join(CSV_HEADER)}; got {reader.fieldnames}"
            )

        for line_number, row in enumerate(reader, start=2):
            if any(row.get(field) is None for field in CSV_HEADER):
                raise TraitInputError(f"line {line_number}: row has missing columns")

            token_id = _parse_integer(row["token_id"], "token_id", line_number)
            if token_id < 0:
                raise TraitInputError(f"line {line_number}: token_id cannot be negative")
            if token_id in seen_token_ids:
                raise TraitInputError(f"line {line_number}: duplicate token_id {token_id}")

            encoded = 0
            for slot in range(4):
                field = f"trait_{slot}"
                trait = _parse_optional_trait(row[field], field, line_number)
                if trait is not None:
                    slot_population[slot] += 1
                    encoded |= (0x80 | trait) << (slot * 8)

            token_ids.append(token_id)
            seen_token_ids.add(token_id)
            traits.append(encoded)

    if not token_ids:
        raise TraitInputError("CSV must contain at least one token row")

    trait_config = sum(0x80 << (slot * 8) for slot, count in enumerate(slot_population) if count)
    batches = []
    for start in range(0, len(token_ids), batch_size):
        batches.append(
            {
                "token_ids": token_ids[start : start + batch_size],
                "traits": [f"0x{value:08x}" for value in traits[start : start + batch_size]],
            }
        )

    return {
        "trait_config": f"0x{trait_config:08x}",
        "batches": batches,
        "warnings": [
            f"trait_{slot} is populated on only {count} of {len(token_ids)} rows"
            for slot, count in enumerate(slot_population)
            if 0 < count < len(token_ids)
        ],
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="Trait CSV path")
    parser.add_argument("--output", type=Path, help="Output JSON path; stdout when omitted")
    parser.add_argument(
        "--batch-size", type=int, default=250, help="Maximum tokens per setTraits call (default: 250)"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        output = convert_csv(args.input, args.batch_size)
    except (OSError, TraitInputError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    warnings = output.pop("warnings")
    serialized = json.dumps(output, indent=2) + "\n"
    if args.output:
        args.output.write_text(serialized, encoding="utf-8")
    else:
        print(serialized, end="")
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
