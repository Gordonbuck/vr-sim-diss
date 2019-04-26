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

val build_params: config -> (module Params)
