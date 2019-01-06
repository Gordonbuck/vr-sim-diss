open Core
open Protocol
open EventList

module Create (P : Protocol_type) = struct

  module T = SimTime
  module EL = EventHeap

  type sim_event = Crash | Recover

  type client_state = { crashed : bool; protocol_state : P.client_state; }
  type replica_state = { crashed : bool; protocol_state : P.replica_state; }

  type event = 
    | ReplicaEvent of T.t * int * (replica_state -> replica_state * event list)
    | ClientEvent of T.t * int * (client_state -> client_state * event list)

  let time_of_event e = 
    match e with
    | ReplicaEvent(t, _, _)
    | ClientEvent(t, _, _) -> t

  let compare_events e1 e2 = T.compare (time_of_event e1) (time_of_event e2)

  type parameters = { msg_delay : T.span; n_replicas : int; n_clients : int; }
  let params = { msg_delay = T.span_of_int 10; n_replicas = 10; n_clients = 10; }

  let protocol_event comp state = (state, [])

  let build_replica_msg_event t i msg = ReplicaEvent(T.inc t params.msg_delay, i, protocol_event (P.on_replica_message msg))
  let build_client_msg_event t i msg = ClientEvent(T.inc t params.msg_delay, i, protocol_event (P.on_client_message msg))

  let msg_to_event t i msg = 
    match msg with
    | P.ReplicaMessage(msg) -> build_replica_msg_event t i msg
    | P.ClientMessage(msg) -> build_client_msg_event t i msg

  let broadcast_msg_to_events t msg = 
    match msg with
    | P.ReplicaMessage(msg) -> List.init params.n_replicas (fun i -> build_replica_msg_event t i msg)
    | P.ClientMessage(msg) -> List.init params.n_clients (fun i -> build_client_msg_event t i msg)

  let rec comm_to_events t comm = 
    match comm with
    | P.Unicast(msg, i) -> [msg_to_event t i msg]
    | P.Broadcast(msg) -> broadcast_msg_to_events t msg
    | P.MultiComm(comms) -> List.fold (List.map comms (comm_to_events t)) ~init:[] ~f:List.append

  let comm_opt_to_events t comm_opt = 
    match comm_opt with
    | None -> []
    | Some(comm) -> comm_to_events t comm
      
  
    

  let replica_timeouts_to_events timeouts i = []
  let client_timeouts_to_events timeouts i = []

  


end














