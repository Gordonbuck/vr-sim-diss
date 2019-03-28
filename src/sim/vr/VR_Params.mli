type replica_timeout = VR_State.replica_timeout
type client_timeout = VR_State.client_timeout
type termination_type = Timelimit of float | WorkCompletion
type trace_level = VR_State.trace_level

val n_replicas: int
val n_clients: int
val n_iterations: int
val workloads: int list
val drop_packet: unit -> bool
val duplicate_packet: unit -> bool
val packet_delay: unit -> float
val time_for_replica_timeout: replica_timeout -> float
val time_for_client_timeout: client_timeout -> float
val fail_replica: unit -> float option
val fail_client: unit -> float option
val termination: termination_type
val trace_level: trace_level