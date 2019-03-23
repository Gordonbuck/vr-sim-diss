
module type Parameters_type = sig 
  type replica_timeout
  type client_timeout
  type termination_type = Timelimit of float | WorkCompletion

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
end

module VR_test_params : Parameters_type with type replica_timeout = VR_Events.replica_timeout 
  with type client_timeout = VR_Events.client_timeout
