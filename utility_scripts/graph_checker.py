import json
import os
from typing import Dict, Set, List


""" This script checks the adjacency list in adjacent.json is a consistent graph for each puzzle in the current directory where the name is <PUZZLENAME>_<PUZZLESIZE>.""" 


PUZZLE_NAMES = {
    "barn", "bunny", "carwash", "cats", "classiccar", "cobblestone",
    "fiftiestown", "fruitpainting", "goldengate", "hobbithole",
    "japan", "macaroon", "oceanpainting", "pinkflower", "puppies",
    "stockholm", "tajmahal", "venice"
}

SIZES = {"10", "100", "500"}


def check_graph_consistency(adj: Dict[str, List[str]]) -> List[str]:
    """
    Check if adjacency list represents a consistent undirected graph.
    """
    errors = []

    # Normalize graph to sets of strings
    graph: Dict[str, Set[str]] = {
        str(node): set(map(str, neighbors))
        for node, neighbors in adj.items()
    }

    nodes = set(graph.keys())

    for node, neighbors in graph.items():
        # Optional sanity check
        if node in neighbors:
            errors.append(f"Self-loop detected: {node} -> {node}")

        for neighbor in neighbors:
            if neighbor not in nodes:
                errors.append(
                    f"Missing node reference: {node} -> {neighbor}"
                )
                continue

            if node not in graph[neighbor]:
                errors.append(
                    f"Asymmetric adjacency: {node} -> {neighbor} "
                    f"but {neighbor} -> {node} is missing"
                )

    return errors


def is_valid_puzzle_folder(name: str) -> bool:
    """
    Check if folder matches puzzleName_size format.
    """
    if "_" not in name:
        return False

    puzzle, size = name.rsplit("_", 1)
    return puzzle in PUZZLE_NAMES and size in SIZES


def check_all_puzzles(root_folder: str):
    total_files = 0
    total_errors = 0

    for entry in sorted(os.listdir(root_folder)):
        puzzle_path = os.path.join(root_folder, entry)

        if not os.path.isdir(puzzle_path):
            continue

        if not is_valid_puzzle_folder(entry):
            continue

        json_path = os.path.join(puzzle_path, "adjacent.json")
        total_files += 1

        if not os.path.exists(json_path):
            print(f"\n❌ {entry}: adjacent.json missing")
            total_errors += 1
            continue

        try:
            with open(json_path, "r") as f:
                data = json.load(f)
        except json.JSONDecodeError as e:
            print(f"\n❌ {entry}: Invalid JSON ({e})")
            total_errors += 1
            continue

        if not isinstance(data, dict):
            print(f"\n❌ {entry}: JSON root must be a dictionary")
            total_errors += 1
            continue

        errors = check_graph_consistency(data)

        if errors:
            total_errors += len(errors)
            print(f"\n❌ {entry} — {len(errors)} error(s)")
            for err in errors:
                print("  -", err)
        else:
            print(f"\n✅ {entry}: Graph is consistent")

    print("\n================ SUMMARY ================")
    print(f"Puzzles checked: {total_files}")
    print(f"Total errors:    {total_errors}")


if __name__ == "__main__":
    check_all_puzzles("Renumbered")

