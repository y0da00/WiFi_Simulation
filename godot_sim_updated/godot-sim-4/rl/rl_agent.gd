extends CharacterBody3D

const SPEED = 4.0
const GRAVITY = 20.0

var requested_movement: Vector2 = Vector2.ZERO

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	velocity.x = requested_movement.x * SPEED
	velocity.z = requested_movement.y * SPEED
	move_and_slide()
