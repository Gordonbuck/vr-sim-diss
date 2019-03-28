type replica_state
type client_state
type replica_message
type client_message
type replica_timeout = VR_State.replica_timeout
type client_timeout = VR_State.client_timeout
type message = ReplicaMessage of replica_message | ClientMessage of client_message
type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
type protocol_event = Communication of communication | Timeout of timeout

type trace
type trace_level = VR_State.trace_level

val on_replica_message: replica_message -> replica_state -> replica_state * protocol_event list * trace
val on_replica_timeout: replica_timeout -> replica_state -> replica_state * protocol_event list * trace
val init_replicas: int -> int -> replica_state list
val crash_replica: replica_state -> replica_state
val start_replica: replica_state -> replica_state * protocol_event list * trace
val recover_replica: replica_state -> replica_state * protocol_event list * trace
val index_of_replica: replica_state -> int
val check_consistency: replica_state list -> bool

val on_client_message: client_message -> client_state -> client_state * protocol_event list * trace
val on_client_timeout: client_timeout -> client_state -> client_state * protocol_event list * trace
val init_clients: int -> int -> client_state list
val crash_client: client_state -> client_state
val start_client: client_state -> client_state * protocol_event list * trace
val recover_client: client_state -> client_state * protocol_event list * trace
val index_of_client: client_state -> int
val gen_workload: client_state -> int -> client_state
val finished_workloads: client_state list -> bool

val string_of_trace: trace -> trace_level -> string