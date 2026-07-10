import json
from pathlib import Path

MANIFEST_PATH = Path(__file__).with_name("functional_test_durations.json")
TEST_EXTENSIONS = (".sql.j2", ".sql", ".sh", ".py", ".expect")


def load_test_durations(build_family: str = "default") -> dict[str, int]:
    manifest = json.loads(MANIFEST_PATH.read_text())
    families = manifest["build_families"]
    return {
        **families.get("default", {}),
        **families.get(build_family, {}),
    }


def is_sequential_test(path: Path) -> bool:
    comment = "--" if path.name.endswith((".sql", ".sql.j2")) else "#"
    with path.open(encoding="utf-8", errors="ignore") as source:
        for line in source:
            if not line.startswith(comment):
                continue
            text = line[len(comment) :].lstrip()
            if not text.startswith("Tags:"):
                continue
            tags = {tag.strip() for tag in text.removeprefix("Tags:").split(",")}
            return "no-parallel" in tags or "sequential" in tags
    return False


def assign_test_batches(
    test_files: list[str],
    total_batches: int,
    durations: dict[str, int],
) -> list[list[str]]:
    if total_batches <= 0:
        raise ValueError("total_batches must be positive")

    batches: list[list[str]] = [[] for _ in range(total_batches)]
    weights = [0] * total_batches
    known = sorted(
        ((name, durations[name]) for name in test_files if durations.get(name, 0) > 0),
        key=lambda item: (-item[1], item[0]),
    )
    unknown = sorted(name for name in test_files if durations.get(name, 0) <= 0)

    for name, duration in known:
        batch = min(range(total_batches), key=lambda index: (weights[index], index))
        batches[batch].append(name)
        weights[batch] += duration

    for index, name in enumerate(unknown):
        batches[index % total_batches].append(name)

    for batch in batches:
        batch.sort(key=lambda name: (-durations.get(name, 0), name))
    return batches


def selected_test_batch(
    test_dir: Path,
    test_files: list[str],
    batch_number: int,
    total_batches: int,
    build_family: str = "default",
    sequential_only: bool | None = None,
) -> set[str]:
    if total_batches <= 0:
        raise ValueError("total_batches must be positive")
    if batch_number < 0 or batch_number >= total_batches:
        raise ValueError(
            f"batch_number must be between 0 and {total_batches - 1}, got {batch_number}"
        )

    selected = []
    for name in test_files:
        if not name.endswith(TEST_EXTENSIONS):
            continue
        sequential = is_sequential_test(test_dir / name)
        if sequential_only is not None and sequential != sequential_only:
            continue
        selected.append(name)

    batches = assign_test_batches(
        selected, total_batches, load_test_durations(build_family)
    )
    return set(batches[batch_number])


def source_test_name(test_name: str) -> str:
    if test_name.endswith(".gen.sql"):
        stem = test_name.removesuffix(".gen.sql")
        return f"{stem}.sql.j2"
    return test_name
