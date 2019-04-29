module type Protocol_type = sig

  type replica_state
  type client_state
  type replica_message
  type client_message
  type replica_timeout
  type client_timeout
  type message = ReplicaMessage of replica_message | ClientMessage of client_message
  type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
  type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
  type protocol_event = Communication of communication | Timeout of timeout

  type trace
  type trace_level

  val on_replica_message: replica_message -> replica_state -> replica_state * protocol_event list * trace
  val on_replica_timeout: replica_timeout -> replica_state -> replica_state * protocol_event list * trace
  val init_replicas: int -> int -> replica_state list
  val crash_replica: replica_state -> replica_state
  val start_replica: replica_state -> replica_state * protocol_event list * trace
  val recover_replica: replica_state -> replica_state * protocol_event list * trace
  val index_of_replica: replica_state -> int
  val check_consistency: replica_state list -> bool
  val replica_is_recovering: replica_state -> bool
  val replica_set_time: replica_state -> float -> replica_state

  val on_client_message: client_message -> client_state -> client_state * protocol_event list * trace
  val on_client_timeout: client_timeout -> client_state -> client_state * protocol_event list * trace
  val init_clients: int -> int -> client_state list
  val crash_client: client_state -> client_state
  val start_client: client_state -> client_state * protocol_event list * trace
  val recover_client: client_state -> client_state * protocol_event list * trace
  val index_of_client: client_state -> int
  val gen_workload: client_state -> int -> client_state
  val finished_workloads: client_state list -> bool
  val client_is_recovering: client_state -> bool 
  val client_set_time: client_state -> float -> client_state

  val string_of_trace: trace -> trace_level -> string

end

module type Parameters_type = sig 

  type replica_timeout
  type client_timeout
  type termination_type = Timelimit of float | WorkCompletion
  type trace_level

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
  val replica_failure_period: float
  val fail_replica: unit -> (float * float) option
  val client_failure_period: float
  val fail_client: unit -> (float * float) option
  val termination: termination_type
  val trace_level: trace_level
  val show_trace: bool

end

module Simulator (P : Protocol_type) 
    (Params : Parameters_type 
     with type replica_timeout = P.replica_timeout 
     with type client_timeout = P.client_timeout
     with type trace_level = P.trace_level): sig

  val run: unit -> unit

end
