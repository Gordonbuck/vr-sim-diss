open Core

module type Parameters_type = sig 

  type replica_timeout
  type client_timeout
  type termination_type = Timelimit of int | WorkCompletion

  val n_replicas: int
  val n_clients: int
  val n_iterations: int
  val workloads: int list
  val drop_packet: unit -> bool
  val duplicate_packet: unit -> bool
  val packet_delay: unit -> int
  val time_for_replica_timeout: replica_timeout -> int
  val time_for_client_timeout: client_timeout -> int
  val fail_replica: int -> int option
  val fail_client: int -> int option
  val termination: termination_type

end

module VR_test_params = struct

  include VR_Events
  type termination_type = Timelimit of int | WorkCompletion

  let n_replicas = 10

  let n_clients = 3

  let n_iterations = 1

  let workloads = [10; 15; 20]

  let drop_packet () = 
    let i = Random.int 100 in
    if i < 20 then true else false

  let duplicate_packet () = 
    let i = Random.int 100 in
    if i < 20 then true else false

  let packet_delay () = 10

  let time_for_replica_timeout timeout = 
    match timeout with
    | HeartbeatTimeout(_, _) -> 20
    | PrepareTimeout(_, _) -> 30
    | PrimaryTimeout(_, _) -> 60
    | StateTransferTimeout(_, _) -> 50
    | StartViewChangeTimeout(_) -> 30
    | DoViewChangeTimeout(_) -> 30
    | RecoveryTimeout(_) -> 30
    | GetStateTimeout(_, _) -> 30

  let time_for_client_timeout timeout = 
    match timeout with
    | RequestTimeout(_) -> 40
    | ClientRecoveryTimeout(_) -> 30

  let fail_replica i = None

  let fail_client i = None

  let termination = WorkCompletion

end
