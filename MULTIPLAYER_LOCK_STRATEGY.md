# Multiplayer Lock Strategy

## Goals
- Prevent two players from moving or merging the same group at the same time.
- Keep runtime authority on the server and minimize race conditions.
- Use a lazy, lobby-scoped lock cache (no pre-built list).

## Core Idea
Each lobby maintains a lock map keyed by group_id. A group is considered unlocked if it is absent from the map. Clients must request a lock before selecting or moving a group. Merges are only accepted if the source group is locked by the caller and the target group is not locked by another player.

## Server State (per lobby)
- `lobby_group_locks`: `group_id -> { owner, expires_at }`
- `lobby_piece_groups`: `piece_id -> group_id` (lazy map for validation)
- `LOCK_TTL_SEC`: lock expiration window (refresh on move/merge)

## RPC Contract
Client -> Server:
- `request_group_lock(piece_id, group_id_hint)`
  - Resolves group_id, tries to acquire lock, responds with grant/deny.
- `release_group_lock(piece_id, group_id_hint)`
  - Releases if owned by caller.
- `_receive_piece_move(group_id, piece_positions)`
  - Accepted only if caller owns lock; refreshes lock TTL.
- `sync_connected_pieces(piece_id, connected_piece_id, source_group_id, target_group_id, new_group_id, piece_positions)`
  - Accepted only if caller owns source lock and target is not locked by another player.
  - Server validates final group_id and rebroadcasts canonical merge.

Server -> Client:
- `_lock_granted(piece_id, group_id)`
- `_lock_denied(piece_id, group_id, owner_id)`
- `_receive_piece_move_client(piece_positions)`
- `_receive_piece_connection(piece_id, connected_piece_id, new_group_id, piece_positions)`

## Client Flow
1. On click:
   - Online: request lock for the group; select only after grant.
   - Offline: select immediately.
2. While dragging:
   - Only allow movement if lock is held.
3. On release:
   - If a merge happened: send merge RPC (server validates).
   - Otherwise: send move RPC.
   - Release lock afterward.

## Validation Rules (Server)
- Move update: caller must own the group lock.
- Merge: caller must own source lock; target group must be unlocked (or owned by caller if you allow same-owner merges).
- Ignore stale/invalid updates; do not rebroadcast them.

## Lock Cleanup
- TTL expiry: lock is removed when `expires_at` is in the past.
- Disconnect: release all locks owned by the peer.
- Merge: release old group lock and retain/transfer lock to the merged group.

## Persistence Notes
- Server remains authoritative for live gameplay.
- If persistence is needed, snapshot from the server (not clients) on merge/release or on a short timer.

## Integration Points
- Server logic: `assets/scripts/NetworkManager.gd`
- Client input/selection/merge: `assets/scripts/Piece_2d.gd`
