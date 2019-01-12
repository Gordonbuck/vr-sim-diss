open Core

module type StateMachine_type = sig
  type operation
  type result
  type t
  val create: unit -> t
  val apply_op: t -> operation -> t
  val last_res: t -> result
  val gen_ops: int -> operation list
end

module KeyValueStore : StateMachine_type = struct

  type operation =
    | Put of string * string
    | Get of string

  type result = string option

  type t = {
    hash_tbl : (string, string) Hashtbl.t;
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

  let gen_string () =
    let length = Random.int 16 in
    let gen() = match Random.int(26+26+10) with
        n when n < 26 -> int_of_char 'a' + n
      | n when n < 26 + 26 -> int_of_char 'A' + n - 26
      | n -> int_of_char '0' + n - 26 - 26 in
    let gen _ = String.make 1 (char_of_int(gen())) in
    String.concat (Array.to_list (Array.init length gen))

  let gen_ops n =
    let rec gen i l = 
      if i < 0 then
        l
      else
        let r = Random.int 2 in
        if r = 0 then
          let key = gen_string () in
          gen (i - 1) (Get(key)::l)
        else
          let key = gen_string () in
          let value = gen_string () in
          gen (i - 1) (Put(key, value)::l) in
    gen (n - 1) []
    
end
