class_name PlanHash
## The one checksum put shared by CityPlan, SectionPlan and MissionPlan: values go into the hashed buffer as int32
## millimetres (round(v * 1000)), immune to float formatting. Changing a byte here changes every plan checksum.


static func put(buf: StreamPeerBuffer, values: Array) -> void:
	for v: Variant in values:
		buf.put_32(int(round(float(v) * 1000.0)))     # millimetres: immune to float formatting


static func put_rect(buf: StreamPeerBuffer, r: Rect2) -> void:
	put(buf, [r.position.x, r.position.y, r.size.x, r.size.y])
