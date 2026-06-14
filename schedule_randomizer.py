#!/usr/bin/env python3
"""Randomize per-account AutoRewarder schedules before a headless run."""

import argparse
import json
import math
import os
import random
from dataclasses import dataclass
from datetime import datetime, time
from pathlib import Path

from src.config import ACCOUNTS_DIR


PC_MIN = 30
PC_MAX = 35
MOBILE_MIN = 20
MOBILE_MAX = 25
QPH_BATCH_TARGET = 10
DEFAULT_DEADLINE_HOUR = 23
DEFAULT_DEADLINE_MINUTE = 0
DEFAULT_SAFETY_BUFFER_MINUTES = 30


@dataclass
class AccountRoll:
    account_id: str
    meta_path: Path
    meta: dict
    schedule: dict
    pc: int
    mobile: int
    duration: int

    @property
    def total_queries(self):
        return self.pc + self.mobile


def ceil_div(numerator, denominator):
    """Return integer ceiling division for positive values."""
    return int(math.ceil(float(numerator) / float(max(1, denominator))))


def app_accounts_dir():
    """Return the default AutoRewarder accounts directory for this platform."""
    return Path(ACCOUNTS_DIR)


def read_json(path):
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def write_json(path, data):
    temp_path = path.with_name(path.name + ".tmp")
    with temp_path.open("w", encoding="utf-8") as file:
        json.dump(data, file, indent=4)
    os.replace(temp_path, path)


def clamp(value, minimum, maximum):
    return max(minimum, min(maximum, int(value)))


def discover_ready_accounts(accounts_dir, rng):
    rolls = []
    for meta_path in sorted(Path(accounts_dir).glob("*/meta.json")):
        try:
            meta = read_json(meta_path)
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            print(f"Skipping {meta_path}: cannot read JSON ({exc})")
            continue

        schedule = meta.get("schedule")
        if not isinstance(schedule, dict):
            continue
        if not meta.get("first_setup_done"):
            continue
        if not schedule.get("enabled"):
            continue

        rolls.append(
            AccountRoll(
                account_id=meta_path.parent.name,
                meta_path=meta_path,
                meta=meta,
                schedule=schedule,
                pc=rng.randint(PC_MIN, PC_MAX),
                mobile=rng.randint(MOBILE_MIN, MOBILE_MAX),
                duration=1,
            )
        )
    return rolls


def available_duration_hours(now, deadline_hour, deadline_minute, safety_buffer_minutes):
    deadline = datetime.combine(now.date(), time(deadline_hour, deadline_minute))
    seconds = (deadline - now).total_seconds() - (safety_buffer_minutes * 60)
    return max(0.0, seconds / 3600)


def allocate_proportional_durations(rolls, available_hours):
    """Allocate available hours across accounts by each account's query share."""
    if not rolls:
        return

    if available_hours <= 0:
        for roll in rolls:
            roll.duration = 1
        return

    if available_hours <= len(rolls):
        for roll in rolls:
            roll.duration = 1
        return

    total_queries = sum(roll.total_queries for roll in rolls)
    if total_queries <= 0:
        for roll in rolls:
            roll.duration = 1
        return

    for roll in rolls:
        exact = (available_hours * roll.total_queries) / total_queries
        duration = max(1.0, exact)
        roll.duration = math.floor(duration * 100) / 100


def randomize_account_schedules(
    accounts_dir=None,
    rng=None,
    now=None,
    deadline_hour=DEFAULT_DEADLINE_HOUR,
    deadline_minute=DEFAULT_DEADLINE_MINUTE,
    safety_buffer_minutes=DEFAULT_SAFETY_BUFFER_MINUTES,
):
    """Randomize schedule fields for enabled, ready accounts."""
    accounts_dir = Path(accounts_dir) if accounts_dir is not None else app_accounts_dir()
    rng = rng if rng is not None else random.SystemRandom()
    now = now if now is not None else datetime.now()

    rolls = discover_ready_accounts(accounts_dir, rng)
    budget = available_duration_hours(
        now, deadline_hour, deadline_minute, safety_buffer_minutes
    )
    allocate_proportional_durations(rolls, budget)

    changes = []
    for roll in rolls:
        old = {
            "runDuration": roll.schedule.get("runDuration"),
            "queriesPerHour": roll.schedule.get("queriesPerHour"),
            "queries_pc": roll.schedule.get("queries_pc"),
            "queries_mobile": roll.schedule.get("queries_mobile"),
        }

        roll.schedule["queries_pc"] = roll.pc
        roll.schedule["queries_mobile"] = roll.mobile
        roll.schedule["runDuration"] = roll.duration
        roll.schedule["queriesPerHour"] = QPH_BATCH_TARGET
        roll.meta["schedule"] = roll.schedule
        write_json(roll.meta_path, roll.meta)

        new = {
            "runDuration": roll.duration,
            "queriesPerHour": QPH_BATCH_TARGET,
            "queries_pc": roll.pc,
            "queries_mobile": roll.mobile,
            "effectiveQueriesPerHour": round(
                roll.total_queries / max(1, roll.duration), 2
            ),
        }
        changes.append({"account_id": roll.account_id, "old": old, "new": new})

    return changes


def main():
    parser = argparse.ArgumentParser(
        description="Randomize AutoRewarder per-account schedules."
    )
    parser.add_argument("--accounts-dir", default=str(app_accounts_dir()))
    parser.add_argument("--deadline-hour", type=int, default=DEFAULT_DEADLINE_HOUR)
    parser.add_argument("--deadline-minute", type=int, default=DEFAULT_DEADLINE_MINUTE)
    parser.add_argument(
        "--safety-buffer-minutes", type=int, default=DEFAULT_SAFETY_BUFFER_MINUTES
    )
    args = parser.parse_args()

    changes = randomize_account_schedules(
        accounts_dir=args.accounts_dir,
        deadline_hour=args.deadline_hour,
        deadline_minute=args.deadline_minute,
        safety_buffer_minutes=args.safety_buffer_minutes,
    )

    if not changes:
        print("No enabled ready account schedules found to randomize.")
        return 0

    for change in changes:
        old = change["old"]
        new = change["new"]
        print(
            f"{change['account_id']}: "
            f"PC {old['queries_pc']} -> {new['queries_pc']}, "
            f"mobile {old['queries_mobile']} -> {new['queries_mobile']}, "
            f"duration {old['runDuration']}h -> {new['runDuration']}h, "
            f"QPH {old['queriesPerHour']} -> {new['queriesPerHour']} "
            f"(effective {new['effectiveQueriesPerHour']}/h)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
