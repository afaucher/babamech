extends SceneTree
## Export all procedural SoundBank cues as .wav files to test_logs/audio/ for offline listening, or pass `--bake`
## to save native .res AudioStreamWAV resources into res://assets/audio/.
##   .\tools\audio\gen_audio.ps1            (writes test_logs/audio/*.wav)
##   .\tools\audio\gen_audio.ps1 -Bake      (writes assets/audio/*.res)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var bake := args.has("--bake")
	var out_dir := SoundBank.BAKED_DIR if bake else ProjectSettings.globalize_path("res://test_logs/audio/")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ids := SoundBank.all_ids()
	var total_sec := 0.0
	var failures := 0
	for cid: String in ids:
		var wav := SoundBank.synthesize(cid)
		var st := AudioSynth.analyze(wav)
		total_sec += float(st["duration"])
		var err := OK
		var fname := cid.replace(".", "_") + (".res" if bake else ".wav")
		var full := out_dir.path_join(fname)
		if bake:
			err = ResourceSaver.save(wav, full)
		else:
			err = wav.save_to_wav(full)
		if err != OK or bool(st["has_nan"]):
			failures += 1
		print("%-26s %5.2fs  rms %.3f  peak %.3f  dc %+.4f  %s %.4f  low %2d%%  zcr %4.0fHz  #%s  %s" % [
			cid, float(st["duration"]), float(st["rms"]), float(st["peak"]), float(st["mean"]),
			"seam" if wav.loop_mode == AudioStreamWAV.LOOP_FORWARD else "tail",
			float(st["seam_delta"]) if wav.loop_mode == AudioStreamWAV.LOOP_FORWARD else float(st["tail_rms"]),
			int(round(float(st["low_ratio"]) * 100.0)), float(st["zcr_hz"]), str(st["hash"]),
			"OK" if err == OK else "ERR %d" % err])
	print("%d cues (%.1fs audio) -> %s%s" % [ids.size(), total_sec, out_dir,
		"" if failures == 0 else "  [%d ERRORS]" % failures])
	quit(0 if failures == 0 else 1)
