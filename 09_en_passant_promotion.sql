-- This migration:
--   1. Updates make_move to record en passant target when a pawn double-pushes
--   2. Creates a view for en passant capture moves
--   3. Updates pawn move generation to include promotion
--   4. Adds promotion parameter to make_move
--   5. Rebuilds dependent views

-- ============================================================
-- View: en_passant_moves
-- Generates en passant captures when available.
-- ============================================================
DROP VIEW IF EXISTS legal_moves;
DROP VIEW IF EXISTS all_pseudo_legal_moves;
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
	p.file      AS from_file,
	p.rank      AS from_rank,
	'P'         AS piece,
	p.color     AS color,
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
-- must promote. Four moves are generated per promotion (Q, R, B, N).
-- Promotions are by storing the promotion piece in a special way.
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


-- ============================================================
-- Recreate all_pseudo_legal_moves with en passant
-- ============================================================
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
	FROM castling_moves
	UNION ALL
	SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
	FROM en_passant_moves;


-- ============================================================
-- Recreate legal_moves
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

numbered_moves AS (
	SELECT
		ROW_NUMBER() OVER (ORDER BY m.from_file, m.from_rank, m.to_file, m.to_rank, m.piece) AS move_id,
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
				EXISTS (
					SELECT 1 FROM hypothetical_boards hb3
					WHERE hb3.move_id = rw.move_id
						AND ascii(hb3.file) = rw.current_file_ascii + d.file_step
						AND hb3.rank = rw.current_rank + d.rank_step
				)
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


-- =======================================================================
-- Replace make_move to handle en passant and promotion.
-- Now accepts an optional third parameter for promotion piece.
-- Usage:
--   SELECT make_move('e2', 'e4');           -- normal move
--   SELECT make_move('e7', 'e5');           -- normal move
--   SELECT make_move('a7', 'a8', 'Q');      -- promote to queen
--   SELECT make_move('d5', 'e6');           -- en passant (auto-detected)
-- =======================================================================

DROP FUNCTION IF EXISTS make_move(CHAR, CHAR);
DROP FUNCTION IF EXISTS make_move(CHAR, CHAR, CHAR);

CREATE FUNCTION make_move(from_sq CHAR(2), to_sq CHAR(2), promotion CHAR(1) DEFAULT NULL)
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
	v_is_en_passant BOOLEAN := FALSE;
	v_is_promotion  BOOLEAN := FALSE;
	v_rook_from     CHAR(1);
	v_rook_to       CHAR(1);
	v_ep_target     CHAR(2);
	v_actual_piece  CHAR(1);
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

	-- Determine what piece is being moved from the board
	SELECT bs.piece
	INTO v_actual_piece
	FROM board_state bs
	WHERE bs.game_id = 1
		AND bs.move_number = v_current_move
		AND bs.file = v_from_file
		AND bs.rank = v_from_rank;

	-- For promotions, the legal_moves view stores the promotion piece
	-- in the piece column.
	IF promotion IS NOT NULL THEN
		SELECT lm.piece, lm.captured_piece, lm.color
		INTO v_piece, v_captured, v_color
		FROM legal_moves lm
		WHERE lm.from_file = v_from_file
			AND lm.from_rank = v_from_rank
			AND lm.to_file   = v_to_file
			AND lm.to_rank   = v_to_rank
			AND lm.piece      = promotion;
	ELSE
		SELECT lm.piece, lm.captured_piece, lm.color
		INTO v_piece, v_captured, v_color
		FROM legal_moves lm
		WHERE lm.from_file = v_from_file
			AND lm.from_rank = v_from_rank
			AND lm.to_file   = v_to_file
			AND lm.to_rank   = v_to_rank;
	END IF;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Illegal move: % to %', from_sq, to_sq;
	END IF;

	-- Detect castling
	IF v_actual_piece = 'K' AND abs(ascii(v_to_file) - ascii(v_from_file)) = 2 THEN
		v_is_castling := TRUE;
		IF v_to_file = 'g' THEN
			v_rook_from := 'h';
			v_rook_to   := 'f';
		ELSE
			v_rook_from := 'a';
			v_rook_to   := 'd';
		END IF;
	END IF;

	-- Detect en passant: pawn moving diagonally to an empty square
	IF v_actual_piece = 'P' AND v_from_file != v_to_file THEN
		-- Check if destination square is empty (meaning this is en passant, not a normal capture)
		IF NOT EXISTS (
			SELECT 1 FROM board_state bs
			WHERE bs.game_id = 1
				AND bs.move_number = v_current_move
				AND bs.file = v_to_file
				AND bs.rank = v_to_rank
		) THEN
			v_is_en_passant := TRUE;
		END IF;
	END IF;

	-- Detect promotion: pawn reaching the final rank
	IF v_actual_piece = 'P' AND (v_to_rank = 8 OR v_to_rank = 1) THEN
		v_is_promotion := TRUE;
		IF promotion IS NULL THEN
			RAISE EXCEPTION 'Promotion required. Use: SELECT make_move(''%'', ''%'', ''Q'') for queen (or R, B, N)', from_sq, to_sq;
		END IF;
	END IF;

	-- Calculate en passant target for the NEXT move
	-- (set when a pawn double-pushes)
	IF v_actual_piece = 'P' AND abs(v_to_rank - v_from_rank) = 2 THEN
		-- The target square is the square the pawn passed through
		v_ep_target := v_from_file || ((v_from_rank + v_to_rank) / 2)::TEXT;
	ELSE
		v_ep_target := NULL;
	END IF;

	-- Insert new game state
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
		gs.white_king_castle
			AND NOT (v_actual_piece = 'K' AND v_color = 'w')
			AND NOT (v_from_file = 'h' AND v_from_rank = 1)
			AND NOT (v_to_file = 'h' AND v_to_rank = 1),
		gs.white_queen_castle
			AND NOT (v_actual_piece = 'K' AND v_color = 'w')
			AND NOT (v_from_file = 'a' AND v_from_rank = 1)
			AND NOT (v_to_file = 'a' AND v_to_rank = 1),
		gs.black_king_castle
			AND NOT (v_actual_piece = 'K' AND v_color = 'b')
			AND NOT (v_from_file = 'h' AND v_from_rank = 8)
			AND NOT (v_to_file = 'h' AND v_to_rank = 8),
		gs.black_queen_castle
			AND NOT (v_actual_piece = 'K' AND v_color = 'b')
			AND NOT (v_from_file = 'a' AND v_from_rank = 8)
			AND NOT (v_to_file = 'a' AND v_to_rank = 8),
		v_ep_target,
		CASE
			WHEN v_actual_piece = 'P' OR v_captured IS NOT NULL THEN 0
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
		-- Remove piece from origin
		AND NOT (bs.file = v_from_file AND bs.rank = v_from_rank)
      -- Remove any piece on destination
		AND NOT (bs.file = v_to_file AND bs.rank = v_to_rank)
		-- If castling, remove rook from its origin
		AND NOT (v_is_castling AND bs.file = v_rook_from AND bs.rank = v_from_rank)
		-- If en passant, remove the captured pawn (it's on the same file as
		-- destination but on the capturing pawn's original rank)
		AND NOT (v_is_en_passant AND bs.file = v_to_file AND bs.rank = v_from_rank);

	-- Place the piece on its new square
	-- For promotion, place the promoted piece instead of the pawn
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	VALUES (1, v_new_move, v_to_file, v_to_rank,
			CASE WHEN v_is_promotion THEN promotion ELSE v_actual_piece END,
			v_color);

	-- If castling, place the rook
	IF v_is_castling THEN
		INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
		VALUES (1, v_new_move, v_rook_to, v_from_rank, 'R', v_color);
	END IF;

	-- Return confirmation
	IF v_is_castling THEN
		IF v_to_file = 'g' THEN RETURN 'O-O (kingside castle)';
		ELSE RETURN 'O-O-O (queenside castle)';
		END IF;
	ELSIF v_is_en_passant THEN
		RETURN 'P ' || from_sq || ' captures en passant on ' || to_sq;
	ELSIF v_is_promotion THEN
		IF v_captured IS NOT NULL THEN
			RETURN 'P ' || from_sq || ' captures ' || v_captured || ' on ' || to_sq || ', promotes to ' || promotion;
		ELSE
			RETURN 'P ' || from_sq || ' promotes to ' || promotion || ' on ' || to_sq;
		END IF;
	ELSIF v_captured IS NOT NULL THEN
		RETURN v_actual_piece || ' ' || from_sq || ' captures ' || v_captured || ' on ' || to_sq;
	ELSE
		RETURN v_actual_piece || ' ' || from_sq || ' to ' || to_sq;
	END IF;
END;
$$ LANGUAGE plpgsql;
