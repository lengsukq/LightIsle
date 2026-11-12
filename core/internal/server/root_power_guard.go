package server

// SetTailscaleURLProvider wires the active Tailscale listener state from the
// daemon's Remote controller into GET /api/v2/admin/tailscale.
func (s *RootServer) SetTailscaleURLProvider(fn func() (string, bool)) {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.tailscaleBoundURL = fn
	if s.baseAPI != nil {
		s.baseAPI.tailscaleBoundURL = fn
	}
	if s.rootAPI != nil {
		s.rootAPI.tailscaleBoundURL = fn
	}
	s.mu.Unlock()
}

// ApplyPowerProtection coordinates background workload throttling across open
// root runtimes when the host switches to UPS/battery power or returns to AC.
func (s *RootServer) ApplyPowerProtection(onBattery, lowBattery bool) {
	if s == nil {
		return
	}
	s.mu.Lock()
	wasAutoPaused := s.upsAutoPausedAI
	runtimes := make([]*rootRuntime, 0, len(s.runtimes))
	for _, rt := range s.runtimes {
		runtimes = append(runtimes, rt)
	}
	if onBattery {
		s.upsAutoPausedAI = true
	} else {
		s.upsAutoPausedAI = false
	}
	s.mu.Unlock()

	for _, rt := range runtimes {
		if rt == nil || rt.services == nil {
			continue
		}
		if rt.services.Gallery != nil {
			if onBattery && !rt.services.Gallery.AIPaused() {
				rt.services.Gallery.SetAIPaused(true)
			} else if !onBattery && wasAutoPaused {
				rt.services.Gallery.SetAIPaused(false)
			}
		}
		if lowBattery && rt.services.Cinema != nil {
			rt.services.Cinema.StopAllTranscodes()
		}
	}
}
