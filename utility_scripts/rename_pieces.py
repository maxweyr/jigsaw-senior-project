import os
import shutil
import json

""" This script renumbers and renames the puzzle pieces generated from Piecemaker software. Warning: The Piecemaker software run on Docker outputs a different file structure than what this script assumes. See create_puzzle_folder.py script for how to convert from Docker file structure to the "standard." See documention for puzzle folder structure. """


# ===================== CONFIG =====================
PUZZLE_NAMES = [
    "barn", "bunny", "carwash", "cats", "classiccar", "cobblestone",
    "fiftiestown", "fruitpainting", "goldengate", "hobbithole",
    "japan", "macaroon", "oceanpainting", "pinkflower", "puppies",
    "stockholm", "tajmahal", "venice"
]
SIZES = ["10", "100", "500"]
OUTPUT_ROOT = "./Renumbered"  # Root folder for renumbered puzzles
# ==================================================

# ---------------- HELPERS ----------------
def ensure_dir(path):
    if not os.path.exists(path):
        os.makedirs(path)

def process_puzzle(puzzle_dir, output_dir):
    """Process a single puzzle folder and create renumbered version."""
    print(f"\n{'='*60}")
    print(f"Processing: {puzzle_dir}")
    print(f"{'='*60}")
    
    # Load index.json
    index_path = os.path.join(puzzle_dir, "index.json")
    if not os.path.exists(index_path):
        print(f"ERROR: index.json not found in {puzzle_dir}, skipping...")
        return False
    
    try:
        with open(index_path, "r") as f:
            index_data = json.load(f)
    except Exception as e:
        print(f"ERROR: Failed to load index.json: {e}")
        return False

    pieces = index_data["piece_properties"]

    # ---------- Build lookup tables ----------
    piece_by_id = {}
    mid_y_by_id = {}
    piece_heights = []

    for p in pieces:
        pid = int(p["id"])
        ox = p["ox"]
        oy = p["oy"]
        oh = p["oh"]

        mid_y = oy + oh / 2.0

        piece_by_id[pid] = p
        mid_y_by_id[pid] = mid_y
        piece_heights.append(oh)

    # ---------- Dynamic ROW_TOLERANCE ----------
    sorted_heights = sorted(piece_heights)
    median_height = sorted_heights[len(sorted_heights)//2]
    ROW_TOLERANCE = max(3.0, median_height * 0.25)
    MERGE_TOLERANCE = ROW_TOLERANCE * 1.5

    print(f"Dynamic ROW_TOLERANCE: {ROW_TOLERANCE:.2f}")
    print(f"Merge Tolerance: {MERGE_TOLERANCE:.2f}")

    # ---------- Initial row grouping ----------
    sorted_pieces = sorted(mid_y_by_id.items(), key=lambda x: x[1])

    rows = []  # each row: { "pieces": [ids] }

    for pid, mid_y in sorted_pieces:
        placed = False

        for row in rows:
            # compare with average mid_y of existing row
            row_mid = sum(mid_y_by_id[x] for x in row["pieces"]) / len(row["pieces"])
            if abs(mid_y - row_mid) <= ROW_TOLERANCE:
                row["pieces"].append(pid)
                placed = True
                break

        if not placed:
            rows.append({ "pieces": [pid] })

    # ---------- Merge nearby rows ----------
    merged = True
    while merged:
        merged = False
        new_rows = []
        used = [False] * len(rows)

        for i in range(len(rows)):
            if used[i]:
                continue

            base = rows[i]["pieces"]
            base_mid = sum(mid_y_by_id[x] for x in base) / len(base)

            for j in range(i + 1, len(rows)):
                if used[j]:
                    continue

                other = rows[j]["pieces"]
                other_mid = sum(mid_y_by_id[x] for x in other) / len(other)

                if abs(base_mid - other_mid) <= MERGE_TOLERANCE:
                    base.extend(other)
                    used[j] = True
                    merged = True

            new_rows.append({ "pieces": base })
            used[i] = True

        rows = new_rows

    # ---------- Sort rows top → bottom ----------
    rows = sorted(
        rows,
        key=lambda r: sum(mid_y_by_id[x] for x in r["pieces"]) / len(r["pieces"])
    )

    # ---------- Sort columns left → right within each row ----------
    rows = [sorted(r["pieces"], key=lambda pid: piece_by_id[pid]["ox"]) for r in rows]

    # ---------- Build renumbering maps ----------
    RENAME_MAP = {}      # new_id -> old_id
    old_to_new = {}      # old_id -> new_id

    new_id = 0
    for r, row in enumerate(rows):
        for c, old_id in enumerate(row):
            RENAME_MAP[new_id] = old_id
            old_to_new[old_id] = new_id
            new_id += 1

    # ---------- Debug prints ----------
    print(f"\nFound {len(rows)} rows with {len(pieces)} total pieces")
    print("Row layout (NEW IDs):")
    for i, row in enumerate(rows):
        print(f"Row {i}: {[old_to_new[pid] for pid in row]}")

    # -------- Copy and rename images/folders ----------
    pieces_src = os.path.join(puzzle_dir, "pieces")
    pieces_dst = os.path.join(output_dir, "pieces")
    ensure_dir(pieces_dst)

    for subfolder in ["mask", "raster", "raster_with_padding", "vector"]:
        src = os.path.join(pieces_src, subfolder)
        dst = os.path.join(pieces_dst, subfolder)
        
        if not os.path.exists(src):
            continue
            
        ensure_dir(dst)
        
        if subfolder in ["raster", "raster_with_padding"]:
            for fname in os.listdir(src):
                old_path = os.path.join(src, fname)
                if not os.path.isfile(old_path):
                    continue
                name, ext = os.path.splitext(fname)
                try:
                    old_id = int(name)
                    new_id = None
                    for k, v in RENAME_MAP.items():
                        if v == old_id:
                            new_id = k
                            break
                    if new_id is None:
                        raise ValueError(f"No new_id for old_id {old_id}")
                    shutil.copyfile(old_path, os.path.join(dst, f"{new_id}{ext}"))
                except ValueError:
                    shutil.copyfile(old_path, os.path.join(dst, fname))
        else:
            # Copy entire mask and vector folders as-is
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)

    # Copy other unchanged files from pieces folder
    pieces_unchanged_files = ["cut_proof-0.html", "lines-resized.png", "original-resized-0.jpg", "sides.json"]
    for f in pieces_unchanged_files:
        src = os.path.join(pieces_src, f)
        dst = os.path.join(pieces_dst, f)
        if os.path.exists(src):
            shutil.copyfile(src, dst)

    # Copy unchanged files from root puzzle folder
    unchanged_files = ["lines-resized.png", "lines-resized.svg", "lines.svg"]
    for f in unchanged_files:
        src = os.path.join(puzzle_dir, f)
        dst = os.path.join(output_dir, f)
        if os.path.exists(src):
            shutil.copyfile(src, dst)

    # -------- Update JSON files ----------
    def update_json_keys(json_path, out_path):
        with open(json_path, "r") as f:
            data = json.load(f)
        new_data = {str(new_id): data[str(old_id)] for new_id, old_id in RENAME_MAP.items()}
        new_data = dict(sorted(new_data.items(), key=lambda x: int(x[0])))
        with open(out_path, "w") as f:
            json.dump(new_data, f, indent=2)

    # Update piece_id_to_mask.json
    piece_mask_path = os.path.join(pieces_src, "piece_id_to_mask.json")
    if os.path.exists(piece_mask_path):
        update_json_keys(piece_mask_path, os.path.join(pieces_dst, "piece_id_to_mask.json"))

    # Update pieces.json (check both locations)
    pieces_json_path = os.path.join(pieces_src, "pieces.json")
    if os.path.exists(pieces_json_path):
        update_json_keys(pieces_json_path, os.path.join(pieces_dst, "pieces.json"))
    else:
        pieces_json_path = os.path.join(puzzle_dir, "pieces.json")
        if os.path.exists(pieces_json_path):
            update_json_keys(pieces_json_path, os.path.join(output_dir, "pieces.json"))

    # ---------- Generate new adjacency (left, up, right, down) ----------
    num_rows = len(rows)
    new_adj = {}

    for r in range(num_rows):
        for c in range(len(rows[r])):
            old_id = rows[r][c]
            nid = old_to_new[old_id]

            neighbors = []

            # LEFT
            if c - 1 >= 0:
                neighbors.append(old_to_new[rows[r][c - 1]])

            # UP
            if r - 1 >= 0 and c < len(rows[r - 1]):
                neighbors.append(old_to_new[rows[r - 1][c]])

            # RIGHT
            if c + 1 < len(rows[r]):
                neighbors.append(old_to_new[rows[r][c + 1]])

            # DOWN
            if r + 1 < num_rows and c < len(rows[r + 1]):
                neighbors.append(old_to_new[rows[r + 1][c]])

            new_adj[str(nid)] = [str(x) for x in neighbors]

    # Sort the adjacent.json by piece ID
    new_adj = dict(sorted(new_adj.items(), key=lambda x: int(x[0])))

    with open(os.path.join(output_dir, "adjacent.json"), "w") as f:
        json.dump(new_adj, f, indent=2)

    # Update index.json piece_properties
    new_piece_properties = []
    for new_id, old_id in RENAME_MAP.items():
        for p in index_data["piece_properties"]:
            if int(p["id"]) == old_id:
                new_p = p.copy()
                new_p["id"] = str(new_id)
                new_piece_properties.append(new_p)
                break

    new_piece_properties = sorted(new_piece_properties, key=lambda x: int(x["id"]))
    index_data["piece_properties"] = new_piece_properties

    with open(os.path.join(output_dir, "index.json"), "w") as f:
        json.dump(index_data, f, indent=2)

    print(f"✓ Successfully renumbered and saved to {output_dir}")
    return True

