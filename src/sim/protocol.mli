module type Protocol_type = sig
  type replica_state
  type client_state
  type replica_message
  type client_message
  type replica_timeout
  type client_timeout
  type message = ReplicaMessage of replica_message | ClientMessage of client_message
  type communication = Unicast of message * int |  Broadcast of message | MultiComm of communication list
  val on_replica_message: replica_message -> replica_state -> replica_state * communication option * replica_timeout list
  val on_client_message: client_message -> client_state -> client_state * communication option * client_timeout list
  val on_replica_timeout: replica_timeout -> replica_state -> replica_state * communication option * replica_timeout list
  val on_client_timeout: client_timeout -> client_state -> client_state * communication option * client_timeout list
  val init_replicas: int -> int -> replica_state list
  val init_clients: int -> int -> client_state list
  val crash_replica: replica_state -> replica_state
  val crash_client: client_state -> client_state
  val recover_replica: replica_state -> replica_state * communication option * replica_timeout list
  val recover_client: client_state -> client_state * communication option * client_timeout list
  val start_replica: replica_state -> replica_state * communication option * replica_timeout list
  val start_client: client_state -> client_state * communication option * client_timeout list
  val gen_workload: client_state -> int -> client_state
  val index_of_replica: replica_state -> int
  val index_of_client: client_state -> int
end

module VR : Protocol_type
