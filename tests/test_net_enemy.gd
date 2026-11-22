extends "res://tests/net_enemy_case.gd"
## Enemies in co-op over a crew of 2 (host + 1 client), once per link: the same enemies everywhere, puppets with no AI,
## pose tracking, a client's damage and kill shown everywhere, an enemy shot decided by its victim, telegraph lead.
## Scenario: net_enemy_case.gd.

const PEERS := 2
