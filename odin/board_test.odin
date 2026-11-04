package minesweeper

import "core:testing"

// The board handle table is deliberately not thread-safe (Neovim calls the
// engine from one thread), so run the runner serially:
//   odin test odin -define:ODIN_TEST_THREADS=1

@(test)
test_new_rejects_invalid :: proc(t: ^testing.T) {
	testing.expect_value(t, ms_new(0, 5, 1), i32(0))
	testing.expect_value(t, ms_new(5, 0, 1), i32(0))
	testing.expect_value(t, ms_new(5, 5, 0), i32(0))
	testing.expect_value(t, ms_new(5, 5, 25), i32(0))
	testing.expect_value(t, ms_new(5, 5, -1), i32(0))
	testing.expect_value(t, ms_new(2000, 2000, 10), i32(0))
}

@(test)
test_bad_handles :: proc(t: ^testing.T) {
	x1, y1, x2, y2: i32
	testing.expect_value(t, ms_abi_version(), i32(1))
	testing.expect_value(t, ms_mine_count(9999), i32(0))
	testing.expect_value(t, ms_flag_count(9999), i32(0))
	testing.expect_value(t, ms_unrevealed_count(9999), i32(0))
	testing.expect_value(t, ms_place_mines(9999, 1, 1), i32(0))
	testing.expect_value(t, ms_reveal(9999, 1, &x1, &y1, &x2, &y2), i32(0))
	testing.expect_value(t, ms_flag(9999, 1, i32(SQUARE_FLAGGED)), i32(0))
	testing.expect(t, ms_state(9999) == nil)
	testing.expect(t, ms_mines(9999) == nil)
	testing.expect(t, ms_danger(9999) == nil)
}

@(test)
test_place_mines_count_and_safe_start :: proc(t: ^testing.T) {
	w, h := 16, 16
	board := ms_new(i32(w), i32(h), 40)
	defer ms_free(board)
	testing.expect(t, board > 0)

	start := i32(8*w + 8)
	testing.expect_value(t, ms_place_mines(board, start, 1234), i32(1))
	testing.expect_value(t, ms_mine_count(board), i32(40))
	testing.expect_value(t, ms_unrevealed_count(board), i32(w*h))

	mines := ms_mines(board)
	total := 0
	for i in 0 ..< w*h {
		if mines[i] != 0 {
			total += 1
		}
	}
	testing.expect_value(t, total, 40)

	for y in 7 ..= 9 {
		for x in 7 ..= 9 {
			testing.expectf(
				t,
				mines[y*w + x] == 0,
				"mine adjacent to start at (%d, %d)",
				x,
				y,
			)
		}
	}

	// every square's danger equals the number of adjacent mines
	danger := ms_danger(board)
	for y in 0 ..< h {
		for x in 0 ..< w {
			adjacent := 0
			for ay in y - 1 ..= y + 1 {
				for ax in x - 1 ..= x + 1 {
					if ax < 0 || ay < 0 || ax >= w || ay >= h {
						continue
					}
					if mines[ay*w + ax] != 0 {
						adjacent += 1
					}
				}
			}
			testing.expectf(
				t,
				danger[y*w + x] == u8(adjacent),
				"danger at (%d, %d) is %d, want %d",
				x,
				y,
				danger[y*w + x],
				adjacent,
			)
		}
	}
}

@(test)
test_same_seed_same_board :: proc(t: ^testing.T) {
	a := ms_new(16, 16, 40)
	defer ms_free(a)
	b := ms_new(16, 16, 40)
	defer ms_free(b)

	testing.expect_value(t, ms_place_mines(a, 100, 918273), i32(1))
	testing.expect_value(t, ms_place_mines(b, 100, 918273), i32(1))

	am, bm := ms_mines(a), ms_mines(b)
	for i in 0 ..< 16*16 {
		testing.expectf(t, am[i] == bm[i], "mine mismatch at %d", i)
	}

	c := ms_new(16, 16, 40)
	defer ms_free(c)
	testing.expect_value(t, ms_place_mines(c, 100, 918274), i32(1))
	cm := ms_mines(c)
	differ := false
	for i in 0 ..< 16*16 {
		if cm[i] != am[i] {
			differ = true
			break
		}
	}
	testing.expect(t, differ)
}

@(test)
test_reveal_bounds_and_counts :: proc(t: ^testing.T) {
	w, h := 16, 16
	board := ms_new(i32(w), i32(h), 40)
	defer ms_free(board)

	start := i32(1) // top-left corner; guaranteed clear of mines
	testing.expect_value(t, ms_place_mines(board, start, 42), i32(1))

	x1, y1, x2, y2: i32 = -1, -1, -1, -1
	changed := ms_reveal(board, start, &x1, &y1, &x2, &y2)
	testing.expect(t, changed > 0)
	testing.expect_value(t, ms_unrevealed_count(board), i32(w*h) - changed)

	state := ms_state(board)
	danger := ms_danger(board)
	min_x, min_y := i32(w), i32(h)
	max_x, max_y: i32 = -1, -1
	revealed := 0
	for i in 0 ..< w*h {
		if state[i] != SQUARE_REVEALED {
			continue
		}
		revealed += 1
		x, y := i32(i)%i32(w), i32(i)/i32(w)
		min_x = min(min_x, x)
		max_x = max(max_x, x)
		min_y = min(min_y, y)
		max_y = max(max_y, y)

		// flood-fill must clear every neighbour of a zero-danger square
		if danger[i] == 0 {
			for ay in y - 1 ..= y + 1 {
				for ax in x - 1 ..= x + 1 {
					if ax < 0 || ay < 0 || ax >= i32(w) || ay >= i32(h) {
						continue
					}
					testing.expectf(
						t,
						state[ay*i32(w) + ax] == SQUARE_REVEALED,
						"(%d, %d) next to cleared (%d, %d) is not revealed",
						ax,
						ay,
						x,
						y,
					)
				}
			}
		}
	}

	testing.expect_value(t, revealed, int(changed))
	testing.expect_value(t, x1, min_x)
	testing.expect_value(t, y1, min_y)
	testing.expect_value(t, x2, max_x)
	testing.expect_value(t, y2, max_y)

	// revealing an already revealed square changes nothing
	testing.expect_value(t, ms_reveal(board, start, &x1, &y1, &x2, &y2), i32(0))
}

