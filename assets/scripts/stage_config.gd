# res://scripts/stage_config.gd
extends Node
class_name StageConfig

enum Stage { PROD, BETA }

const PROD_PORT := 8080
const BETA_PORT := 8090

# Match these to your Firebase projects (you can rename keys later)
const FIREBASE_PROD := {
	"env_name": "prod",
	"project_id": "jigsaw-59175",
	"users_collection": "sp_users",
	"servers_collection": "servers",
}

const FIREBASE_BETA := {
	"env_name": "beta",
	"project_id": "jigsaw-beta-879cc",
	"users_collection": "sp_users",
	"servers_collection": "sp_servers",
}

static func get_stage_from_cmdline(args: PackedStringArray) -> Stage:
	# default is prod when no stage flag is provided
	for a in args:
		var arg := str(a).strip_edges().to_lower()
		if arg == "--stage.beta" or arg == "--stage=beta":
			return Stage.BETA
		if arg == "--stage.prod" or arg == "--stage=prod":
			return Stage.PROD
	return Stage.PROD

static func get_port(stage: Stage) -> int:
	return BETA_PORT if stage == Stage.BETA else PROD_PORT

static func get_firebase_config(stage: Stage) -> Dictionary:
	return FIREBASE_BETA if stage == Stage.BETA else FIREBASE_PROD
