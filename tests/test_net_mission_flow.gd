extends "res://tests/net_mission_flow_case.gd"
## The mission's win over a crew of 2 (host + 1 client), once per link: gated evaluation, mission.state on the client,
## extraction by the client's mech, banner and mission.end everywhere. Scenario: net_mission_flow_case.gd.

const PEERS := 2
