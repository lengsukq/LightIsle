package server

import "errors"

// EvictRootRuntime cancels any background scans or transcodes for a removed
// root ID and closes its cached runtime services when idle so its SQLite files
// in dataDir release file descriptors and WAL locks immediately.
func (s *RootServer) EvictRootRuntime(id string) error {
	if s == nil || id == "" {
		return nil
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	if timer, ok := s.mediaRefreshTimers[id]; ok {
		timer.Stop()
		delete(s.mediaRefreshTimers, id)
	}
	delete(s.mediaRefreshScopes, id)
	rt := s.runtimes[id]
	if rt == nil {
		s.mu.Unlock()
		return nil
	}
	delete(s.runtimes, id)
	canCloseNow := rt.users == 0
	var pending chan struct{}
	if canCloseNow {
		pending = make(chan struct{})
		s.initializing[id] = pending
	}
	s.mu.Unlock()

	if rt.services != nil {
		if rt.services.Backup != nil {
			rt.services.Backup.Cancel()
		}
		if rt.services.Gallery != nil {
			rt.services.Gallery.CancelScan()
		}
		if rt.services.Cinema != nil {
			rt.services.Cinema.CancelScan()
		}
	}
	if !canCloseNow {
		return errors.New("root_runtime_in_use")
	}
	err := closeRootServices(rt.services)
	rt.scanWG.Wait()
	s.mu.Lock()
	delete(s.initializing, id)
	close(pending)
	s.mu.Unlock()
	return err
}
