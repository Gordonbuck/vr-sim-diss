open Core

module GilbertElliottModel = struct 

  type state = Good | Bad

  type t = {p: float; q : float; state: state}    

  let init p q = assert(p +. q = 1.); {p = p; q = q; state = Good}

  let tick model = 
    let r = Random.float 1. in
    match model.state with
    | Good -> 
      if r < model.p then (model.state, model)
      else 
        let model = {model with state = Bad;} in
        (model.state , model)
    | Bad ->
      if r < model.q then (model.state, model)
      else 
        let model = {model with state = Good;} in
        (model.state , model)

end

let sample_uniform a b = 
  let x = Random.float 1. in
  a +. (x *. (b -. a))

let sample_stdnormal_boxmuller () = 
  let u1 = Random.float 1. in
  let u2 = Random.float 1. in
  let z0 = (sqrt ((-. 2.) *. (log u1))) *. (Float.cos (2. *. Float.pi *. u2)) in
  let _ = (sqrt ((-. 2.) *. (log u1))) *. (Float.sin (2. *. Float.pi *. u2)) in
  z0

let sample_normal_boxmuller mu stdv = 
  let x = sample_stdnormal_boxmuller () in
  stdv *. x +. mu

let sample_truncatednormal_boxmuller mu stdv lower = 
  let rec repeat () = 
    let x = sample_normal_boxmuller mu stdv in
    if x >= lower then x else repeat () in
  repeat ()

include VR_State
type termination_type = Timelimit of float | WorkCompletion

let n_replicas = 11

let n_clients = 3

let max_replica_failures = 5

let max_client_failures = 1

let n_iterations = 1

let workloads = [10; 15; 20]

let drop_packet () = 
  let i = Random.int 100 in
  if i < 20 then true else false

let duplicate_packet () = 
  let i = Random.int 100 in
  if i < 20 then true else false

let packet_delay () = sample_truncatednormal_boxmuller 10. 5. 5. 

let time_for_replica_timeout timeout = 
  match timeout with
  | HeartbeatTimeout(_, _) -> 20.
  | PrepareTimeout(_, _) -> 30.
  | PrimaryTimeout(_, _) -> 60.
  | StateTransferTimeout(_, _) -> 50.
  | StartViewChangeTimeout(_) -> 30.
  | DoViewChangeTimeout(_) -> 30.
  | RecoveryTimeout(_) -> 30.
  | GetStateTimeout(_, _) -> 30.

let time_for_client_timeout timeout = 
  match timeout with
  | RequestTimeout(_) -> 40.
  | ClientRecoveryTimeout(_) -> 30.

let clock_skew () = 0.

let fail_replica () = 
  let i = Random.int 1000 in
  if i < 1 then Some(sample_truncatednormal_boxmuller 50. 400. 50.) else None

let fail_client () = 
  let i = Random.int 1000 in
  if i < 1 then Some(sample_truncatednormal_boxmuller 50. 400. 50.) else None

let termination = WorkCompletion

let trace_level = High

let show_trace = true
