extends "res://tests/net_load_stall_case.gd"
## A crew client blocks its main thread 12 s in the mission load: it still lands in the mission, the crew stays at 2.
## Scenario: net_load_stall_case.gd.

const PEERS := 2
