class_name Heat
extends RefCounted
## A heat gauge (decisions.md: "Overheat → hard shutdown → cooldown → reboot"; weapons.md §2, §4.6): the shooter's (a
## mech's) and a target's. Heat comes in from shots fired (`add`), passive heat from carried weapons and the flamer
## (CombatTarget.apply_heat); `tick` sheds `cooling` heat/s. Reaching `cap` shuts down: nothing fires or moves until
## the gauge has cooled to REBOOT_AT × cap, then it reboots. OWNER state of whoever carries it.

const REBOOT_AT := 0.4    ## share of the cap the gauge must cool to before a shut-down machine reboots (first pass)

signal overheated
signal rebooted

var cap := 100.0
var cooling := 6.0        ## heat/s shed
var passive := 0.0        ## heat/s added while carried (mounted weapons)
var value := 0.0
var shutdown := false


func _init(cap_: float = 100.0, cooling_: float = 6.0, passive_: float = 0.0) -> void:
	cap = cap_
	cooling = cooling_
	passive = passive_


func net_fields() -> Dictionary:
	return {"cap": Net.SPAWN, "cooling": Net.SPAWN, "passive": Net.OWNER, "value": Net.OWNER, "shutdown": Net.OWNER}


func add(amount: float) -> void:
	value = clampf(value + amount, 0.0, cap)
	_check()


func tick(dt: float) -> void:
	value = clampf(value + (passive - cooling) * dt, 0.0, cap)
	_check()


func fraction() -> float:
	return value / cap if cap > 0.0 else 0.0


## False while shut down.
func can_act() -> bool:
	return not shutdown


func reset() -> void:
	value = 0.0
	shutdown = false


func _check() -> void:
	if not shutdown and value >= cap:
		shutdown = true
		overheated.emit()
	elif shutdown and value <= cap * REBOOT_AT:
		shutdown = false
		rebooted.emit()
