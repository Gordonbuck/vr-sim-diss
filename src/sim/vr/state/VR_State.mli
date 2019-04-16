module StateMachine : StateMachine.StateMachine_type

type index
type status =
  | Normal
  | ViewChange
  | Recovering

type replica_state
type replica_message =
  | Request of StateMachine.operation * index * index
  | Prepare of index * (StateMachine.operation * index * index) * index * index
  | PrepareOk of index * index * index
  | Commit of index * index
  | StartViewChange of index * index
  | DoViewChange of index * (StateMachine.operation * index * index) list * index * index * index * index
  | StartView of index * (StateMachine.operation * index * index) list * index * index
  | Recovery of index * int
  | RecoveryResponse of index * int * ((StateMachine.operation * index * index) list * index * index) option * index
  | ClientRecovery of index
  | GetState of index * index * index
  | NewState of index * (StateMachine.operation * index * index) list * index * index
type replica_timeout = 
  | HeartbeatTimeout of int * index
  | PrepareTimeout of int * index
  | PrimaryTimeout of int * int
  | StateTransferTimeout of int * index
  | StartViewChangeTimeout of int
  | DoViewChangeTimeout of int
  | RecoveryTimeout of int
  | GetStateTimeout of int * index

type client_state
type client_message =
  | Reply of index * index * StateMachine.result
  | ClientRecoveryResponse of index * index * index
type client_timeout = 
  | RequestTimeout of int
  | ClientRecoveryTimeout of int

type message = ReplicaMessage of replica_message | ClientMessage of client_message
type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
type protocol_event = Communication of communication | Timeout of timeout

type trace_level = High | Medium | Low
type trace = 
  | ReplicaTrace of int * int * replica_state * string * string 
  | ClientTrace of int * int * client_state * string * string
  | Null

val reset_monitor: replica_state -> replica_state
val update_monitor: replica_state -> VR_Safety_Monitor.s -> replica_state
val statecalls: replica_state -> VR_Safety_Monitor.s list

val index_of_int: int -> index
val int_of_index: index -> int

val init_clients: int -> int -> client_state list
val crash_client: client_state -> client_state
val index_of_client: client_state -> int

val init_replicas: int -> int -> replica_state list
val crash_replica: replica_state -> replica_state
val index_of_replica: replica_state -> int

val n_replicas: replica_state -> int
val client_n_replicas: client_state -> int

val gen_workload: client_state -> int -> client_state
val finished_workload: client_state -> bool

val received_clientrecoveryresponse: client_state -> index -> bool
val log_clientrecoveryresponse: client_state -> index -> index -> index -> client_state
val client_set_recovering: client_state -> bool -> client_state

val next_operation: client_state -> (client_state * StateMachine.operation option)
val previous_operation: client_state -> (client_state * StateMachine.operation)

val client_set_view_no: client_state -> index -> client_state
val client_primary_no: client_state -> index
val client_id: client_state -> index
val client_request_no: client_state -> index

val client_valid_timeout: client_state -> int
val client_recovering: client_state -> bool

val client_quorum: client_state -> int
val client_no_received_clientrecoveryresponses: client_state -> int

val waiting_on_clientrecoveryresponses: client_state -> index list

val get_request: replica_state -> index -> (StateMachine.operation * index * index)

val waiting_on_prepareoks: replica_state -> index -> index list
val waiting_on_startviewchanges: replica_state -> index list
val waiting_on_recoveryresponses: replica_state -> index list

val is_primary: replica_state -> bool
val primary_no: replica_state -> index
val view_no: replica_state -> index
val replica_no: replica_state -> index
val op_no: replica_state -> index
val commit_no: replica_state -> index
val status: replica_state -> status
val log: replica_state -> (StateMachine.operation * index * index) list
val client_table: replica_state -> (index * StateMachine.result option) list

val quorum: replica_state -> int
val commited_requests: replica_state -> (StateMachine.operation * int * int) list

val increment_view_no: replica_state -> replica_state
val set_status: replica_state -> status -> replica_state
val get_client_table_entry: replica_state -> index -> (index * StateMachine.result option)
val rollback_to_commit: replica_state -> replica_state
val log_suffix: replica_state -> index -> (StateMachine.operation * index * index) list
val append_log: replica_state -> (StateMachine.operation * index * index) list -> index -> replica_state
val last_normal_view_no: replica_state -> index

val valid_timeout: replica_state -> int
val no_primary_comms: replica_state -> int
val no_received_startviewchanges: replica_state -> int
val no_received_doviewchanges: replica_state -> int
val no_received_recoveryresponses: replica_state -> int
val current_recovery_nonce: replica_state -> int
val primary_recoveryresponse: replica_state -> (index * int * (StateMachine.operation * index * index) list * index * index * index) option

val get_casted_prepareok: replica_state -> index -> index

val received_startviewchange: replica_state -> index -> bool
val log_startviewchange: replica_state -> index -> replica_state
val received_doviewchange: replica_state -> index -> bool
val log_doviewchange: replica_state -> index -> (StateMachine.operation * index * index) list -> index -> index -> index -> index -> replica_state
val received_recoveryresponse: replica_state -> index -> bool
val log_recoveryresponse: replica_state -> index -> int -> ((StateMachine.operation * index * index) list * index * index) option -> index -> replica_state

val become_primary: replica_state -> replica_state
val become_replica: replica_state -> replica_state

val set_view_no: replica_state -> index -> replica_state
val set_op_no: replica_state -> index -> replica_state
val set_log: replica_state -> (StateMachine.operation * index * index) list -> replica_state

val increment_primary_comms: replica_state -> replica_state
val update_client_table: ?res:StateMachine.result option -> replica_state -> index -> index -> replica_state
val update_client_table_requests: replica_state -> (StateMachine.operation * index * index) list -> replica_state

val process_doviewchanges: replica_state -> (replica_state * index)

val log_request: replica_state -> StateMachine.operation -> index -> index -> replica_state
val queue_prepare: replica_state -> index -> (StateMachine.operation * index * index) -> replica_state
val process_queued_prepares: replica_state -> replica_state
val commit: replica_state -> index -> (replica_state * communication list)
val log_prepareok: replica_state -> index -> index -> replica_state
val process_waiting_prepareoks: replica_state -> (replica_state * index)
