-- Creates two views:
--   1. en_passant_moves — generates en passant captures when available
--   2. pseudo_legal_moves_pawn - includes promotion

-- ============================================================
-- View: en_passant_moves
-- ============================================================
DROP VIEW IF EXISTS en_passant_moves;
DROP VIEW IF EXISTS pseudo_legal_moves_pawn;

CREATE VIEW en_passant_moves AS

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
current_state AS (
	SELECT gs.*
	FROM game_state gs
	JOIN current_move cm ON gs.move_number = cm.move_number
	WHERE gs.game_id = 1
),
pieces AS (
	SELECT bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	JOIN current_move cm ON bs.move_number = cm.move_number
	WHERE bs.game_id = 1
)

-- An en passant capture is available when:
--   1. en_passant_target is set in game_state (a pawn just double-pushed)
--   2. A friendly pawn is adjacent to the target square's file
--   3. The friendly pawn is on the correct rank (5 for white, 4 for black)
SELECT
	p.file	  AS from_file,
	p.rank	  AS from_rank,
	'P'		 AS piece,
	p.color	 AS color,
	-- The destination is the en passant target square
	substring(st.en_passant_target from 1 for 1) AS to_file,
	substring(st.en_passant_target from 2 for 1)::INT AS to_rank,
	'P'::CHAR(1) AS captured_piece
FROM current_state st
JOIN current_side cs ON TRUE
JOIN pieces p ON p.piece = 'P' AND p.color = cs.side_to_move
WHERE
	st.en_passant_target IS NOT NULL
	-- Pawn must be adjacent (one file away from target)
	AND abs(ascii(p.file) - ascii(substring(st.en_passant_target from 1 for 1))) = 1
	-- Pawn must be on the correct rank for en passant
	-- White captures en passant from rank 5, black from rank 4
	AND p.rank = CASE WHEN cs.side_to_move = 'w' THEN 5 ELSE 4 END;


-- ============================================================
-- Recreate pawn moves view to include promotion.
-- A pawn reaching the final rank (8 for white, 1 for black)
-- must promote. Generate 4 moves per promotion (Q, R, B, N).
-- Mark promotions by storing the promotion piece in a special way.
-- ============================================================
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
pawns AS (
	SELECT
		p.file,
		p.rank,
		p.color,
		CASE WHEN p.color = 'w' THEN +1 ELSE -1 END AS direction,
		CASE WHEN p.color = 'w' THEN 2   ELSE 7   END AS start_rank,
		CASE WHEN p.color = 'w' THEN 8   ELSE 1   END AS promo_rank
	FROM pieces p
	JOIN current_side cs ON p.color = cs.side_to_move
	WHERE p.piece = 'P'
),

-- Non-promotion single pushes (destination is NOT the promotion rank)
single_pushes AS (
	SELECT
		pw.file AS from_file, pw.rank AS from_rank,
		'P' AS piece, pw.color AS color,
		pw.file AS to_file, pw.rank + pw.direction AS to_rank,
		NULL::CHAR(1) AS captured_piece
	FROM pawns pw
	WHERE NOT EXISTS (
		SELECT 1 FROM pieces occ
		WHERE occ.file = pw.file AND occ.rank = pw.rank + pw.direction
	)
	AND pw.rank + pw.direction != pw.promo_rank
),

-- Double pushes (never a promotion)
double_pushes AS (
	SELECT
		pw.file AS from_file, pw.rank AS from_rank,
		'P' AS piece, pw.color AS color,
		pw.file AS to_file, pw.rank + (pw.direction * 2) AS to_rank,
		NULL::CHAR(1) AS captured_piece
	FROM pawns pw
	WHERE pw.rank = pw.start_rank
	AND NOT EXISTS (
		SELECT 1 FROM pieces occ
		WHERE occ.file = pw.file AND occ.rank = pw.rank + pw.direction
	)
	AND NOT EXISTS (
		SELECT 1 FROM pieces occ
		WHERE occ.file = pw.file AND occ.rank = pw.rank + (pw.direction * 2)
	)
),

-- Non-promotion captures
captures AS (
	SELECT
		pw.file AS from_file, pw.rank AS from_rank,
		'P' AS piece, pw.color AS color,
		chr(ascii(pw.file) + file_offset) AS to_file,
		pw.rank + pw.direction AS to_rank,
		target.piece AS captured_piece
	FROM pawns pw
	CROSS JOIN (VALUES (-1), (+1)) AS offsets(file_offset)
	JOIN pieces target
		ON ascii(target.file) = ascii(pw.file) + offsets.file_offset
		AND target.rank = pw.rank + pw.direction
	WHERE ascii(pw.file) + offsets.file_offset BETWEEN ascii('a') AND ascii('h')
	  AND target.color != pw.color
	  AND pw.rank + pw.direction != pw.promo_rank
),

-- Promotion pushes (pawn reaches final rank by pushing forward)
promotion_pushes AS (
	SELECT
		pw.file AS from_file, pw.rank AS from_rank,
		promo.promo_piece AS piece, pw.color AS color,
		pw.file AS to_file, pw.rank + pw.direction AS to_rank,
		NULL::CHAR(1) AS captured_piece
	FROM pawns pw
	CROSS JOIN (VALUES ('Q'), ('R'), ('B'), ('N')) AS promo(promo_piece)
	WHERE NOT EXISTS (
		SELECT 1 FROM pieces occ
		WHERE occ.file = pw.file AND occ.rank = pw.rank + pw.direction
	)
	AND pw.rank + pw.direction = pw.promo_rank
),

-- Promotion captures (pawn reaches final rank by capturing)
promotion_captures AS (
	SELECT
		pw.file AS from_file, pw.rank AS from_rank,
		promo.promo_piece AS piece, pw.color AS color,
		chr(ascii(pw.file) + file_offset) AS to_file,
		pw.rank + pw.direction AS to_rank,
		target.piece AS captured_piece
	FROM pawns pw
	CROSS JOIN (VALUES (-1), (+1)) AS offsets(file_offset)
	CROSS JOIN (VALUES ('Q'), ('R'), ('B'), ('N')) AS promo(promo_piece)
	JOIN pieces target
		ON ascii(target.file) = ascii(pw.file) + offsets.file_offset
		AND target.rank = pw.rank + pw.direction
	WHERE ascii(pw.file) + offsets.file_offset BETWEEN ascii('a') AND ascii('h')
	  AND target.color != pw.color
	  AND pw.rank + pw.direction = pw.promo_rank
)

SELECT * FROM single_pushes
UNION ALL SELECT * FROM double_pushes
UNION ALL SELECT * FROM captures
UNION ALL SELECT * FROM promotion_pushes
UNION ALL SELECT * FROM promotion_captures;
