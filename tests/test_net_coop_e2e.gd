extends "res://tests/net_coop_case.gd"
## W9: the end-to-end co-op scenario (launch, city, walk, fire, kill, prop, down + revive, end) over a crew of 2, once per
## link (off, coast). Steps whose co-op API is not built yet print `TODO W9 skip ...` and the run goes on. Scenario:
## net_coop_case.gd.

const PEERS := 2
