-- Creates a view that generates all pseudo-legal pawn moves
-- Handles single push, double push, from starting rank, diagonal captures

-- Clean slate
DROP VIEW IF EXISTS pseudo_legal_moves_pawn;

CREATE VIEW pseudo_legal_moves_pawn AS

WITH current_move AS (
	SELECT MAX(move_number) AS move_number
	FROM game_state
	WHERE game_id = 1
),
current_side AS (
	SELECT gs.side_to_move
	FROM game_state gs
	JOIN current_move cm ON gs.move_number = cm.move_number
	WHERE gs.game_id = 1
),
pieces AS (
	SELECT bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	JOIN current_move cm ON bs.move_number = cm.move_number
	WHERE bs.game_id = 1
),
-- Get all pawns for the side to move and compute their direction
-- White pawns increase rank (+1) black pawns decrease rank (-1)
-- starting rank is 2 for white, 7 for black (used for two-square move eligibility)
pawns AS (
	SELECT
		p.file,
		p.rank,
		p.color,
		CASE WHEN p.color = 'w' THEN +1 ELSE -1 END AS direction,
		CASE WHEN p.color = 'w' THEN 2 ELSE 7 END as start_rank
	FROM pieces p
	JOIN current_side cs ON p.color = cs.side_to_move
	WHERE p.piece = 'P'
),

-- single 'push', one square forward. must be empty
single_pushes AS (
	SELECT
		pw.file                AS from_file,
		pw.rank                AS from_rank,
		'P'                    AS piece,
		pw.color               AS color,
		pw.file                AS to_file,
		pw.rank + pw.direction AS to_rank,
		NULL::CHAR(1)          AS captured_piece
	FROM pawns pw
	-- The destination square must be empty (no piece of any color)
	WHERE NOT EXISTS (
		SELECT 1 FROM pieces occ
		WHERE occ.file = pw.file
			AND occ.rank = pw.rank + pw.direction

	)
),

-- double 'push', two squares forward. intermediate AND destination squares must be empty
double_pushes AS (
	SELECT
		pw.file     AS from_file,
		pw.rank     AS from_rank,
		'P'         AS piece,
		pw.color    AS color,
		pw.file     AS to_file,
		pw.rank + (pw.direction * 2) AS to_rank,
		NULL::CHAR(1) AS captured_piece
	FROM pawns pw
	WHERE
		-- Must be on starting rank
		pw.rank = pw.start_rank
		-- Intermediate square (one ahead) must be empty
		AND NOT EXISTS (
			SELECT 1 FROM pieces occ
			WHERE occ.file = pw.file
				AND occ.rank = pw.rank + pw.direction
		)
		-- Destination square (two ahead) must be empty
		AND NOT EXISTS (
			SELECT 1 FROM pieces occ
			WHERE occ.file = pw.file
				AND occ.rank = pw.rank + (pw.direction * 2)
		)
),

-- Diagonal captures: one square diagonally forward but ONLY if enemy piece is there
captures AS (
	SELECT
		pw.file                           AS from_file,
		pw.rank                           AS from_rank,
		'P'                               AS piece,
		pw.color                          AS color,
		chr(ascii(pw.file) + file_offset) AS to_file,
		pw.rank + pw.direction            AS to_rank,
		target.piece                      AS captured_piece
	FROM pawns pw
	-- Two capture directions: left diagonal vs right diagonal
	CROSS JOIN (VALUES (-1), (+1)) AS offsets(file_offset)
	-- Must be on the board
	JOIN pieces target
		ON ascii(target.file) = ascii(pw.file) + offsets.file_offset
		AND target.rank = pw.rank + pw.direction
    WHERE
		-- Destination file must be on the board
		ascii(pw.file) + offsets.file_offset BETWEEN ascii('a') AND ascii('h')
		-- Must be an enemy piece (not friendly)
		AND target.color != pw.color
)

-- Combine all three move types
SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece FROM single_pushes
UNION ALL
SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece FROM double_pushes
UNION ALL
SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece FROM captures;
