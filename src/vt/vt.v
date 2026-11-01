// Package vt turns the byte stream a shell writes into a grid of cells, for the native
// renderer (beta). It follows the DEC/xterm state machine (vt100.net/emu/dec_ansi_parser)
// for the subset ConPTY and common TUIs emit; anything else is parsed and ignored.
module vt

import math

pub const attr_bold = u8(1)
pub const attr_dim = u8(2)
pub const attr_italic = u8(4)
pub const attr_underline = u8(8)
pub const attr_inverse = u8(16)

// Colors: 0 is the theme default, (1 << 24) | index is a palette entry (0-255),
// (2 << 24) | 0xRRGGBB is true color.
pub fn palette(i int) u32 {
	return (u32(1) << 24) | u32(i & 0xff)
}

pub fn rgb(r int, g int, b int) u32 {
	return (u32(2) << 24) | (u32(r & 0xff) << 16) | (u32(g & 0xff) << 8) | u32(b & 0xff)
}

// ch is 0 on the right half of a wide character.
pub struct Cell {
pub mut:
	ch    rune = ` `
	fg    u32
	bg    u32
	attrs u8
}

enum State {
	ground
	escape
	esc_inter
	csi_entry
	csi_param
	csi_inter
	csi_ignore
	osc
	osc_esc
	str_ignore
	str_esc
}

const max_params = 32
const max_osc = 4096

@[heap]
pub struct Screen {
pub mut:
	cols            int
	rows            int
	lines           [][]Cell // the active buffer, one array per row
	cx              int
	cy              int
	title           string
	cursor_visible  bool = true
	app_cursor      bool // DECCKM: arrow keys send ESC O A instead of ESC [ A
	bracketed_paste bool
	reply           []u8 // answers (cursor position, device attributes) to write back to the shell
	dirty           bool
	max_scrollback  int = 10000
mut:
	pen          Cell
	wrap_pending bool
	autowrap     bool = true
	top          int
	bottom       int
	saved_x      int
	saved_y      int
	saved_pen    Cell
	alt          [][]Cell // the inactive buffer
	alt_active   bool
	scrollback   [][]Cell // ring buffer, oldest at sb_head once full
	sb_head      int
	state        State
	params       []int // -1 marks an omitted parameter
	cur          int
	private      u8
	inter        u8
	osc          []u8
	utf_need     int
	utf_cp       u32
}

pub fn new_screen(cols int, rows int) &Screen {
	c := math.max(cols, 1)
	r := math.max(rows, 1)
	return &Screen{
		cols:   c
		rows:   r
		lines:  grid(c, r)
		alt:    grid(c, r)
		bottom: r - 1
	}
}

pub fn (mut s Screen) feed(data []u8) {
	for b in data {
		s.step(b)
	}
	s.dirty = true
}

pub fn (s &Screen) scrollback_len() int {
	return s.scrollback.len
}

// scrollback_line(0) is the oldest kept line. Lines keep the width they had when they
// scrolled off.
pub fn (s &Screen) scrollback_line(i int) []Cell {
	return s.scrollback[(s.sb_head + i) % s.scrollback.len]
}

// line returns row r as text without trailing blanks, for tests and search.
pub fn (s &Screen) line(r int) string {
	return cells_text(s.lines[r])
}

pub fn cells_text(cells []Cell) string {
	mut out := []rune{cap: cells.len}
	for c in cells {
		if c.ch != 0 {
			out << c.ch
		}
	}
	return out.string().trim_right(' ')
}

// resize keeps the rows around the cursor: when the screen gets shorter, the lines above
// move to the scrollback, like xterm.
// shortcut: no reflow of wrapped lines; add it when long lines look wrong after a resize.
pub fn (mut s Screen) resize(cols int, rows int) {
	if cols < 1 || rows < 1 || (cols == s.cols && rows == s.rows) {
		return
	}
	skip := math.max(0, s.cy - rows + 1)
	if !s.alt_active {
		for r in 0 .. skip {
			s.push_scrollback(s.lines[r])
		}
	}
	s.lines = reshape(s.lines, cols, rows, skip)
	s.alt = reshape(s.alt, cols, rows, 0)
	s.cols = cols
	s.rows = rows
	s.cy -= skip
	s.cx = clamp(s.cx, 0, cols - 1)
	s.cy = clamp(s.cy, 0, rows - 1)
	s.top = 0
	s.bottom = rows - 1
	s.wrap_pending = false
	s.dirty = true
}

fn grid(cols int, rows int) [][]Cell {
	return [][]Cell{len: rows, init: []Cell{len: cols}}
}

