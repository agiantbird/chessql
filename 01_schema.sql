-- Clean slate
DROP TABLE IF EXISTS board_state;
DROP TABLE IF EXISTS game_state;
DROP TABLE IF EXISTS games;

-- ============================================================
-- Table: games
-- Notes: One row per chess game
-- ============================================================
CREATE TABLE games (
	game_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_at TIMESTAMP DEFAULT now()
);

-- ============================================================
-- Table: game_state
-- Notes: One row per position. Captures metadata like whose 
-- turn it is, castling rights, en passant, and move clocks.
-- move_number = 0 is the starting position, each moves creates
-- a new row incrementing move_number.
-- Rows are not updated, more rows are *inserted*
-- ============================================================
CREATE TABLE game_state (
	game_id            INT NOT NULL REFERENCES games(game_id),
	move_number        INT NOT NULL DEFAULT 0,
	-- 'w' or 'b'
	side_to_move       CHAR(1) NOT NULL DEFAULT 'w'
				           CHECK (side_to_move IN ('w', 'b')),
	-- castling rights: true means castling is still available
	white_king_castle  BOOLEAN NOT NULL DEFAULT TRUE,
	white_queen_castle BOOLEAN NOT NULL DEFAULT TRUE,
	black_king_castle  BOOLEAN NOT NULL DEFAULT TRUE,
	black_queen_castle BOOLEAN NOT NULL DEFAULT TRUE,
	-- En passant target square or NULL if none
	en_passant_target  CHAR(2),
	-- Halfmove clock: moves since last pawn move or capture (50 move rule)
	halfmove_clock     INT NOT NULL DEFAULT 0,

	PRIMARY KEY (game_id, move_number)
);

-- ============================================================
-- Table: board_state
-- Notes: one row per piece on the board per position
-- A position is identified by (game_id, move_number)
--
-- file = column (a-h), rank = row (1-8)
-- piece = 'P', 'N', 'B', 'R', 'Q', 'K'
-- color = 'w' or 'b'

-- Empty squares have no row, only occupied squares are stores
-- ============================================================
CREATE TABLE board_state (
	game_id     INT NOT NULL,
	move_number INT NOT NULL,
	file        CHAR(1) NOT NULL CHECK (file IN ('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h')),
	rank        INT NOT NULL CHECK (rank BETWEEN 1 AND 8),
	piece       CHAR(1) NOT NULL CHECK (piece IN ('P','N','B','R','Q','K')),
	color       CHAR(1) NOT NULL CHECK (color IN ('w', 'b')),

	FOREIGN KEY (game_id, move_number) REFERENCES game_state(game_id, move_number),

	-- no two pieces on the same square in the same position
	UNIQUE (game_id, move_number, file, rank)
);

-- ============================================================
-- Insert a game with starting positions
-- ============================================================

-- Game 1
INSERT INTO games DEFAULT VALUES;

-- starting metadata
INSERT INTO game_state (game_id, move_number, side_to_move)
VALUES (1, 0, 'w');

-- starting position for all 32 pieces

INSERT INTO board_state (game_id, move_number, file, rank, piece, color) VALUES
    -- White back rank
    (1, 0, 'a', 1, 'R', 'w'),
    (1, 0, 'b', 1, 'N', 'w'),
    (1, 0, 'c', 1, 'B', 'w'),
    (1, 0, 'd', 1, 'Q', 'w'),
    (1, 0, 'e', 1, 'K', 'w'),
    (1, 0, 'f', 1, 'B', 'w'),
    (1, 0, 'g', 1, 'N', 'w'),
    (1, 0, 'h', 1, 'R', 'w'),
    -- White pawns
    (1, 0, 'a', 2, 'P', 'w'),
    (1, 0, 'b', 2, 'P', 'w'),
    (1, 0, 'c', 2, 'P', 'w'),
    (1, 0, 'd', 2, 'P', 'w'),
    (1, 0, 'e', 2, 'P', 'w'),
    (1, 0, 'f', 2, 'P', 'w'),
    (1, 0, 'g', 2, 'P', 'w'),
    (1, 0, 'h', 2, 'P', 'w'),
    -- Black pawns
    (1, 0, 'a', 7, 'P', 'b'),
    (1, 0, 'b', 7, 'P', 'b'),
    (1, 0, 'c', 7, 'P', 'b'),
    (1, 0, 'd', 7, 'P', 'b'),
    (1, 0, 'e', 7, 'P', 'b'),
    (1, 0, 'f', 7, 'P', 'b'),
    (1, 0, 'g', 7, 'P', 'b'),
    (1, 0, 'h', 7, 'P', 'b'),
    -- Black back rank
    (1, 0, 'a', 8, 'R', 'b'),
    (1, 0, 'b', 8, 'N', 'b'),
    (1, 0, 'c', 8, 'B', 'b'),
    (1, 0, 'd', 8, 'Q', 'b'),
    (1, 0, 'e', 8, 'K', 'b'),
    (1, 0, 'f', 8, 'B', 'b'),
    (1, 0, 'g', 8, 'N', 'b'),
    (1, 0, 'h', 8, 'R', 'b');

