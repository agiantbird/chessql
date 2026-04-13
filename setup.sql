-- ChessQL: Setup Script -- Run this, first!
-- Run with: psql chessql -f setup.sql
--
-- This script loads all components in the correct order and creates
-- the shared views and functions that tie everything together.
-- Run this single file to get a fully working chess game.

-- ============================================================
-- Step 1: Schema & initial position
-- ============================================================
\i 01_schema.sql

-- ============================================================
-- Step 2: Board rendering
-- ============================================================
\i 02_render_board.sql

-- ============================================================
-- Step 3: Piece move generation (order doesn't matter here,
-- these views are independent of each other)
-- ============================================================
\i 03_knight_king_moves.sql
\i 04_sliding_moves.sql
\i 09_en_passant_promotion.sql
\i 08_castling.sql

-- ============================================================
-- Step 4: Combine all pseudo-legal moves into one view.
-- This must come AFTER all individual move views are created.
-- ============================================================
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
	FROM pseudo_legal_moves_pawn
	UNION ALL
	SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
	FROM castling_moves
	UNION ALL
	SELECT from_file, from_rank, piece, color, to_file, to_rank, captured_piece
	FROM en_passant_moves;

-- ============================================================
-- Step 5: Legal move filtering (check detection).
-- Must come AFTER all_pseudo_legal_moves.
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

-- ============================================================
-- Step 6: Endgame detection
-- Must come AFTER legal_moves.
-- ============================================================
\i 10_endgame.sql

-- ============================================================
-- Step 7: The make_move function.
-- Must come AFTER legal_moves and game_status.
-- ============================================================
DROP FUNCTION IF EXISTS make_move(CHAR, CHAR, CHAR);

CREATE FUNCTION make_move(from_sq CHAR(2), to_sq CHAR(2), promotion CHAR(1) DEFAULT NULL)
RETURNS TEXT AS $$
DECLARE
	v_from_file	 CHAR(1);
	v_from_rank	 INT;
	v_to_file	   CHAR(1);
	v_to_rank	   INT;
	v_piece		 CHAR(1);
	v_color		 CHAR(1);
	v_captured	  CHAR(1);
	v_current_move  INT;
	v_new_move	  INT;
	v_side		  CHAR(1);
	v_is_castling   BOOLEAN := FALSE;
	v_is_en_passant BOOLEAN := FALSE;
	v_is_promotion  BOOLEAN := FALSE;
	v_rook_from	 CHAR(1);
	v_rook_to	   CHAR(1);
	v_ep_target	 CHAR(2);
	v_actual_piece  CHAR(1);
	v_result		TEXT;
	v_status		TEXT;
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
		  AND lm.piece	  = promotion;
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

-- ============================================================
-- Done! You can now play chess:
--   SELECT * FROM board_view;
--   SELECT make_move('e2', 'e4');
-- ============================================================