fn reshape(old [][]Cell, cols int, rows int, skip int) [][]Cell {
	mut out := grid(cols, rows)
	for r in 0 .. math.min(rows, old.len - skip) {
		src := old[r + skip]
		for c in 0 .. math.min(cols, src.len) {
			out[r][c] = src[c]
		}
	}
	return out
}

fn clamp(v int, lo int, hi int) int {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}

// ---- parser -------------------------------------------------------------------------

fn (mut s Screen) step(b u8) {
	if b == 0x1b {
		s.utf_need = 0
		s.state = match s.state {
			.osc { State.osc_esc }
			.str_ignore { State.str_esc }
			else { State.escape }
		}

		s.inter = 0
		return
	}
	if b == 0x18 || b == 0x1a { // CAN, SUB abort a sequence
		s.state = .ground
		return
	}
	match s.state {
		.ground {
			s.ground(b)
		}
		.escape {
			s.escape(b)
		}
		.esc_inter {
			if b < 0x20 {
				s.execute(b)
			} else if b >= 0x30 && b <= 0x7e {
				s.state = .ground // charset designations (ESC ( B ...) are ignored
			}
		}
		.csi_entry, .csi_param, .csi_inter, .csi_ignore {
			s.csi(b)
		}
		.osc {
			if b == 0x07 {
				s.osc_dispatch()
				s.state = .ground
			} else if s.osc.len < max_osc {
				s.osc << b
			}
		}
		.osc_esc {
			s.osc_dispatch()
			s.state = .escape
			s.escape(b) // ESC \ ends the string; ESC <other> starts a new sequence
		}
		.str_ignore {
			if b == 0x07 {
				s.state = .ground
			}
		}
		.str_esc {
			s.state = .escape
			s.escape(b)
		}
	}
}

fn (mut s Screen) ground(b u8) {
	if s.utf_need > 0 {
		if (b & 0xc0) == 0x80 {
			s.utf_cp = (s.utf_cp << 6) | u32(b & 0x3f)
			s.utf_need--
			if s.utf_need == 0 {
				s.print(rune(s.utf_cp))
			}
			return
		}
		s.utf_need = 0
		s.print(0xfffd)
	}
	if b < 0x20 || b == 0x7f {
		s.execute(b)
	} else if b < 0x80 {
		s.print(rune(b))
	} else if (b & 0xe0) == 0xc0 {
		s.utf_cp = u32(b & 0x1f)
		s.utf_need = 1
	} else if (b & 0xf0) == 0xe0 {
		s.utf_cp = u32(b & 0x0f)
		s.utf_need = 2
	} else if (b & 0xf8) == 0xf0 {
		s.utf_cp = u32(b & 0x07)
		s.utf_need = 3
	} else {
		s.print(0xfffd)
	}
}

fn (mut s Screen) escape(b u8) {
	match rune(b) {
		`[` {
			s.state = .csi_entry
			s.params.clear()
			s.cur = -1
			s.private = 0
			s.inter = 0
			return
		}
		`]` {
			s.state = .osc
			s.osc.clear()
			return
		}
		`P`, `X`, `^`, `_` { // DCS, SOS, PM, APC: skipped up to ST
			s.state = .str_ignore
			return
		}
		`\\` { // ST on its own
			s.state = .ground
			return
		}
		else {}
	}

	if b < 0x20 {
		s.execute(b)
		return
	}
	if b <= 0x2f {
		s.inter = b
		s.state = .esc_inter
		return
	}
	s.state = .ground
	match rune(b) {
		`7` {
			s.save_cursor()
		}
		`8` {
			s.restore_cursor()
		}
		`D` {
			s.linefeed()
		}
		`E` {
			s.cx = 0
			s.linefeed()
		}
		`M` {
			s.reverse_index()
		}
		`c` {
			s.reset()
		}
		else {}
	}
}

fn (mut s Screen) csi(b u8) {
	if b < 0x20 {
		s.execute(b)
		return
	}
	if s.state == .csi_ignore {
		if b >= 0x40 && b <= 0x7e {
			s.state = .ground
		}
		return
	}
	if b >= 0x30 && b <= 0x39 { // digit
		if s.state == .csi_inter {
			s.state = .csi_ignore
			return
		}
		s.cur = math.min(math.max(s.cur, 0) * 10 + int(b - 0x30), 65535)
		s.state = .csi_param
	} else if b == 0x3b || b == 0x3a { // ; and : (sub-parameters are flattened)
		if s.params.len < max_params {
			s.params << s.cur
		}
		s.cur = -1
		s.state = .csi_param
	} else if b >= 0x3c && b <= 0x3f { // < = > ? private markers
		if s.state == .csi_entry {
			s.private = b
			s.state = .csi_param
		} else {
			s.state = .csi_ignore
		}
	} else if b <= 0x2f {
		s.inter = b
		s.state = .csi_inter
	} else if b >= 0x40 && b <= 0x7e {
		if s.params.len < max_params {
			s.params << s.cur
		}
		s.state = .ground
		s.csi_dispatch(b)
	}
}

