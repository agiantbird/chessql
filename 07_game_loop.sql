-- Create function make_move(from_sq, to_sq) that:
--		1. Validates the move against the legal_moves view
--		2. Inserts a new board state with the piece moved
--		3. Advances the game state (move number, slide to move, clocks)

-- Usage:
--		SELECT make_move('e2', 'e4');
--		SELECT * FROM board_view;

-- Clean slate
DROP FUNCTION IF EXISTS make_move(CHAR, CHAR);

CREATE FUNCTION make_move(from_sq CHAR(2), to_sq CHAR(2))
-- everything between $$...$$ is PL/pgSQL code
RETURNS TEXT AS $$
DECLARE
	-- variables
	v_from_file    CHAR(1);
	v_from_rank    INT;
	v_to_file      CHAR(1);
	v_to_rank      INT;
	v_piece        CHAR(1);
	v_color        CHAR(1);
	v_captured     CHAR(1);
	v_current_move INT;
	v_new_move     INT;
	v_side         CHAR(1);
BEGIN
	-- Parse the input squares
	-- 'e2' -> file='e', rank='2'
	v_from_file := substring(from_sq from 1 for 1);
	v_from_rank := substring(from_sq from 2 for 1)::INT;
	v_to_file   := substring(to_sq from 1 for 1);
	v_to_rank   := substring(to_sq from 2 for 1)::INT;

	-- Get the current move number and side to move (black or white)
	SELECT gs.move_number, gs.side_to_move
	INTO v_current_move, v_side
	FROM game_state gs
	WHERE gs.game_id = 1
	ORDER BY gs.move_number DESC
	LIMIT 1;

	v_new_move := v_current_move + 1;

	-- Check if this move is legal by looking for it in the legal_moves view
	SELECT lm.piece, lm.captured_piece, lm.color
	INTO v_piece, v_captured, v_color
	FROM legal_moves lm
	WHERE lm.from_file   = v_from_file
		AND lm.from_rank = v_from_rank
		AND lm.to_file   = v_to_file
		AND lm.to_rank   = v_to_rank;

	-- If no matching move found, move is illegal and should be rejected
	-- FOUND is a built-in PL/pgSQL variable that is TRUE if the previous query
	-- returned at least one row
	IF NOT FOUND THEN
		RAISE EXCEPTION 'Illegal move: % to %', from_sq, to_sq;
	END IF;

	-- Otherwise, insert new game state metadata
	INSERT INTO game_state (
		game_id, move_number, side_to_move,
		white_king_castle, white_queen_castle,
		black_king_castle, black_queen_castle,
		en_passant_target, halfmove_clock
	)
	SELECT
		1,
		v_new_move,
		-- Flip side to move
		CASE WHEN v_side = 'w' THEN 'b' ELSE 'w' END,
		-- carry forward castling rights
		gs.white_king_castle,
		gs.white_queen_castle,
		gs.black_king_castle,
		gs.black_queen_castle,
		-- Clear en passant target
		NULL,
		-- Halfmove clock: reset on pawn move or capture, otherwise increment
		CASE
			WHEN v_piece = 'P' OR v_captured IS NOT NULL THEN 0
			ELSE gs.halfmove_clock + 1
		END
	FROM game_state gs
	WHERE gs.game_id = 1 AND gs.move_number = v_current_move;

	-- Insert the new board state:
	-- Copy all pieces from their current position, except:
	-- 		* Remove the moving piece from its origin
	-- 		* Remove any captured piece from the destination
	-- Then add the moving piece to its destination

	-- Copy surviving pieces
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	SELECT 1, v_new_move, bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	WHERE bs.game_id = 1
		AND bs.move_number = v_current_move
		-- remove piece from origin
		AND NOT (bs.file = v_from_file AND bs.rank = v_from_rank)
		-- remove any piece on destination (capture)
		AND NOT (bs.file = v_to_file AND bs.rank = v_to_rank);

	-- Place the moving piece on its new square
	INSERT INTO board_state (game_id, move_number, file, rank, piece, color)
	VALUES (1, v_new_move, v_to_file, v_to_rank, v_piece, v_color);

	-- Return a confirmation message
	IF v_captured IS NOT NULL THEN
		RETURN v_piece || ' ' || from_sq || ' captures ' || v_captured || ' on ' || to_sq;
	ELSE
		RETURN v_piece || ' ' || from_sq || ' to ' || to_sq;
	END IF;
END;
$$ LANGUAGE plpgsql;
