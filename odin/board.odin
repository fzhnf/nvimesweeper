// C ABI of the game engine, called from lua/nvimesweeper/native.lua.
package minesweeper

import "base:runtime"
import "core:math/rand"

ABI_VERSION :: 1

// Square states; must match lua/nvimesweeper/board.lua.
SQUARE_NONE     :: u8(0)
SQUARE_FLAGGED  :: u8(1)
SQUARE_MAYBE    :: u8(2)
SQUARE_REVEALED :: u8(3)

// shortcut: boards are capped at 1M cells because indices are i32, raise if a
// bigger board is actually playable.
MAX_CELLS :: 1_000_000

Board :: struct {
	width, height:    i32,
	mine_count:       i32,
	flag_count:       i32,
	unrevealed_count: i32,
	mines:            []u8,
	state:            []u8,
	danger:           []u8,
	queued:           []u8,
	stack:            []i32,
	candidates:       []i32,
}

// Handles are 1-based indices into this table; freed slots are reused.
boards: [dynamic]^Board

board_at :: proc "contextless" (h: i32) -> ^Board {
	i := int(h) - 1
	if i < 0 || i >= len(boards) {
		return nil
	}
	return boards[i]
}

is_valid_index :: proc "contextless" (b: ^Board, i: i32) -> bool {
	return i >= 1 && i <= b.width*b.height
}

cell_x :: proc "contextless" (b: ^Board, i: i32) -> i32 {return (i - 1) % b.width}
cell_y :: proc "contextless" (b: ^Board, i: i32) -> i32 {return (i - 1) / b.width}

is_adjacent :: proc "contextless" (x, y, x2, y2: i32) -> bool {
	return abs(x - x2) <= 1 && abs(y - y2) <= 1
}

is_revealable :: proc "contextless" (state: u8) -> bool {
	return state == SQUARE_NONE || state == SQUARE_MAYBE
}

reveal_square :: proc "contextless" (b: ^Board, i: i32) -> bool {
	if !is_revealable(b.state[i - 1]) {
		return false
	}
	b.state[i - 1] = SQUARE_REVEALED
	b.unrevealed_count -= 1
	return true
}

// Collects the cells a mine may occupy, as 1-based indices; returns how many.
fill_candidates :: proc "contextless" (
	b: ^Board,
	safe_x, safe_y: i32,
	avoid_safe: bool,
) -> int {
	n := 0
	for i in 0 ..< len(b.mines) {
		if b.mines[i] != 0 {
			continue
		}
		if avoid_safe &&
		   is_adjacent(safe_x, safe_y, i32(i)%b.width, i32(i)/b.width) {
			continue
		}
		b.candidates[n] = i32(i) + 1
		n += 1
	}
	return n
}

@(export)
ms_abi_version :: proc "c" () -> i32 {return ABI_VERSION}

@(export)
ms_new :: proc "c" (width, height, mines: i32) -> i32 {
	context = runtime.default_context()

	if width <= 0 || height <= 0 || mines <= 0 {
		return 0
	}
	cells := i64(width)*i64(height)
	if cells > MAX_CELLS || mines >= i32(cells) {
		return 0
	}

	n := int(cells)
	b := new(Board)
	b.width = width
	b.height = height
	b.mine_count = mines
	b.unrevealed_count = i32(cells)
	b.mines = make([]u8, n)
	b.state = make([]u8, n)
	b.danger = make([]u8, n)
	b.queued = make([]u8, n)
	b.stack = make([]i32, n)
	b.candidates = make([]i32, n)

	for ptr, i in boards {
		if ptr == nil {
			boards[i] = b
			return i32(i) + 1
		}
	}
	append(&boards, b)
	return i32(len(boards))
}

@(export)
ms_free :: proc "c" (h: i32) {
	context = runtime.default_context()

	b := board_at(h)
	if b == nil {
		return
	}
	delete(b.mines)
	delete(b.state)
	delete(b.danger)
	delete(b.queued)
	delete(b.stack)
	delete(b.candidates)
	free(b)
	boards[h - 1] = nil
}