// arg is parameter i, or 0 when omitted. count is the same with 0 meaning 1.
fn (s &Screen) arg(i int) int {
	return if i < s.params.len && s.params[i] > 0 { s.params[i] } else { 0 }
}

fn (s &Screen) count(i int) int {
	return math.max(s.arg(i), 1)
}

fn (mut s Screen) osc_dispatch() {
	text := s.osc.bytestr()
	s.osc.clear()
	if text.starts_with('0;') || text.starts_with('2;') {
		s.title = text[2..]
	}
}

// ---- actions ------------------------------------------------------------------------

fn (mut s Screen) execute(b u8) {
	match b {
		0x08 {
			if s.cx > 0 {
				s.cx--
			}
			s.wrap_pending = false
		}
		0x09 {
			s.cx = math.min(s.cols - 1, (s.cx / 8 + 1) * 8)
			s.wrap_pending = false
		}
		0x0a, 0x0b, 0x0c {
			s.linefeed()
		}
		0x0d {
			s.cx = 0
			s.wrap_pending = false
		}
		else {}
	}
}

fn (mut s Screen) print(r rune) {
	w := if r < 0x300 { 1 } else { width(r) }
	if w == 0 {
		return
	}
	if s.wrap_pending && s.autowrap {
		s.cx = 0
		s.linefeed()
	}
	s.wrap_pending = false
	if w == 2 && s.cx == s.cols - 1 && s.autowrap && s.cols > 1 {
		s.lines[s.cy][s.cx] = s.blank()
		s.cx = 0
		s.linefeed()
	}
	mut line := s.lines[s.cy]
	line[s.cx] = Cell{
		ch:    r
		fg:    s.pen.fg
		bg:    s.pen.bg
		attrs: s.pen.attrs
	}
	if w == 2 && s.cx + 1 < s.cols {
		line[s.cx + 1] = Cell{
			ch:    0
			fg:    s.pen.fg
			bg:    s.pen.bg
			attrs: s.pen.attrs
		}
	}
	s.cx += w
	if s.cx >= s.cols {
		s.cx = s.cols - 1
		s.wrap_pending = true
	}
}

fn (s &Screen) blank() Cell {
	return Cell{
		bg: s.pen.bg
	}
}

// clear blanks the cells from..to, counted row by row from the top left.
fn (mut s Screen) clear(from int, to int) {
	b := s.blank()
	for i in math.max(from, 0) .. math.min(to, s.rows * s.cols) {
		s.lines[i / s.cols][i % s.cols] = b
	}
}

fn (mut s Screen) linefeed() {
	if s.cy == s.bottom {
		s.scroll_up(1, true)
	} else if s.cy < s.rows - 1 {
		s.cy++
	}
	s.wrap_pending = false
}

fn (mut s Screen) reverse_index() {
	if s.cy == s.top {
		s.scroll_down(1)
	} else if s.cy > 0 {
		s.cy--
	}
	s.wrap_pending = false
}

// scroll_up moves the scroll region up by n lines. Lines leaving the top of the main
// screen go to the scrollback only when history is set (line feeds, not CSI S / DL).
// Rows are moved, not copied, and the row the scrollback drops is reused.
fn (mut s Screen) scroll_up(count int, history bool) {
	n := math.min(count, s.bottom - s.top + 1)
	b := s.blank()
	for _ in 0 .. n {
		mut old := s.lines[s.top]
		for r in s.top .. s.bottom {
			s.lines[r] = s.lines[r + 1]
		}
		mut fresh := if history && s.top == 0 && !s.alt_active {
			s.push_scrollback(old)
		} else {
			old
		}
		if fresh.len != s.cols {
			fresh = []Cell{len: s.cols}
		}
		for c in 0 .. s.cols {
			fresh[c] = b
		}
		s.lines[s.bottom] = fresh
	}
}

fn (mut s Screen) scroll_down(count int) {
	n := math.min(count, s.bottom - s.top + 1)
	b := s.blank()
	for _ in 0 .. n {
		mut fresh := s.lines[s.bottom]
		for r := s.bottom; r > s.top; r-- {
			s.lines[r] = s.lines[r - 1]
		}
		for c in 0 .. fresh.len {
			fresh[c] = b
		}
		s.lines[s.top] = fresh
	}
}

