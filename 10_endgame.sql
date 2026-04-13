-- End game detection

-- Creates a view that reports the current game status:
--	'checkmate_white' / 'checkmate_black' — game over, winner declared
--	'stalemate' — draw, no legal moves but not in check
--	'draw_50_move' — draw by 50-move rule
--	'check' — king is in check but has legal moves
--	'in_progress' — normal play continues
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


-- ============================================================
-- Replace make_move to announce game status after each move
-- ============================================================
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
	v_result        TEXT;
	v_status        TEXT;
BEGIN
	v_from_file := substring(from_sq from 1 for 1);
	v_from_rank := substring(from_sq from 2 for 1)::INT;
	v_to_file   := substring(to_sq from 1 for 1);
	v_to_rank   := substring(to_sq from 2 for 1)::INT;

	-- Check if game is already over
	SELECT gs.status INTO v_status FROM game_status gs;
	IF v_status IN ('checkmate_white_wins', 'checkmate_black_wins', 'stalemate', 'draw_50_move') THEN
		RAISE EXCEPTION 'Game is over: %', v_status;
	END IF;

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

	-- Check if this move is legal
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
			v_rook_from := 'h'; v_rook_to := 'f';
		ELSE
			v_rook_from := 'a'; v_rook_to := 'd';
		END IF;
	END IF;

	-- Detect en passant
	IF v_actual_piece = 'P' AND v_from_file != v_to_file THEN
		IF NOT EXISTS (
			SELECT 1 FROM board_state bs
			WHERE bs.game_id = 1 AND bs.move_number = v_current_move
				AND bs.file = v_to_file AND bs.rank = v_to_rank
		) THEN
			v_is_en_passant := TRUE;
		END IF;
	END IF;

	-- Detect promotion
	IF v_actual_piece = 'P' AND (v_to_rank = 8 OR v_to_rank = 1) THEN
		v_is_promotion := TRUE;
		IF promotion IS NULL THEN
			RAISE EXCEPTION 'Promotion required. Use: SELECT make_move(''%'', ''%'', ''Q'') for queen (or R, B, N)', from_sq, to_sq;
		END IF;
	END IF;

	-- Calculate en passant target
	IF v_actual_piece = 'P' AND abs(v_to_rank - v_from_rank) = 2 THEN
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
		1, v_new_move,
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

	-- Insert new board state
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	SELECT 1, v_new_move, bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	WHERE bs.game_id = 1
		AND bs.move_number = v_current_move
		AND NOT (bs.file = v_from_file AND bs.rank = v_from_rank)
		AND NOT (bs.file = v_to_file AND bs.rank = v_to_rank)
		AND NOT (v_is_castling AND bs.file = v_rook_from AND bs.rank = v_from_rank)
		AND NOT (v_is_en_passant AND bs.file = v_to_file AND bs.rank = v_from_rank);

	-- Place piece on destination
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	VALUES (1, v_new_move, v_to_file, v_to_rank,
		CASE WHEN v_is_promotion THEN promotion ELSE v_actual_piece END,
			v_color);

	-- Place rook if castling
	IF v_is_castling THEN
		INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
		VALUES (1, v_new_move, v_rook_to, v_from_rank, 'R', v_color);
	END IF;

	-- Build the move description
    IF v_is_castling THEN
		IF v_to_file = 'g' THEN v_result := 'O-O (kingside castle)';
		ELSE v_result := 'O-O-O (queenside castle)';
		END IF;
	ELSIF v_is_en_passant THEN
		v_result := 'P ' || from_sq || ' captures en passant on ' || to_sq;
	ELSIF v_is_promotion THEN
		IF v_captured IS NOT NULL THEN
			v_result := 'P ' || from_sq || ' captures ' || v_captured || ' on ' || to_sq || ', promotes to ' || promotion;
		ELSE
			v_result := 'P ' || from_sq || ' promotes to ' || promotion || ' on ' || to_sq;
		END IF;
	ELSIF v_captured IS NOT NULL THEN
		v_result := v_actual_piece || ' ' || from_sq || ' captures ' || v_captured || ' on ' || to_sq;
	ELSE
		v_result := v_actual_piece || ' ' || from_sq || ' to ' || to_sq;
	END IF;

	-- Check game status AFTER the move
	SELECT gs.status INTO v_status FROM game_status gs;
	IF v_status = 'checkmate_white_wins' THEN
		v_result := v_result || ' — CHECKMATE! White wins!';
	ELSIF v_status = 'checkmate_black_wins' THEN
		v_result := v_result || ' — CHECKMATE! Black wins!';
	ELSIF v_status = 'stalemate' THEN
		v_result := v_result || ' — STALEMATE! Draw.';
	ELSIF v_status = 'draw_50_move' THEN
		v_result := v_result || ' — DRAW by 50-move rule.';
	ELSIF v_status = 'check' THEN
		v_result := v_result || ' — CHECK!';
	END IF;

	RETURN v_result;
END;
$$ LANGUAGE plpgsql;
