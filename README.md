# ChessQL

A fully functional chess engine implemented entirely in PostgreSQL. No application code, no external libraries — just SQL views, recursive CTEs, and one PL/pgSQL function.

Every chess rule is enforced by the database: legal move generation, check detection, castling, en passant, promotion, and endgame detection (checkmate, stalemate, 50-move rule). The board state is immutable — each move creates a new snapshot, giving you full move history and perfect replayability.

## Requirements

- PostgreSQL 16+ (installed via Homebrew, apt, or your preferred method)

## Setup

Create the database and load the game:

```
createdb chessql
psql chessql -f setup.sql
```

To reset and start a new game at any time, just run the setup script again:

```
psql chessql -f setup.sql
```

## How to Play

Connect to the database:

```
psql chessql
```

View the board:

```sql
SELECT * FROM board_view;
```

Make a move by specifying the from-square and to-square:

```sql
SELECT make_move('e2', 'e4');
```

For pawn promotion, pass the desired piece as a third argument:

```sql
SELECT make_move('a7', 'a8', 'Q');
```

View all legal moves in the current position:

```sql
SELECT * FROM legal_moves;
```

Check the game status:

```sql
SELECT * FROM game_status;
```

## Example: Fool's Mate

The fastest possible checkmate — black wins in 4 moves.

```
chessql=# SELECT * FROM board_view;
         board_row
----------------------------
 8 | r  n  b  q  k  b  n  r
 7 | p  p  p  p  p  p  p  p
 6 | .  .  .  .  .  .  .  .
 5 | .  .  .  .  .  .  .  .
 4 | .  .  .  .  .  .  .  .
 3 | .  .  .  .  .  .  .  .
 2 | P  P  P  P  P  P  P  P
 1 | R  N  B  Q  K  B  N  R
     a  b  c  d  e  f  g  h

chessql=# SELECT make_move('f2', 'f3');
 make_move
------------
 P f2 to f3

chessql=# SELECT make_move('e7', 'e5');
 make_move
------------
 P e7 to e5

chessql=# SELECT make_move('g2', 'g4');
 make_move
------------
 P g2 to g4

chessql=# SELECT make_move('d8', 'h4');
              make_move
-------------------------------------
 Q d8 to h4 — CHECKMATE! Black wins!

chessql=# SELECT * FROM board_view;
         board_row
----------------------------
 8 | r  n  b  .  k  b  n  r
 7 | p  p  p  p  .  p  p  p
 6 | .  .  .  .  .  .  .  .
 5 | .  .  .  .  p  .  .  .
 4 | .  .  .  .  .  .  P  q
 3 | .  .  .  .  .  P  .  .
 2 | P  P  P  P  P  .  .  P
 1 | R  N  B  Q  K  B  N  R
     a  b  c  d  e  f  g  h

chessql=# SELECT make_move('a2', 'a3');
ERROR:  Game is over: checkmate_black_wins
```

## Project Structure

| File | Purpose |
|------|---------|
| `setup.sql` | Master script — run this to set up everything |
| `01_schema.sql` | Tables and starting position |
| `02_render_board.sql` | ASCII board rendering view |
| `03_knight_king_moves.sql` | Knight and king move generation |
| `04_sliding_moves.sql` | Rook, bishop, and queen move generation (recursive CTEs) |
| `08_castling.sql` | Castling move generation |
| `09_en_passant_promotion.sql` | En passant, pawn promotion, and pawn move generation |
| `10_endgame.sql` | Checkmate, stalemate, and draw detection |