// push_scrollback keeps line and returns the line it dropped (empty while not full).
fn (mut s Screen) push_scrollback(line []Cell) []Cell {
	if s.max_scrollback <= 0 {
		return line
	}
	if s.scrollback.len < s.max_scrollback {
		s.scrollback << line
		return []Cell{}
	}
	dropped := s.scrollback[s.sb_head]
	s.scrollback[s.sb_head] = line
	s.sb_head = (s.sb_head + 1) % s.scrollback.len
	return dropped
}

fn (mut s Screen) save_cursor() {
	s.saved_x = s.cx
	s.saved_y = s.cy
	s.saved_pen = s.pen
}

fn (mut s Screen) restore_cursor() {
	s.cx = clamp(s.saved_x, 0, s.cols - 1)
	s.cy = clamp(s.saved_y, 0, s.rows - 1)
	s.pen = s.saved_pen
	s.wrap_pending = false
}

fn (mut s Screen) set_alt(on bool) {
	if on == s.alt_active {
		return
	}
	s.lines, s.alt = s.alt, s.lines
	s.alt_active = on
	if on {
		s.clear(0, s.rows * s.cols)
	}
}

fn (mut s Screen) reset() {
	s.set_alt(false)
	s.pen = Cell{}
	s.clear(0, s.rows * s.cols)
	s.cx, s.cy = 0, 0
	s.top, s.bottom = 0, s.rows - 1
	s.wrap_pending = false
	s.autowrap = true
	s.cursor_visible = true
	s.app_cursor = false
	s.bracketed_paste = false
}

fn (mut s Screen) mode(p int, on bool) {
	match p {
		1 {
			s.app_cursor = on
		}
		7 {
			s.autowrap = on
		}
		25 {
			s.cursor_visible = on
		}
		47, 1047 {
			s.set_alt(on)
		}
		1049 {
			if on {
				s.save_cursor()
				s.set_alt(true)
			} else {
				s.set_alt(false)
				s.restore_cursor()
			}
		}
		2004 {
			s.bracketed_paste = on
		}
		else {}
	}
}

fn (mut s Screen) csi_dispatch(f u8) {
	if s.private == 0x3f { // ?
		if rune(f) == `h` || rune(f) == `l` {
			for p in s.params {
				s.mode(p, rune(f) == `h`)
			}
		}
		return
	}
	if s.private != 0 || s.inter != 0 {
		return
	}
	row := s.cy * s.cols
	match rune(f) {
		`A` {
			s.cy = math.max(s.cy - s.count(0), if s.cy >= s.top { s.top } else { 0 })
		}
		`B`, `e` {
			s.cy = math.min(s.cy + s.count(0), if s.cy <= s.bottom { s.bottom } else { s.rows - 1 })
		}
		`C`, `a` {
			s.cx = math.min(s.cx + s.count(0), s.cols - 1)
		}
		`D` {
			s.cx = math.max(s.cx - s.count(0), 0)
		}
		`E` {
			s.cy = math.min(s.cy + s.count(0), s.rows - 1)
			s.cx = 0
		}
		`F` {
			s.cy = math.max(s.cy - s.count(0), 0)
			s.cx = 0
		}
		`G`, `\`` {
			s.cx = clamp(s.count(0) - 1, 0, s.cols - 1)
		}
		`H`, `f` {
			s.cy = clamp(s.count(0) - 1, 0, s.rows - 1)
			s.cx = clamp(s.count(1) - 1, 0, s.cols - 1)
		}
		`d` {
			s.cy = clamp(s.count(0) - 1, 0, s.rows - 1)
		}
		`J` {
			match s.arg(0) {
				0 {
					s.clear(row + s.cx, s.rows * s.cols)
				}
				1 {
					s.clear(0, row + s.cx + 1)
				}
				2 {
					s.clear(0, s.rows * s.cols)
				}
				3 {
					s.scrollback.clear()
					s.sb_head = 0
				}
				else {}
			}
		}
		`K` {
			match s.arg(0) {
				0 { s.clear(row + s.cx, row + s.cols) }
				1 { s.clear(row, row + s.cx + 1) }
				2 { s.clear(row, row + s.cols) }
				else {}
			}
		}
		`L`, `M` {
			if s.cy >= s.top && s.cy <= s.bottom {
				old := s.top
				s.top = s.cy
				if rune(f) == `L` {
					s.scroll_down(s.count(0))
				} else {
					s.scroll_up(s.count(0), false)
				}
				s.top = old
				s.cx = 0
			}
		}
		`P` {
			n := math.min(s.count(0), s.cols - s.cx)
			for c in s.cx .. s.cols - n {
				s.lines[s.cy][c] = s.lines[s.cy][c + n]
			}
			s.clear(row + s.cols - n, row + s.cols)
		}
		`@` {
			n := math.min(s.count(0), s.cols - s.cx)
			for c := s.cols - 1; c >= s.cx + n; c-- {
				s.lines[s.cy][c] = s.lines[s.cy][c - n]
			}
			s.clear(row + s.cx, row + s.cx + n)
		}
		`X` {
			s.clear(row + s.cx, row + math.min(s.cx + s.count(0), s.cols))
		}
		`S` {
			s.scroll_up(s.count(0), false)
		}
		`T` {
			s.scroll_down(s.count(0))
		}
		`m` {
			s.sgr()
			return
		}
		`r` {
			t := s.count(0) - 1
			b := if s.arg(1) == 0 { s.rows - 1 } else { s.arg(1) - 1 }
			if t < b && b < s.rows {
				s.top, s.bottom = t, b
				s.cx, s.cy = 0, 0
			}
		}
		`s` {
			s.save_cursor()
		}
		`u` {
			s.restore_cursor()
		}
		`n` {
			if s.arg(0) == 6 {
				s.reply << '\x1b[${s.cy + 1};${s.cx + 1}R'.bytes()
			} else if s.arg(0) == 5 {
				s.reply << '\x1b[0n'.bytes()
			}
		}
		`c` {
			s.reply << '\x1b[?1;2c'.bytes()
		}
		else {}
	}

	s.wrap_pending = false
}