@(test)
test_flag_rules :: proc(t: ^testing.T) {
	board := ms_new(9, 9, 10)
	defer ms_free(board)
	testing.expect_value(t, ms_place_mines(board, 1, 7), i32(1))

	state := ms_state(board)
	x1, y1, x2, y2: i32

	testing.expect_value(t, ms_flag(board, 5, i32(SQUARE_FLAGGED)), i32(1))
	testing.expect_value(t, ms_flag_count(board), i32(1))
	testing.expect_value(t, state[4], SQUARE_FLAGGED)

	// same state is a no-op that succeeds
	testing.expect_value(t, ms_flag(board, 5, i32(SQUARE_FLAGGED)), i32(1))
	testing.expect_value(t, ms_flag_count(board), i32(1))

	// flagged squares cannot be revealed
	testing.expect_value(t, ms_reveal(board, 5, &x1, &y1, &x2, &y2), i32(0))
	testing.expect_value(t, state[4], SQUARE_FLAGGED)

	testing.expect_value(t, ms_flag(board, 5, i32(SQUARE_MAYBE)), i32(1))
	testing.expect_value(t, ms_flag_count(board), i32(0))
	testing.expect_value(t, state[4], SQUARE_MAYBE)

	// revealed squares reject every marker change
	testing.expect(t, ms_reveal(board, 1, &x1, &y1, &x2, &y2) > 0)
	testing.expect_value(t, ms_flag(board, 1, i32(SQUARE_FLAGGED)), i32(0))
	testing.expect_value(t, ms_flag(board, 1, i32(SQUARE_REVEALED)), i32(0))
	testing.expect_value(t, ms_flag_count(board), i32(0))

	// out of range index / marker
	testing.expect_value(t, ms_flag(board, 0, i32(SQUARE_FLAGGED)), i32(0))
	testing.expect_value(t, ms_flag(board, 82, i32(SQUARE_FLAGGED)), i32(0))
	testing.expect_value(t, ms_flag(board, 2, 9), i32(0))
}

// Regression: a nearly full board cannot keep mines away from the start, but
// the clicked square itself must never be one of them.
@(test)
test_start_square_never_mined :: proc(t: ^testing.T) {
	cases := [][3]i32{{3, 3, 7}, {9, 9, 72}, {9, 9, 79}, {5, 5, 20}}
	for c in cases {
		board := ms_new(c[0], c[1], c[2])
		defer ms_free(board)

		safe := i32(1)
		testing.expect_value(t, ms_place_mines(board, safe, 1234), i32(1))
		testing.expect_value(t, ms_mine_count(board), c[2])
		testing.expectf(
			t,
			ms_mines(board)[safe - 1] == 0,
			"start square mined on %dx%d with %d mines",
			c[0],
			c[1],
			c[2],
		)
	}
}

// The UI blocks marking before the first reveal, but the engine must still
// keep any markers a caller sets before mine placement.
@(test)
test_markers_survive_placement :: proc(t: ^testing.T) {
	board := ms_new(9, 9, 10)
	defer ms_free(board)

	testing.expect_value(t, ms_flag(board, 10, i32(SQUARE_FLAGGED)), i32(1))
	testing.expect_value(t, ms_flag(board, 11, i32(SQUARE_MAYBE)), i32(1))
	testing.expect_value(t, ms_place_mines(board, 1, 5), i32(1))
	testing.expect_value(t, ms_flag_count(board), i32(1))
	testing.expect_value(t, ms_state(board)[9], SQUARE_FLAGGED)
	testing.expect_value(t, ms_state(board)[10], SQUARE_MAYBE)
	testing.expect_value(t, ms_unrevealed_count(board), i32(81))
}

// Regression: avoiding mines next to the start square is impossible on a 3x3
// board with 7 mines, and must fall back instead of spinning forever.
@(test)
test_tight_board_terminates :: proc(t: ^testing.T) {
	board := ms_new(3, 3, 7)
	defer ms_free(board)
	testing.expect_value(t, ms_place_mines(board, 5, 42), i32(1))
	testing.expect_value(t, ms_mine_count(board), i32(7))

	mines := ms_mines(board)
	total := 0
	for i in 0 ..< 9 {
		if mines[i] != 0 {
			total += 1
		}
	}
	testing.expect_value(t, total, 7)
}

@(test)
test_free_reuses_handle :: proc(t: ^testing.T) {
	first := ms_new(9, 9, 10)
	testing.expect(t, first > 0)
	ms_free(first)
	testing.expect(t, ms_state(first) == nil)

	second := ms_new(9, 9, 10)
	defer ms_free(second)
	testing.expect_value(t, second, first)

	// freeing twice is harmless
	ms_free(second)
	ms_free(second)
}
