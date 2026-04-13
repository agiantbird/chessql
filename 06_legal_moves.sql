-- OBSOLETE: moved into setup.sql
-- Creates views that:
---- 1. Combine all pseudo-legal moves into one set
---- 2. Determine if a given side's king is under attack on a given board
---- 3. Filter out any move that leaves the moving side's king in check

-- ============================================================
-- View: all_pseudo_legal_moves
-- Combines knight/king, sliding, and pawn moves into one set.
-- ============================================================

-- Clean slate
DROP VIEW IF EXISTS legal_moves;
DROP VIEW IF EXISTS all_pseudo_legal_moves;

CREATE VIEW all_pseudo_legal_moves AS
	SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
	FROM pseudo_legal_moves_knight_king
	UNION ALL
	SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
	FROM pseudo_legal_moves_sliding
	UNION ALL
	SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
	FROM pseudo_legal_moves_pawn;

-- ============================================================
-- View: legal_moves
-- For each pseudo-legal move:
--   1. Build the hypothetical board after that move
--   2. Generate all opponent attacks on that hypothetical board
--   3. Check if any attack reaches the king
--   4. Keep only moves where the king is NOT attacked
-- ============================================================
CREATE VIEW legal_moves AS
 
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

-- 1. Get all candidate moves
-- Each move is numbered so which hypothetical board is being analyzed can be tracked
numbered_moves AS (
	SELECT
		ROW_NUMBER() OVER (ORDER BY m.from_file, m.from_rank, m.to_file, m.to_rank) AS move_id,
		m.*
	FROM all_pseudo_legal_moves m
),
-- 2. For each candidate move build the hypothetical board
-- Start with all current pieces, then:
-- 		* Remove the piece from its origin square
-- 		* Remove any captured piece from the destination square
-- 		* Place the moving piece on the destination square
-- This is done with a UNION ALL of:
--		A. All existing pieces EXCEPT the one that moved and any piece on the destination
--		B. The moving piece on its new square
hypothetical_boards AS (
	-- A. Keep all pieces except the one that moved and any capture victim
	SELECT
		nm.move_id,
		p.file,
		p.rank,
		p.piece,
		p.color
	FROM numbered_moves nm
	CROSS JOIN pieces p
	WHERE
		-- remove the moving piece from its origin
		NOT (p.file = nm.from_file AND p.rank = nm.from_rank)
		-- remove any piece on the destinatin (capture)
		AND NOT (p.file = nm.to_file AND p.rank = nm.to_rank)

	UNION ALL

	-- B. Place the moving piece on its destination
	SELECT
		nm.move_id,
		nm.to_file   AS file,
		nm.to_rank   AS rank,
		nm.piece,
		nm.color
	FROM numbered_moves nm
),

-- Find the king's position on each hypothetical board
king_positions AS (
	SELECT
		hb.move_id,
		hb.file AS king_file,
		hb.rank AS king_rank,
		hb.color
	FROM hypothetical_boards hb
	JOIN current_side cs ON hb.color = cs.side_to_move
	WHERE hb.piece = 'K'
),

-- Check if any opponent piece can attack the king's square by
-- checking each piece type's attack pattern against the king position

-- knights
knight_attacks AS (
	SELECT kp.move_id
	FROM king_positions kp
	JOIN hypothetical_boards hb ON hb.move_id = kp.move_id
	CROSS JOIN (VALUES
		(-2,-1),(-2,+1),(-1,-2),(-1,+2),
		(+1,-2),(+1,+2),(+2,-1),(+2,+1)
	) AS offsets(df, dr)
	WHERE
		hb.piece = 'N'
		AND hb.color != kp.color
		AND ascii(hb.file) = ascii(kp.king_file) + offsets.df
		AND hb.rank = kp.king_rank + offsets.dr
),

-- pawns
--    Pawns attack diagonally: 
--        * a white pawn on rank R attacks rank R+1
--        * a black pawn on rank R attacks rank R-1
pawn_attacks AS (
	SELECT kp.move_id
	FROM king_positions kp
	JOIN hypothetical_boards hb ON hb.move_id = kp.move_id
	WHERE
		hb.piece = 'P'
		AND hb.color != kp.color
		-- Enemy pawn must be one diagonal step from king
		AND abs(ascii(hb.file) - ascii(kp.king_file)) = 1
		-- White pawns attack upward, black pawns attack downward
		AND hb.rank + CASE WHEN hb.color = 'w' THEN 1 ELSE -1 END = kp.king_rank
),

