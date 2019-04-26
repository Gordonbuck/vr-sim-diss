open Core
open VR_State

module GilbertElliottModel = struct 

  type state = Good | Bad

  type t = {p : float; r : float; k : float; h : float; state: state}    

  let init p r k h = {p = p; r = r; k = k; h = h; state = Good}

  let tick model = 
    let f = Random.float 1. in
    match model.state with
    | Good -> 
      if f > model.p then ((Random.float 1.) > model.k, model)
      else 
        let model = {model with state = Bad;} in
        ((Random.float 1.) > model.h , model)
    | Bad ->
      if f > model.r then ((Random.float 1.) > model.h, model)
      else 
        let model = {model with state = Good;} in
        ((Random.float 1.) > model.k, model)

end

let sample_uniform a b = 
  let x = Random.float 1. in
  a +. (x *. (b -. a))

let sample_stdnormal_boxmuller () = 
  let u1 = Random.float 1. in
  let u2 = Random.float 1. in
  let z0 = (Pervasives.sqrt ((-. 2.) *. (Pervasives.log u1))) *. (Float.cos (2. *. Float.pi *. u2)) in
  let _ = (Pervasives.sqrt ((-. 2.) *. (Pervasives.log u1))) *. (Float.sin (2. *. Float.pi *. u2)) in
  z0

let sample_normal_boxmuller mu stdv = 
  let x = sample_stdnormal_boxmuller () in
  stdv *. x +. mu

let sample_truncatednormal_boxmuller mu stdv lower = 
  let rec repeat () = 
    let x = sample_normal_boxmuller mu stdv in
    if x >= lower then x else repeat () in
  repeat ()

type continuous_distribution = 
  | Constant of float
  | Uniform of float * float
  | Normal of float * float
  | TruncatedNormal of float * float * float

type discrete_distribution = 
  | Bernoulli of float
  | GilbertElliott of float * float * float * float

type termination_type = Timelimit of float | WorkCompletion

type trace_level = VR_State.trace_level

type config = {
  n_replicas : int;
  n_clients : int;
  max_replica_failures : int;
  max_client_failures : int;
  n_iterations : int;
  workloads : int list;
  packet_loss : discrete_distribution;
  packet_duplication : discrete_distribution;
  packet_delay : continuous_distribution;
  heartbeat_timeout : float;
  prepare_timeout : float;
  primary_timeout : float;
  statetransfer_timeout : float;
  startviewchange_timeout : float;
  doviewchange_timeout : float;
  recovery_timeout : float;
  getstate_timeout : float;
  request_timeout : float;
  clientrecovery_timeout : float;
  clock_skew : continuous_distribution;
  replica_failure : discrete_distribution * continuous_distribution;
  client_failure : discrete_distribution * continuous_distribution;
  termination : termination_type;
  trace_level : trace_level;
  show_trace : bool;
}

let func_of_cont_dist dist = 
  match dist with
  | Constant(c) -> (fun () -> c)
  | Uniform(l,h) -> (fun () -> sample_uniform l h)
  | Normal(mu,stdv) -> (fun () -> sample_normal_boxmuller mu stdv)
  | TruncatedNormal(mu, stdv, lower) -> (fun () -> sample_truncatednormal_boxmuller mu stdv lower)

let func_of_disc_dist dist = 
  match dist with
  | Bernoulli(p) -> (fun () -> if (sample_uniform 0. 1. < p) then true else false)
  | GilbertElliott(p, r, k, h) -> 
    let model = ref (GilbertElliottModel.init p r k h) in
    fun () ->
      let (b, m) = GilbertElliottModel.tick (!model) in
      (model := m); b

module type Params = sig 
  type replica_timeout = VR_State.replica_timeout
  type client_timeout = VR_State.client_timeout
  type termination_type = Timelimit of float | WorkCompletion
  type trace_level = VR_State.trace_level
  val n_replicas: int
  val n_clients: int
  val max_replica_failures: int
  val max_client_failures: int
  val n_iterations: int
  val workloads: int list
  val drop_packet: unit -> bool
  val duplicate_packet: unit -> bool
  val packet_delay: unit -> float
  val time_for_replica_timeout: replica_timeout -> float
  val time_for_client_timeout: client_timeout -> float
  val clock_skew: unit -> float
  val fail_replica: unit -> float option
  val fail_client: unit -> float option
  val termination: termination_type
  val trace_level: trace_level
  val show_trace: bool
end

let build_params (conf : config) = (module struct 
  include VR_State
  type termination_type = Timelimit of float | WorkCompletion

  let n_replicas = conf.n_replicas
  let n_clients = conf.n_clients
  let max_replica_failures = conf.max_replica_failures
  let max_client_failures = conf.max_client_failures
  let n_iterations = conf.n_iterations
  let workloads = if (List.length conf.workloads) <> conf.n_clients then assert(false) else conf.workloads
  let drop_packet = func_of_disc_dist conf.packet_loss
  let duplicate_packet = func_of_disc_dist conf.packet_duplication
  let packet_delay = func_of_cont_dist conf.packet_delay

  let time_for_replica_timeout timeout = 
    match timeout with
    | HeartbeatTimeout(_, _) -> conf.heartbeat_timeout
    | PrepareTimeout(_, _) -> conf.prepare_timeout
    | PrimaryTimeout(_, _) -> conf.primary_timeout
    | StateTransferTimeout(_, _) -> conf.statetransfer_timeout
    | StartViewChangeTimeout(_) -> conf.startviewchange_timeout
    | DoViewChangeTimeout(_) -> conf.doviewchange_timeout
    | RecoveryTimeout(_) -> conf.recovery_timeout
    | GetStateTimeout(_, _) -> conf.getstate_timeout

  let time_for_client_timeout timeout = 
    match timeout with
    | RequestTimeout(_) -> conf.request_timeout
    | ClientRecoveryTimeout(_) -> conf.clientrecovery_timeout

  let clock_skew = func_of_cont_dist conf.clock_skew

  let fail_replica () = 
    let (disc, cont) = conf.replica_failure in
    if (func_of_disc_dist disc) () then Some((func_of_cont_dist cont) ()) else None

  let fail_client () = 
    let (disc, cont) = conf.client_failure in
    if (func_of_disc_dist disc) () then Some((func_of_cont_dist cont) ()) else None

  let termination = 
    match conf.termination with
    | Timelimit(f) -> Timelimit(f)
    | WorkCompletion -> WorkCompletion

  let trace_level = conf.trace_level
  let show_trace = conf.show_trace

end : Params)
