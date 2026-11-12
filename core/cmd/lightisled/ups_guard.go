//go:build darwin && arm64

package main

import (
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/system"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

type upsGuardState struct {
	lastOnBattery  bool
	lastLowBattery bool
}

func (g *upsGuardState) evaluate(
	pwr system.PowerStatus,
	rootServer *server.RootServer,
	accounts *auth.Store,
	journal *tasks.Journal,
	desired map[string]bool,
) {
	if !pwr.Available {
		return
	}
	desired["ups_on_battery"] = pwr.OnBattery
	desired["ups_low_battery"] = pwr.LowBattery

	transitionedToBattery := pwr.OnBattery && !g.lastOnBattery
	transitionedToLow := pwr.LowBattery && !g.lastLowBattery
	recoveredToAC := !pwr.OnBattery && g.lastOnBattery

	if (transitionedToBattery || transitionedToLow || recoveredToAC) && rootServer != nil {
		rootServer.ApplyPowerProtection(pwr.OnBattery, pwr.LowBattery)
	}
	if transitionedToBattery || transitionedToLow {
		if accounts != nil {
			accounts.CheckpointPassive()
		}
		if journal != nil {
			journal.CheckpointPassive()
		}
	}
	g.lastOnBattery = pwr.OnBattery
	g.lastLowBattery = pwr.LowBattery
}
