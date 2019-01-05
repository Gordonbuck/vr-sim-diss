module Event : sig
  type ('time, 'id, 'replica, 'client) t =
    | ReplicaEvent of 'time * 'id * ('time, 'id, 'replica, 'client) replica_comp
    | ClientEvent of 'time * 'id * ('time, 'id, 'replica, 'client) client_comp
    | SimulationEvent of 'time * 'id * sim_comp
  and ('time, 'id, 'replica, 'client) replica_comp = 'replica -> 'replica * ('time, 'id, 'replica, 'client) t list
  and ('time, 'id, 'replica, 'client) client_comp = 'client -> 'client * ('time, 'id, 'replica, 'client) t list
  and sim_comp = Crash | Recover
  val time_of: ('time, 'id, 'replica, 'client) t -> 'time
  val compare: ('time, 'id, 'replica, 'client) t -> ('time, 'id, 'replica, 'client) t -> int
end

module type EventList_type = sig
  type 'event t
  val create: ('event -> 'event -> int) -> 'event t
  val add: 'event t -> 'event -> 'event t
  val pop: 'event t -> ('event * 'event t) option
end

module EventList : EventList_type