# ---------------- MAIN ----------------
ensure_dir(OUTPUT_ROOT)

# Process all puzzles
total_puzzles = len(PUZZLE_NAMES) * len(SIZES)
processed = 0
skipped = 0
failed = 0

print(f"\n{'#'*60}")
print(f"BATCH PROCESSING: {total_puzzles} PUZZLES")
print(f"Output directory: {OUTPUT_ROOT}")
print(f"{'#'*60}")

for name in sorted(PUZZLE_NAMES):
    for size in sorted(SIZES):
        puzzle_dir = f"./{name}_{size}"
        output_dir = os.path.join(OUTPUT_ROOT, f"{name}_{size}")
        
        if not os.path.exists(puzzle_dir):
            print(f"\nWARNING: {puzzle_dir} does not exist, skipping...")
            skipped += 1
            continue
        
        ensure_dir(output_dir)
        
        try:
            success = process_puzzle(puzzle_dir, output_dir)
            if success:
                processed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"\nERROR processing {puzzle_dir}: {e}")
            import traceback
            traceback.print_exc()
            failed += 1

print(f"\n{'#'*60}")
print(f"BATCH PROCESSING COMPLETE")
print(f"{'#'*60}")
print(f"Total puzzles: {total_puzzles}")
print(f"Successfully processed: {processed}")
print(f"Skipped (not found): {skipped}")
print(f"Failed: {failed}")
print(f"\nAll renumbered puzzles saved to: {OUTPUT_ROOT}")
