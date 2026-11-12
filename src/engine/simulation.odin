package engine

// Simulation drives a host with an explicit clock. Time only moves when the
// test advances it and schedules run in id order, so a script produces the same
// state every run. It is the base for deterministic simulation testing: the
// clock, the commit sequence and the scheduler are all under the caller's
// control.
Simulation :: struct {
	host:   ^Host,
	now_us: i64,
	ran:    int,
}

simulation_init :: proc(host: ^Host, start_us: i64) -> Simulation {
	host.now_us = start_us
	return Simulation{host = host, now_us = start_us}
}

simulation_now :: proc(sim: ^Simulation) -> i64 {
	return sim.now_us
}

// simulation_advance moves the clock forward and runs the schedules that
// become due, returning how many ran.
simulation_advance :: proc(sim: ^Simulation, delta_us: i64) -> (int, Error) {
	if delta_us < 0 do return 0, errf(.Invalid_Argument, "simulation time cannot move backwards")
	sim.now_us += delta_us
	sim.host.now_us = sim.now_us
	ran, tick_err := host_tick(sim.host, sim.now_us)
	sim.ran += ran
	return ran, tick_err
}

// simulation_run_until advances in fixed steps until `end_us`.
simulation_run_until :: proc(sim: ^Simulation, end_us: i64, step_us: i64) -> (int, Error) {
	if step_us <= 0 do return 0, errf(.Invalid_Argument, "the step must be positive")
	total := 0
	for sim.now_us < end_us {
		remaining := end_us - sim.now_us
		delta := remaining < step_us ? remaining : step_us
		ran, step_err := simulation_advance(sim, delta)
		total += ran
		if step_err.kind != .None do return total, step_err
	}
	return total, ERROR_NONE
}
