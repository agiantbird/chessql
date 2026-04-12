--   1. Creates a view that generates castling moves when legal
--   2. Updates make_move function to handle castling execution and revoke rights

-- Castling is represented as a king move of two squares:
--   White kingside:  e1 -> g1 (rook h1 -> f1)
--   White queenside: e1 -> c1 (rook a1 -> d1)
--   Black kingside:  e8 -> g8 (rook h8 -> f8)
--   Black queenside: e8 -> c8 (rook a8 -> d8)

-- =================================================================
-- View: castling_moves
-- Generates castling as a pseudo-legal move when conditions are met.
-- =================================================================

-- Clean slate
DROP VIEW IF EXISTS legal_moves;
DROP VIEW IF EXISTS all_pseudo_legal_moves;
DROP VIEW IF EXISTS castling_moves;

CREATE VIEW castling_moves AS


-- Basic setup
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

-- Define the four possible castling moves and their requirements
-- Each row describes one castling option:
-- -- * Which side and which direction
-- -- * The castling rights flag that must be true
-- -- * The squares that must be empty (path)
-- -- * The king's start, pass-through, and destination squares
-- -- * The rook's start and destination squares
castling_defs AS (
	SELECT *
	FROM (VALUES
		-- color, king_file, king_rank, to_file, rook_file, rook_to_file,
		-- path files (squares that must be empty), rights flag name (e.g. black kingside = bk)
		('w', 'e', 1, 'g', 'h', 'f', ARRAY['f', 'g'],    'wk'),
		('w', 'e', 1, 'c', 'a', 'd', ARRAY['b','c','d'], 'wq'),
		('b', 'e', 8, 'g', 'h', 'f', ARRAY['f','g'],     'bk'),
		('b', 'e', 8, 'c', 'a', 'd', ARRAY['b','c','d'], 'bq')
	) AS t(color, king_file, king_rank, to_file, rook_file, rook_to_file, path_files, rights_key)
),

-- filter to the current side's castling options where castling rights still exist
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

-- Check that path between king and rook is clear
-- unnest() expands the path_files array into individual rows
path_clear AS (
	SELECT e.*
	FROM eligible e
	WHERE NOT EXISTS (
		SELECT 1
		FROM unnest(e.path_files) AS pf(file)
		JOIN pieces p ON p.file = pf.file AND p.rank = e.king_rank
	)
),

-- * Check that the king is not currently in check and doesn't pass through
-- or land on an attacked square.
-- * Approach is to use the same piece-attack logic already in the project but
-- checked against the _current_ board, not hypothetical board-states that would exist
-- after a piece moves.
-- * The legal_moves view filters castling though check detection, but the squares
-- a king passed through while castling need to be evaluated for check conditions, as well
-- -- * legal_moves won't catch these as it only evaluates final, not intermediary, positions

-- generate all squares the king occupies during castling (start, through, destination)
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
				TRUE
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

-- keep only castling moves where NO king path square is attacked
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
	sc.king_file    AS from_file,
	sc.king_rank    AS from_rank,
	'K'             AS piece,
	sc.color        AS color,
	sc.to_file      AS to_file,
	sc.king_rank    AS to_rank,
	NULL::CHAR(1)   AS captured_piece
FROM safe_castles sc;

-- ============================================================
-- Recreate all_pseudo_legal_moves to include castling
-- ============================================================
DROP VIEW IF EXISTS all_pseudo_legal_moves;

CREATE VIEW all_pseudo_legal_moves AS
    SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
    FROM pseudo_legal_moves_knight_king
    UNION ALL
    SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
    FROM pseudo_legal_moves_sliding
    UNION ALL
    SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
    FROM pseudo_legal_moves_pawn
    UNION ALL
    SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
    FROM castling_moves;
 
 
-- ======================================================================================
-- Recreate legal_moves: now includes castling through the updated all_pseudo_legal_moves
-- ======================================================================================

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

numbered_moves AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY m.from_file, m.from_rank, m.to_file, m.to_rank) AS move_id,
        m.*
    FROM all_pseudo_legal_moves m
),

hypothetical_boards AS (
	SELECT nm.move_id, p.file, p.rank, p.piece, p.color
	FROM numbered_moves nm
	CROSS JOIN pieces p
	WHERE NOT (p.file = nm.from_file AND p.rank = nm.from_rank)
		AND NOT (p.file = nm.to_file AND p.rank = nm.to_rank)
	UNION ALL
	SELECT nm.move_id, nm.to_file AS file, nm.to_rank AS rank, nm.piece, nm.color
	FROM numbered_moves nm
),

