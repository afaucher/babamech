extends "res://tests/test_auto_land.gd"
## test_auto_land's whole sweep (drop heights 5..300 m x 30 / 60 / 120 Hz x flat, run, ramp, roof edge, ledge, hot; then
## shut down and heat cap mid-burn) for the Bulwark: its weaker thrust (30 - gravity 22 = 8 m/s^2 of braking, the
## Strider's 12) and its wider capsule (r 3.6: the landing probe is its bottom). Every automatic-burn touchdown under the
## 20 m/s fall-damage speed with headroom (<= 18), no fall damage. The Strider's old-burn comparison does not apply.


func chassis_under_test() -> String:
	return "bulwark"
