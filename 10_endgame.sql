-- Creates a view that reports the current game status:
--   'checkmate_white' / 'checkmate_black' — game over, winner declared
--   'stalemate' — draw, no legal moves but not in check
--   'draw_50_move' — draw by 50-move rule
--   'check' — king is in check but has legal moves
--   'in_progress' — normal play continues
--
-- Also updates make_move to announce game-ending conditions.

-- ============================================================
-- View: game_status
-- ============================================================
DROP VIEW IF EXISTS game_status;

CREATE VIEW game_status AS

WITH current_move AS (
	SELECT MAX(move_number) AS move_number
	FROM game_state
	WHERE game_id = 1
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
),

-- Count legal moves for the side to move
move_count AS (
	SELECT COUNT(*) AS num_legal_moves
	FROM legal_moves
),

-- Check if the current side's king is under attack.
-- Done by generating opponent attacks against the king's position
-- on the CURRENT board (not a hypothetical one).
king_info AS (
	SELECT p.file AS king_file, p.rank AS king_rank, p.color
	FROM pieces p
	JOIN current_state st ON p.color = st.side_to_move
	WHERE p.piece = 'K'
),

-- Knight attacks on king
knight_check AS (
	SELECT 1
	FROM king_info ki
	JOIN pieces p ON p.piece = 'N' AND p.color != ki.color
	CROSS JOIN (VALUES
		(-2,-1),(-2,+1),(-1,-2),(-1,+2),
		(+1,-2),(+1,+2),(+2,-1),(+2,+1)
	) AS offsets(df, dr)
	WHERE ascii(p.file) = ascii(ki.king_file) + offsets.df
	  AND p.rank = ki.king_rank + offsets.dr
	LIMIT 1
),

-- Pawn attacks on king
pawn_check AS (
	SELECT 1
	FROM king_info ki
	JOIN pieces p ON p.piece = 'P' AND p.color != ki.color
	WHERE abs(ascii(p.file) - ascii(ki.king_file)) = 1
	  AND p.rank + CASE WHEN p.color = 'w' THEN 1 ELSE -1 END = ki.king_rank
	LIMIT 1
),

-- Sliding piece attacks on king
sliding_check AS (
	SELECT 1
	FROM king_info ki
	CROSS JOIN (VALUES
		(0,+1),(0,-1),(-1,0),(+1,0),
		(-1,-1),(-1,+1),(+1,-1),(+1,+1)
	) AS d(file_step, rank_step)
	JOIN LATERAL (
		WITH RECURSIVE ray_walk AS (
			SELECT
				ascii(ki.king_file) + d.file_step AS cf,
				ki.king_rank + d.rank_step AS cr,
				FALSE AS blocked
			WHERE
				ascii(ki.king_file) + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND ki.king_rank + d.rank_step BETWEEN 1 AND 8
			UNION ALL
			SELECT
				rw.cf + d.file_step,
				rw.cr + d.rank_step,
				EXISTS (
					SELECT 1 FROM pieces p3
					WHERE ascii(p3.file) = rw.cf + d.file_step
					  AND p3.rank = rw.cr + d.rank_step
				)
			FROM ray_walk rw
			WHERE
				rw.cf + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND rw.cr + d.rank_step BETWEEN 1 AND 8
				AND NOT rw.blocked
				AND NOT EXISTS (
					SELECT 1 FROM pieces p2
					WHERE ascii(p2.file) = rw.cf AND p2.rank = rw.cr
				)
		)
		SELECT 1 AS found
		FROM ray_walk rw
		JOIN pieces p ON ascii(p.file) = rw.cf AND p.rank = rw.cr
		WHERE p.color != ki.color
		  AND (
			  (p.piece IN ('R','Q') AND (d.file_step = 0 OR d.rank_step = 0))
			  OR
			  (p.piece IN ('B','Q') AND d.file_step != 0 AND d.rank_step != 0)
		  )
		LIMIT 1
	) ray ON TRUE
	LIMIT 1
),

-- Is the king in check?
in_check AS (
	SELECT EXISTS (SELECT 1 FROM knight_check)
		OR EXISTS (SELECT 1 FROM pawn_check)
		OR EXISTS (SELECT 1 FROM sliding_check)
	AS is_in_check
)

SELECT
	CASE
		-- 50-move rule: halfmove_clock >= 100 means 50 full moves
		WHEN st.halfmove_clock >= 100 THEN 'draw_50_move'
		-- No legal moves + in check = checkmate
		WHEN mc.num_legal_moves = 0 AND ic.is_in_check AND st.side_to_move = 'w'
			THEN 'checkmate_black_wins'
		WHEN mc.num_legal_moves = 0 AND ic.is_in_check AND st.side_to_move = 'b'
			THEN 'checkmate_white_wins'
		-- No legal moves + not in check = stalemate
		WHEN mc.num_legal_moves = 0 AND NOT ic.is_in_check
			THEN 'stalemate'
		-- Has legal moves but in check
		WHEN ic.is_in_check THEN 'check'
		-- Normal play
		ELSE 'in_progress'
	END AS status,
	st.side_to_move,
	mc.num_legal_moves,
	ic.is_in_check,
	st.halfmove_clock
FROM current_state st
CROSS JOIN move_count mc
CROSS JOIN in_check ic;
