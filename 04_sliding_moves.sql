-- Create a view that generates pseudo-legal moves for rooks, bishops, and queens
-- Uses recursive CTEs to 'walk' along each direction until a board-edge or piece is hit

-- Cleanup
DROP VIEW IF EXISTS pseudo_legal_moves_sliding;

CREATE VIEW pseudo_legal_moves_sliding AS

-- Each direction is a (file_step, rank_step) pair representing one square of movement
-- Rooks slide along ranks and along files (4 directions)
-- Bishops slide diagonally (4 directions)
-- Queens get all 8 directions (rook + bishop combined)
-- RECURSIVE is required here by Postgres syntax even though direction_vectors
-- itself isn't recursive — it enables the recursive slide_rays CTE below.
WITH RECURSIVE direction_vectors AS (
	SELECT piece, file_step, rank_step
	FROM (VALUES
		-- Rook directions: up, down, left, right
		('R', 0, +1), ('R', 0, -1), ('R', -1, 0), ('R', +1, 0),
		-- Bishop directions: four diagonals
		('B', -1, -1), ('B', -1, +1), ('B', +1, -1), ('B', +1, +1),
		-- Queen = rook + bishop (all 8 directions)
		('Q', 0, +1), ('Q', 0, -1), ('Q', -1, 0), ('Q', +1, 0),
        ('Q', -1, -1), ('Q', -1, +1), ('Q', +1, -1), ('Q', +1, +1)
	) AS t(piece, file_step, rank_step)
),

-- Get current position information
current_move AS (
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
-- The following is a recursive CTE used to determine sliding-move validity
----  The base case starts at each sliding piece's _current_ square
----  The recursive case works as follows:
----      * Move one step in a sliding direction. Keep going if:
----          * The new square is on the board
----          * The piece has not been blocked yet
----  The "blocked" flag tracks whether the ray has hit a piece
----  Once blocked = TRUE, the recursion stops producing new rows.

-- After recursion squares are filtered out if:
----  * They are the starting square (step 0: where the piece already is)
----  * They sit _beyond_ a blocking piece
----  * They are occupied by friendly pieces
slide_rays AS (
	-- Base case: each sliding piece paired with each of its directions
	-- step = 0 means "piece is in its starting square, hasn't moved yet"
	SELECT
		p.file          AS from_file,
		p.rank          AS from_rank,
		p.piece         AS piece,
		p.color         AS color,
		d.file_step,
		d.rank_step,
		ascii(p.file)   AS current_file_ascii,
		p.rank          AS current_rank,
		0               AS step,
		FALSE           AS blocked
	FROM pieces p
	JOIN current_side cs ON p.color = cs.side_to_move
	JOIN direction_vectors d ON p.piece = d.piece

	UNION ALL

	-- Recursive case: advance one square in the direction
	-- Only continue if piece is still on the board and not yet blocked
	SELECT
		sr.from_file,
		sr.from_rank,
		sr.piece,
		sr.color,
		sr.file_step,
		sr.rank_step,
		sr.current_file_ascii + sr.file_step AS current_file_ascii,
		sr.current_rank + sr.rank_step       AS current_rank,
		sr.step + 1                          AS step,
		-- mark path as blocked if this new square has _any_ piece on it
		-- once blocked, the recursion will not continue (see WHERE clause)
		EXISTS (
			SELECT 1 FROM pieces occ -- occ for occupant/occupying piece
			WHERE ascii(occ.file) = sr.current_file_ascii + sr.file_step
			  AND occ.rank = sr.current_rank + sr.rank_step
		)                                    AS blocked
	FROM slide_rays sr
	WHERE
		-- stay on the board
		sr.current_file_ascii + sr.file_step BETWEEN ascii('a') AND ascii('h')
		AND sr.current_rank + sr.rank_step BETWEEN 1 AND 8
		-- stop if already blocked on a previous step
		AND NOT sr.blocked
)

-- Filter the ray results into legal destination squares
-- Exclude step 0 (starting square)
-- Keep squares that are empty OR occupied by an enemy (capture)
-- Exclude squares occupied by a friendly piece
SELECT
	sr.from_file,
	sr.from_rank,
	sr.piece,
	sr.color,
	chr(sr.current_file_ascii) AS to_file,
	sr.current_rank            AS to_rank,
	target.piece               AS captured_piece
FROM slide_rays sr
LEFT JOIN pieces target
	ON sr.current_file_ascii = ascii(target.file)
	AND sr.current_rank = target.rank
WHERE
	sr.step > 0
	AND (target.color IS NULL OR target.color != sr.color) -- enemy piece (capture)

