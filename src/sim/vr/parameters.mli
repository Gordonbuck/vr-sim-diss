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

module VR_test_params : Parameters_type
