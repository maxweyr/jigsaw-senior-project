#!/usr/bin/env python3
import os
import shutil
from pathlib import Path

""" This script converts the puzzle folder structure from the output of Docker to the standard structure that the Godot game assumes/is based on."""


# === CONFIG ===
OUTPUT_ROOT = Path(".")  # CPE350-Jigsaw
SIZES = [10, 100, 500]
EXCLUDE = ["barn_puzzles"]  # folders to skip

def copy_files(src, dst):
    """Copy all files from src to dst, creating dst if needed."""
    if not src.exists():
        print(f"WARNING: Source folder {src} does not exist")
        return
    os.makedirs(dst, exist_ok=True)
    for item in src.iterdir():
        if item.is_file():
            shutil.copy(item, dst)

def process_puzzle(puzzle_folder: Path):
    """Create the _size folders for a puzzle and copy files."""
    puzzle_name = puzzle_folder.name.replace("_puzzles", "")
    output_dir = puzzle_folder / "output"
    if not output_dir.exists():
        print(f"ERROR: {output_dir} does not exist")
        return

    for size in SIZES:
        # Find the corresponding piecemaker-* folder for this size
        size_folders = [f for f in output_dir.iterdir() 
                        if f.is_dir() and f.name.startswith(f"piecemaker-{size}-")]
        if not size_folders:
            print(f"WARNING: No piecemaker-{size}-* folder found in {output_dir}")
            continue
        piecemaker_folder = size_folders[0]

        # Timestamp folder (exactly one)
        ts_folders = [f for f in piecemaker_folder.iterdir() if f.is_dir()]
        if len(ts_folders) != 1:
            print(f"WARNING: Expected 1 timestamp folder in {piecemaker_folder}, found {len(ts_folders)}")
            continue
        ts_folder = ts_folders[0]

        # Second output folder inside timestamp folder
        second_output_folder = ts_folder / "output"
        if not second_output_folder.exists():
            print(f"ERROR: {second_output_folder} does not exist")
            continue

        # size-* folder (exactly one)
        size_dirs = [f for f in second_output_folder.iterdir() if f.is_dir() and f.name.startswith("size-")]
        if len(size_dirs) != 1:
            print(f"WARNING: Expected 1 size-* folder in {second_output_folder}, found {len(size_dirs)}")
            continue
        size_folder = size_dirs[0]

        # Prepare destination folder
        output_folder = OUTPUT_ROOT / f"{puzzle_name}_{size}"
        pieces_folder = output_folder / "pieces"
        os.makedirs(pieces_folder, exist_ok=True)

        # --- Copy pieces ---
        copy_files(size_folder / "mask", pieces_folder / "mask")
        copy_files(size_folder / "raster" / "image-0", pieces_folder / "raster")
        copy_files(size_folder / "raster_with_padding" / "image-0", pieces_folder / "raster_with_padding")
        copy_files(size_folder / "vector", pieces_folder / "vector")

        # Copy files from size folder to pieces/
        for fname in ["cut_proof-0.html", "lines-resized.png", "original-resized-0.jpg",
                      "piece_id_to_mask.json", "pieces.json", "sides.json"]:
            src_file = size_folder / fname
            if src_file.exists():
                shutil.copy(src_file, pieces_folder)

        # Copy top-level files from second_output_folder
        for fname in ["adjacent.json", "index.json", "lines.svg", "lines-resized.png", "lines-resized.svg"]:
            src_file = second_output_folder / fname
            if src_file.exists():
                shutil.copy(src_file, output_folder)

        print(f"Processed {puzzle_name}_{size}")

def main():
    # Loop over all *_puzzles folders in current directory
    for folder in OUTPUT_ROOT.iterdir():
        if folder.is_dir() and folder.name.endswith("_puzzles") and folder.name not in EXCLUDE:
            print(f"\nProcessing puzzle folder: {folder.name}")
            process_puzzle(folder)

    print("\nAll done!")

if __name__ == "__main__":
    main()