king_positions AS (
	SELECT hb.move_id, hb.file AS king_file, hb.rank AS king_rank, hb.color
	FROM hypothetical_boards hb
	JOIN current_side cs ON hb.color = cs.side_to_move
	WHERE hb.piece = 'K'
),

knight_attacks AS (
	SELECT kp.move_id
	FROM king_positions kp
	JOIN hypothetical_boards hb ON hb.move_id = kp.move_id
	CROSS JOIN (VALUES (-2,-1),(-2,+1),(-1,-2),(-1,+2),(+1,-2),(+1,+2),(+2,-1),(+2,+1)) AS offsets(df,dr)
	WHERE hb.piece = 'N' AND hb.color != kp.color
		AND ascii(hb.file) = ascii(kp.king_file) + offsets.df
		AND hb.rank = kp.king_rank + offsets.dr
),

pawn_attacks AS (
	SELECT kp.move_id
	FROM king_positions kp
	JOIN hypothetical_boards hb ON hb.move_id = kp.move_id
	WHERE hb.piece = 'P' AND hb.color != kp.color
		AND abs(ascii(hb.file) - ascii(kp.king_file)) = 1
		AND hb.rank + CASE WHEN hb.color = 'w' THEN 1 ELSE -1 END = kp.king_rank
),

king_attacks AS (
	SELECT kp.move_id
	FROM king_positions kp
	JOIN hypothetical_boards hb ON hb.move_id = kp.move_id
	WHERE hb.piece = 'K' AND hb.color != kp.color
		AND abs(ascii(hb.file) - ascii(kp.king_file)) <= 1
		AND abs(hb.rank - kp.king_rank) <= 1
),

sliding_attacks AS (
	SELECT DISTINCT ray.move_id
	FROM king_positions kp
	CROSS JOIN (VALUES (0,+1),(0,-1),(-1,0),(+1,0),(-1,-1),(-1,+1),(+1,-1),(+1,+1)) AS d(file_step, rank_step)
	JOIN LATERAL (
		WITH RECURSIVE ray_walk AS (
			SELECT kp.move_id,
				ascii(kp.king_file) + d.file_step AS current_file_ascii,
				kp.king_rank + d.rank_step AS current_rank,
				FALSE AS blocked
			WHERE ascii(kp.king_file) + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND kp.king_rank + d.rank_step BETWEEN 1 AND 8
			UNION ALL
			SELECT rw.move_id,
				rw.current_file_ascii + d.file_step,
				rw.current_rank + d.rank_step,
				TRUE
			FROM ray_walk rw
			WHERE rw.current_file_ascii + d.file_step BETWEEN ascii('a') AND ascii('h')
				AND rw.current_rank + d.rank_step BETWEEN 1 AND 8
				AND NOT rw.blocked
				AND NOT EXISTS (
					SELECT 1 FROM hypothetical_boards hb2
					WHERE hb2.move_id = rw.move_id
						AND ascii(hb2.file) = rw.current_file_ascii
						AND hb2.rank = rw.current_rank
				)
		)
		SELECT rw.move_id
		FROM ray_walk rw
		JOIN hypothetical_boards hb ON hb.move_id = rw.move_id
			AND ascii(hb.file) = rw.current_file_ascii AND hb.rank = rw.current_rank
		WHERE hb.color != kp.color
			AND ((hb.piece IN ('R','Q') AND (d.file_step = 0 OR d.rank_step = 0))
				OR (hb.piece IN ('B','Q') AND d.file_step != 0 AND d.rank_step != 0))
		LIMIT 1
	) ray ON TRUE
),

attacked_moves AS (
	SELECT move_id FROM knight_attacks
	UNION SELECT move_id FROM pawn_attacks
	UNION SELECT move_id FROM king_attacks
	UNION SELECT move_id FROM sliding_attacks
)

SELECT nm.from_file, nm.from_rank, nm.piece, nm.color,
	nm.to_file, nm.to_rank, nm.captured_piece
FROM numbered_moves nm
WHERE nm.move_id NOT IN (SELECT move_id FROM attacked_moves);

-- ============================================================
-- Replace make_move to handle castling execution and rights
-- ============================================================

DROP FUNCTION IF EXISTS make_move(CHAR, CHAR);
 
CREATE FUNCTION make_move(from_sq CHAR(2), to_sq CHAR(2))
RETURNS TEXT AS $$
DECLARE
	v_from_file     CHAR(1);
	v_from_rank     INT;
	v_to_file       CHAR(1);
	v_to_rank       INT;
	v_piece         CHAR(1);
	v_color         CHAR(1);
	v_captured      CHAR(1);
	v_current_move  INT;
	v_new_move      INT;
	v_side          CHAR(1);
	v_is_castling   BOOLEAN := FALSE;
	v_rook_from     CHAR(1);
	v_rook_to       CHAR(1);
