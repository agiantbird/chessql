-- Create a view that renders any board position as ASCII art
-- Usage: Select * FROM board_view;
--        (shows the latest position of game 1)

-- Clean slate
DROP VIEW IF EXISTS board_view;

CREATE VIEW board_view AS

-- Generate all 64 squares
WITH files AS (
	SELECT unnest(ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) AS file
),
ranks AS (
	SELECT generate_series(1,8) AS rank
),
all_squares AS (
	SELECT f.file, r.rank
	FROM files f
	CROSS JOIN ranks r
),

-- Find the latest move number for game 1 so view has current position
current_move AS (
	SELECT MAX(move_number) AS move_number
	FROM game_state
	WHERE game_id = 1
),

-- Get the pieces on the board at the current position
pieces AS (
	SELECT bs.file, bs.rank, bs.piece, bs.color
	FROM board_state bs
	JOIN current_move cm ON bs.move_number = cm.move_number
),

-- Left JOIN so squares without pieces still appear, so '.''s can be put in their
-- square to represent empty squares in the ASCII art.
-- Then, lowercase black pieces (since everything will be the same font color in the terminal)
square_display AS (
	SELECT
		sq.file,
		sq.rank,
		COALESCE(
			CASE WHEN p.color = 'b' THEN lower(p.piece) ELSE p.piece END,
			'.'
		) AS symbol
	FROM all_squares sq
	LEFT JOIN pieces p ON sq.file = p.file AND sq.rank = p.rank
)

-- For each rank, concatenate the 8 symbols in one line
-- Order by rank DESC so rank 8 (black's side) is at the top
-- UNION ALL adds the file labels as a footer row.
-- We use sort_key to control ordering: ranks 8 down to 1, then 0 for the footer.
SELECT board_row FROM (
    SELECT
        sd.rank AS sort_key,
        sd.rank || ' | ' || string_agg(sd.symbol, '  ' ORDER BY sd.file) AS board_row
    FROM square_display sd
    GROUP BY sd.rank
 
    UNION ALL
 
    SELECT
    	-- Will put this footer row below 8, 7, ... 2, 1 row labels
        0 AS sort_key,
        '    a  b  c  d  e  f  g  h' AS board_row
) final
ORDER BY final.sort_key DESC;














