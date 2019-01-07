open Core
open Protocol
open EventList

module Create (P : Protocol_type) = struct

  module T = SimTime
  module EL = EventHeap

  type sim_event = Crash | Recover

  type replica_state =  { crashed : bool; protocol_state: P.replica_state }
  type client_state = { crashed : bool; protocol_state: P.client_state }

  type event = 
    | ReplicaEvent of T.t * int * (replica_state -> replica_state * event list)
    | ClientEvent of T.t * int * (client_state -> client_state * event list)

  let time_of_event e = 
    match e with
    | ReplicaEvent(t, _, _)
    | ClientEvent(t, _, _) -> t

  let compare_events e1 e2 = T.compare (time_of_event e1) (time_of_event e2)

  type parameters = { timeout_delay : T.span; msg_delay : T.span; n_replicas : int; n_clients : int; }
  let params = { timeout_delay = T.span_of_int 10; msg_delay = T.span_of_int 10; n_replicas = 10; n_clients = 10; }

  let rec build_replica_msg_event t i msg = 
    let t = T.inc t params.msg_delay in
    ReplicaEvent(t, i, replica_protocol_event t (P.on_replica_message msg))
  and build_client_msg_event t i msg = 
    let t = T.inc t params.msg_delay in
    ClientEvent(t, i, client_protocol_event t (P.on_client_message msg))
  and build_replica_timeout_event t i timeout =  
    let t = T.inc t params.timeout_delay in
    ReplicaEvent(t, i, replica_protocol_event t (P.on_replica_timeout timeout))
  and build_client_timeout_event t i timeout = 
    let t = T.inc t params.timeout_delay in
    ClientEvent(t, i, client_protocol_event t (P.on_client_timeout timeout))

  and timeout_to_event t timeout = 
    match timeout with
    | P.ReplicaTimeout(timeout, i) -> build_replica_timeout_event t i timeout
    | P.ClientTimeout(timeout, i) -> build_client_timeout_event t i timeout

  and msg_to_event t i msg = 
    match msg with
    | P.ReplicaMessage(msg) -> build_replica_msg_event t i msg
    | P.ClientMessage(msg) -> build_client_msg_event t i msg

  and broadcast_msg_to_events t msg = 
    match msg with
    | P.ReplicaMessage(msg) -> List.init params.n_replicas (fun i -> build_replica_msg_event t i msg)
    | P.ClientMessage(msg) -> List.init params.n_clients (fun i -> build_client_msg_event t i msg)

  and comm_to_events t comm = 
    match comm with
    | P.Unicast(msg, i) -> [msg_to_event t i msg]
    | P.Broadcast(msg) -> broadcast_msg_to_events t msg
    | P.Multicast(msg, indices) -> List.map indices (fun i -> msg_to_event t i msg)

  and protocol_events_to_events t pevents = 
    let rec pete l acc =
      match l with
      | [] -> acc
      | e::l ->
        let new_events = 
          match e with
          | P.Communication(comm) -> comm_to_events t comm
          | P.Timeout(timeout) -> [timeout_to_event t timeout] in
        pete l (new_events@acc) in
    pete pevents []

  and replica_protocol_event t comp state = 
    if state.crashed then
      (state, [])
    else
      let (protocol_state, pevents) = comp state.protocol_state in
      let events = protocol_events_to_events t pevents in
      ({state with 
        protocol_state = protocol_state;
       }, events)

  and client_protocol_event t comp state = 
    if state.crashed then
      (state, [])
    else
      let (protocol_state, pevents) = comp state.protocol_state in
      let events = protocol_events_to_events t pevents in
      ({state with 
        protocol_state = protocol_state;
       }, events)
  
end