fn (mut s Screen) sgr() {
	mut i := 0
	for i < s.params.len {
		p := math.max(s.params[i], 0)
		match p {
			0 {
				s.pen = Cell{}
			}
			1 {
				s.pen.attrs |= attr_bold
			}
			2 {
				s.pen.attrs |= attr_dim
			}
			3 {
				s.pen.attrs |= attr_italic
			}
			4 {
				s.pen.attrs |= attr_underline
			}
			7 {
				s.pen.attrs |= attr_inverse
			}
			22 {
				s.pen.attrs &= ~(attr_bold | attr_dim)
			}
			23 {
				s.pen.attrs &= ~attr_italic
			}
			24 {
				s.pen.attrs &= ~attr_underline
			}
			27 {
				s.pen.attrs &= ~attr_inverse
			}
			30...37 {
				s.pen.fg = palette(p - 30)
			}
			39 {
				s.pen.fg = 0
			}
			40...47 {
				s.pen.bg = palette(p - 40)
			}
			49 {
				s.pen.bg = 0
			}
			90...97 {
				s.pen.fg = palette(p - 90 + 8)
			}
			100...107 {
				s.pen.bg = palette(p - 100 + 8)
			}
			38, 48 {
				mut c := u32(0)
				if i + 2 < s.params.len && s.params[i + 1] == 5 {
					c = palette(math.max(s.params[i + 2], 0))
					i += 2
				} else if i + 4 < s.params.len && s.params[i + 1] == 2 {
					c = rgb(math.max(s.params[i + 2], 0), math.max(s.params[i + 3], 0), math.max(s.params[
						i + 4], 0))
					i += 4
				}
				if p == 38 {
					s.pen.fg = c
				} else {
					s.pen.bg = c
				}
			}
			else {}
		}

		i++
	}
}

// width is the number of cells a character takes: 0 for combining marks, 2 for East
// Asian wide characters and emoji.
// shortcut: a hand-picked range table, not full Unicode EastAsianWidth; extend it when a
// script renders misaligned.
pub fn width(r rune) int {
	c := u32(r)
	if (c >= 0x0300 && c <= 0x036f) || (c >= 0x200b && c <= 0x200f) || (c >= 0xfe00 && c <= 0xfe0f) {
		return 0
	}
	if (c >= 0x1100 && c <= 0x115f) || (c >= 0x2e80 && c <= 0xa4cf && c != 0x303f)
		|| (c >= 0xac00 && c <= 0xd7a3) || (c >= 0xf900 && c <= 0xfaff)
		|| (c >= 0xfe30 && c <= 0xfe4f) || (c >= 0xff00 && c <= 0xff60)
		|| (c >= 0xffe0 && c <= 0xffe6) || (c >= 0x1f300 && c <= 0x1f64f)
		|| (c >= 0x1f900 && c <= 0x1f9ff) || (c >= 0x20000 && c <= 0x3fffd) {
		return 2
	}
	return 1
}
