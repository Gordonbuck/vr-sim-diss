open Core

module type StateMachine_type = sig
  type operation
  type result
  type t
  val create: unit -> t
  val apply_op: t -> operation -> t
  val last_res: t -> result
end

module KeyValueStore : StateMachine_type = struct

  type operation =
    | Put of string * bytes
    | Get of string

  type result = bytes option

  type t = {
    hash_tbl : (string, bytes) Hashtbl.t;
    last_res : result;
  }

  let create () = { hash_tbl = Hashtbl.create ~growth_allowed:true ~size:256 (module String); last_res = None; }

  let apply_op mach op =
    match op with
    | Put(key, value) -> (
        Hashtbl.set mach.hash_tbl key value;
        { hash_tbl = mach.hash_tbl; last_res = Some(value); }
      )
    | Get(key) -> { hash_tbl = mach.hash_tbl; last_res = Hashtbl.find mach.hash_tbl key; }

  let last_res mach = mach.last_res

end
