extends "res://tests/net_load_stall_case.gd"
## A crew client stalls past the (shortened) load timeout: sent out with LOAD_SLOW, and both sides say why.
## Scenario: net_load_stall_case.gd.

const PEERS := 2


func _init() -> void:
	slow = true
