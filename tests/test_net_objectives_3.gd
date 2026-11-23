extends "res://tests/net_objectives_case.gd"
## Mission objectives phase 1 over a crew of 3 (host + 2 clients), once per link: the same scenario as
## test_net_objectives (net_objectives_case.gd); the last client raises the flag, the other only sees it.

const PEERS := 3
