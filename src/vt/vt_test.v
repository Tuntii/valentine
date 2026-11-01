module vt

fn feed(mut s Screen, text string) {
	s.feed(text.bytes())
}

fn test_text_wraps_and_scrolls_into_history() {
	mut s := new_screen(5, 2)
	feed(mut s, 'abcdefgh\r\nxy')
	assert s.scrollback_len() == 1
	assert cells_text(s.scrollback_line(0)) == 'abcde'
	assert s.line(0) == 'fgh'
	assert s.line(1) == 'xy'
	assert s.cx == 2 && s.cy == 1
}

fn test_pending_wrap_stays_on_last_column() {
	mut s := new_screen(3, 2)
	feed(mut s, 'abc')
	assert s.cx == 2 && s.cy == 0 // the next printable wraps, a CR does not
	feed(mut s, '\r')
	assert s.cy == 0
}

fn test_utf8_and_wide_characters() {
	mut s := new_screen(6, 1)
	feed(mut s, 'ğü界x')
	assert s.line(0) == 'ğü界x'
	assert s.lines[0][2].ch == `界` && s.lines[0][3].ch == 0
	assert s.cx == 5
	// a byte that breaks a sequence shows a replacement character
	mut t := new_screen(4, 1)
	t.feed([u8(0xc4), `a`])
	assert t.line(0) == '\ufffda'
}

fn test_split_utf8_across_feeds() {
	mut s := new_screen(4, 1)
	b := 'ş'.bytes()
	s.feed(b[..1])
	s.feed(b[1..])
	assert s.line(0) == 'ş'
}

fn test_cursor_movement_and_erase() {
	mut s := new_screen(10, 3)
	feed(mut s, 'hello\x1b[2;3Hx\x1b[1;1H\x1b[2C!')
	assert s.line(0) == 'he!lo'
	assert s.line(1) == '  x'
	feed(mut s, '\x1b[1;4H\x1b[K')
	assert s.line(0) == 'he!'
	feed(mut s, '\x1b[2J')
	assert s.line(0) == '' && s.line(1) == ''
}

fn test_sgr_colors_and_attributes() {
	mut s := new_screen(10, 1)
	feed(mut s, '\x1b[1;31ma\x1b[38;5;200mb\x1b[48;2;1;2;3mc\x1b[0md')
	assert s.lines[0][0].fg == palette(1) && s.lines[0][0].attrs & attr_bold != 0
	assert s.lines[0][1].fg == palette(200)
	assert s.lines[0][2].bg == rgb(1, 2, 3)
	assert s.lines[0][3].fg == 0 && s.lines[0][3].attrs == 0
}

fn test_scroll_region_and_line_editing() {
	mut s := new_screen(3, 4)
	feed(mut s, '1\r\n2\r\n3\r\n4')
	feed(mut s, '\x1b[2;3r\x1b[3;1H\n') // LF at the region bottom scrolls only rows 2-3
	assert s.line(0) == '1' && s.line(1) == '3' && s.line(2) == '' && s.line(3) == '4'
	assert s.scrollback_len() == 0
	feed(mut s, '\x1b[r\x1b[1;1H\x1b[L')
	assert s.line(0) == '' && s.line(1) == '1'
}

fn test_alternate_screen_restores_main() {
	mut s := new_screen(5, 2)
	feed(mut s, 'main')
	feed(mut s, '\x1b[?1049h\x1b[Hvim')
	assert s.line(0) == 'vim'
	feed(mut s, '\x1b[?1049l')
	assert s.line(0) == 'main' && s.cx == 4
}

fn test_osc_title_and_ignored_strings() {
	mut s := new_screen(10, 1)
	feed(mut s, '\x1b]0;my title\x07a\x1b]9;9;"C:\\"\x1b\\b\x1bP1$r\x1b\\c')
	assert s.title == 'my title'
	assert s.line(0) == 'abc'
}

fn test_cursor_position_report() {
	mut s := new_screen(10, 5)
	feed(mut s, '\x1b[3;4H\x1b[6n')
	assert s.reply.bytestr() == '\x1b[3;4R'
}

fn test_scrollback_is_capped() {
	mut s := new_screen(2, 1)
	s.max_scrollback = 3
	feed(mut s, '1\r\n2\r\n3\r\n4\r\n5\r\n')
	assert s.scrollback_len() == 3
	assert cells_text(s.scrollback_line(0)) == '3'
	assert cells_text(s.scrollback_line(2)) == '5'
}

fn test_resize_keeps_the_cursor_row() {
	mut s := new_screen(4, 4)
	feed(mut s, 'a\r\nb\r\nc\r\nd')
	s.resize(2, 2)
	assert s.line(0) == 'c' && s.line(1) == 'd'
	assert s.cy == 1
	assert s.scrollback_len() == 2
}