BEGIN
	v_from_file := substring(from_sq from 1 for 1);
	v_from_rank := substring(from_sq from 2 for 1)::INT;
	v_to_file   := substring(to_sq from 1 for 1);
	v_to_rank   := substring(to_sq from 2 for 1)::INT;

	SELECT gs.move_number, gs.side_to_move
	INTO v_current_move, v_side
	FROM game_state gs
	WHERE gs.game_id = 1
	ORDER BY gs.move_number DESC
	LIMIT 1;

	v_new_move := v_current_move + 1;

	-- Check if this move is legal
	SELECT lm.piece, lm.captured_piece, lm.color
	INTO v_piece, v_captured, v_color
	FROM legal_moves lm
	WHERE lm.from_file = v_from_file
		AND lm.from_rank = v_from_rank
		AND lm.to_file   = v_to_file
		AND lm.to_rank   = v_to_rank;
 
	IF NOT FOUND THEN
		RAISE EXCEPTION 'Illegal move: % to %', from_sq, to_sq;
	END IF;

	-- Detect castling: king moving two squares horizontally
	IF v_piece = 'K' AND abs(ascii(v_to_file) - ascii(v_from_file)) = 2 THEN
		v_is_castling := TRUE;
		IF v_to_file = 'g' THEN
			-- Kingside: rook goes from h to f
			v_rook_from := 'h';
			v_rook_to   := 'f';
		ELSE
			-- Queenside: rook goes from a to d
			v_rook_from := 'a';
			v_rook_to   := 'd';
		END IF;
	END IF;

	-- Insert new game state with updated castling rights
	INSERT INTO game_state (
		game_id, move_number, side_to_move,
		white_king_castle, white_queen_castle,
		black_king_castle, black_queen_castle,
		en_passant_target, halfmove_clock
	)
	SELECT
		1,
		v_new_move,
		CASE WHEN v_side = 'w' THEN 'b' ELSE 'w' END,
		-- Revoke castling rights when king or rook moves
		gs.white_king_castle
			AND NOT (v_piece = 'K' AND v_color = 'w')
			AND NOT (v_from_file = 'h' AND v_from_rank = 1),
		gs.white_queen_castle
			AND NOT (v_piece = 'K' AND v_color = 'w')
			AND NOT (v_from_file = 'a' AND v_from_rank = 1),
		gs.black_king_castle
			AND NOT (v_piece = 'K' AND v_color = 'b')
			AND NOT (v_from_file = 'h' AND v_from_rank = 8),
		gs.black_queen_castle
			AND NOT (v_piece = 'K' AND v_color = 'b')
			AND NOT (v_from_file = 'a' AND v_from_rank = 8),
		NULL,
		CASE
			WHEN v_piece = 'P' OR v_captured IS NOT NULL THEN 0
			ELSE gs.halfmove_clock + 1
		END
	FROM game_state gs
	WHERE gs.game_id = 1 AND gs.move_number = v_current_move;

	-- Insert new board state: copy surviving pieces
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	SELECT 1, v_new_move, bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	WHERE bs.game_id = 1
		AND bs.move_number = v_current_move
		AND NOT (bs.file = v_from_file AND bs.rank = v_from_rank)
		AND NOT (bs.file = v_to_file AND bs.rank = v_to_rank)
		-- If castling, also remove the rook from its original square
		AND NOT (v_is_castling AND bs.file = v_rook_from AND bs.rank = v_from_rank);

	-- Place the king on its new square
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	VALUES (1, v_new_move, v_to_file, v_to_rank, v_piece, v_color);

	-- If castling, place the rook on its new square
	IF v_is_castling THEN
		INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
		VALUES (1, v_new_move, v_rook_to, v_from_rank, 'R', v_color);
	END IF;

	-- Return confirmation
	IF v_is_castling THEN
		IF v_to_file = 'g' THEN
			RETURN 'O-O (kingside castle)';
		ELSE
			RETURN 'O-O-O (queenside castle)';
		END IF;
	ELSIF v_captured IS NOT NULL THEN
		RETURN v_piece || ' ' || from_sq || ' captures ' || v_captured || ' on ' || to_sq;
	ELSE
		RETURN v_piece || ' ' || from_sq || ' to ' || to_sq;
	END IF;
END;
$$ LANGUAGE plpgsql;
