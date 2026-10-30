module main

import db.sqlite
import sync

const now_sql = "CAST(strftime('%s', 'now') AS INTEGER)"

const schema = [
	"CREATE TABLE IF NOT EXISTS panes (
		id          TEXT PRIMARY KEY,
		title       TEXT NOT NULL DEFAULT '',
		cwd         TEXT NOT NULL DEFAULT '',
		startup_cmd TEXT NOT NULL DEFAULT '',
		autorun     INTEGER NOT NULL DEFAULT 0,
		shell       TEXT NOT NULL DEFAULT '',
		claude      TEXT NOT NULL DEFAULT '',
		slot        INTEGER NOT NULL DEFAULT 0,
		buffer      TEXT NOT NULL DEFAULT '',
		updated_at  INTEGER NOT NULL DEFAULT 0
	)",
	'CREATE TABLE IF NOT EXISTS layout_config (
		name  TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)',
]

@[heap]
struct Storage {
mut:
	db sqlite.DB
	mu &sync.Mutex = sync.new_mutex()
}

struct PaneRow {
	id          string
	title       string
	cwd         string
	startup_cmd string
	autorun     bool
	shell       string
	claude      string // Claude Code session running in the pane, resumed after a restart
	slot        int
	buffer      string
mut:
	running bool
}

fn new_storage(path string) !&Storage {
	mut s := &Storage{
		db: sqlite.connect(path)!
	}
	// WAL + NORMAL: every commit survives a process crash; a power cut can drop only the
	// last few commits and never corrupts the file. No fsync per keystroke.
	s.query('PRAGMA journal_mode=WAL')!
	s.query('PRAGMA synchronous=NORMAL')!
	s.query('PRAGMA busy_timeout=5000')!
	for q in schema {
		s.query(q)!
	}
	// Databases from older versions; each fails harmlessly once its column exists.
	s.query("ALTER TABLE panes ADD COLUMN shell TEXT NOT NULL DEFAULT ''") or {}
	s.query("ALTER TABLE panes ADD COLUMN claude TEXT NOT NULL DEFAULT ''") or {}
	return s
}

// query is the only path to the connection; the mutex makes it safe from any thread.
fn (mut s Storage) query(q string, params ...string) ![]sqlite.Row {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	return s.db.exec_param_many(q, params)!
}

fn (mut s Storage) load_panes() ![]PaneRow {
	rows := s.query('SELECT id, title, cwd, startup_cmd, autorun, shell, claude, slot, buffer FROM panes ORDER BY slot, rowid')!
	return rows.map(PaneRow{
		id:          it.vals[0]
		title:       it.vals[1]
		cwd:         it.vals[2]
		startup_cmd: it.vals[3]
		autorun:     it.vals[4] == '1'
		shell:       it.vals[5]
		claude:      it.vals[6]
		slot:        it.vals[7].int()
		buffer:      it.vals[8]
	})
}

// pane_launch returns what a pane's shell starts with: its last cwd and its shell.
fn (mut s Storage) pane_launch(id string) (string, string) {
	rows := s.query('SELECT cwd, shell FROM panes WHERE id = ?', id) or { return '', '' }
	if rows.len == 0 {
		return '', ''
	}
	return rows[0].vals[0], rows[0].vals[1]
}

fn (mut s Storage) save_meta(id string, title string, startup_cmd string, autorun bool, shell string, slot int) ! {
	s.query('INSERT INTO panes (id, title, startup_cmd, autorun, shell, slot, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ${now_sql})
		ON CONFLICT(id) DO UPDATE SET title = excluded.title, startup_cmd = excluded.startup_cmd,
			autorun = excluded.autorun, shell = excluded.shell, slot = excluded.slot,
			updated_at = excluded.updated_at',
		id, title, startup_cmd, if autorun { '1' } else { '0' }, shell, slot.str())!
}

// save_cwd and save_buffer only UPDATE: a late message for a pane that was just closed
// must not bring its row back. pane_meta is what creates rows.
fn (mut s Storage) save_cwd(id string, cwd string) ! {
	s.query('UPDATE panes SET cwd = ?, updated_at = ${now_sql} WHERE id = ?', cwd, id)!
}

// save_claude records (or, with '', clears) the Claude Code session running in a pane.
fn (mut s Storage) save_claude(id string, session string) ! {
	s.query('UPDATE panes SET claude = ?, updated_at = ${now_sql} WHERE id = ?', session, id)!
}

fn (mut s Storage) save_buffer(id string, buffer string) ! {
	s.query('UPDATE panes SET buffer = ?, updated_at = ${now_sql} WHERE id = ?', buffer, id)!
}

fn (mut s Storage) delete_pane(id string) ! {
	s.query('DELETE FROM panes WHERE id = ?', id)!
}

fn (mut s Storage) get_config(name string) string {
	rows := s.query('SELECT value FROM layout_config WHERE name = ?', name) or { return '' }
	return if rows.len > 0 { rows[0].vals[0] } else { '' }
}

fn (mut s Storage) set_config(name string, value string) ! {
	s.query('INSERT INTO layout_config (name, value) VALUES (?, ?)
		ON CONFLICT(name) DO UPDATE SET value = excluded.value', name, value)!
}

// begin_session marks this run as in progress and reports whether the previous run
// ended without reaching end_session (crash, power loss, killed process).
fn (mut s Storage) begin_session() !bool {
	clean := s.get_config('clean_exit') == '1'
	s.set_config('clean_exit', '0')!
	return !clean
}

fn (mut s Storage) end_session() ! {
	s.set_config('clean_exit', '1')!
}
