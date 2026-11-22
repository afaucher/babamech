extends "res://tests/net_combat_case.gd"
## Combat across machines over a crew of 3: as test_net_combat, plus c2 watching (the host relays every record to it, it
## shows A's shots and the impact on B, and builds no hit on B's puppet). Scenario: net_combat_case.gd.

const PEERS := 3