-- kings
king_attacks AS (
	SELECT kp.move_id
	FROM king_positions kp
	JOIN hypothetical_boards hb ON hb.move_id = kp.move_id
	WHERE
		hb.piece = 'K'
		AND hb.color != kp.color
		AND abs(ascii(hb.file) - ascii(kp.king_file)) <= 1
		AND abs(hb.rank - kp.king_rank) <= 1
),

-- sliding pieces (bishops, rooks, queens)
-- uses same ray-walking, recursive technique as is in 04_sliding_moves.sql
sliding_attack_directions AS (
	SELECT piece, file_step, rank_step
	FROM (VALUES
		('R', 0,+1),('R', 0,-1),('R',-1, 0),('R',+1, 0),
		('B',-1,-1),('B',-1,+1),('B',+1,-1),('B',+1,+1),
		('Q', 0,+1),('Q', 0,-1),('Q',-1, 0),('Q',+1, 0),
		('Q',-1,-1),('Q',-1,+1),('Q',+1,-1),('Q',+1,+1)
	) AS t(piece, file_step, rank_step)
),

sliding_attacks AS (
	SELECT DISTINCT ray.move_id
	FROM king_positions kp
	CROSS JOIN sliding_attack_directions d
	JOIN LATERAL (
		-- Recursive ray walk from king's position outward
		WITH RECURSIVE ray_walk AS (
			-- Base case: start at king's position
			SELECT
			kp.move_id,
				ascii(kp.king_file) + d.file_step AS current_file_ascii,
				kp.king_rank + d.rank_step         AS current_rank,
				FALSE                              AS blocked
			WHERE
				ascii(kp.king_file) + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND kp.king_rank + d.rank_step BETWEEN 1 AND 8

			UNION ALL

			SELECT
				rw.move_id,
				rw.current_file_ascii + d.file_step,
				rw.current_rank + d.rank_step,
				TRUE  -- any piece we encounter blocks further squares
			FROM ray_walk rw
			WHERE
				rw.current_file_ascii + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND rw.current_rank + d.rank_step BETWEEN 1 AND 8
				AND NOT rw.blocked
				-- Stop if current square has a piece
				AND NOT EXISTS (
					SELECT 1 FROM hypothetical_boards hb2
					WHERE hb2.move_id = rw.move_id
						AND ascii(hb2.file) = rw.current_file_ascii
						AND hb2.rank = rw.current_rank
				)
		)
		-- Check if the first piece we hit along this ray is an enemy attacker
		SELECT rw.move_id
		FROM ray_walk rw
		JOIN hypothetical_boards hb ON hb.move_id = rw.move_id
			AND ascii(hb.file) = rw.current_file_ascii
			AND hb.rank = rw.current_rank
		WHERE
			hb.color != kp.color
			AND (
				-- Rook or queen on a straight line
				(hb.piece IN ('R', 'Q') AND (d.file_step = 0 OR d.rank_step = 0))
				OR
				-- Bishop or queen on a diagonal
				(hb.piece IN ('B', 'Q') AND d.file_step != 0 AND d.rank_step != 0)
			)
		LIMIT 1
	) ray ON TRUE
),

-- Collect all move_ids where the king _is_ under attack.
attacked_moves AS (
	SELECT move_id FROM knight_attacks
	UNION
	SELECT move_id FROM pawn_attacks
	UNION
	SELECT move_id FROM king_attacks
	UNION
	SELECT move_id FROM sliding_attacks
)

-- Return only moves where the king is _not_ under attack.
SELECT
	nm.from_file,
	nm.from_rank,
	nm.piece,
	nm.color,
	nm.to_file,
	nm.to_rank,
	nm.captured_piece
FROM numbered_moves nm
WHERE nm.move_id NOT IN (SELECT move_id FROM attacked_moves);
