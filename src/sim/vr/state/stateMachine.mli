module type StateMachine_type = sig
  type operation
  type result
  type t
  val create: unit -> t
  val apply_op: t -> operation -> t
  val last_res: t -> result
  val gen_ops: int -> operation list
  val is_read: operation -> bool
end

module KeyValueStore : StateMachine_type
