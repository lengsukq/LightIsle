package cinema

import "time"

// ClearHistory deletes only the caller's own progress rows; other members'
// history is untouched.
func (l *Library) ClearHistory(userID int64) (int64, error) {
	if userID <= 0 {
		return 0, ErrInvalid
	}
	result, err := l.db.Exec("DELETE FROM watch_progress WHERE user_id=?", userID)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// MarkWatched flips the completed flag for one film. Marking watched keeps
// the stored position and duration; marking unwatched also resets the
// position so "continue watching" stops offering it.
func (l *Library) MarkWatched(userID, filmID int64, completed bool) error {
	if userID <= 0 {
		return ErrInvalid
	}
	current, err := l.Get(filmID, userID)
	if err != nil {
		return err
	}
	position, duration := 0.0, 0.0
	if completed {
		position, duration = current.Position, current.Duration
	}
	complete := 0
	if completed {
		complete = 1
	}
	_, err = l.db.Exec(`INSERT INTO watch_progress(user_id,film_id,position,duration,completed,updated_at)
	VALUES(?,?,?,?,?,?)
	ON CONFLICT(user_id,film_id) DO UPDATE SET position=excluded.position,
	duration=excluded.duration,completed=excluded.completed,updated_at=excluded.updated_at`,
		userID, filmID, position, duration, complete, time.Now().Unix())
	return err
}

// ReadStrmTarget opens and validates a .strm virtual stream file, returning its
// sanitized HTTP(S) target URL for client-direct or 307 redirect playback.
func (l *Library) ReadStrmTarget(id, userID int64) (string, Film, error) {
	f, _, film, err := l.Read(id, userID)
	if err != nil {
		return "", Film{}, err
	}
	defer f.Close()
	if !IsStrmPath(film.Path) {
		return "", Film{}, ErrInvalid
	}
	targetURL, err := ReadAndValidateStrmURL(f)
	if err != nil {
		return "", Film{}, err
	}
	return targetURL, film, nil
}

// StopAllTranscodes terminates active FFmpeg HLS sessions (used during UPS low
// battery protection without closing the cinema SQLite handles).
func (l *Library) StopAllTranscodes() {
	if l == nil || l.transcoder == nil {
		return
	}
	l.transcoder.Close()
}
