-- Creates a view that generates all (pseudo-legal) moves for knights and kings.

-- Cleanup
DROP VIEW IF EXISTS pseudo_legal_moves_knight_king;

CREATE VIEW pseudo_legal_moves_knight_king AS
-- Define movement offsets for knights and kings
-- Each row is a (file_offset, rank_offset) pair
-- This defines 'x' and 'y' movement in the chess grid
WITH knight_offsets AS (
	SELECT file_offset, rank_offset
	FROM (VALUES
		(-2, -1), (-2, +1),
		(-1, -2), (-1, +2),
		(+1, -2), (+1, +2),
		(+2, -1), (+2, +1)
	) AS t(file_offset, rank_offset)
),
king_offsets AS (
	SELECT file_offset, rank_offset
	FROM (VALUES
		(-1, -1), (-1, 0), (-1, +1),
		( 0, -1),          ( 0, +1),
		(+1, -1), (+1, 0), (+1, +1)
	) AS t(file_offset, rank_offset)
),

-- Combine both into one set, tagging which piece each belongs to.
piece_offsets AS(
	SELECT 'N' AS piece, file_offset, rank_offset FROM knight_offsets
	UNION ALL
	SELECT 'K' AS piece, file_offset, rank_offset FROM king_offsets
),

-- Find the current position
current_move AS (
	SELECT MAX(move_number) AS move_number
	FROM game_state
	WHERE game_id = 1
),

-- Get the side that is to move
current_side AS (
	SELECT gs.side_to_move
	FROM game_state gs
	JOIN current_move cm ON gs.move_number = cm.move_number
	WHERE gs.game_id = 1
),

-- Get all pieces on the board at the current position
pieces AS (
	SELECT bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	JOIN current_move cm ON bs.move_number = cm.move_number
	WHERE bs.game_id = 1
),

-- For each knight/king of the side to move, apply offsets
-- ascii(file) converts 'a' -> 97, 'b' -> 98, etc.
-- The offset is added directly in ASCII space, then result is checked to ensure
-- it's between ascii('a')=97 and ascii('h')=104 (i.e. still on the board).
-- chr() converts the resulting ASCII code back to a letter.
candidate_moves AS (
	SELECT
		p.file AS from_file,
		p.rank AS from_rank,
		p.piece AS piece,
		p.color AS color,
		chr(ascii(p.file) + po.file_offset) AS to_file,
		p.rank + po.rank_offset             AS to_rank
	FROM pieces p
	JOIN current_side cs ON p.color = cs.side_to_move
	JOIN piece_offsets po ON p.piece = po.piece
	WHERE
		-- Check that destination of piece is within bounds of chess board
		ascii(p.file) + po.file_offset BETWEEN ascii('a') AND ascii('h')
		AND p.rank + po.rank_offset BETWEEN 1 AND 8
)

-- Filter out moves that land on a friendly place
-- LEFT JOIN against all pieces at the destination square:
--   * If no piece there (target is NULL): legal (move to empty square) 
--   * If enemy piece there: legal (capture)
--   * If friendly piece there: illegal

SELECT
	cm.from_file,
	cm.from_rank,
	cm.piece,
	cm.color,
	cm.to_file,
	cm.to_rank,
	target.piece AS captured_piece
FROM candidate_moves cm
LEFT JOIN pieces target
	ON cm.to_file = target.file AND cm.to_rank = target.rank
WHERE
	target.color IS NULL -- empty square
	OR target.color != cm.color -- enemy piece
