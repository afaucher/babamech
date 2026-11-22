extends "res://tests/net_mission_case.gd"
## The net_mission_case.gd scenario with a desync: client 2 of 3 perturbs its city checksum (NetMission.checksum_salt). The host finds it
## at the load barrier, notes it (print + telemetry) and sends that client out with NetSession.DESYNC; the other two go
## on and start together. The sent-out client trying to come back mid-mission is refused with ON_MISSION.

const PEERS := 3


func _configure() -> void:
	crew_size = peers
	desync_index = 2