// Places all mines at once; no mine touches the start square unless there is
// no room left to avoid it.
@(export)
ms_place_mines :: proc "c" (h: i32, safe_i: i32, seed: i64) -> i32 {
	context = runtime.default_context()

	b := board_at(h)
	if b == nil || !is_valid_index(b, safe_i) {
		return 0
	}

	for i in 0 ..< len(b.state) {
		b.mines[i] = 0
		b.danger[i] = 0
		b.queued[i] = 0
	}
	// squares marked before the first reveal keep their marker and count
	b.unrevealed_count = b.width*b.height

	safe_x := cell_x(b, safe_i)
	safe_y := cell_y(b, safe_i)
	state := rand.create_u64(u64(seed))
	gen := rand.default_random_generator(&state)

	for placed: i32 = 0; placed < b.mine_count; {
		avoid_safe := b.unrevealed_count - placed > 8
		n := fill_candidates(b, safe_x, safe_y, avoid_safe)
		if n == 0 && avoid_safe {
			n = fill_candidates(b, safe_x, safe_y, false)
		}
		if n == 0 {
			return 0
		}

		i := b.candidates[int(rand.int_max(n, gen))]
		b.mines[i - 1] = 1
		placed += 1

		x, y := cell_x(b, i), cell_y(b, i)
		for ay in y - 1 ..= y + 1 {
			for ax in x - 1 ..= x + 1 {
				if ax < 0 || ay < 0 || ax >= b.width || ay >= b.height {
					continue
				}
				b.danger[ay*b.width + ax] += 1
			}
		}
	}

	return 1
}

// Flood-reveals from a cell. Returns the number of squares revealed; when it is
// non-zero, the bounding box of those squares is written to x1/y1/x2/y2
// (0-based, inclusive).
@(export)
ms_reveal :: proc "c" (
	h: i32,
	start_i: i32,
	x1, y1, x2, y2: ^i32,
) -> i32 {
	b := board_at(h)
	if b == nil || !is_valid_index(b, start_i) {
		return 0
	}

	changed: i32
	min_x, min_y := b.width, b.height
	max_x, max_y: i32 = -1, -1

	b.queued[start_i - 1] = 1
	b.stack[0] = start_i
	top := 1

	for top > 0 {
		top -= 1
		i := b.stack[top]
		if !reveal_square(b, i) {
			continue
		}

		changed += 1
		x, y := cell_x(b, i), cell_y(b, i)
		min_x = min(min_x, x)
		max_x = max(max_x, x)
		min_y = min(min_y, y)
		max_y = max(max_y, y)

		if b.danger[i - 1] != 0 {
			continue
		}
		for ay in y - 1 ..= y + 1 {
			for ax in x - 1 ..= x + 1 {
				if ax < 0 || ay < 0 || ax >= b.width || ay >= b.height {
					continue
				}
				ai := ay*b.width + ax + 1
				if b.queued[ai - 1] != 0 || !is_revealable(b.state[ai - 1]) {
					continue
				}
				b.queued[ai - 1] = 1
				b.stack[top] = ai
				top += 1
			}
		}
	}

	if changed > 0 {
		x1^ = min_x
		y1^ = min_y
		x2^ = max_x
		y2^ = max_y
	}
	return changed
}

// Sets the marker state of an unrevealed cell. Returns 1 if the board changed.
@(export)
ms_flag :: proc "c" (h: i32, i: i32, new_state: i32) -> i32 {
	b := board_at(h)
	if b == nil || !is_valid_index(b, i) {
		return 0
	}
	if new_state < 0 || new_state > i32(SQUARE_REVEALED) {
		return 0
	}
	if new_state == i32(SQUARE_REVEALED) {
		return 0
	}

	state := b.state[i - 1]
	if state == SQUARE_REVEALED {
		return 0
	}
	if state == u8(new_state) {
		return 1
	}

	if new_state == i32(SQUARE_FLAGGED) {
		b.flag_count += 1
	} else if state == SQUARE_FLAGGED {
		b.flag_count -= 1
	}
	b.state[i - 1] = u8(new_state)
	return 1
}

@(export)
ms_state :: proc "c" (h: i32) -> [^]u8 {
	b := board_at(h)
	if b == nil {
		return nil
	}
	return raw_data(b.state)
}

@(export)
ms_mines :: proc "c" (h: i32) -> [^]u8 {
	b := board_at(h)
	if b == nil {
		return nil
	}
	return raw_data(b.mines)
}

@(export)
ms_danger :: proc "c" (h: i32) -> [^]u8 {
	b := board_at(h)
	if b == nil {
		return nil
	}
	return raw_data(b.danger)
}

@(export)
ms_mine_count :: proc "c" (h: i32) -> i32 {
	b := board_at(h)
	if b == nil {
		return 0
	}
	return b.mine_count
}

@(export)
ms_flag_count :: proc "c" (h: i32) -> i32 {
	b := board_at(h)
	if b == nil {
		return 0
	}
	return b.flag_count
}

@(export)
ms_unrevealed_count :: proc "c" (h: i32) -> i32 {
	b := board_at(h)
	if b == nil {
		return 0
	}
	return b.unrevealed_count
}
