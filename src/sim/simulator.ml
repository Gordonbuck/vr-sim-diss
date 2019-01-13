open Core
open Protocol
open Parameters
open EventList

module Make (P : Protocol_type) 
    (Params : Parameters_type 
     with type replica_timeout = P.replica_timeout 
     with type client_timeout = P.client_timeout) = struct

  module T = SimTime
  module EL = EventHeap

  type sim_event = Crash | Recover

  type 'protocol_state state = { alive : bool; protocol_state: 'protocol_state }
  type replica_state =  P.replica_state state
  type client_state = P.client_state state

  type event = 
    | ReplicaEvent of T.t * int * (replica_state -> replica_state * event list)
    | ClientEvent of T.t * int * (client_state -> client_state * event list)

  let time_of_event e = 
    match e with
    | ReplicaEvent(t, _, _)
    | ClientEvent(t, _, _) -> t

  let compare_events e1 e2 = T.compare (time_of_event e1) (time_of_event e2)

      (* protocol events *)

  let rec build_replica_msg_event t i msg = 
    let t = T.inc t (T.span_of_int (Params.packet_delay ())) in
    ReplicaEvent(t, i, replica_protocol_event t (P.on_replica_message msg))
  and build_client_msg_event t i msg = 
    let t = T.inc t (T.span_of_int (Params.packet_delay ())) in
    ClientEvent(t, i, client_protocol_event t (P.on_client_message msg))
  and build_replica_timeout_event t i timeout =  
    let t = T.inc t (T.span_of_int (Params.time_for_replica_timeout timeout)) in
    ReplicaEvent(t, i, replica_protocol_event t (P.on_replica_timeout timeout))
  and build_client_timeout_event t i timeout = 
    let t = T.inc t (T.span_of_int (Params.time_for_client_timeout timeout)) in
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
    | P.ReplicaMessage(msg) -> List.init (Params.n_replicas) (fun i -> build_replica_msg_event t i msg)
    | P.ClientMessage(msg) -> List.init (Params.n_clients) (fun i -> build_client_msg_event t i msg)

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
    if not state.alive then
      (state, [])
    else
      let (protocol_state, pevents) = comp state.protocol_state in
      let events = protocol_events_to_events t pevents in
      ({state with 
        protocol_state = protocol_state;
       }, events)

  and client_protocol_event t comp state = 
    if not state.alive then
      (state, [])
    else
      let (protocol_state, pevents) = comp state.protocol_state in
      let events = protocol_events_to_events t pevents in
      ({state with 
        protocol_state = protocol_state;
       }, events)

        (* crash events *)

  let crash_replica state = 
    let protocol_state = P.crash_replica state.protocol_state in
    {alive = false; protocol_state = protocol_state;}

  let crash_client state = 
    let protocol_state = P.crash_client state.protocol_state in
    {alive = false; protocol_state = protocol_state;}

  let recover_replica t state = 
    let (protocol_state, pevents) = P.recover_replica state.protocol_state in
    let events = protocol_events_to_events t pevents in
    ({alive = true;
      protocol_state = protocol_state;
     }, events)

  let recover_client t state = 
    let (protocol_state, pevents) = P.recover_client state.protocol_state in
    let events = protocol_events_to_events t pevents in
    ({alive = true;
      protocol_state = protocol_state;
     }, events)

      (* initalization *)

  let gen_replicas n_replicas n_clients = 
    let protocol_states = P.init_replicas n_replicas n_clients in
    List.map protocol_states (fun s -> {alive = true; protocol_state = s})

  let gen_clients n_replicas n_clients workload_sizes = 
    let protocol_states = P.init_clients n_replicas n_clients in
    let protocol_states_opt = List.map2 protocol_states workload_sizes (fun s w -> P.gen_workload s w) in
    match protocol_states_opt with
    | Unequal_lengths -> assert(false)
    | Ok(protocol_states) -> List.map protocol_states (fun s -> {alive = true; protocol_state = s})

  let initial_replica_events t states = 
    let (states, pevents_l) = List.unzip (List.map states (fun s -> 
        let (protocol_state, pevents) = P.start_replica s.protocol_state in
        ({s with protocol_state = protocol_state;}, pevents)
      )) in
    let pevents = List.fold pevents_l ~init:[] ~f:List.append in
    let events = protocol_events_to_events t pevents in
    (states, events)

  let initial_client_events t states = 
    let (states, pevents_l) = List.unzip (List.map states (fun s -> 
        let (protocol_state, pevents) = P.start_client s.protocol_state in
        ({s with protocol_state = protocol_state;}, pevents)
      )) in
    let pevents = List.fold pevents_l ~init:[] ~f:List.append in
    let events = protocol_events_to_events t pevents in
    (states, events)

  let initial_sim_events = []

      (* termination *)

  let should_terminate replicas clients e = 
    match Params.termination with
    | Timelimit(t_int) -> 
      T.compare (time_of_event e) (T.t_of_int t_int) >= 0
    | WorkCompletion -> 
      let protocol_clients = List.map clients (fun c -> c.protocol_state) in
      P.finished_workloads protocol_clients

      (* simulation *)

  let simulate states eventlist i comp = 
    let state_opt = List.nth states i in
    match state_opt with
    | None -> assert(false)
    | Some(state) ->
      let (state, events) = comp state in
      let states = List.mapi states (fun j s -> if j = i then state else s) in
      let eventlist = EL.add_multi eventlist events in
      (states, eventlist)

  let rec sim_loop j replicas clients eventlist = 
    let event_opt = EL.pop eventlist in
    match event_opt with
    | None -> Printf.printf "No more events to simulate, terminating\n"
    | Some(e, eventlist) ->
      if should_terminate replicas clients e then
        Printf.printf "Work completed, terminating\n"
      else
        let (replicas, clients, eventlist) = 
          match e with
          | ReplicaEvent(t, i, comp) -> 
            let (replicas, eventlist) = simulate replicas eventlist i comp in
            (replicas, clients, eventlist)
          | ClientEvent(t, i, comp) -> 
            let (clients, eventlist) = simulate clients eventlist i comp in
            (replicas, clients, eventlist) in
        let protocol_replicas = List.map replicas (fun r -> r.protocol_state) in
        Printf.printf "Simulating event number %n\n" j;
        if P.check_consistency protocol_replicas then
          sim_loop (j+1) replicas clients eventlist
        else
          Printf.printf "Consistency check failed, terminating\n";
          ()

  let run () = 
    let rec inner i = 
      if i > Params.n_iterations then ()
      else
        let replicas = gen_replicas Params.n_replicas Params.n_clients in
        let clients = gen_clients Params.n_replicas Params.n_clients Params.workloads in
        let (replicas, replica_events) = initial_replica_events (T.t_of_int 0) replicas in
        let (clients, client_events) = initial_client_events (T.t_of_int 0) clients in
        let eventlist = EL.add_multi (EL.add_multi (EL.create compare_events) replica_events) client_events in
        Printf.printf "Simulation number %n\n" i;
        sim_loop 1 replicas clients eventlist; 
        inner (i + 1) in
    inner (1)

end
