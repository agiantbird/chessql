-- Creates a view that generates castling moves when all conditions are met.
-- Castling is represented as a king move of two squares:
--   White kingside:  e1 -> g1 (rook h1 -> f1)
--   White queenside: e1 -> c1 (rook a1 -> d1)
--   Black kingside:  e8 -> g8 (rook h8 -> f8)
--   Black queenside: e8 -> c8 (rook a8 -> d8)

-- ============================================================
-- View: castling_moves
-- ============================================================
DROP VIEW IF EXISTS castling_moves;

CREATE VIEW castling_moves AS

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
),

-- Define the four possible castling moves and their requirements.
-- Each row describes one castling option:
--   - Which side and which direction
--   - The castling rights flag that must be true
--   - The squares that must be empty (path)
--   - The king's start, pass-through, and destination squares
--   - The rook's start and destination squares
castling_defs AS (
	SELECT *
	FROM (VALUES
		-- color, king_file, king_rank, to_file, rook_file, rook_to_file,
		-- path files (squares that must be empty), rights flag name
		('w', 'e', 1, 'g', 'h', 'f', ARRAY['f','g'],	 'wk'),
		('w', 'e', 1, 'c', 'a', 'd', ARRAY['b','c','d'], 'wq'),
		('b', 'e', 8, 'g', 'h', 'f', ARRAY['f','g'],	 'bk'),
		('b', 'e', 8, 'c', 'a', 'd', ARRAY['b','c','d'], 'bq')
	) AS t(color, king_file, king_rank, to_file, rook_file, rook_to_file,
		   path_files, rights_key)
),

-- Filter to the current side's castling options where rights are still available.
eligible AS (
	SELECT cd.*
	FROM castling_defs cd
	JOIN current_side cs ON cd.color = cs.side_to_move
	JOIN current_state st ON TRUE
	WHERE
		-- Check the appropriate castling rights flag
		CASE cd.rights_key
			WHEN 'wk' THEN st.white_king_castle
			WHEN 'wq' THEN st.white_queen_castle
			WHEN 'bk' THEN st.black_king_castle
			WHEN 'bq' THEN st.black_queen_castle
		END
),

-- Check that the path between king and rook is clear.
-- unnest() expands the path_files array into individual rows.
path_clear AS (
	SELECT e.*
	FROM eligible e
	WHERE NOT EXISTS (
		SELECT 1
		FROM unnest(e.path_files) AS pf(file)
		JOIN pieces p ON p.file = pf.file AND p.rank = e.king_rank
	)
),

-- Check that the king is not currently in check,
-- and doesn't pass through or land on an attacked square.
-- Check three squares: king's current, pass-through, and destination.
-- Check if any enemy piece attacks these squares.
--
-- The legal_moves view will also filter castling through check detection,
-- but the pass-through square needs to be checked too(the king "passes through"
-- it, which legal_moves wouldn't catch since it only sees the final position).

-- Generate all squares the king occupies during castling (start, through, dest)
king_path_squares AS (
	SELECT pc.*, sq.file AS check_file
	FROM path_clear pc
	CROSS JOIN LATERAL (VALUES
		(pc.king_file),
		-- Pass-through square: one step toward destination
		(CASE WHEN pc.to_file = 'g' THEN 'f' ELSE 'd' END),
		(pc.to_file)
	) AS sq(file)
),

-- Check if any enemy knight attacks a king path square
knight_threat AS (
	SELECT kps.rights_key, kps.check_file
	FROM king_path_squares kps
	JOIN pieces p ON p.piece = 'N' AND p.color != kps.color
	CROSS JOIN (VALUES
		(-2,-1),(-2,+1),(-1,-2),(-1,+2),
		(+1,-2),(+1,+2),(+2,-1),(+2,+1)
	) AS offsets(df, dr)
	WHERE ascii(p.file) = ascii(kps.check_file) + offsets.df
	  AND p.rank = kps.king_rank + offsets.dr
),

-- Check if any enemy pawn attacks a king path square
pawn_threat AS (
	SELECT kps.rights_key, kps.check_file
	FROM king_path_squares kps
	JOIN pieces p ON p.piece = 'P' AND p.color != kps.color
	WHERE abs(ascii(p.file) - ascii(kps.check_file)) = 1
	  AND p.rank + CASE WHEN p.color = 'w' THEN 1 ELSE -1 END = kps.king_rank
),

-- Check if any enemy king attacks a king path square
king_threat AS (
	SELECT kps.rights_key, kps.check_file
	FROM king_path_squares kps
	JOIN pieces p ON p.piece = 'K' AND p.color != kps.color
	WHERE abs(ascii(p.file) - ascii(kps.check_file)) <= 1
	  AND abs(p.rank - kps.king_rank) <= 1
),

-- Check if any enemy sliding piece attacks a king path square
-- (simplified: walk rays from each check square outward)
sliding_threat AS (
	SELECT DISTINCT kps.rights_key, kps.check_file
	FROM king_path_squares kps
	CROSS JOIN (VALUES
		(0,+1),(0,-1),(-1,0),(+1,0),
		(-1,-1),(-1,+1),(+1,-1),(+1,+1)
	) AS d(file_step, rank_step)
	JOIN LATERAL (
		WITH RECURSIVE ray_walk AS (
			SELECT
				ascii(kps.check_file) + d.file_step AS cf,
				kps.king_rank + d.rank_step AS cr,
				FALSE AS blocked
			WHERE
				ascii(kps.check_file) + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND kps.king_rank + d.rank_step BETWEEN 1 AND 8

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
		WHERE p.color != kps.color
		  AND (
			  (p.piece IN ('R','Q') AND (d.file_step = 0 OR d.rank_step = 0))
			  OR
			  (p.piece IN ('B','Q') AND d.file_step != 0 AND d.rank_step != 0)
		  )
		LIMIT 1
	) ray ON TRUE
),

-- Collect all threatened squares
all_threats AS (
	SELECT rights_key, check_file FROM knight_threat
	UNION SELECT rights_key, check_file FROM pawn_threat
	UNION SELECT rights_key, check_file FROM king_threat
	UNION SELECT rights_key, check_file FROM sliding_threat
),

-- Keep only castling moves where NO king path square is attacked
safe_castles AS (
	SELECT pc.*
	FROM path_clear pc
	WHERE NOT EXISTS (
		SELECT 1 FROM all_threats at
		WHERE at.rights_key = pc.rights_key
	)
)

-- Output castling moves in the same format as other move views
SELECT
	sc.king_file	AS from_file,
	sc.king_rank	AS from_rank,
	'K'			 AS piece,
	sc.color		AS color,
	sc.to_file	  AS to_file,
	sc.king_rank	AS to_rank,
	NULL::CHAR(1)   AS captured_piece
FROM safe_castles sc;
